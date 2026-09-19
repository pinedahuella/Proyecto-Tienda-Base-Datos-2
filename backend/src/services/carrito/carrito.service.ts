import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { pool } from '../../database/postgres';
import { mongoDb } from '../../database/mongo';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorRedis } from '../../helpers/manejar-error-redis';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { esTextoNoVacio } from '../../helpers/validaciones-perfil';
import { validarYCobrarTarjeta } from '../../helpers/validaciones-tarjeta';
import { validarCantidadCarrito } from '../../helpers/validaciones-carrito';
import {
  QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR,
  TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS,
} from '../../helpers/constantes';
import { DefinirCantidadCarritoPeticion } from '../../dto/definir-cantidad-carrito';
import {
  AvisoPrecioCarrito,
  ComprarCarritoPeticion,
  ComprarCarritoRespuesta,
} from '../../dto/comprar-carrito';
import {
  Carrito,
  CarritoLinea,
  LineaCarritoDefinida,
  MotivoNoDisponible,
  ResumenCarrito,
} from '../../models/carrito';
import { METODO_PAGO_TARJETA } from '../../models/metodo-pago';
import { Producto } from '../../models/producto';
import { ProductosService } from '../productos/productos.service';
import { InventarioLimitadoService } from '../inventario-limitado/inventario-limitado.service';
import { EventosService } from '../eventos/eventos.service';

const REGEX_ID = /^\d+$/;

/** Lo que devuelve comprar_carrito() de PostgreSQL, tal cual. */
interface CompraCarritoPostgres {
  id_pedido: number;
  total: string;
  stock: {
    id_oferta: number;
    id_usuario: number;
    id_producto: number;
    id_producto_variante: number;
    stock: number;
  }[];
}

/** Fila cruda de `oferta` + estado + vendedor, para enriquecer el carrito. */
interface FilaOferta {
  id_oferta: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  precio: string;
  stock: number;
  estado_oferta_nombre: string;
  vendedor_usuario: string;
  vendedor_nombre: string;
}

/** Solo lo que hace falta de un producto para pintar una linea del carrito. */
interface ProductoLigero {
  _id: number;
  nombre: string;
  variantes: {
    id_producto_variante: number;
    nombre_variante: string;
    estado: string;
    imagenes: string[];
  }[];
}

/**
 * El carrito de compra, que vive SOLO en Redis (Entrega 2). Reemplaza al
 * carrito viejo, que era una fila de `pedido` en estado `pendiente` en
 * PostgreSQL.
 *
 *
 * La forma
 * ============================================================
 * Una sola clave por cuenta, un HASH:
 *
 *     mesh:carrito:<id_usuario>   HASH   { <id_oferta>: cantidad, ... }
 *
 * El carrito es literalmente un `Map<id_oferta, cantidad>`: la INTENCION
 * ("quiero N de la oferta X"), nada mas. El nombre, el precio, el stock y
 * la imagen NO se guardan aca -- viven en `oferta` (PostgreSQL) y en
 * `productos` (MongoDB), cambian, y una copia en Redis se desactualizaria
 * en segundos. Se resuelven al vuelo en `GET /carrito` o al pagar.
 *
 *
 * Que toca PostgreSQL/Mongo y que no
 * ============================================================
 *   PUT / DELETE /carrito/lineas/:idOferta   -> Redis puro (HSET/HDEL +
 *       EXPIRE). Sin una sola consulta a PostgreSQL. Devuelven un resumen
 *       calculado solo con Redis.
 *   GET /carrito                             -> HGETALL + DOS consultas en
 *       lote (una a `oferta`, una a `productos` de Mongo) para todo el
 *       carrito de una. Es la vista, no el camino de agregar.
 *
 *
 * Como nace y como muere -- sin un paso de "crear"
 * ============================================================
 * No hay ruta para crear un carrito. El primer `HSET` sobre una clave que
 * no existe la crea sola: el carrito nace con el primer producto. Muere
 * solo: TTL de 24 h sin tocarlo, `DEL` tras el checkout, o
 * `DELETE /carrito`. Un carrito sin lineas no existe como clave.
 *
 *
 * De quien es el carrito
 * ============================================================
 * El `id_usuario` sale del token de sesion; la clave es
 * `mesh:carrito:<id_usuario>`. No hay id de carrito que pasar ni guardar en
 * `localStorage`. Dos dispositivos de la misma cuenta comparten el carrito
 * sin hacer nada.
 */
@Injectable()
export class CarritoService {
  private readonly logger = new Logger(CarritoService.name);

  constructor(
    private readonly productosService: ProductosService,
    private readonly inventarioLimitadoService: InventarioLimitadoService,
    private readonly eventosService: EventosService,
  ) {}

  /** TTL del carrito, en segundos: 24 h de INACTIVIDAD (se re-pone en cada toque). */
  static readonly TTL_SEGUNDOS = 60 * 60 * 24;

  /** La clave del carrito de una cuenta en Redis. */
  private clave(idUsuario: string): string {
    return `mesh:carrito:${idUsuario}`;
  }

