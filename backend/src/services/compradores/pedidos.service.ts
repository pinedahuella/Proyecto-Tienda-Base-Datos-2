import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { PedidoCompleto } from '../../dto/pedido-completo';
import { PedidoResumen } from '../../dto/listar-pedidos';
import { CancelacionResultado } from '../../dto/cancelar-pedido';
import { DetallePedido } from '../../models/pedido-producto';
import { MetodoPago } from '../../models/metodo-pago';
import { ProductosService } from '../productos/productos.service';
import { EventosService } from '../eventos/eventos.service';
import { ResenasCanceladasDetectorService } from '../fraude/resenas-canceladas-detector.service';
import { InventarioLimitadoService } from '../inventario-limitado/inventario-limitado.service';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';

const REGEX_ID = /^\d+$/;

/**
 * Servicio de /comprador/pedidos: consultar los pedidos propios (uno o el
 * listado), el catalogo de formas de pago, y cancelar.
 *
 * Desde el 2026-10-17 el pedido `pendiente` de cada cuenta ES su carrito (ver
 * `plan pendiente/carrito-postgres-verdad.md`): se arma y se compra por
 * /carrito, nunca por aqui. Por eso se quitaron las rutas viejas que armaban
 * un pedido a mano (crear, agregar/cambiar/quitar lineas, cambiar direccion,
 * comprar): pasaban por encima del carrito y lo dejaban desincronizado. Y por
 * eso este servicio no muestra ni cancela el pedido pendiente: no es un
 * pedido todavia, es el carrito.
 *
 * Sin restriccion de rol: cualquiera con sesion puede comprar (comprador,
 * vendedor o admin), a diferencia de /vendedor/productos o /admin/*.
 *
 * Las funciones del flujo de pedido viven en PostgreSQL
 * (migrations/007_flujo_pedido.sql) y no se tocan: este servicio solo las
 * llama, resolviendo antes lo que Postgres no puede saber por su cuenta
 * (los nombres de Mongo, de quien es el pedido -- que ninguna funcion
 * comprueba). Los cuatro numeros calculados del catalogo en Mongo los pone al
 * dia aparte `EventoProductoSyncService` (cola `evento_producto`).
 */
@Injectable()
export class PedidosCompradorService {
  private readonly logger = new Logger(PedidosCompradorService.name);

  constructor(
    private readonly productosService: ProductosService,
    private readonly eventosService: EventosService,
    private readonly resenasCanceladasDetectorService: ResenasCanceladasDetectorService,
    private readonly inventarioLimitadoService: InventarioLimitadoService,
  ) {}

