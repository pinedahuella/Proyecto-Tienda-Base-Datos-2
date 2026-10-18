import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import {
  ErrorConexion,
  ErrorConexionRedis,
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorPago,
  ErrorValidacion,
} from '../../helpers/errores';
import { esRedisInalcanzable } from '../../helpers/manejar-error-redis';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
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
import type { StockResultanteOferta } from '../../dto/comprar-pedido';
import {
  Carrito,
  CarritoLinea,
  LineaCarritoDefinida,
  MotivoNoDisponible,
  ResumenCarrito,
} from '../../models/carrito';
import { METODO_PAGO_TARJETA } from '../../models/metodo-pago';
import { ProductosService } from '../productos/productos.service';
import { InventarioLimitadoService } from '../inventario-limitado/inventario-limitado.service';
import { EventosService } from '../eventos/eventos.service';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';
import {
  CarritoPostgres,
  CarritoPostgresService,
  ConflictoCapacidad,
  ConflictoVersion,
  LineaCarritoPostgres,
  LineaDeseada,
  VIDA_CARRITO_SEGUNDOS,
} from './carrito-postgres.service';
import {
  CarritoRedisService,
  HashCarrito,
  LineaCarritoRedis,
} from './carrito-redis.service';

const REGEX_ID = /^\d+$/;

/** Cada cuanto, como mucho, ver el carrito renueva el reloj de PostgreSQL. */
const TOCAR_POSTGRES_CADA_MS = 5 * 60 * 1000;

const MENSAJE_DESINCRONIZADO =
  'Tu carrito no quedo guardado del todo: sincronizalo (POST /carrito/sincronizar) y revisalo antes de comprar';

/** Fila de `oferta` + estado + vendedor + catalogo, para pintar y cobrar una linea. */
interface FilaOferta {
  id_oferta: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  /** El precio de LISTA, sin descuento -- ver `precio_final`. */
  precio: string;
  porcentaje_descuento: string | null;
  /** El precio que de verdad se cobra/muestra, ya calculado por la consulta. */
  precio_final: string;
  stock: number;
  estado_oferta_nombre: string;
  vendedor_usuario: string;
  vendedor_nombre: string;
  /**
   * Del catalogo copiado a PostgreSQL (`producto_catalogo` /
   * `variante_catalogo`, LEFT JOIN): NULL si esa variante todavia no esta
   * en la copia. `imagen` es solo la portada.
   */
  nombre_producto: string | null;
  nombre_variante: string | null;
  estado_variante: string | null;
  imagen: string | null;
  /** La fila de `precio_historial` vigente: la que se guarda con la linea. */
  id_precio_historial: string | null;
  /** Hay una venta relampago abierta y sin vencer (PostgreSQL decide, no Redis). */
  venta_vigente: boolean;
}

/** La replica pendiente de una cuenta: una sola a la vez, y otra si algo cambio mientras corria. */
interface ReplicaEnCurso {
  promesa: Promise<void>;
  otraVez: boolean;
}

/**
 * El carrito de compra. Directiva del profesor: **Redis nunca es la fuente de
 * verdad**. Ver `elementos Generales/plan pendiente/carrito-postgres-verdad.md`.
 *
 *
 * Las dos copias
 * ============================================================
 *   Redis       `mesh:carrito:<id_usuario>`, un HASH: una FOTO por linea
 *               (`<id_oferta>` -> JSON), el ticket de cada reserva de venta
 *               relampago (`t:<id_oferta>`), la version de PostgreSQL que
 *               conoce (`_v`) y la marca de desincronizado (`_d`)
 *               (`CarritoRedisService`). Es la copia rapida: se escribe y se
 *               lee aqui primero.
 *   PostgreSQL  el pedido `pendiente` de la cuenta y sus lineas
 *               (`CarritoPostgresService`), mas `reserva_venta_relampago`.
 *               Es la VERDAD: el checkout compra esto.
 *
 * Agregar, quitar o vaciar: se escribe en Redis, se le contesta a la persona,
 * y DEBAJO, sin hacerla esperar, un intento (`programarReplica`) copia el
 * carrito entero de Redis a PostgreSQL. Si ese intento falla (PostgreSQL
 * caido, o PostgreSQL tenia cambios que Redis no vio), el carrito queda
 * marcado como desincronizado (`_d`): `GET /carrito` lo dice
 * (`sincronizado: false`), el checkout no compra, y
 * `POST /carrito/sincronizar` lo arregla. La siguiente escritura que si se
 * replica tambien lo arregla sola.
 *
 * Si Redis no responde, todo va directo a PostgreSQL (mas lento, pero sigue
 * funcionando): agregar, quitar, ver y comprar. La cuenta queda anotada
 * (`afectados`) para reconstruir su Redis desde PostgreSQL cuando vuelva.
 *
 * Si Redis no tiene el carrito (vencio, se reinicio) se reconstruye desde
 * PostgreSQL. Las 24 h de inactividad las decide PostgreSQL
 * (`fecha_ultima_actividad`): un carrito con mas de 24 h sin tocar se borra
 * al leerlo, y el barrido (`CarritoBarridoService`) borra los que nadie lee.
 *
 *
 * Venta relampago
 * ============================================================
 * Redis sigue siendo la puerta rapida: su script atomico
 * (`redimensionar`) decide primero, sin candados, y rechaza en el acto a
 * quien llega tarde. La reserva de verdad es una fila de
 * `reserva_venta_relampago`, que se escribe con la replica. Si Redis no
 * responde, PostgreSQL reserva solo (`FOR UPDATE` corto sobre la oferta). Si
 * Redis perdio la venta, se reconstruye desde PostgreSQL
 * (`InventarioLimitadoService.restaurar`).
 *
 * El checkout compra el pedido pendiente: bloquea el pedido y las ofertas,
 * comprueba disponibilidad y reservas (una linea relampago sin reserva viva
 * intenta reservar ahi mismo), avisa si el precio cambio, y llama a
 * `comprar_pedido()` (`migrations/007`) en la misma transaccion en que las
 * reservas pasan a `confirmada`.
 */
@Injectable()
export class CarritoService {
  private readonly logger = new Logger(CarritoService.name);

  /** Las replicas en curso, por cuenta. */
  private readonly replicas = new Map<string, ReplicaEnCurso>();

  /** Cuentas que escribieron con Redis caido: su Redis se reconstruye al volver. */
  private readonly afectados = new Set<string>();

  /**
   * Cuentas que vaciaron el carrito y todavia no se replico, con la version
   * que Redis conocia (la clave ya no esta para guardarla).
   */
  private readonly vaciados = new Map<string, number | null>();

  /** Ultima vez que ver el carrito renovo el reloj de PostgreSQL, por cuenta. */
  private readonly tocados = new Map<string, number>();

  constructor(
    private readonly productosService: ProductosService,
    private readonly inventarioLimitadoService: InventarioLimitadoService,
    private readonly eventosService: EventosService,
    private readonly carritoPostgres: CarritoPostgresService,
    private readonly carritoRedis: CarritoRedisService,
  ) {}