  /**
   * El carrito completo, enriquecido: cada linea con su nombre, precio
   * actual, stock, subtotal y si se puede comprar. Renueva el TTL (mirar el
   * carrito cuenta como actividad).
   *
   * Dos consultas en lote, sin importar cuantas lineas: una a `oferta` y
   * una a `productos` de Mongo.
   */
  async verCarrito(idUsuario: string): Promise<Carrito> {
    const { cantidades: crudo, tickets } =
      await this.leerHashCompleto(idUsuario);
    const idsOferta = Object.keys(crudo).map(Number);

    if (idsOferta.length === 0) {
      return { lineas: [], total: '0.00', total_lineas: 0, total_items: 0 };
    }

    await this.renovarTtl(idUsuario);

    const ofertas = await this.consultarOfertas(idsOferta);
    const idsProducto = [
      ...new Set([...ofertas.values()].map((o) => Number(o.id_producto_mongo))),
    ];
    const productos = await this.consultarProductos(idsProducto);

    // Async por linea (no un .map sincrono): las lineas de inventario
    // limitado necesitan una consulta mas a Redis (ticketVigente) para
    // saber si la reserva que las respalda sigue viva.
    const lineas: CarritoLinea[] = await Promise.all(
      idsOferta.map(async (idOferta) => {
        const cantidad = crudo[idOferta];
        const oferta = ofertas.get(idOferta);
        const ticket = tickets[idOferta] ?? null;
        const esInventarioLimitado = ticket != null;

        if (oferta == null) {
          // El id de oferta esta en el carrito pero no existe en `oferta`
          // (un PUT con un id inventado). Se muestra como no disponible en
          // vez de desaparecer sin avisar.
          return {
            id_oferta: idOferta,
            cantidad,
            id_producto: 0,
            id_producto_variante: 0,
            nombre_producto: '(oferta no encontrada)',
            nombre_variante: '(oferta no encontrada)',
            imagen: null,
            precio: '0.00',
            subtotal: '0.00',
            vendedor: { usuario: '', nombre: '' },
            stock_disponible: 0,
            disponible: false,
            motivo: 'oferta_no_existe' as const,
            es_inventario_limitado: esInventarioLimitado,
          };
        }

        const idProducto = Number(oferta.id_producto_mongo);
        const idVariante = Number(oferta.id_producto_variante_mongo);
        const producto = productos.get(idProducto);
        const variante = producto?.variantes.find(
          (v) => v.id_producto_variante === idVariante,
        );

        const subtotal = (Number(oferta.precio) * cantidad).toFixed(2);
        let { disponible, motivo } = this.evaluarDisponibilidad(
          oferta,
          cantidad,
          variante?.estado,
        );

        // Para una linea de inventario limitado, el stock de PostgreSQL
        // esta CONGELADO desde que se abrio la venta (sembrar copio el
        // numero una sola vez) -- no refleja lo que de verdad queda en
        // Redis. La disponibilidad real de esta linea es "la reserva
        // sigue viva", no "hay stock en Postgres": si la reserva vencio
        // sola (nadie confirmo ni redimensiono a tiempo), se marca no
        // disponible aunque Postgres todavia diga que hay stock.
        if (esInventarioLimitado && disponible) {
          const vigente = await this.inventarioLimitadoService.ticketVigente(
            idOferta,
            ticket,
          );
          if (!vigente) {
            disponible = false;
            motivo = 'reserva_vencida';
          }
        }

        return {
          id_oferta: idOferta,
          cantidad,
          id_producto: idProducto,
          id_producto_variante: idVariante,
          nombre_producto: producto?.nombre ?? '(producto no encontrado)',
          nombre_variante:
            variante?.nombre_variante ?? '(variante no encontrada)',
          imagen: variante?.imagenes[0] ?? null,
          precio: oferta.precio,
          subtotal,
          vendedor: {
            usuario: oferta.vendedor_usuario,
            nombre: oferta.vendedor_nombre,
          },
          stock_disponible: oferta.stock,
          disponible,
          motivo,
          es_inventario_limitado: esInventarioLimitado,
        };
      }),
    );

    const total = lineas
      .reduce((suma, linea) => suma + Number(linea.subtotal), 0)
      .toFixed(2);
    const totalItems = idsOferta.reduce((suma, id) => suma + crudo[id], 0);

    return {
      lineas,
      total,
      total_lineas: lineas.length,
      total_items: totalItems,
    };
  }

