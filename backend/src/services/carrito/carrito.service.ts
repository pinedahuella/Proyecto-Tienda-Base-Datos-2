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
import { DefinirCantidadCarritoPeticion } from '../../dto/definir-cantidad-carrito';
import {
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

  constructor(private readonly productosService: ProductosService) {}

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
    const crudo = await this.leerHash(idUsuario);
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

    const lineas: CarritoLinea[] = idsOferta.map((idOferta) => {
      const cantidad = crudo[idOferta];
      const oferta = ofertas.get(idOferta);

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
          motivo: 'oferta_no_existe',
        };
      }

      const idProducto = Number(oferta.id_producto_mongo);
      const idVariante = Number(oferta.id_producto_variante_mongo);
      const producto = productos.get(idProducto);
      const variante = producto?.variantes.find(
        (v) => v.id_producto_variante === idVariante,
      );

      const subtotal = (Number(oferta.precio) * cantidad).toFixed(2);
      const { disponible, motivo } = this.evaluarDisponibilidad(
        oferta,
        cantidad,
        variante?.estado,
      );

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
      };
    });

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
   * la clave del carrito no existe, `HSET` la crea. Renueva el TTL. Redis
   * puro: ninguna consulta a PostgreSQL -- la oferta y su stock se
   * comprueban al pintar el carrito y al pagar.
   */
  async definirCantidad(
    idUsuario: string,
    idOfertaParametro: string,
    datos: DefinirCantidadCarritoPeticion,
  ): Promise<LineaCarritoDefinida> {
    const idOferta = this.validarIdOferta(idOfertaParametro);
    const cantidad = validarCantidadCarrito(datos.cantidad);

    try {
      const clave = this.clave(idUsuario);
      await redis.hset(clave, String(idOferta), String(cantidad));
      await redis.expire(clave, CarritoService.TTL_SEGUNDOS);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }

    const resumen = await this.resumen(idUsuario);
    return { id_oferta: idOferta, cantidad, ...resumen };
  }

  /**
   * Quita una oferta del carrito. Idempotente: si la linea no estaba,
   * responde igual. Si era la ultima linea, Redis borra la clave sola (un
   * HASH sin campos deja de existir).
   */
  async quitarLinea(
    idUsuario: string,
    idOfertaParametro: string,
  ): Promise<ResumenCarrito> {
    const idOferta = this.validarIdOferta(idOfertaParametro);

    try {
      const clave = this.clave(idUsuario);
      await redis.hdel(clave, String(idOferta));
      // Si quedan lineas, se renueva el TTL. Si el hash quedo vacio, la
      // clave ya no existe y EXPIRE no hace nada (devuelve 0).
      await redis.expire(clave, CarritoService.TTL_SEGUNDOS);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }

    return this.resumen(idUsuario);
  }

  /**
   * Vacia el carrito de una cuenta: un `DEL` de la clave. Se usa desde
   * `DELETE /carrito` y despues de un checkout correcto. Idempotente.
   */
  async vaciar(idUsuario: string): Promise<void> {
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
   *      desactivada, sin stock, o un id inventado) -> 409 con la lista, sin
   *      tocar nada. Es un chequeo previo para dar un buen mensaje; la
   *      verdad la vuelve a comprobar `comprar_carrito()` dentro de su
   *      transaccion, con `FOR UPDATE`.
   *   3. Se resuelve `id_direccion_historial` (exige que la direccion sea de
   *      la cuenta) y, si el metodo es tarjeta, se valida/cobra el mock.
   *   4. `SELECT comprar_carrito(...)` con las lineas ya con nombre.
   *   5. `DEL` del carrito y recalculo de los campos calculados de Mongo de
   *      cada producto tocado. Si el recalculo falla, la compra NO se
   *      deshace: solo queda una tarjeta del catalogo desfasada un rato
   *      (mismo criterio que `comprarPedido`).
   *
   * El precio que se cobra es el del momento de pagar (el que muestra
   * `GET /carrito`), porque el carrito de Redis no guarda el precio visto
   * -- ver el DTO y `endpoints-carrito.md`.
   */
  async comprarCarrito(
    idUsuario: string,
    datos: ComprarCarritoPeticion,
  ): Promise<ComprarCarritoRespuesta> {
    if (!esTextoNoVacio(datos.metodo_pago)) {
      throw new ErrorValidacion('El metodo_pago es obligatorio');
    }
    const idDireccion = this.resolverIdDireccion(datos.id_direccion);

    const carrito = await this.verCarrito(idUsuario);
    if (carrito.lineas.length === 0) {
      throw new ErrorConflicto('El carrito esta vacio');
    }

    const bloqueantes = carrito.lineas
      .filter((linea) => !linea.disponible)
      .map(
        (linea) =>
          `"${linea.nombre_variante}" ${this.motivoATexto(linea.motivo)}`,
      );
    if (bloqueantes.length > 0) {
      throw new ErrorConflicto(bloqueantes.join('; '));
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
      // comprar_carrito lo rechaza y no queda nada escrito.
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    }

    await this.vaciar(idUsuario);

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

  private validarIdOferta(valor: string): number {
    if (!REGEX_ID.test(valor)) {
      throw new ErrorValidacion('El id no es valido');
    }
    return Number(valor);
  }

  /** El HASH del carrito como `{ id_oferta: cantidad }`, filtrando basura. */
  private async leerHash(idUsuario: string): Promise<Record<number, number>> {
    try {
      const crudo = await redis.hgetall(this.clave(idUsuario));
      const mapa: Record<number, number> = {};
      for (const [campo, valor] of Object.entries(crudo)) {
        const id = Number(campo);
        const cantidad = Number(valor);
        if (
          Number.isInteger(id) &&
          Number.isInteger(cantidad) &&
          cantidad > 0
        ) {
          mapa[id] = cantidad;
        }
      }
      return mapa;
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