  /** TTL del carrito, en segundos: 24 h de INACTIVIDAD (se re-pone en cada toque). */
  static readonly TTL_SEGUNDOS = VIDA_CARRITO_SEGUNDOS;

  // ---------------------------------------------------------------------
  // GET /carrito
  // ---------------------------------------------------------------------

  /**
   * El carrito como lo ve la persona. Lo normal es Redis puro: la foto que
   * tomo el `PUT` de cada linea. Renueva el TTL (mirar cuenta como
   * actividad), y cada tanto tambien el reloj de PostgreSQL.
   *
   * Si Redis no tiene el carrito, se reconstruye desde PostgreSQL. Si Redis no
   * responde, se lee PostgreSQL directo (`fuente: 'postgres'`).
   *
   * La disponibilidad de una linea de venta relampago se revisa en vivo
   * contra Redis (`ticketVigente`): la reserva puede vencer sola dentro de
   * las 24 h del carrito.
   */
  async verCarrito(idUsuario: string): Promise<Carrito> {
    if (esRedisInalcanzable()) {
      return this.verDesdePostgres(idUsuario);
    }
    try {
      await this.prepararRedis(idUsuario);
      const hash = await this.carritoRedis.leerHashCompleto(idUsuario);
      if (!hash.existe) {
        return await this.calentar(idUsuario);
      }
      const carrito = await this.pintarDesdeRedis(hash);
      await this.carritoRedis.renovarTtl(idUsuario);
      this.tocarPostgres(idUsuario);
      return carrito;
    } catch (error) {
      if (esRedisInalcanzable(error)) {
        return this.verDesdePostgres(idUsuario);
      }
      throw error;
    }
  }

  // ---------------------------------------------------------------------
  // PUT /carrito/lineas/:idOferta
  // ---------------------------------------------------------------------

  /**
   * Fija la cantidad ABSOLUTA de una oferta en el carrito (no un +1/-1).
   * Consulta PostgreSQL una vez para tomar la foto de esa linea (nombre,
   * precio, imagen, vendedor, stock, disponibilidad), la guarda en Redis y
   * contesta; la copia a PostgreSQL va debajo.
   *
   * Una oferta que no existe da 404: ya no se puede guardar en la verdad, y
   * un carrito con una linea que no existe no tiene sentido.
   *
   * Si la oferta tiene una venta relampago vigente (lo dice PostgreSQL), el
   * script atomico de Redis (`redimensionar`) reserva las unidades: si no
   * alcanzan, 409 en el acto, ANTES de tocar el carrito. Una oferta normal se
   * deja agregar siempre y avisa en `GET /carrito`.
   */
  async definirCantidad(
    idUsuario: string,
    idOfertaParametro: string,
    datos: DefinirCantidadCarritoPeticion,
  ): Promise<LineaCarritoDefinida> {
    const idOferta = this.validarIdOferta(idOfertaParametro);
    const cantidad = validarCantidadCarrito(datos.cantidad);

    const oferta = (await this.consultarOfertas([idOferta])).get(idOferta);
    if (oferta == null) {
      throw new ErrorNoEncontrado('No existe una oferta con ese id');
    }
    const foto = this.fotoDeOferta(oferta, cantidad);

    if (!esRedisInalcanzable()) {
      try {
        return await this.definirEnRedis(
          idUsuario,
          idOferta,
          cantidad,
          oferta,
          foto,
        );
      } catch (error) {
        if (!esRedisInalcanzable(error)) {
          throw error;
        }
      }
    }
    return this.definirEnPostgres(idUsuario, idOferta, cantidad, oferta);
  }

  private async definirEnRedis(
    idUsuario: string,
    idOferta: number,
    cantidad: number,
    oferta: FilaOferta,
    foto: LineaCarritoRedis,
  ): Promise<LineaCarritoDefinida> {
    await this.prepararRedis(idUsuario);
    if (!(await this.carritoRedis.existeCarrito(idUsuario))) {
      // Redis no tiene el carrito: puede que PostgreSQL si. Se trae antes de
      // escribir, para no empezar uno nuevo encima del de verdad.
      await this.calentar(idUsuario);
    }

    let ticket: number | null = null;
    if (oferta.venta_vigente) {
      const ticketViejo = await this.carritoRedis.leerTicket(
        idUsuario,
        idOferta,
      );
      let resultado = await this.inventarioLimitadoService.redimensionar(
        idOferta,
        idUsuario,
        ticketViejo,
        cantidad,
        TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS,
      );
      if (resultado.resultado === 'SIN_OFERTA') {
        // PostgreSQL dice que la venta sigue abierta y Redis no la tiene (se
        // reinicio, un FLUSHALL): se reconstruye desde PostgreSQL y se
        // vuelve a intentar una vez.
        if (await this.inventarioLimitadoService.restaurar(idOferta)) {
          resultado = await this.inventarioLimitadoService.redimensionar(
            idOferta,
            idUsuario,
            ticketViejo,
            cantidad,
            TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS,
          );
        }
      }

      if (resultado.resultado === 'AGOTADO') {
        throw new ErrorConflicto(
          `No hay suficiente stock en la venta relampago de la oferta ${idOferta}: pediste ${cantidad} y hay ${resultado.numero} disponibles (contando lo que ya tenias reservado)`,
        );
      }
      if (resultado.resultado === 'TICKET_AJENO') {
        // No deberia pasar: el ticket viejo sale del propio carrito de ESTE
        // usuario. Defensivo: algo mas toco esa reserva por fuera.
        throw new ErrorConflicto(
          'No se pudo actualizar la reserva de esta oferta',
        );
      }
      if (resultado.resultado === 'REDIMENSIONADO') {
        ticket = resultado.ticket;
        foto.reserva_vence = new Date(
          Date.now() + TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS * 1000,
        ).toISOString();
      }
      // SIN_OFERTA despues de restaurar: la venta ya no esta vigente (cerro
      // en el medio). La linea se guarda como normal.
    }

    // Sin ticket, se limpia el que la linea arrastrara de una venta que ya
    // cerro.
    await this.carritoRedis.guardarLinea(idUsuario, idOferta, foto, ticket);

    this.programarReplica(idUsuario);
    const resumen = await this.carritoRedis.resumen(idUsuario);
    return {
      id_oferta: idOferta,
      cantidad,
      es_inventario_limitado: ticket != null,
      ...resumen,
    };
  }