  /**
   * Fija la cantidad ABSOLUTA de una oferta en el carrito (no un +1/-1). Si
   * la clave del carrito no existe, `HSET` la crea. Renueva el TTL.
   *
   * Para una oferta NORMAL sigue siendo Redis puro, sin una sola consulta
   * a PostgreSQL -- el stock se comprueba al pintar el carrito y al pagar,
   * como siempre.
   *
   * Para una oferta de INVENTARIO LIMITADO (se detecta con
   * `existeVentaLimitada`, una sola consulta a Redis, `EXISTS`, tampoco
   * toca Postgres) es la UNICA excepcion a "agregar nunca reserva nada":
   * llama a `redimensionar` (acredita el ticket viejo si esta linea ya
   * tenia uno, y pide la cantidad nueva, las dos cosas en un solo paso
   * atomico -- ver `plan pendiente/redimensionar-reserva.lua`). Si no
   * alcanza, 409 de una vez, ANTES de tocar el carrito -- a diferencia de
   * una oferta normal, que se deja agregar siempre y se avisa recien en
   * `GET /carrito`.
   */
  async definirCantidad(
    idUsuario: string,
    idOfertaParametro: string,
    datos: DefinirCantidadCarritoPeticion,
  ): Promise<LineaCarritoDefinida> {
    const idOferta = this.validarIdOferta(idOfertaParametro);
    const cantidad = validarCantidadCarrito(datos.cantidad);

    const esInventarioLimitado =
      await this.inventarioLimitadoService.existeVentaLimitada(idOferta);

    if (esInventarioLimitado) {
      const ticketViejo = await this.leerTicket(idUsuario, idOferta);
      const resultado = await this.inventarioLimitadoService.redimensionar(
        idOferta,
        idUsuario,
        ticketViejo,
        cantidad,
        TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS,
      );

      if (resultado.resultado === 'AGOTADO') {
        throw new ErrorConflicto(
          `No hay suficiente stock en la venta relampago de la oferta ${idOferta}: pediste ${cantidad} y hay ${resultado.numero} disponibles (contando lo que ya tenias reservado)`,
        );
      }
      if (resultado.resultado === 'TICKET_AJENO') {
        // No deberia pasar en circunstancias normales -- el ticket viejo
        // sale del propio carrito de ESTE usuario. Defensivo: si pasa, es
        // que algo mas toco esa reserva por fuera.
        throw new ErrorConflicto(
          'No se pudo actualizar la reserva de esta oferta',
        );
      }

      try {
        const clave = this.clave(idUsuario);
        await redis.hset(
          clave,
          String(idOferta),
          String(cantidad),
          this.campoTicket(idOferta),
          String(resultado.ticket),
        );
        await redis.expire(clave, CarritoService.TTL_SEGUNDOS);
      } catch (error) {
        manejarErrorRedis(this.logger, error);
      }

      const resumen = await this.resumen(idUsuario);
      return {
        id_oferta: idOferta,
        cantidad,
        es_inventario_limitado: true,
        ...resumen,
      };
    }

    try {
      const clave = this.clave(idUsuario);
      await redis.hset(clave, String(idOferta), String(cantidad));
      // Si esta linea arrastraba un ticket de una venta relampago que ya
      // cerro (`existeVentaLimitada` dio false porque la clave Redis de la
      // oferta ya no existe -> no hay ninguna reserva viva que soltar), se
      // limpia el campo companero. Sin esto la linea seguiria saliendo como
      // `es_inventario_limitado` en `GET /carrito` y el checkout intentaria
      // `confirmar` un ticket muerto. `HDEL` de un campo que no esta es un
      // no-op, asi que va siempre sin comprobar antes.
      await redis.hdel(clave, this.campoTicket(idOferta));
      await redis.expire(clave, CarritoService.TTL_SEGUNDOS);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }

    const resumen = await this.resumen(idUsuario);
    return {
      id_oferta: idOferta,
      cantidad,
      es_inventario_limitado: false,
      ...resumen,
    };
  }

  /**
   * Quita una oferta del carrito. Idempotente: si la linea no estaba,
   * responde igual. Si era la ultima linea, Redis borra la clave sola (un
   * HASH sin campos deja de existir).
   *
   * Si la linea era de inventario limitado (tenia ticket guardado), suelta
   * la reserva con `devolver` ANTES de quitarla del carrito -- si no, la
   * unidad quedaria "reservada" en Redis hasta que venza sola, en vez de
   * liberarse al toque para el siguiente comprador. `devolver` sobre un
   * ticket que ya vencio o ya se confirmo no es un error (contesta
   * `SIN_TICKET`/`TICKET_AJENO`, no lanza nada) -- solo un fallo real de
   * conexion a Redis detiene esto.
   */
  async quitarLinea(
    idUsuario: string,
    idOfertaParametro: string,
  ): Promise<ResumenCarrito> {
    const idOferta = this.validarIdOferta(idOfertaParametro);

    const ticket = await this.leerTicket(idUsuario, idOferta);
    if (ticket != null) {
      await this.inventarioLimitadoService.devolver(
        idOferta,
        idUsuario,
        ticket,
      );
    }

    try {
      const clave = this.clave(idUsuario);
      await redis.hdel(clave, String(idOferta), this.campoTicket(idOferta));
      // Si quedan lineas, se renueva el TTL. Si el hash quedo vacio, la
      // clave ya no existe y EXPIRE no hace nada (devuelve 0).
      await redis.expire(clave, CarritoService.TTL_SEGUNDOS);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }

    return this.resumen(idUsuario);
  }