  /**
   * Todos los pedidos propios, resumidos (no el detalle completo, para
   * eso esta obtener(); y no un historial de eventos). El total sale de
   * sumar precio_historial.precio * cantidad de cada linea -- el precio
   * congelado de cada una, no el de hoy.
   *
   * Trae tambien el pago (metodo, estado, cuando se salda), con LEFT JOIN:
   * un pedido `pendiente` todavia no tiene fila en Pago (esa nace recien
   * en comprar_pedido()), asi que esos tres campos salen null. Pago es una
   * sola fila por pedido, asi que unirla no duplica renglones del GROUP BY.
   */
  async listar(idUsuario: string): Promise<PedidoResumen[]> {
    try {
      const resultado = await pool.query<PedidoResumen>(
        `SELECT p.id_pedido, p.fecha_creacion, p.id_estado_pedido, ep.estado_pedido_nombre,
                COALESCE(SUM(${expresionPrecioFinal('ph')} * pp.cantidad), 0)::text AS total,
                COUNT(pp.id_pedido_producto)::int AS cantidad_lineas,
                mp.metodo_nombre AS metodo_pago,
                epa.estado_pago_nombre AS estado_pago,
                pg.fecha_cancelacion
         FROM pedido p
         JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
         LEFT JOIN pedido_producto pp ON pp.id_pedido = p.id_pedido
         LEFT JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
         LEFT JOIN pago pg ON pg.id_pedido = p.id_pedido
         LEFT JOIN metodo_pago mp ON mp.id_metodo_pago = pg.id_metodo_pago
         LEFT JOIN estado_pago epa ON epa.id_estado_pago = pg.id_estado_pago
         WHERE p.id_usuario = $1
           -- El pendiente es el carrito (se ve en GET /carrito), no un pedido.
           AND ep.estado_pedido_nombre <> 'pendiente'
         GROUP BY p.id_pedido, p.fecha_creacion, p.id_estado_pedido, ep.estado_pedido_nombre,
                  mp.metodo_nombre, epa.estado_pago_nombre, pg.fecha_cancelacion
         ORDER BY p.fecha_creacion DESC`,
        [idUsuario],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Trae un pedido propio completo: el pedido, la version de la direccion
   * que regia al crearlo y sus lineas (vacio si todavia no tiene
   * ninguna), cada una con su precio y su oferta ya resueltos con un JOIN
   * contra precio_historial y oferta -- el precio ya no se copia directo
   * en pedido_producto, se llega a el por id_precio_historial. Consulta
   * rapida, sin tocar Mongo: nombre_producto, nombre_variante y
   * nombre_vendedor ya estan copiados en la linea.
   *
   * Cada linea trae ademas `id_resena` y `puede_resenar`
   * (`docs/BACKEND-PENDIENTE.md`, bloque 5 -- el frontend ya esta escrito
   * contra estos dos nombres, no contra un booleano de "ya reseno"), misma
   * regla que `ResenasService.exigirCompraPagada` mas los dos casos que el
   * bloque marca como trampas: no ofrecer el boton si ya existe la resena,
   * y no ofrecerlo si el vendedor de la linea sos vos mismo (la tabla
   * `resena` tiene `CHECK (id_usuario <> id_usuario_vendedor)`).
   *
   * Solo si es propio: el WHERE exige ese id_usuario, asi que un pedido
   * ajeno da el mismo ErrorNoEncontrado que uno que no existe.
   */
  async obtener(
    idPedidoParametro: string,
    idUsuario: string,
  ): Promise<PedidoCompleto> {
    if (!REGEX_ID.test(idPedidoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }

    try {
      const resultadoPedido = await pool.query<{
        id_pedido: string;
        pedido_fecha_creacion: Date;
        id_usuario: string;
        id_direccion_historial: string;
        id_estado_pedido: number;
        estado_pedido_nombre: string;
        id_direccion: string;
        pais: string;
        departamento: string;
        ciudad: string;
        direccion_exacta: string | null;
        codigo_postal: string | null;
        direccion_fecha_creacion: Date;
      }>(
        `SELECT p.id_pedido, p.fecha_creacion AS pedido_fecha_creacion, p.id_usuario,
                p.id_direccion_historial, p.id_estado_pedido, ep.estado_pedido_nombre,
                dh.id_direccion, dh.pais, dh.departamento, dh.ciudad,
                dh.direccion_exacta, dh.codigo_postal,
                dh.fecha_creacion AS direccion_fecha_creacion
         FROM pedido p
         JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
         JOIN direccion_historial dh ON dh.id_direccion_historial = p.id_direccion_historial
         WHERE p.id_pedido = $1 AND p.id_usuario = $2
           -- El pendiente es el carrito: da el mismo 404 que uno que no existe.
           AND ep.estado_pedido_nombre <> 'pendiente'`,
        [idPedidoParametro, idUsuario],
      );
      const fila = resultadoPedido.rows[0];

      if (fila == null) {
        throw new ErrorNoEncontrado('No existe un pedido con ese id');
      }

      const resultadoDetalles = await pool.query<DetallePedido>(
        `SELECT pp.id_pedido_producto, pp.id_pedido, pp.id_precio_historial,
                pp.id_producto_mongo, pp.id_producto_variante_mongo, pp.cantidad,
                pp.nombre_producto, pp.nombre_variante, pp.nombre_vendedor,
                ${expresionPrecioFinal('ph')}::text AS precio_unitario,
                ph.porcentaje_descuento AS porcentaje_descuento_aplicado,
                ph.id_oferta,
                o.id_usuario AS id_usuario_vendedor,
                (
                  SELECT r.id_resena FROM resena r
                  WHERE r.id_usuario = $2
                    AND r.id_usuario_vendedor = o.id_usuario
                    AND r.id_producto_mongo = pp.id_producto_mongo
                ) AS id_resena,
                (
                  epe.estado_pedido_nombre <> 'cancelado'
                  AND o.id_usuario <> $2
                  AND NOT EXISTS (
                    SELECT 1 FROM resena r
                    WHERE r.id_usuario = $2
                      AND r.id_usuario_vendedor = o.id_usuario
                      AND r.id_producto_mongo = pp.id_producto_mongo
                  )
                  AND EXISTS (
                    SELECT 1 FROM pago pg
                    JOIN estado_pago epa ON epa.id_estado_pago = pg.id_estado_pago
                    WHERE pg.id_pedido = pp.id_pedido AND epa.estado_pago_nombre = 'pagado'
                  )
                ) AS puede_resenar
         FROM pedido_producto pp
         JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
         JOIN oferta o ON o.id_oferta = ph.id_oferta
         JOIN pedido pe ON pe.id_pedido = pp.id_pedido
         JOIN estado_pedido epe ON epe.id_estado_pedido = pe.id_estado_pedido
         WHERE pp.id_pedido = $1
         ORDER BY pp.id_pedido_producto`,
        [idPedidoParametro, idUsuario],
      );

      return {
        pedido: {
          id_pedido: fila.id_pedido,
          fecha_creacion: fila.pedido_fecha_creacion,
          id_usuario: fila.id_usuario,
          id_direccion_historial: fila.id_direccion_historial,
          id_estado_pedido: fila.id_estado_pedido,
          estado_pedido_nombre: fila.estado_pedido_nombre,
        },
        direccion: {
          id_direccion_historial: fila.id_direccion_historial,
          id_direccion: fila.id_direccion,
          pais: fila.pais,
          departamento: fila.departamento,
          ciudad: fila.ciudad,
          direccion_exacta: fila.direccion_exacta,
          codigo_postal: fila.codigo_postal,
          fecha_creacion: fila.direccion_fecha_creacion,
        },
        detalles: resultadoDetalles.rows,
      };
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /** El catalogo (cerrado) de formas de pago, para armar el selector del checkout. */
  async metodosPago(): Promise<MetodoPago[]> {
    try {
      const resultado = await pool.query<MetodoPago>(
        'SELECT id_metodo_pago, metodo_nombre FROM metodo_pago ORDER BY id_metodo_pago',
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Cancela un pedido propio, llamando a cancelar_pedido(). Si estaba
   * comprado, la propia funcion devuelve las unidades con un movimiento de
   * devolucion; si estaba pendiente, no toca el stock porque nunca se
   * descontó. En cualquier caso donde si hubo movimiento, pone al dia los
   * cuatro numeros calculados de los productos afectados en Mongo (ver
   * comprarPedido).
   */
  async cancelarPedido(
    idPedidoParametro: string,
    idUsuario: string,
    ip: string,
  ): Promise<CancelacionResultado> {
    if (!REGEX_ID.test(idPedidoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idPedido = Number(idPedidoParametro);

    const { estadoPedido } = await this.verificarPedidoPropio(idPedido, idUsuario);
    if (estadoPedido === 'pendiente') {
      // El pendiente es el carrito: cancelarlo lo dejaria a medias en Redis.
      throw new ErrorConflicto(
        'Ese pedido es tu carrito: para vaciarlo usa DELETE /carrito',
      );
    }

    try {
      const resultado = await pool.query<{
        cancelar_pedido: CancelacionResultado;
      }>('SELECT cancelar_pedido($1)', [idPedido]);
      const cancelacion = resultado.rows[0].cancelar_pedido;

      if (cancelacion.stock.length > 0) {
        // Las unidades volvieron al stock de PostgreSQL. Si alguna oferta esta
        // en venta relampago, el contador de Redis no lo sabe: se reconstruye
        // desde PostgreSQL en la proxima reconciliacion (una oferta sin venta
        // vigente no hace nada).
        for (const { id_oferta } of cancelacion.stock) {
          this.inventarioLimitadoService.marcarParaRestaurar(Number(id_oferta));
        }
        // Los campos calculados de Mongo los recalcula el worker de
        // `evento_producto` (lo encola el trigger de `oferta`).

        // Evento de analitica en ClickHouse (plan pendiente/eventos-clickhouse.md).
        // Solo cuando el pedido SI estaba comprado (stock.length > 0) -- uno
        // pendiente nunca llego a "compra" en el embudo, asi que cancelarlo
        // no es una devolucion que valga la pena medir. Fire-and-forget, SIN
        // `await`: mismo criterio que `registrarCompra`.
        const lineas = await pool.query<{
          id_producto: string;
          id_oferta: string;
          cantidad: number;
        }>(
          `SELECT pp.id_producto_mongo AS id_producto, ph.id_oferta, pp.cantidad
             FROM pedido_producto pp
             JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
            WHERE pp.id_pedido = $1`,
          [idPedido],
        );
        // Deteccion de fraude: reseñar y cancelar la compra. Es la cancelacion
        // la que completa el patron (al escribir la reseña todavia no pasaba).
        // Fire-and-forget: no retrasa la respuesta, un error solo se loguea.
        void this.resenasCanceladasDetectorService.detectarInmediato(idPedido);
        void this.eventosService.registrarDevolucion({
          idUsuario,
          idPedido,
          ip,
          lineas: lineas.rows.map((linea) => ({
            idProducto: Number(linea.id_producto),
            idOferta: Number(linea.id_oferta),
            cantidad: linea.cantidad,
          })),
        });
      }

      return cancelacion;
    } catch (error) {
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /** El pedido tiene que existir y ser del usuario logueado. */
  /**
   * Devuelve el nombre del estado del pedido de paso, para que
   * comprarPedido() pueda rechazar un pedido que ya no esta pendiente
   * ANTES de correr el mock de tarjeta -- ver el comentario en
   * comprarPedido() sobre por que el orden importa.
   */
  private async verificarPedidoPropio(
    idPedido: number,
    idUsuario: string,
  ): Promise<{ estadoPedido: string }> {
    try {
      const resultado = await pool.query<{
        id_usuario: string;
        estado_pedido_nombre: string;
      }>(
        `SELECT p.id_usuario, ep.estado_pedido_nombre
         FROM pedido p
         JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
         WHERE p.id_pedido = $1`,
        [idPedido],
      );
      const pedido = resultado.rows[0];

      if (pedido == null || Number(pedido.id_usuario) !== Number(idUsuario)) {
        throw new ErrorNoEncontrado('No existe un pedido con ese id');
      }
      return { estadoPedido: pedido.estado_pedido_nombre };
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * 23503 (foreign_key_violation) y 23514 (check_violation) son los dos
   * codigos con los que las funciones de pedido levantan sus propios
   * errores de negocio (estado, stock) via RAISE EXCEPTION. A este punto
   * ya se resolvieron la existencia del pedido, el dueno y el formato de
   * los datos, asi que lo unico que puede seguir fallando con estos
   * codigos es lo que solo Postgres sabe en el momento: el estado del
   * pedido, de la oferta, o el stock disponible.
   */
  private esErrorDeNegocio(error: unknown): boolean {
    const codigo = (error as { code?: string } | undefined)?.code;
    return codigo === '23503' || codigo === '23514';
  }
}