  /**
   * Redis no responde: la linea se escribe directo en PostgreSQL, mas lento
   * pero sin perder la venta. Una venta relampago reserva aqui mismo (sin
   * ticket: Redis no esta para darlo); si no alcanza, el mismo 409 que daria
   * Redis.
   */
  private async definirEnPostgres(
    idUsuario: string,
    idOferta: number,
    cantidad: number,
    oferta: FilaOferta,
  ): Promise<LineaCarritoDefinida> {
    let quedan: LineaDeseada[] = [];
    await this.carritoPostgres.escribir(
      idUsuario,
      (actuales) => {
        const otras = actuales
          .filter((l) => l.id_oferta !== idOferta)
          .map((l) => this.deseadaDesdePostgres(l));
        const actual = actuales.find((l) => l.id_oferta === idOferta);
        let reserva: LineaDeseada['reserva'] = null;
        if (oferta.venta_vigente) {
          const vieja = actual?.reserva;
          reserva =
            vieja != null &&
            vieja.cantidad === cantidad &&
            vieja.fecha_vence.getTime() > Date.now()
              ? { ticket: vieja.ticket, fecha_vence: vieja.fecha_vence }
              : {
                  ticket: null,
                  fecha_vence: new Date(
                    Date.now() +
                      TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS * 1000,
                  ),
                };
        }
        quedan = [
          ...otras,
          {
            id_oferta: idOferta,
            cantidad,
            id_precio_historial: oferta.id_precio_historial,
            nombre_producto:
              oferta.nombre_producto ?? '(producto no encontrado)',
            nombre_variante:
              oferta.nombre_variante ?? '(variante no encontrada)',
            id_producto: Number(oferta.id_producto_mongo),
            id_producto_variante: Number(oferta.id_producto_variante_mongo),
            reserva,
          },
        ];
        return quedan;
      },
      { versionEsperada: undefined, capacidad: 'rechazar' },
    );
    this.afectados.add(idUsuario);
    if (oferta.venta_vigente) {
      this.inventarioLimitadoService.marcarParaRestaurar(idOferta);
    }
    return {
      id_oferta: idOferta,
      cantidad,
      es_inventario_limitado: oferta.venta_vigente,
      ...this.resumenDe(quedan),
    };
  }

  // ---------------------------------------------------------------------
  // DELETE /carrito/lineas/:idOferta y DELETE /carrito
  // ---------------------------------------------------------------------

  /**
   * Quita una oferta del carrito. Idempotente: si la linea no estaba,
   * responde igual. Si era de venta relampago, suelta la reserva en Redis en
   * el acto (`devolver`); en PostgreSQL pasa a `devuelta` con la replica.
   */
  async quitarLinea(
    idUsuario: string,
    idOfertaParametro: string,
  ): Promise<ResumenCarrito> {
    const idOferta = this.validarIdOferta(idOfertaParametro);

    if (!esRedisInalcanzable()) {
      try {
        await this.prepararRedis(idUsuario);
        if (!(await this.carritoRedis.existeCarrito(idUsuario))) {
          await this.calentar(idUsuario);
        }
        const ticket = await this.carritoRedis.leerTicket(idUsuario, idOferta);
        if (ticket != null) {
          await this.inventarioLimitadoService.devolver(
            idOferta,
            idUsuario,
            ticket,
          );
        }
        await this.carritoRedis.borrarLinea(idUsuario, idOferta);
        this.programarReplica(idUsuario);
        return await this.carritoRedis.resumen(idUsuario);
      } catch (error) {
        if (!esRedisInalcanzable(error)) {
          throw error;
        }
      }
    }

    let quedan: LineaDeseada[] = [];
    let teniaReserva = false;
    await this.carritoPostgres.escribir(
      idUsuario,
      (actuales) => {
        teniaReserva =
          actuales.find((l) => l.id_oferta === idOferta)?.reserva != null;
        quedan = actuales
          .filter((l) => l.id_oferta !== idOferta)
          .map((l) => this.deseadaDesdePostgres(l));
        return quedan;
      },
      { versionEsperada: undefined, capacidad: 'rechazar' },
    );
    this.afectados.add(idUsuario);
    if (teniaReserva) {
      this.inventarioLimitadoService.marcarParaRestaurar(idOferta);
    }
    return this.resumenDe(quedan);
  }

  /**
   * Vacia el carrito (`DELETE /carrito`). Suelta en el acto las reservas de
   * venta relampago que hubiera y borra la clave de Redis (un carrito vacio no
   * existe como clave). La replica vacia PostgreSQL debajo.
   */
  async vaciar(idUsuario: string): Promise<void> {
    if (!esRedisInalcanzable()) {
      try {
        await this.prepararRedis(idUsuario);
        if (!(await this.carritoRedis.existeCarrito(idUsuario))) {
          await this.calentar(idUsuario);
        }
        const hash = await this.carritoRedis.leerHashCompleto(idUsuario);
        for (const [idOferta, ticket] of Object.entries(hash.tickets)) {
          await this.inventarioLimitadoService.devolver(
            Number(idOferta),
            idUsuario,
            ticket,
          );
        }
        await this.carritoRedis.borrar(idUsuario);
        // La clave ya no esta, y con ella la version: se le pasa a la replica
        // aparte, para que vacie PostgreSQL comparando contra la version que
        // Redis conocia.
        this.vaciados.set(idUsuario, hash.version);
        this.programarReplica(idUsuario);
        return;
      } catch (error) {
        if (!esRedisInalcanzable(error)) {
          throw error;
        }
      }
    }

    let teniaReservas: number[] = [];
    await this.carritoPostgres.escribir(
      idUsuario,
      (actuales) => {
        teniaReservas = actuales
          .filter((l) => l.reserva != null)
          .map((l) => l.id_oferta);
        return [];
      },
      { versionEsperada: undefined, capacidad: 'rechazar' },
    );
    this.afectados.add(idUsuario);
    for (const idOferta of teniaReservas) {
      this.inventarioLimitadoService.marcarParaRestaurar(idOferta);
    }
  }

  // ---------------------------------------------------------------------
  // POST /carrito/sincronizar
  // ---------------------------------------------------------------------

  /**
   * Arregla un carrito desincronizado. Primero espera la replica en curso.
   * Despues decide quien tiene razon:
   *
   *   - Redis y PostgreSQL estan en la misma version (o PostgreSQL no tiene
   *     carrito): lo que falta en PostgreSQL es la ultima escritura de Redis,
   *     que no se pudo copiar. Se vuelve a copiar.
   *   - PostgreSQL tiene una version mas nueva (hubo escrituras con Redis
   *     caido), o la copia choca: PostgreSQL es la verdad y Redis se
   *     reconstruye desde ahi.
   *
   * Devuelve el carrito como queda.
   */
  async sincronizar(idUsuario: string): Promise<Carrito> {
    await this.esperarReplica(idUsuario);
    if (esRedisInalcanzable()) {
      return this.verDesdePostgres(idUsuario);
    }
    let hash: HashCarrito;
    try {
      hash = await this.carritoRedis.leerHashCompleto(idUsuario);
    } catch (error) {
      if (esRedisInalcanzable(error)) {
        return this.verDesdePostgres(idUsuario);
      }
      throw error;
    }

    const postgres = await this.carritoPostgres.leer(idUsuario);
    const mismaVersion =
      postgres == null
        ? hash.version == null || hash.version === 0
        : hash.version === postgres.version ||
          (hash.version == null && postgres.lineas.length === 0);

    if (hash.existe && mismaVersion) {
      try {
        const resultado = await this.carritoPostgres.escribir(
          idUsuario,
          () => this.deseadasDesdeRedis(hash),
          { versionEsperada: hash.version, capacidad: 'conflicto' },
        );
        await this.carritoRedis.marcarSincronizado(
          idUsuario,
          resultado.version,
        );
        this.afectados.delete(idUsuario);
        return this.verCarrito(idUsuario);
      } catch (error) {
        if (error instanceof ConflictoCapacidad) {
          // PostgreSQL no tiene esas unidades: la reserva de Redis se suelta y
          // la linea se queda como PostgreSQL diga.
          const ticket = hash.tickets[error.idOferta];
          if (ticket != null) {
            await this.inventarioLimitadoService
              .devolver(error.idOferta, idUsuario, ticket)
              .catch(() => undefined);
          }
          this.inventarioLimitadoService.marcarParaRestaurar(error.idOferta);
        } else if (!(error instanceof ConflictoVersion)) {
          throw error;
        }
      }
    }

    await this.reconstruirDesdePostgres(idUsuario);
    this.afectados.delete(idUsuario);
    return this.verCarrito(idUsuario);
  }