  /**
   * Vacia el carrito de una cuenta: un `DEL` de la clave. Idempotente.
   *
   * `soltarReservas` decide que pasa con las reservas de inventario
   * limitado que hubiera en el carrito (campos `t:<id_oferta>`):
   *
   *   - `true` (vaciado MANUAL, `DELETE /carrito`): antes del `DEL` se
   *     recorren esos tickets y se devuelven (op `devolver`), para que sus
   *     unidades vuelvan al contador de Redis en el acto en vez de esperar
   *     a que venza cada reserva (`TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS`).
   *   - `false` (vaciado tras un checkout correcto, desde `comprarCarrito`):
   *     esas reservas YA se confirmaron (op `confirmar`) una por una antes
   *     de llegar aca -- devolverlas soltaria unidades recien vendidas.
   */
  async vaciar(idUsuario: string, soltarReservas = false): Promise<void> {
    if (soltarReservas) {
      const { tickets } = await this.leerHashCompleto(idUsuario);
      await this.devolverReservas(
        idUsuario,
        Object.entries(tickets).map(([idOferta, ticket]) => ({
          idOferta: Number(idOferta),
          ticket,
        })),
      );
    }

    try {
      await redis.del(this.clave(idUsuario));
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * El checkout. Lee el carrito, comprueba que todo se pueda comprar, y lo
   * compra llamando a `comprar_carrito()` de PostgreSQL
   * (`migrations/012_comprar_carrito.sql`), que crea el pedido, le mete
   * todas las lineas y lo compra en **una sola transaccion** -- un fallo no
   * deja ni pedido ni lineas a medias.
   *
   * Orden:
   *   1. `verCarrito()` -> lineas enriquecidas (nombre, precio, stock,
   *      disponibilidad). Carrito vacio -> 409.
   *   2. Si alguna linea no se puede comprar (oferta pausada, variante
   *      desactivada, sin stock, o un id inventado) -> 409 con la lista,
   *      SIEMPRE (no hay forma de saltarse esto). Segun el interruptor
   *      `QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR`
   *      (`helpers/constantes.ts`), esas lineas ademas se quitan del
   *      carrito en Redis antes de responder, o se dejan intactas. Es un
   *      chequeo previo para dar un buen mensaje; la verdad la vuelve a
   *      comprobar `comprar_carrito()` dentro de su transaccion, con
   *      `FOR UPDATE`.
   *   3. Si no hay bloqueantes, se compara el `precio_visto` que mando el
   *      cliente (por linea, en `lineas_precio_visto`) contra el precio
   *      actual. Si alguno discrepa y `confirmar_cambios` no vino en
   *      `true` -> se devuelve `{comprado: false, avisos}` (sin tocar
   *      nada); reenviar con `confirmar_cambios: true` deja pasar la
   *      compra al precio de hoy. Mismo criterio que
   *      `PedidosCompradorService.revisarCambiosAntesDeComprar`.
   *   4. Se resuelve `id_direccion_historial` (exige que la direccion sea de
   *      la cuenta) y, si el metodo es tarjeta, se valida/cobra el mock.
   *   5. `SELECT comprar_carrito(...)` con las lineas ya con nombre.
   *   6. `DEL` del carrito y recalculo de los campos calculados de Mongo de
   *      cada producto tocado. Si el recalculo falla, la compra NO se
   *      deshace: solo queda una tarjeta del catalogo desfasada un rato
   *      (mismo criterio que `comprarPedido`).
   */
  async comprarCarrito(
    idUsuario: string,
    datos: ComprarCarritoPeticion,
    ip: string,
  ): Promise<ComprarCarritoRespuesta> {
    // Un candado corto por cuenta cierra el hueco del doble submit (dos
    // POST /carrito/comprar identicos y concurrentes creaban dos pedidos,
    // cobrando dos veces). Ver conCandadoCheckout.
    return this.conCandadoCheckout(idUsuario, () =>
      this.ejecutarCompraCarrito(idUsuario, datos, ip),
    );
  }

  private async ejecutarCompraCarrito(
    idUsuario: string,
    datos: ComprarCarritoPeticion,
    ip: string,
  ): Promise<ComprarCarritoRespuesta> {
    if (!esTextoNoVacio(datos.metodo_pago)) {
      throw new ErrorValidacion('El metodo_pago es obligatorio');
    }
    const idDireccion = this.resolverIdDireccion(datos.id_direccion);

    const carrito = await this.verCarrito(idUsuario);
    if (carrito.lineas.length === 0) {
      throw new ErrorConflicto('El carrito esta vacio');
    }

    // Las lineas de inventario limitado que traen una reserva viva en Redis
    // (campo `t:<id_oferta>` del hash), con su numero de ticket. Se leen
    // ANTES de comprar porque el `vaciar()` del final borra el hash del
    // carrito -- y con el, los tickets: despues de pagar hay que CONFIRMAR
    // cada uno (op `confirmar` de `redis/inventario_limitado.lua`), y si el
    // pago no se concreta, DEVOLVERLO. Es el paso 4 de
    // `plan pendiente/inventario-limitado.md`.
    const lineasConReserva = await this.leerLineasConReserva(
      idUsuario,
      carrito.lineas,
    );

    const lineasBloqueantes = carrito.lineas.filter(
      (linea) => !linea.disponible,
    );
    if (lineasBloqueantes.length > 0) {
      if (QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR) {
        await this.quitarLineasDelCarrito(
          idUsuario,
          lineasBloqueantes.map((linea) => linea.id_oferta),
        );
      }
      const mensaje = lineasBloqueantes
        .map(
          (linea) =>
            `"${linea.nombre_variante}" ${this.motivoATexto(linea.motivo)}`,
        )
        .join('; ');
      throw new ErrorConflicto(mensaje);
    }

    const avisos = this.detectarAvisosPrecio(
      carrito.lineas,
      datos.lineas_precio_visto,
    );
    if (avisos.length > 0 && datos.confirmar_cambios !== true) {
      return { comprado: false, avisos };
    }

    const idDireccionHistorial = await this.resolverDireccionHistorial(
      idUsuario,
      idDireccion,
    );

    if (datos.metodo_pago === METODO_PAGO_TARJETA) {
      validarYCobrarTarjeta(datos.tarjeta);
    }

    // Las lineas en el formato que espera agregar_linea (dentro de
    // comprar_carrito). El nombre del producto/variante ya lo resolvio
    // verCarrito desde Mongo; el del vendedor lo pone la propia funcion.
    const lineas = carrito.lineas.map((linea) => ({
      id_oferta: linea.id_oferta,
      cantidad: linea.cantidad,
      id_producto: linea.id_producto,
      id_producto_variante: linea.id_producto_variante,
      nombre_producto: linea.nombre_producto,
      nombre_variante: linea.nombre_variante,
    }));

    let compra: CompraCarritoPostgres;
    try {
      const resultado = await pool.query<{
        comprar_carrito: CompraCarritoPostgres;
      }>('SELECT comprar_carrito($1, $2, $3::jsonb, $4)', [
        idUsuario,
        idDireccionHistorial,
        JSON.stringify(lineas),
        datos.metodo_pago,
      ]);
      compra = resultado.rows[0].comprar_carrito;
    } catch (error) {
      // La oferta se pauso / se agoto entre verCarrito y esta llamada:
      // comprar_carrito lo rechaza y no queda nada escrito. Como el pago no
      // se concreto, se sueltan las reservas de inventario limitado que se
      // habian tomado -- sus unidades vuelven al contador de Redis en el
      // acto, en vez de esperar los 15 min del TTL de cada reserva.
      await this.devolverReservas(idUsuario, lineasConReserva);
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    }

    // El pago paso: cada reserva de inventario limitado pasa de "reservada"
    // a "vendida" (op `confirmar`). Best-effort -- la venta ya esta cerrada
    // en PostgreSQL y un fallo de Redis aca no la deshace (ver
    // confirmarReservas).
    await this.confirmarReservas(idUsuario, lineasConReserva);

    await this.vaciar(idUsuario);

    // Evento de analitica en ClickHouse (plan pendiente/eventos-clickhouse.md).
    // Fire-and-forget, SIN `await`: si ClickHouse esta caido o tarda, la
    // compra ya quedo cerrada en PostgreSQL y no debe verse afectada -- ver
    // `EventosService.registrarCompra`, que nunca lanza. Una fila por linea
    // del pedido, todas en un solo INSERT.
    void this.eventosService.registrarCompra({
      idUsuario,
      idPedido: compra.id_pedido,
      ip,
      lineas: lineas.map((linea) => ({
        idProducto: linea.id_producto,
        idOferta: linea.id_oferta,
        cantidad: linea.cantidad,
      })),
    });

    const idsProducto = compra.stock.map((linea) => linea.id_producto);
    await this.productosService.recalcularCamposCalculados(idsProducto);

    return {
      comprado: true,
      id_pedido: compra.id_pedido,
      total: compra.total,
      stock: compra.stock,
    };
  }

  // ---------------------------------------------------------------------
  // Privados
  // ---------------------------------------------------------------------

  /**
   * Corre `fn` bajo un candado corto en Redis exclusivo del checkout de
   * esta cuenta (`mesh:checkout:<id_usuario>`). Si ya hay una compra en
   * curso para la misma cuenta, corta con 409 sin tocar nada.
   *
   * Cierra el hueco del doble submit: dos `POST /carrito/comprar`
   * identicos y concurrentes leian los dos el carrito lleno ANTES de que
   * ninguno lo vaciara, y cada uno creaba su propio pedido -- cobrando dos
   * veces. `SET ... NX` es atomico (Redis atiende un comando a la vez),
   * asi que de dos peticiones que llegan juntas solo una consigue el
   * candado; la otra ni siquiera llega a leer el carrito.
   *
   * El candado vence solo a los 30 s (`EX`) por si el proceso muere a
   * mitad del checkout -- un `comprar_carrito()` normal tarda muucho menos.
   * El `finally` lo suelta en el camino feliz y en el de error; si ese
   * `DEL` fallara, el `EX` lo limpia igual.
   */
  private async conCandadoCheckout<T>(
    idUsuario: string,
    fn: () => Promise<T>,
  ): Promise<T> {
    const clave = `mesh:checkout:${idUsuario}`;

    let obtenido: string | null = null;
    try {
      obtenido = await redis.set(clave, '1', 'EX', 30, 'NX');
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }

    if (obtenido == null) {
      throw new ErrorConflicto(
        'Ya tienes una compra en curso, espera un momento antes de reintentar',
      );
    }

    try {
      return await fn();
    } finally {
      try {
        await redis.del(clave);
      } catch (error) {
        this.logger.warn(
          `No se pudo soltar el candado de checkout de ${idUsuario} (vence solo en 30 s): ` +
            (error instanceof Error ? error.message : String(error)),
        );
      }
    }
  }

  private validarIdOferta(valor: string): number {
    if (!REGEX_ID.test(valor)) {
      throw new ErrorValidacion('El id no es valido');
    }
    return Number(valor);
  }

  /** El HASH del carrito como `{ id_oferta: cantidad }`, filtrando basura. */
  private async leerHash(idUsuario: string): Promise<Record<number, number>> {
    const { cantidades } = await this.leerHashCompleto(idUsuario);
    return cantidades;
  }

  /**
   * El HASH del carrito completo, separado en dos mapas: las cantidades
   * normales (`<id_oferta>: cantidad`) y los tickets de inventario
   * limitado (`t:<id_oferta>: ticket`). Son campos DEL MISMO hash de
   * Redis -- mismo truco que usa `inventario_limitado.lua` para no
   * necesitar una clave nueva por cada reserva (ver ese archivo).
   */
  private async leerHashCompleto(idUsuario: string): Promise<{
    cantidades: Record<number, number>;
    tickets: Record<number, number>;
  }> {
    try {
      const crudo = await redis.hgetall(this.clave(idUsuario));
      const cantidades: Record<number, number> = {};
      const tickets: Record<number, number> = {};

      for (const [campo, valor] of Object.entries(crudo)) {
        if (campo.startsWith('t:')) {
          const idOferta = Number(campo.slice(2));
          const ticket = Number(valor);
          if (Number.isInteger(idOferta) && Number.isInteger(ticket)) {
            tickets[idOferta] = ticket;
          }
          continue;
        }
        const id = Number(campo);
        const cantidad = Number(valor);
        if (
          Number.isInteger(id) &&
          Number.isInteger(cantidad) &&
          cantidad > 0
        ) {
          cantidades[id] = cantidad;
        }
      }
      return { cantidades, tickets };
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /** El nombre del campo companero (dentro del mismo HASH del carrito) que guarda el ticket de una linea de inventario limitado. */
  private campoTicket(idOferta: number): string {
    return `t:${idOferta}`;
  }

  /** El ticket guardado para esta linea, o `null` si no tiene (oferta normal, o nunca tuvo). */
  private async leerTicket(
    idUsuario: string,
    idOferta: number,
  ): Promise<number | null> {
    try {
      const valor = await redis.hget(
        this.clave(idUsuario),
        this.campoTicket(idOferta),
      );
      return valor == null ? null : Number(valor);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /** Resumen ligero (solo Redis) para las respuestas de PUT/DELETE. */
  private async resumen(idUsuario: string): Promise<ResumenCarrito> {
    const mapa = await this.leerHash(idUsuario);
    const ids = Object.keys(mapa).map(Number);
    return {
      total_lineas: ids.length,
      total_items: ids.reduce((suma, id) => suma + mapa[id], 0),
    };
  }

  /**
   * `HDEL` de una o mas lineas del carrito -- usado solo cuando
   * `QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR` esta en `true` y el checkout
   * encontro lineas que ya no se pueden comprar. La compra de todos modos
   * se rechaza (409); esto solo deja el carrito limpio para el proximo
   * intento.
   *
   * Tambien borra el campo ticket companero (`t:<id_oferta>`) de cada
   * linea, si tenia -- sin esto, quedaria un ticket huerfano en el
   * carrito, apuntando a una linea que ya no esta. Y si esa linea todavia
   * tenia una reserva de inventario limitado viva (por ejemplo, la oferta
   * se pauso pero su venta relampago sigue abierta en Redis), se suelta
   * con `devolver` antes de quitarla -- si no, la reserva quedaria colgada
   * hasta que venza su TTL. Una reserva ya vencida (`reserva_vencida`)
   * contesta `SIN_TICKET` sin efecto, no es un error.
   */
  private async quitarLineasDelCarrito(
    idUsuario: string,
    idsOferta: number[],
  ): Promise<void> {
    const { tickets } = await this.leerHashCompleto(idUsuario);
    const conReserva = idsOferta
      .filter((id) => tickets[id] != null)
      .map((id) => ({ idOferta: id, ticket: tickets[id] }));
    if (conReserva.length > 0) {
      await this.devolverReservas(idUsuario, conReserva);
    }

    try {
      const campos = idsOferta.flatMap((id) => [
        String(id),
        this.campoTicket(id),
      ]);
      await redis.hdel(this.clave(idUsuario), ...campos);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * De las lineas del carrito, las de inventario limitado que tienen una
   * reserva viva (campo `t:<id_oferta>` en el hash) junto con su numero de
   * ticket. Una sola lectura del hash (`HGETALL`), barata porque el
   * carrito es chico.
   */
  private async leerLineasConReserva(
    idUsuario: string,
    lineas: CarritoLinea[],
  ): Promise<{ idOferta: number; ticket: number }[]> {
    const { tickets } = await this.leerHashCompleto(idUsuario);
    return lineas
      .filter((linea) => tickets[linea.id_oferta] != null)
      .map((linea) => ({
        idOferta: linea.id_oferta,
        ticket: tickets[linea.id_oferta],
      }));
  }

  /**
   * Tras un pago exitoso, marca como vendidas (op `confirmar` de
   * `redis/inventario_limitado.lua`) las reservas de inventario limitado
   * del carrito.
   *
   * Best-effort a proposito: cuando esto corre, `comprar_carrito()` ya
   * cerro la venta en PostgreSQL, que es el libro contable real (con su
   * `FOR UPDATE`). Si `confirmar` falla aca -- Redis caido, o el ticket ya
   * vencio -- NO se deshace la compra: se registra y se sigue. Una reserva
   * que quedo sin confirmar vence sola a los 15 min y `cosechar` devuelve
   * su unidad al contador de Redis; es un desajuste chico y acotado entre
   * los dos contadores, no una sobreventa, y `revertir` borra las claves
   * de Redis cuando la venta cierra. Mismo criterio que el recalculo de
   * Mongo de mas abajo.
   */
  private async confirmarReservas(
    idUsuario: string,
    lineas: { idOferta: number; ticket: number }[],
  ): Promise<void> {
    for (const { idOferta, ticket } of lineas) {
      try {
        const { resultado } = await this.inventarioLimitadoService.confirmar(
          idOferta,
          idUsuario,
          ticket,
        );
        if (resultado !== 'CONFIRMADO') {
          this.logger.warn(
            `Reserva de inventario limitado no confirmada (oferta ${idOferta}, ticket ${ticket}): ${resultado}. La compra ya se concreto en PostgreSQL.`,
          );
        }
      } catch (error) {
        this.logger.error(
          `No se pudo confirmar la reserva de inventario limitado (oferta ${idOferta}, ticket ${ticket}); la compra ya se concreto: ` +
            (error instanceof Error ? error.message : String(error)),
        );
      }
    }
  }

  /**
   * El pago no se concreto: suelta (op `devolver`) las reservas de
   * inventario limitado que se habian tomado, para que sus unidades
   * vuelvan al contador en el acto. Best-effort y nunca lanza: ya estamos
   * en el camino de error (o de vaciado manual), y el 409/503 original es
   * el que tiene que llegar al cliente. Si `devolver` falla, la reserva
   * vence sola igual a los 15 min.
   */
  private async devolverReservas(
    idUsuario: string,
    lineas: { idOferta: number; ticket: number }[],
  ): Promise<void> {
    for (const { idOferta, ticket } of lineas) {
      try {
        await this.inventarioLimitadoService.devolver(
          idOferta,
          idUsuario,
          ticket,
        );
      } catch (error) {
        this.logger.error(
          `No se pudo devolver la reserva de inventario limitado (oferta ${idOferta}, ticket ${ticket}): ` +
            (error instanceof Error ? error.message : String(error)),
        );
      }
    }
  }

  /**
   * Compara el `precio_visto` que mando el cliente por linea (lo que le
   * mostro el ultimo `GET /carrito`) contra el precio actual de esa misma
   * linea. Texto contra texto (los dos `numeric(12,2)` formateados igual
   * por PostgreSQL) -- exacto, sin el redondeo binario de comparar como
   * numero de JavaScript. Una linea que el cliente no menciono en
   * `lineas_precio_visto` no genera aviso: no hay nada que comparar.
   */
  private detectarAvisosPrecio(
    lineas: CarritoLinea[],
    lineasVisto: ComprarCarritoPeticion['lineas_precio_visto'],
  ): AvisoPrecioCarrito[] {
    if (lineasVisto == null || lineasVisto.length === 0) {
      return [];
    }
    const precioVistoPorOferta = new Map(
      lineasVisto.map((linea) => [linea.id_oferta, linea.precio_visto]),
    );

    const avisos: AvisoPrecioCarrito[] = [];
    for (const linea of lineas) {
      const precioVisto = precioVistoPorOferta.get(linea.id_oferta);
      if (precioVisto != null && precioVisto !== linea.precio) {
        avisos.push({
          id_oferta: linea.id_oferta,
          nombre_producto: linea.nombre_producto,
          nombre_variante: linea.nombre_variante,
          precio_visto: precioVisto,
          precio_actual: linea.precio,
        });
      }
    }
    return avisos;
  }

  private async renovarTtl(idUsuario: string): Promise<void> {
    try {
      await redis.expire(this.clave(idUsuario), CarritoService.TTL_SEGUNDOS);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  private evaluarDisponibilidad(
    oferta: FilaOferta,
    cantidad: number,
    estadoVariante: string | undefined,
  ): { disponible: boolean; motivo: MotivoNoDisponible | null } {
    if (oferta.estado_oferta_nombre !== 'activa') {
      return { disponible: false, motivo: 'oferta_no_disponible' };
    }
    // La variante puede haberse desactivado en el catalogo despues de
    // agregarla. Si el producto no aparece en Mongo, `estadoVariante` es
    // undefined y se deja pasar (el nombre ya sale como "(no encontrada)").
    if (estadoVariante != null && estadoVariante !== 'activa') {
      return { disponible: false, motivo: 'variante_no_disponible' };
    }
    if (oferta.stock <= 0) {
      return { disponible: false, motivo: 'agotado' };
    }
    if (oferta.stock < cantidad) {
      return { disponible: false, motivo: 'stock_insuficiente' };
    }
    return { disponible: true, motivo: null };
  }

  private async consultarOfertas(
    idsOferta: number[],
  ): Promise<Map<number, FilaOferta>> {
    try {
      const resultado = await pool.query<FilaOferta>(
        `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.stock, eo.estado_oferta_nombre,
                u.usuario AS vendedor_usuario,
                u.nombre || COALESCE(' ' || u.apellido, '') AS vendedor_nombre
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
           JOIN usuarios u ON u.id_usuario = o.id_usuario
          WHERE o.id_oferta = ANY($1::bigint[])`,
        [idsOferta],
      );
      return new Map(
        resultado.rows.map((fila) => [Number(fila.id_oferta), fila]),
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async consultarProductos(
    idsProducto: number[],
  ): Promise<Map<number, ProductoLigero>> {
    try {
      const docs = await mongoDb
        .collection<Producto>('productos')
        .find<ProductoLigero>(
          { _id: { $in: idsProducto } },
          {
            projection: {
              _id: 1,
              nombre: 1,
              'variantes.id_producto_variante': 1,
              'variantes.nombre_variante': 1,
              'variantes.estado': 1,
              'variantes.imagenes': 1,
            },
          },
        )
        .toArray();
      return new Map(docs.map((doc) => [doc._id, doc]));
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /** Un `motivo` de no-disponible, en texto para el mensaje de 409. */
  private motivoATexto(motivo: MotivoNoDisponible | null): string {
    switch (motivo) {
      case 'oferta_no_disponible':
        return 'ya no esta disponible';
      case 'variante_no_disponible':
        return 'ya no esta disponible en el catalogo';
      case 'agotado':
        return 'esta agotada';
      case 'stock_insuficiente':
        return 'no tiene stock suficiente';
      case 'oferta_no_existe':
        return 'ya no existe';
      case 'reserva_vencida':
        return 'era una venta relampago y la reserva ya vencio';
      default:
        return 'no se puede comprar';
    }
  }

  /**
   * Acepta el `id_direccion` como number o como el string que devuelve
   * GET /direccion-usuario (es un bigint y el driver pg lo da como texto).
   * Mismo criterio que PedidosCompradorService.
   */
  private resolverIdDireccion(valor: number | string): number {
    const id =
      typeof valor === 'string' && /^\d+$/.test(valor) ? Number(valor) : valor;
    if (typeof id !== 'number' || !Number.isInteger(id) || id <= 0) {
      throw new ErrorValidacion(
        'El id_direccion es obligatorio y debe ser un numero entero mayor a 0',
      );
    }
    return id;
  }

  /**
   * La version mas reciente de esa direccion en `direccion_historial`.
   * Exige que sea de la cuenta logueada -- una direccion ajena da el mismo
   * 404 que una que no existe. Mismo criterio y misma consulta que
   * PedidosCompradorService.
   */
  private async resolverDireccionHistorial(
    idUsuario: string,
    idDireccion: number,
  ): Promise<string> {
    try {
      const resultado = await pool.query<{ id_direccion_historial: string }>(
        `SELECT dh.id_direccion_historial
           FROM direccion_historial dh
           JOIN direcciones d ON d.id_direccion = dh.id_direccion
          WHERE dh.id_direccion = $1 AND d.id_usuario = $2
          ORDER BY dh.fecha_creacion DESC
          LIMIT 1`,
        [idDireccion, idUsuario],
      );
      const historial = resultado.rows[0];
      if (historial == null) {
        throw new ErrorNoEncontrado('No existe una direccion con ese id');
      }
      return historial.id_direccion_historial;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * 23503 (foreign_key_violation) y 23514 (check_violation): los dos codigos
   * con los que `crear_pedido` / `agregar_linea` / `comprar_pedido` levantan
   * sus errores de negocio (oferta inexistente, no activa, sin stock,
   * direccion ajena, metodo de pago invalido). Mismo criterio que
   * PedidosCompradorService.
   */
  private esErrorDeNegocio(error: unknown): boolean {
    const codigo = (error as { code?: string } | undefined)?.code;
    return codigo === '23503' || codigo === '23514';
  }
}