  // ---------------------------------------------------------------------
  // POST /carrito/comprar
  // ---------------------------------------------------------------------

  /**
   * El checkout. Compra el carrito de VERDAD (el pedido pendiente de
   * PostgreSQL) en una sola transaccion:
   *
   *   1. Espera la replica en curso. Si Redis esta, el carrito no puede estar
   *      desincronizado, y lo que ve Redis tiene que coincidir con PostgreSQL
   *      (version y lineas): si no, 409 y se marca desincronizado. PostgreSQL
   *      manda; si Redis no responde, se compra lo que dice PostgreSQL.
   *   2. Bloquea el pedido y las ofertas (`FOR UPDATE`, en orden de id).
   *      Carrito vencido (24 h) o vacio -> 409.
   *   3. Disponibilidad en vivo (oferta activa, variante activa, stock). Si
   *      algo no se puede comprar -> 409 con la lista, siempre.
   *   4. Venta relampago: cada linea necesita una reserva activa, sin vencer y
   *      de la misma cantidad. Si no la tiene (vencio, o la venta se abrio
   *      despues de agregarla) intenta reservar ahi mismo; si no hay unidades,
   *      409.
   *   5. Precio: si alguna linea cambio de precio desde que se agrego y no
   *      vino `confirmar_cambios: true` -> `{comprado: false, avisos}` sin
   *      tocar nada (ROLLBACK). Con la confirmacion, se cobra el de hoy.
   *   6. Direccion (tiene que ser de la cuenta), tarjeta si aplica,
   *      `comprar_pedido()` (stock, kardex, pago, estado `comprado`), y las
   *      reservas del pedido pasan a `confirmada`. COMMIT.
   *   7. Despues: se confirman los tickets en Redis, se borra el carrito de
   *      Redis y se registra la compra en ClickHouse. Nada de esto deshace la
   *      compra si falla.
   */
  async comprarCarrito(
    idUsuario: string,
    datos: ComprarCarritoPeticion,
    ip: string,
  ): Promise<ComprarCarritoRespuesta> {
    // Un candado corto por cuenta cierra el hueco del doble submit. Si Redis
    // no esta, el `FOR UPDATE` del pedido hace el mismo trabajo (la segunda
    // compra espera y encuentra el carrito ya comprado).
    return this.carritoRedis.conCandadoCheckout(idUsuario, () =>
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

    await this.esperarReplica(idUsuario);
    let hash: HashCarrito | null = null;
    if (!esRedisInalcanzable()) {
      try {
        hash = await this.carritoRedis.leerHashCompleto(idUsuario);
      } catch (error) {
        if (!esRedisInalcanzable(error)) {
          throw error;
        }
      }
    }
    if (hash?.desincronizado) {
      throw new ErrorConflicto(MENSAJE_DESINCRONIZADO);
    }

    const cliente = await this.carritoPostgres.conectar();
    let compra: {
      id_pedido: number;
      total: string;
      stock: StockResultanteOferta[];
    };
    let lineasCompradas: LineaCarritoPostgres[];
    let confirmadas: { id_oferta: number; ticket: number | null }[];
    const reservadasAqui: number[] = [];
    let quitarDespues: number[] = [];
    try {
      await cliente.query('BEGIN');
      const { carrito, vencido } = await this.leerParaComprar(
        cliente,
        idUsuario,
      );

      if (carrito == null || carrito.lineas.length === 0) {
        // El vencimiento (si lo hubo) ya borro el carrito: eso se guarda.
        await cliente.query('COMMIT');
        if (vencido) {
          // La copia de Redis tampoco vale ya: si no se borra, seguiria
          // mostrando un carrito que en la verdad ya no existe.
          if (hash != null) {
            await this.carritoRedis.borrar(idUsuario).catch(() => undefined);
          }
          throw new ErrorConflicto(
            'El carrito vencio por inactividad (24 h sin tocarlo): vuelve a agregar los productos',
          );
        }
        if (hash != null && Object.keys(hash.lineas).length > 0) {
          await this.carritoRedis.marcarDesincronizado(idUsuario);
          throw new ErrorConflicto(MENSAJE_DESINCRONIZADO);
        }
        throw new ErrorConflicto('El carrito esta vacio');
      }

      if (hash != null && hash.existe && !this.coincide(hash, carrito)) {
        await cliente.query('ROLLBACK');
        await this.carritoRedis.marcarDesincronizado(idUsuario);
        throw new ErrorConflicto(MENSAJE_DESINCRONIZADO);
      }

      const ids = carrito.lineas.map((l) => l.id_oferta);
      const ofertas = await this.consultarOfertas(ids, cliente);

      const bloqueantes: { linea: LineaCarritoPostgres; motivo: string }[] = [];
      for (const linea of carrito.lineas) {
        const oferta = ofertas.get(linea.id_oferta);
        if (oferta == null) {
          bloqueantes.push({
            linea,
            motivo: this.motivoATexto('oferta_no_existe'),
          });
          continue;
        }
        const { disponible, motivo } = this.evaluarDisponibilidad(
          oferta,
          linea.cantidad,
          oferta.estado_variante ?? undefined,
        );
        if (!disponible) {
          bloqueantes.push({ linea, motivo: this.motivoATexto(motivo) });
        }
      }

      if (bloqueantes.length === 0) {
        for (const linea of carrito.lineas) {
          const oferta = ofertas.get(linea.id_oferta)!;
          if (!oferta.venta_vigente) {
            continue;
          }
          const reserva = linea.reserva;
          const vale =
            reserva != null &&
            reserva.cantidad === linea.cantidad &&
            reserva.fecha_vence.getTime() > Date.now();
          if (vale) {
            continue;
          }
          // Sin ticket: Redis no la dio. La reconciliacion la vuelve a sembrar.
          const { reservada, libres } =
            await this.carritoPostgres.reservarSiHayUnidades(cliente, {
              idPedido: carrito.id_pedido,
              idUsuario,
              idOferta: linea.id_oferta,
              cantidad: linea.cantidad,
              stock: oferta.stock,
              ticket: null,
              fechaVence: new Date(
                Date.now() + TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS * 1000,
              ),
              idReservaActual: reserva?.id_reserva ?? null,
            });
          if (!reservada) {
            bloqueantes.push({
              linea,
              motivo: `es de una venta relampago y ${reserva == null ? 'no tenia reserva' : 'su reserva vencio'}: pediste ${linea.cantidad} y hay ${libres} disponibles`,
            });
            continue;
          }
          reservadasAqui.push(linea.id_oferta);
        }
      }

      if (bloqueantes.length > 0) {
        await cliente.query('ROLLBACK');
        if (QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR) {
          quitarDespues = bloqueantes.map((b) => b.linea.id_oferta);
        }
        const mensaje = bloqueantes
          .map((b) => `"${b.linea.nombre_variante}" ${b.motivo}`)
          .join('; ');
        throw new ErrorConflicto(mensaje);
      }

      const avisos: AvisoPrecioCarrito[] = [];
      for (const linea of carrito.lineas) {
        const oferta = ofertas.get(linea.id_oferta)!;
        if (linea.precio_visto !== oferta.precio_final) {
          avisos.push({
            id_oferta: linea.id_oferta,
            nombre_producto: oferta.nombre_producto ?? linea.nombre_producto,
            nombre_variante: oferta.nombre_variante ?? linea.nombre_variante,
            precio_visto: linea.precio_visto,
            precio_actual: oferta.precio_final,
          });
        }
      }
      if (avisos.length > 0 && datos.confirmar_cambios !== true) {
        await cliente.query('ROLLBACK');
        return { comprado: false, avisos };
      }

      const idDireccionHistorial = await this.resolverDireccionHistorial(
        idUsuario,
        idDireccion,
      );
      if (datos.metodo_pago === METODO_PAGO_TARJETA) {
        validarYCobrarTarjeta(datos.tarjeta);
      }

      await cliente.query('SELECT cambiar_direccion_pedido($1, $2)', [
        carrito.id_pedido,
        idDireccionHistorial,
      ]);

      // Lo que queda en la factura: los nombres de hoy, y el precio de hoy si
      // la persona acepto los cambios.
      const aceptoCambios = new Set(avisos.map((a) => a.id_oferta));
      for (const linea of carrito.lineas) {
        const oferta = ofertas.get(linea.id_oferta)!;
        await cliente.query(
          `UPDATE pedido_producto pp
              SET nombre_producto = $3, nombre_variante = $4,
                  nombre_vendedor = $5,
                  id_precio_historial = CASE WHEN $6 THEN $7::bigint
                                             ELSE pp.id_precio_historial END
             FROM precio_historial ph
            WHERE ph.id_precio_historial = pp.id_precio_historial
              AND pp.id_pedido = $1 AND ph.id_oferta = $2`,
          [
            carrito.id_pedido,
            linea.id_oferta,
            (oferta.nombre_producto ?? linea.nombre_producto).slice(0, 200),
            (oferta.nombre_variante ?? linea.nombre_variante).slice(0, 100),
            oferta.vendedor_nombre.slice(0, 200),
            aceptoCambios.has(linea.id_oferta),
            oferta.id_precio_historial,
          ],
        );
      }

      const { rows } = await cliente.query<{
        comprar_pedido: {
          id_pedido: number;
          total: string;
          stock: StockResultanteOferta[];
        };
      }>('SELECT comprar_pedido($1, $2)', [
        carrito.id_pedido,
        datos.metodo_pago,
      ]);
      compra = rows[0].comprar_pedido;

      const { rows: reservas } = await cliente.query<{
        id_oferta: string;
        ticket: string | null;
      }>(
        `UPDATE reserva_venta_relampago
            SET id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                      WHERE estado_reserva_nombre = 'confirmada'),
                fecha_cierre = now()
          WHERE id_pedido = $1
            AND id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                      WHERE estado_reserva_nombre = 'activa')
      RETURNING id_oferta, ticket`,
        [carrito.id_pedido],
      );
      confirmadas = reservas.map((r) => ({
        id_oferta: Number(r.id_oferta),
        ticket: r.ticket == null ? null : Number(r.ticket),
      }));

      await cliente.query('COMMIT');
      lineasCompradas = carrito.lineas;
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      if (
        error instanceof ErrorConflicto ||
        error instanceof ErrorValidacion ||
        error instanceof ErrorNoEncontrado ||
        error instanceof ErrorPago
      ) {
        throw error;
      }
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
      for (const idOferta of quitarDespues) {
        await this.quitarLinea(idUsuario, String(idOferta)).catch(
          () => undefined,
        );
      }
    }

    await this.despuesDeComprar(idUsuario, confirmadas, reservadasAqui);

    // Evento de analitica en ClickHouse (plan pendiente/eventos-clickhouse.md).
    // Fire-and-forget, SIN `await`: la compra ya quedo cerrada en PostgreSQL.
    void this.eventosService.registrarCompra({
      idUsuario,
      idPedido: compra.id_pedido,
      ip,
      lineas: lineasCompradas.map((linea) => ({
        idProducto: linea.id_producto,
        idOferta: linea.id_oferta,
        cantidad: linea.cantidad,
      })),
    });

    return {
      comprado: true,
      id_pedido: Number(compra.id_pedido),
      total: compra.total,
      stock: compra.stock,
    };
  }

  /**
   * La compra ya esta cerrada en PostgreSQL. Lo de Redis va despues y nunca la
   * deshace: se confirman los tickets (pasan de reservados a vendidos), se
   * borra el carrito, y lo que no se pudo dejar en orden se marca para que la
   * reconciliacion lo reconstruya desde PostgreSQL.
   */
  private async despuesDeComprar(
    idUsuario: string,
    confirmadas: { id_oferta: number; ticket: number | null }[],
    reservadasAqui: number[],
  ): Promise<void> {
    const redisVivo = !esRedisInalcanzable();
    for (const { id_oferta, ticket } of confirmadas) {
      if (!redisVivo || ticket == null || reservadasAqui.includes(id_oferta)) {
        this.inventarioLimitadoService.marcarParaRestaurar(id_oferta);
        continue;
      }
      try {
        const { resultado } = await this.inventarioLimitadoService.confirmar(
          id_oferta,
          idUsuario,
          ticket,
        );
        if (resultado !== 'CONFIRMADO') {
          this.logger.warn(
            `Reserva de la oferta ${id_oferta} (ticket ${ticket}) no confirmada en Redis: ${resultado}. La compra ya se concreto en PostgreSQL; se reconstruye desde ahi.`,
          );
          this.inventarioLimitadoService.marcarParaRestaurar(id_oferta);
        }
      } catch (error) {
        this.logger.warn(
          `No se pudo confirmar la reserva de la oferta ${id_oferta} en Redis; la compra ya se concreto: ${error instanceof Error ? error.message : String(error)}`,
        );
        this.inventarioLimitadoService.marcarParaRestaurar(id_oferta);
      }
    }

    if (!redisVivo) {
      this.afectados.add(idUsuario);
      return;
    }
    try {
      await this.carritoRedis.borrar(idUsuario);
    } catch (error) {
      this.logger.warn(
        `No se pudo borrar de Redis el carrito ya comprado de ${idUsuario}: ${error instanceof Error ? error.message : String(error)}`,
      );
      this.afectados.add(idUsuario);
    }
  }

  // ---------------------------------------------------------------------
  // La replica: Redis -> PostgreSQL, debajo
  // ---------------------------------------------------------------------

  /**
   * Programa la copia del carrito de Redis a PostgreSQL, sin esperarla. Una
   * sola a la vez por cuenta: si ya hay una corriendo, se pide otra al
   * terminar (que copiara el estado de ese momento, que ya incluye este
   * cambio). Asi el orden de las escrituras se respeta y varias seguidas se
   * resuelven con pocas copias.
   */
  private programarReplica(idUsuario: string): void {
    const enCurso = this.replicas.get(idUsuario);
    if (enCurso != null) {
      enCurso.otraVez = true;
      return;
    }
    const replica: ReplicaEnCurso = {
      promesa: Promise.resolve(),
      otraVez: false,
    };
    replica.promesa = (async () => {
      try {
        do {
          replica.otraVez = false;
          await this.replicarUnaVez(idUsuario);
        } while (replica.otraVez);
      } finally {
        this.replicas.delete(idUsuario);
      }
    })();
    this.replicas.set(idUsuario, replica);
  }

  /** Espera a que termine la replica en curso de la cuenta, si hay una. */
  private async esperarReplica(idUsuario: string): Promise<void> {
    while (this.replicas.has(idUsuario)) {
      await this.replicas.get(idUsuario)!.promesa;
    }
  }

  /**
   * UN intento de copiar el carrito entero de Redis a PostgreSQL. Nunca
   * lanza. Si sale bien, Redis guarda la version nueva y deja de estar
   * desincronizado. Si choca o PostgreSQL falla, se marca desincronizado.
   */
  private async replicarUnaVez(idUsuario: string): Promise<void> {
    if (esRedisInalcanzable()) {
      return;
    }
    let hash: HashCarrito;
    try {
      hash = await this.carritoRedis.leerHashCompleto(idUsuario);
    } catch {
      return;
    }
    if (!hash.existe) {
      if (this.vaciados.has(idUsuario)) {
        await this.replicarVaciado(idUsuario);
      }
      return;
    }
    this.vaciados.delete(idUsuario);

    try {
      const resultado = await this.carritoPostgres.escribir(
        idUsuario,
        () => this.deseadasDesdeRedis(hash),
        { versionEsperada: hash.version, capacidad: 'conflicto' },
      );
      await this.carritoRedis.marcarSincronizado(idUsuario, resultado.version);
      if (Object.keys(hash.lineas).length === 0) {
        // Quedo vacio y PostgreSQL ya lo sabe: la clave sobra. Solo si sigue
        // sin lineas.
        await this.carritoRedis.borrarSiVacio(idUsuario);
      }
      if (resultado.omitidas.length > 0) {
        this.logger.warn(
          `carrito de ${idUsuario}: ${resultado.omitidas.length} linea(s) de ofertas que ya no existen no se guardaron en PostgreSQL`,
        );
      }
    } catch (error) {
      await this.carritoRedis.marcarDesincronizado(idUsuario);
      if (error instanceof ConflictoCapacidad) {
        this.inventarioLimitadoService.marcarParaRestaurar(error.idOferta);
      }
      this.logger.warn(
        `carrito de ${idUsuario} desincronizado: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  /**
   * La replica de un `DELETE /carrito`: vacia PostgreSQL contra la version que
   * Redis conocia. Si choca (PostgreSQL tenia cambios que Redis no vio) o
   * PostgreSQL falla, PostgreSQL se queda como estaba y es lo que se vera: la
   * clave de Redis ya no esta, asi que el proximo `GET` lo trae de ahi.
   */
  private async replicarVaciado(idUsuario: string): Promise<void> {
    const version = this.vaciados.get(idUsuario) ?? null;
    this.vaciados.delete(idUsuario);
    try {
      await this.carritoPostgres.escribir(idUsuario, () => [], {
        versionEsperada: version,
        capacidad: 'conflicto',
      });
    } catch (error) {
      this.logger.warn(
        `No se pudo vaciar en PostgreSQL el carrito de ${idUsuario} (se vera lo que quedo ahi): ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  // ---------------------------------------------------------------------
  // Redis desde PostgreSQL
  // ---------------------------------------------------------------------

  /**
   * Si la cuenta escribio con Redis caido, su Redis no vio esos cambios: antes
   * de usarlo se reconstruye desde PostgreSQL. Si PostgreSQL tampoco esta, se
   * sigue con lo que hay y se reintenta la proxima vez.
   */
  private async prepararRedis(idUsuario: string): Promise<void> {
    if (!this.afectados.has(idUsuario)) {
      return;
    }
    try {
      await this.reconstruirDesdePostgres(idUsuario);
      this.afectados.delete(idUsuario);
    } catch (error) {
      if (error instanceof ErrorConexionRedis) {
        throw error;
      }
      this.logger.warn(
        `No se pudo reconstruir el carrito de ${idUsuario} desde PostgreSQL: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  /**
   * Redis no tiene el carrito: se trae de PostgreSQL (si tiene) y se devuelve
   * pintado. Si PostgreSQL no responde, el carrito se ve vacio: Redis es todo
   * lo que se puede consultar, y el checkout volvera a preguntarle a la
   * verdad.
   */
  private async calentar(idUsuario: string): Promise<Carrito> {
    await this.esperarReplica(idUsuario);
    let postgres: CarritoPostgres | null;
    try {
      postgres = await this.carritoPostgres.leer(idUsuario);
    } catch (error) {
      if (
        error instanceof ErrorConexion &&
        !(error instanceof ErrorConexionRedis)
      ) {
        return this.carritoVacio('redis');
      }
      throw error;
    }
    if (postgres == null || postgres.lineas.length === 0) {
      return this.carritoVacio('redis');
    }
    await this.escribirRedisDesdePostgres(idUsuario, postgres);
    return this.pintarDesdeRedis(
      await this.carritoRedis.leerHashCompleto(idUsuario),
    );
  }

  /** Tira el carrito de Redis y lo vuelve a escribir desde PostgreSQL (vacio si no hay). */
  private async reconstruirDesdePostgres(idUsuario: string): Promise<void> {
    await this.esperarReplica(idUsuario);
    const postgres = await this.carritoPostgres.leer(idUsuario);
    if (postgres == null || postgres.lineas.length === 0) {
      // Un carrito vacio pero existente: Redis guarda su version para que la
      // proxima escritura se compare contra ella.
      await this.carritoRedis.dejarVacio(
        idUsuario,
        postgres?.version ?? null,
        postgres == null ? 0 : this.ttlRestante(postgres),
      );
      return;
    }
    await this.escribirRedisDesdePostgres(idUsuario, postgres);
  }

  /**
   * Escribe en Redis el carrito de PostgreSQL, entero y de una vez: la foto de
   * cada linea con el precio que la persona vio (el de la linea en
   * PostgreSQL) y la disponibilidad de ahora, los tickets que tengan sus
   * reservas, la version, y el TTL que le queda segun PostgreSQL.
   */
  private async escribirRedisDesdePostgres(
    idUsuario: string,
    postgres: CarritoPostgres,
  ): Promise<void> {
    const ofertas = await this.consultarOfertas(
      postgres.lineas.map((l) => l.id_oferta),
    );
    await this.carritoRedis.reemplazar(
      idUsuario,
      postgres.version,
      postgres.lineas.map((linea) => ({
        idOferta: linea.id_oferta,
        foto: this.fotoDesdePostgres(linea, ofertas.get(linea.id_oferta)),
        ticket: linea.reserva?.ticket ?? null,
      })),
      this.ttlRestante(postgres),
    );
  }

  /** Lo que le queda al carrito de sus 24 h, segun PostgreSQL. Al menos 1 s. */
  private ttlRestante(postgres: CarritoPostgres): number {
    const pasados = Math.floor(
      (Date.now() - postgres.fecha_ultima_actividad.getTime()) / 1000,
    );
    return Math.max(1, CarritoService.TTL_SEGUNDOS - pasados);
  }

  // ---------------------------------------------------------------------
  // Pintar el carrito
  // ---------------------------------------------------------------------

  private async pintarDesdeRedis(hash: HashCarrito): Promise<Carrito> {
    const idsOferta = Object.keys(hash.lineas).map(Number);
    const lineas: CarritoLinea[] = await Promise.all(
      idsOferta.map(async (idOferta) => {
        const foto = hash.lineas[idOferta];
        const ticket = hash.tickets[idOferta] ?? null;
        const esInventarioLimitado = ticket != null;

        let { disponible, motivo } = foto;
        // La reserva de una venta relampago puede vencer sola dentro de las
        // 24 h del carrito, sin que nadie vuelva a tocar esta linea: se
        // revisa en vivo contra Redis en vez de confiar en la foto.
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
        return this.lineaDeFoto(
          idOferta,
          foto,
          disponible,
          motivo,
          esInventarioLimitado,
        );
      }),
    );
    return this.armarCarrito(lineas, !hash.desincronizado, 'redis');
  }

  /**
   * El carrito leido directo de PostgreSQL (Redis no responde). Precio y
   * nombres son los de cada linea (lo que la persona vio); disponibilidad y
   * stock, los de ahora.
   */
  private async verDesdePostgres(idUsuario: string): Promise<Carrito> {
    const postgres = await this.carritoPostgres.leer(idUsuario);
    if (postgres == null || postgres.lineas.length === 0) {
      return this.carritoVacio('postgres');
    }
    const ofertas = await this.consultarOfertas(
      postgres.lineas.map((l) => l.id_oferta),
    );
    const lineas = postgres.lineas.map((linea) => {
      const foto = this.fotoDesdePostgres(linea, ofertas.get(linea.id_oferta));
      return this.lineaDeFoto(
        linea.id_oferta,
        foto,
        foto.disponible,
        foto.motivo,
        linea.reserva != null,
      );
    });
    return this.armarCarrito(lineas, true, 'postgres');
  }

  private lineaDeFoto(
    idOferta: number,
    foto: LineaCarritoRedis,
    disponible: boolean,
    motivo: MotivoNoDisponible | null,
    esInventarioLimitado: boolean,
  ): CarritoLinea {
    return {
      id_oferta: idOferta,
      cantidad: foto.cantidad,
      id_producto: foto.id_producto,
      id_producto_variante: foto.id_producto_variante,
      nombre_producto: foto.nombre_producto,
      nombre_variante: foto.nombre_variante,
      imagen: foto.imagen,
      precio: foto.precio,
      porcentaje_descuento: foto.porcentaje_descuento,
      subtotal: (Number(foto.precio) * foto.cantidad).toFixed(2),
      vendedor: {
        usuario: foto.vendedor_usuario,
        nombre: foto.vendedor_nombre,
      },
      stock_disponible: foto.stock_disponible,
      disponible,
      motivo,
      es_inventario_limitado: esInventarioLimitado,
    };
  }

  private armarCarrito(
    lineas: CarritoLinea[],
    sincronizado: boolean,
    fuente: 'redis' | 'postgres',
  ): Carrito {
    return {
      lineas,
      total: lineas
        .reduce((suma, l) => suma + Number(l.subtotal), 0)
        .toFixed(2),
      total_lineas: lineas.length,
      total_items: lineas.reduce((suma, l) => suma + l.cantidad, 0),
      sincronizado,
      fuente,
    };
  }

  private carritoVacio(fuente: 'redis' | 'postgres'): Carrito {
    return {
      lineas: [],
      total: '0.00',
      total_lineas: 0,
      total_items: 0,
      sincronizado: true,
      fuente,
    };
  }

  // ---------------------------------------------------------------------
  // Fotos y lineas deseadas
  // ---------------------------------------------------------------------

  /** La foto de una linea recien agregada, con los datos de ahora. */
  private fotoDeOferta(
    oferta: FilaOferta,
    cantidad: number,
  ): LineaCarritoRedis {
    const { disponible, motivo } = this.evaluarDisponibilidad(
      oferta,
      cantidad,
      oferta.estado_variante ?? undefined,
    );
    return {
      cantidad,
      id_producto: Number(oferta.id_producto_mongo),
      id_producto_variante: Number(oferta.id_producto_variante_mongo),
      nombre_producto: oferta.nombre_producto ?? '(producto no encontrado)',
      nombre_variante: oferta.nombre_variante ?? '(variante no encontrada)',
      imagen: oferta.imagen,
      precio: oferta.precio_final,
      porcentaje_descuento: oferta.porcentaje_descuento,
      vendedor_usuario: oferta.vendedor_usuario,
      vendedor_nombre: oferta.vendedor_nombre,
      stock_disponible: oferta.stock,
      disponible,
      motivo,
      id_precio_historial: oferta.id_precio_historial,
      reserva_vence: null,
    };
  }

  /**
   * La foto de una linea que viene de PostgreSQL: precio y nombres de la linea
   * (lo que la persona vio), disponibilidad de ahora. Una reserva vencida se
   * marca como tal.
   */
  private fotoDesdePostgres(
    linea: LineaCarritoPostgres,
    oferta: FilaOferta | undefined,
  ): LineaCarritoRedis {
    let disponible = false;
    let motivo: MotivoNoDisponible | null = 'oferta_no_existe';
    if (oferta != null) {
      ({ disponible, motivo } = this.evaluarDisponibilidad(
        oferta,
        linea.cantidad,
        oferta.estado_variante ?? undefined,
      ));
      if (
        disponible &&
        linea.reserva != null &&
        linea.reserva.fecha_vence.getTime() <= Date.now()
      ) {
        disponible = false;
        motivo = 'reserva_vencida';
      }
    }
    return {
      cantidad: linea.cantidad,
      id_producto: linea.id_producto,
      id_producto_variante: linea.id_producto_variante,
      nombre_producto: linea.nombre_producto,
      nombre_variante: linea.nombre_variante,
      imagen: oferta?.imagen ?? null,
      precio: linea.precio_visto,
      porcentaje_descuento: linea.porcentaje_descuento_visto,
      vendedor_usuario: oferta?.vendedor_usuario ?? '',
      vendedor_nombre: oferta?.vendedor_nombre ?? '',
      stock_disponible: oferta?.stock ?? 0,
      disponible,
      motivo,
      id_precio_historial: linea.id_precio_historial,
      reserva_vence: linea.reserva?.fecha_vence.toISOString() ?? null,
    };
  }

  /** Como quiere Redis que quede PostgreSQL: sus lineas, con sus tickets. */
  private deseadasDesdeRedis(hash: HashCarrito): LineaDeseada[] {
    return Object.entries(hash.lineas).map(([id, foto]) => {
      const idOferta = Number(id);
      const ticket = hash.tickets[idOferta] ?? null;
      return {
        id_oferta: idOferta,
        cantidad: foto.cantidad,
        id_precio_historial: foto.id_precio_historial ?? null,
        nombre_producto: foto.nombre_producto,
        nombre_variante: foto.nombre_variante,
        id_producto: foto.id_producto,
        id_producto_variante: foto.id_producto_variante,
        reserva:
          ticket == null
            ? null
            : {
                ticket,
                fecha_vence: foto.reserva_vence
                  ? new Date(foto.reserva_vence)
                  : new Date(
                      Date.now() +
                        TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS * 1000,
                    ),
              },
      };
    });
  }

  /** Una linea de PostgreSQL tal cual, para reescribirla sin cambios. */
  private deseadaDesdePostgres(linea: LineaCarritoPostgres): LineaDeseada {
    return {
      id_oferta: linea.id_oferta,
      cantidad: linea.cantidad,
      id_precio_historial: linea.id_precio_historial,
      nombre_producto: linea.nombre_producto,
      nombre_variante: linea.nombre_variante,
      id_producto: linea.id_producto,
      id_producto_variante: linea.id_producto_variante,
      reserva:
        linea.reserva == null
          ? null
          : {
              ticket: linea.reserva.ticket,
              fecha_vence: linea.reserva.fecha_vence,
            },
    };
  }

  private resumenDe(lineas: LineaDeseada[]): ResumenCarrito {
    return {
      total_lineas: lineas.length,
      total_items: lineas.reduce((suma, l) => suma + l.cantidad, 0),
    };
  }

  /** Redis y PostgreSQL cuentan lo mismo: misma version y mismas lineas con mismas cantidades. */
  private coincide(hash: HashCarrito, postgres: CarritoPostgres): boolean {
    if (hash.version !== postgres.version) {
      return false;
    }
    const enRedis = Object.entries(hash.lineas);
    if (enRedis.length !== postgres.lineas.length) {
      return false;
    }
    const cantidades = new Map(
      postgres.lineas.map((l) => [l.id_oferta, l.cantidad]),
    );
    return enRedis.every(
      ([id, foto]) => cantidades.get(Number(id)) === foto.cantidad,
    );
  }

  // ---------------------------------------------------------------------
  // Checkout: privados
  // ---------------------------------------------------------------------

  /** El carrito para comprar, bloqueado, y si se acaba de vencer. */
  private async leerParaComprar(
    cliente: PoolClient,
    idUsuario: string,
  ): Promise<{ carrito: CarritoPostgres | null; vencido: boolean }> {
    const { rows } = await cliente.query<{ vencido: boolean }>(
      `SELECT p.fecha_ultima_actividad <= now() - make_interval(secs => $2) AS vencido
         FROM pedido p
         JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
        WHERE p.id_usuario = $1 AND ep.estado_pedido_nombre = 'pendiente'`,
      [idUsuario, VIDA_CARRITO_SEGUNDOS],
    );
    const vencido = rows[0]?.vencido === true;
    const carrito = await this.carritoPostgres.leerEnTransaccion(
      cliente,
      idUsuario,
      true,
    );
    return { carrito, vencido };
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

  /** Ver el carrito tambien renueva el reloj de PostgreSQL, como mucho cada 5 min. */
  private tocarPostgres(idUsuario: string): void {
    const ahora = Date.now();
    if (ahora - (this.tocados.get(idUsuario) ?? 0) < TOCAR_POSTGRES_CADA_MS) {
      return;
    }
    this.tocados.set(idUsuario, ahora);
    void this.carritoPostgres.tocar(idUsuario);
  }

  // ---------------------------------------------------------------------
  // PostgreSQL: privados
  // ---------------------------------------------------------------------

  private evaluarDisponibilidad(
    oferta: FilaOferta,
    cantidad: number,
    estadoVariante: string | undefined,
  ): { disponible: boolean; motivo: MotivoNoDisponible | null } {
    if (oferta.estado_oferta_nombre !== 'activa') {
      return { disponible: false, motivo: 'oferta_no_disponible' };
    }
    // La variante puede haberse desactivado en el catalogo despues de
    // agregarla. Si la variante no esta en `variante_catalogo`,
    // `estadoVariante` es undefined y se deja pasar.
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

  /**
   * Las ofertas en vivo, con todo lo que hace falta para pintar y cobrar una
   * linea. Con `cliente` corre dentro de esa transaccion y BLOQUEA las
   * ofertas (`FOR UPDATE OF o`, en orden de id): es la del checkout.
   */
  private async consultarOfertas(
    idsOferta: number[],
    cliente?: PoolClient,
  ): Promise<Map<number, FilaOferta>> {
    if (idsOferta.length === 0) {
      return new Map();
    }
    const sql = `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
                o.precio, o.porcentaje_descuento,
                ${expresionPrecioFinal('o')}::text AS precio_final,
                o.stock, eo.estado_oferta_nombre,
                u.usuario AS vendedor_usuario,
                u.nombre || COALESCE(' ' || u.apellido, '') AS vendedor_nombre,
                pc.nombre AS nombre_producto,
                vc.nombre_variante,
                vc.estado AS estado_variante,
                vc.imagen,
                (SELECT ph.id_precio_historial FROM precio_historial ph
                  WHERE ph.id_oferta = o.id_oferta
                  ORDER BY ph.fecha_creacion DESC, ph.id_precio_historial DESC
                  LIMIT 1) AS id_precio_historial,
                (o.es_inventario_limitado
                 AND (o.fecha_vencimiento_venta_limitada IS NULL
                      OR o.fecha_vencimiento_venta_limitada > now())) AS venta_vigente
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
           JOIN usuarios u ON u.id_usuario = o.id_usuario
           LEFT JOIN variante_catalogo vc
                  ON vc.id_producto_mongo = o.id_producto_mongo
                 AND vc.id_producto_variante_mongo = o.id_producto_variante_mongo
           LEFT JOIN producto_catalogo pc
                  ON pc.id_producto_mongo = o.id_producto_mongo
          WHERE o.id_oferta = ANY($1::bigint[])
          ${cliente != null ? 'ORDER BY o.id_oferta FOR UPDATE OF o' : ''}`;
    try {
      const resultado = await (cliente ?? pool).query<FilaOferta>(sql, [
        idsOferta,
      ]);
      return new Map(
        resultado.rows.map((fila) => [Number(fila.id_oferta), fila]),
      );
    } catch (error) {
      if (cliente != null) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
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
   * 404 que una que no existe.
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
   * con los que `comprar_pedido` / `cambiar_direccion_pedido` levantan sus
   * errores de negocio (sin stock, metodo de pago invalido, direccion).
   */
  private esErrorDeNegocio(error: unknown): boolean {
    const codigo = (error as { code?: string } | undefined)?.code;
    return codigo === '23503' || codigo === '23514';
  }
}
