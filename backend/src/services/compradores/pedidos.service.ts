import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { ErrorConflicto, ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { esTextoNoVacio } from '../../helpers/validaciones-perfil';
import { validarCantidadMovimiento } from '../../helpers/validaciones-inventario';
import { validarIdOferta } from '../../helpers/validaciones-pedido';
import { validarYCobrarTarjeta } from '../../helpers/validaciones-tarjeta';
import { AgregarLineaPeticion, LineaPedidoResultado } from '../../dto/agregar-linea-pedido';
import { RestarLineaPeticion, LineaRestada } from '../../dto/restar-linea-pedido';
import { CrearPedidoPeticion } from '../../dto/crear-pedido';
import {
  CambiarDireccionPedidoPeticion,
  PedidoDireccionCambiada,
} from '../../dto/cambiar-direccion-pedido';
import { PedidoCompleto } from '../../dto/pedido-completo';
import { PedidoResumen } from '../../dto/listar-pedidos';
import {
  AvisoPrecioPedido,
  ComprarPedidoPeticion,
  ComprarPedidoRespuesta,
  StockResultanteOferta,
} from '../../dto/comprar-pedido';
import { CancelacionResultado } from '../../dto/cancelar-pedido';
import { DetallePedido } from '../../models/pedido-producto';
import { MetodoPago, METODO_PAGO_TARJETA } from '../../models/metodo-pago';
import { ProductosService } from '../productos/productos.service';
import { EventosService } from '../eventos/eventos.service';

const REGEX_ID = /^\d+$/;

/** Lo que devuelve comprar_pedido() de PostgreSQL, tal cual, antes de envolverlo en la respuesta. */
interface CompraResultadoPostgres {
  id_pedido: number;
  total: string;
  stock: StockResultanteOferta[];
}

/**
 * Servicio de /comprador/pedidos: armar el pedido (crear, agregar/quitar
 * lineas), consultarlo (uno o el listado propio), pagarlo y cancelarlo.
 *
 * Sin restriccion de rol: cualquiera con sesion puede comprar (comprador,
 * vendedor o admin), a diferencia de /vendedor/productos o /admin/*.
 *
 * Las funciones del flujo de pedido viven en PostgreSQL
 * (migrations/007_flujo_pedido.sql) y no se tocan: este servicio solo las
 * llama, resolviendo antes lo que Postgres no puede saber por su cuenta
 * (los nombres de Mongo, de quien es el pedido -- que ninguna funcion
 * comprueba) y poniendo al dia despues los cuatro numeros calculados del
 * catalogo en Mongo (ver ProductosService.recalcularCamposCalculados).
 */
@Injectable()
export class PedidosCompradorService {
  private readonly logger = new Logger(PedidosCompradorService.name);

  constructor(
    private readonly productosService: ProductosService,
    private readonly eventosService: EventosService,
  ) {}

  /**
   * Abre un pedido vacio en estado "pendiente", llamando a
   * crear_pedido(id_usuario, id_direccion_historial) de PostgreSQL. No
   * toca stock todavia: eso pasa despues, al agregar lineas y comprar.
   *
   * crear_pedido pide el id_direccion_historial (la version de la
   * direccion, congelada), no el id_direccion normal. Quien compra solo
   * conoce su direccion por id_direccion, asi que primero se resuelve cual
   * es su version mas reciente en direccion_historial -- la misma
   * consulta exige de paso que esa direccion sea del usuario logueado, asi
   * que una direccion ajena da el mismo 404 que una que no existe (mismo
   * criterio que ya usa DireccionUsuarioService).
   */
  async crear(idUsuario: string, datos: CrearPedidoPeticion): Promise<string> {
    const idDireccion = this.resolverIdDireccionPeticion(datos.id_direccion);
    const idDireccionHistorial = await this.resolverDireccionHistorial(
      idUsuario,
      idDireccion,
    );

    try {
      const resultado = await pool.query<{ crear_pedido: string }>(
        'SELECT crear_pedido($1, $2)',
        [idUsuario, idDireccionHistorial],
      );

      return resultado.rows[0].crear_pedido;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Cambia la direccion de un pedido pendiente, llamando a
   * cambiar_direccion_pedido(id_pedido, id_direccion_historial). Solo
   * mientras esta pendiente -- comprado, enviado o cancelado rechazan con
   * 409, misma logica que agregar_linea/quitar_linea. Un pedido ajeno da
   * el mismo 404 que uno que no existe (verificarPedidoPropio), y una
   * direccion ajena o inexistente tambien (resolverDireccionHistorial).
   */
  async cambiarDireccion(
    idPedidoParametro: string,
    idUsuario: string,
    datos: CambiarDireccionPedidoPeticion,
  ): Promise<PedidoDireccionCambiada> {
    if (!REGEX_ID.test(idPedidoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idPedido = Number(idPedidoParametro);

    const idDireccion = this.resolverIdDireccionPeticion(datos.id_direccion);

    await this.verificarPedidoPropio(idPedido, idUsuario);

    const idDireccionHistorial = await this.resolverDireccionHistorial(
      idUsuario,
      idDireccion,
    );

    try {
      await pool.query('SELECT cambiar_direccion_pedido($1, $2)', [
        idPedido,
        idDireccionHistorial,
      ]);
    } catch (error) {
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    }

    return { id_pedido: idPedido, id_direccion: idDireccion };
  }

  /**
   * id_direccion es un bigint, y el driver pg lo devuelve como STRING para
   * no perder precision -- GET /direccion-usuario responde
   * { "id_direccion": "2" }, y exigir aqui solo number rechazaba justo lo
   * que esa misma API acababa de entregar. Se acepta number o ese string;
   * lo que no se acepta es texto que no sea un numero.
   */
  private resolverIdDireccionPeticion(valor: number | string): number {
    const idDireccion =
      typeof valor === 'string' && /^\d+$/.test(valor) ? Number(valor) : valor;

    if (
      typeof idDireccion !== 'number' ||
      !Number.isInteger(idDireccion) ||
      idDireccion <= 0
    ) {
      throw new ErrorValidacion(
        'El id_direccion es obligatorio y debe ser un numero entero mayor a 0',
      );
    }
    return idDireccion;
  }

  /**
   * La version mas reciente de esa direccion en direccion_historial --
   * exige de paso que sea del usuario logueado, asi que una direccion
   * ajena da el mismo 404 que una que no existe.
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
   * Agrega una oferta al pedido (o le suma la cantidad, si ya estaba),
   * llamando a agregar_linea(id_pedido, linea_jsonb). Una oferta por
   * llamada -- no admite lote.
   *
   * El cliente solo manda id_oferta y cantidad. El backend resuelve el
   * resto el mismo, sin confiar en nada que mande el cliente:
   *
   *   1. de la oferta en PostgreSQL sale el par de ids del catalogo en Mongo
   *   2. de Mongo sale el nombre del producto y el de la variante
   *
   * agregar_linea() congela el precio ahi mismo (busca la fila vigente de
   * precio_historial y guarda su id): si el vendedor lo sube despues, este
   * pedido conserva el que se le mostro. El nombre del vendedor tampoco
   * viene de aqui: lo pone la propia funcion, leyendolo de usuarios.
   *
   * Ninguna funcion de pedido comprueba de quien es el pedido -- eso lo
   * hace esta funcion antes de llamar a agregar_linea: un pedido ajeno da
   * el mismo 404 que uno que no existe. El estado de la oferta ("ya no se
   * puede comprar") y el stock ("no hay suficiente") si los comprueba la
   * propia funcion de Postgres; esos errores se traducen a ErrorConflicto
   * tal cual vienen, porque su mensaje ya es claro y seguro de mostrar.
   */
  async agregarLinea(
    idPedidoParametro: string,
    idUsuario: string,
    datos: AgregarLineaPeticion,
  ): Promise<LineaPedidoResultado> {
    if (!REGEX_ID.test(idPedidoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idPedido = Number(idPedidoParametro);

    const idOferta = validarIdOferta(datos.id_oferta);
    const cantidad = validarCantidadMovimiento(datos.cantidad);

    await this.verificarPedidoPropio(idPedido, idUsuario);

    const { idProductoMongo, idProductoVarianteMongo } =
      await this.resolverOferta(idOferta);

    // Publico, no "propio": cualquiera puede comprar cualquier producto
    // publicado, no solo los del vendedor logueado. Da el mismo 404 que
    // GET /productos/:id si el producto no existe o esta oculto
    // (borrador/inactivo).
    const producto = await this.productosService.obtenerPublico(
      String(idProductoMongo),
    );
    const variante = producto.variantes.find(
      (candidata) => candidata.id_producto_variante === idProductoVarianteMongo,
    );
    // Una variante inactiva se trata igual que un producto oculto: mismo
    // 404 generico, tanto si no existe como si existe pero esta apagada --
    // no se puede agregar al carrito en ninguno de los dos casos.
    if (variante == null || variante.estado !== 'activa') {
      throw new ErrorNoEncontrado('No existe una variante con ese id en este producto');
    }

    const linea = {
      id_oferta: idOferta,
      cantidad,
      id_producto: idProductoMongo,
      id_producto_variante: idProductoVarianteMongo,
      nombre_producto: producto.nombre,
      nombre_variante: variante.nombre_variante,
    };

    try {
      const resultado = await pool.query<{ agregar_linea: LineaPedidoResultado }>(
        'SELECT agregar_linea($1, $2::jsonb)',
        [idPedido, JSON.stringify(linea)],
      );
      return resultado.rows[0].agregar_linea;
    } catch (error) {
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * El "-1" de agregarLinea: resta cantidad de una oferta que ya esta en
   * el pedido, llamando a restar_linea(id_pedido, id_oferta, cantidad).
   * Si la resta deja la cantidad en 0 o menos, la linea se borra entera
   * (mismo resultado que quitarLinea, disparado por llegar a 0). Un
   * pedido ajeno da el mismo 404 de siempre; una oferta que no esta en
   * el pedido, o un pedido que ya no admite cambios, dan 409 -- los
   * resuelve la propia funcion de Postgres.
   */
  async restarLinea(
    idPedidoParametro: string,
    idUsuario: string,
    datos: RestarLineaPeticion,
  ): Promise<LineaRestada> {
    if (!REGEX_ID.test(idPedidoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idPedido = Number(idPedidoParametro);

    const idOferta = validarIdOferta(datos.id_oferta);
    const cantidad = validarCantidadMovimiento(datos.cantidad);

    await this.verificarPedidoPropio(idPedido, idUsuario);

    try {
      const resultado = await pool.query<{ restar_linea: LineaRestada }>(
        'SELECT restar_linea($1, $2, $3)',
        [idPedido, idOferta, cantidad],
      );
      return resultado.rows[0].restar_linea;
    } catch (error) {
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Saca una linea del pedido, llamando a quitar_linea(id_pedido,
   * id_oferta). Se recibe el id propio de la linea
   * (pedido_producto.id_pedido_producto), no la oferta directa -- se
   * resuelve aqui, en la misma consulta que comprueba que el pedido sea
   * del usuario logueado (un detalle ajeno, o de un pedido ajeno, da el
   * mismo 404 que uno que no existe).
   */
  async quitarLinea(
    idPedidoParametro: string,
    idDetalleParametro: string,
    idUsuario: string,
  ): Promise<void> {
    if (!REGEX_ID.test(idPedidoParametro) || !REGEX_ID.test(idDetalleParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idPedido = Number(idPedidoParametro);
    const idDetalle = Number(idDetalleParametro);

    try {
      const resultadoDetalle = await pool.query<{ id_oferta: string }>(
        `SELECT ph.id_oferta
         FROM pedido_producto pp
         JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
         JOIN pedido p ON p.id_pedido = pp.id_pedido
         WHERE pp.id_pedido_producto = $1 AND pp.id_pedido = $2 AND p.id_usuario = $3`,
        [idDetalle, idPedido, idUsuario],
      );
      const detalle = resultadoDetalle.rows[0];

      if (detalle == null) {
        throw new ErrorNoEncontrado('No existe un detalle con ese id');
      }

      const resultado = await pool.query<{ quitar_linea: boolean }>(
        'SELECT quitar_linea($1, $2)',
        [idPedido, detalle.id_oferta],
      );

      if (!resultado.rows[0].quitar_linea) {
        throw new ErrorNoEncontrado('No existe un detalle con ese id');
      }
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    }
  }

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
                COALESCE(SUM(ph.precio * pp.cantidad), 0)::text AS total,
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
         WHERE p.id_pedido = $1 AND p.id_usuario = $2`,
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
                ph.precio AS precio_unitario, ph.id_oferta,
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
   * Confirma la compra. Antes de tocar nada:
   *
   *   1. Revisa que el pedido siga "pendiente". Un pedido que ya esta
   *      comprado, cancelado, etc. rechaza con 409 aqui mismo -- ANTES de
   *      correr el mock de tarjeta, no despues. Si se corriera despues, una
   *      tarjeta de prueba que rechaza (ver validaciones-tarjeta.ts) le
   *      ganaria al 409 y un pedido ya comprado devolveria 402 en vez de
   *      "el pedido ya esta comprado", que es lo que de verdad paso.
   *      comprar_pedido() en SQL vuelve a hacer este mismo chequeo dentro
   *      de la transaccion (por si el estado cambio entre este SELECT y el
   *      COMMIT), pero para el caso comun -- pedido ya comprado antes de
   *      siquiera empezar -- el rechazo tiene que salir de aqui, con el
   *      mismo mensaje que ya documenta `endpoints-compradores.md`.
   *   2. Si el metodo es "tarjeta", corre el mock de validacion (formato,
   *      Luhn, vencimiento, CVV, y las tarjetas de prueba que simulan un
   *      rechazo) -- ver helpers/validaciones-tarjeta.ts. Rechaza con 400
   *      (formato invalido) o 402 (tarjeta rechazada) sin llegar a tocar
   *      el pedido.
   *   3. Revisa que ninguna oferta cambio desde que se agrego al carrito
   *      (revisarCambiosAntesDeComprar). Una oferta pausada/retirada o sin
   *      stock rechaza con 409, siempre. Un precio que ya no es el
   *      congelado no bloquea -- lo que se cobra es igual el precio
   *      congelado -- pero se avisa: sin `confirmar_cambios: true` la
   *      respuesta sale con `comprado: false` y la lista de avisos, sin
   *      tocar nada todavia.
   *
   * Solo entonces llama a comprar_pedido(), que es la que de verdad
   * descuenta el stock, registra el pago y pasa el pedido a "comprado".
   *
   * Los pasos 2 y la llamada a comprar_pedido() van en una sola transaccion
   * (BEGIN/COMMIT con un cliente dedicado, no con pool.query), y el SELECT
   * de revisarCambiosAntesDeComprar bloquea las filas de oferta que revisa
   * (FOR UPDATE OF o). Sin esto quedaba una ventana angosta: el chequeo y
   * comprar_pedido() eran dos consultas sueltas, y entre una y otra alguien
   * podia pausar/retirar la oferta (PATCH /vendedor/ofertas/:id) sin que
   * comprar_pedido() -- que solo revisa stock, nunca estado -- se enterara.
   * Con el bloqueo tomado desde el chequeo, ese PATCH se queda esperando a
   * que esta transaccion termine, y comprar_pedido() (que vuelve a pedir
   * FOR UPDATE sobre la misma fila, ya bloqueada por esta misma
   * transaccion) lee siempre el mismo estado que ya se valido.
   *
   * Con la compra ya confirmada en PostgreSQL, pone al dia en Mongo los
   * cuatro numeros calculados de cada producto afectado (ver
   * ProductosService.recalcularCamposCalculados) -- si eso fallara, no
   * deshace la compra: solo queda una tarjeta del catalogo desactualizada
   * un rato.
   */
  async comprarPedido(
    idPedidoParametro: string,
    idUsuario: string,
    datos: ComprarPedidoPeticion,
  ): Promise<ComprarPedidoRespuesta> {
    if (!REGEX_ID.test(idPedidoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idPedido = Number(idPedidoParametro);

    if (!esTextoNoVacio(datos.metodo_pago)) {
      throw new ErrorValidacion('El metodo_pago es obligatorio');
    }

    const { estadoPedido } = await this.verificarPedidoPropio(idPedido, idUsuario);

    if (estadoPedido !== 'pendiente') {
      throw new ErrorConflicto(`El pedido ${idPedido} ya esta ${estadoPedido}`);
    }

    if (datos.metodo_pago === METODO_PAGO_TARJETA) {
      validarYCobrarTarjeta(datos.tarjeta);
    }

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const { bloqueantes, avisos } = await this.revisarCambiosAntesDeComprar(
        cliente,
        idPedido,
      );

      if (bloqueantes.length > 0) {
        throw new ErrorConflicto(bloqueantes.join('; '));
      }
      if (avisos.length > 0 && datos.confirmar_cambios !== true) {
        await cliente.query('ROLLBACK');
        return { comprado: false, avisos };
      }

      const resultado = await cliente.query<{ comprar_pedido: CompraResultadoPostgres }>(
        'SELECT comprar_pedido($1, $2)',
        [idPedido, datos.metodo_pago],
      );
      await cliente.query('COMMIT');

      const compra = resultado.rows[0].comprar_pedido;
      const idsProducto = compra.stock.map((linea) => linea.id_producto);
      await this.productosService.recalcularCamposCalculados(idsProducto);

      return {
        comprado: true,
        id_pedido: compra.id_pedido,
        total: compra.total,
        stock: compra.stock,
      };
    } catch (error) {
      await this.intentarRollback(cliente);
      if (error instanceof ErrorConflicto) {
        throw error;
      }
      if (this.esErrorDeNegocio(error)) {
        throw new ErrorConflicto((error as Error).message);
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
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

    await this.verificarPedidoPropio(idPedido, idUsuario);

    try {
      const resultado = await pool.query<{ cancelar_pedido: CancelacionResultado }>(
        'SELECT cancelar_pedido($1)',
        [idPedido],
      );
      const cancelacion = resultado.rows[0].cancelar_pedido;

      if (cancelacion.stock.length > 0) {
        const idsProducto = cancelacion.stock.map((linea) => linea.id_producto);
        await this.productosService.recalcularCamposCalculados(idsProducto);

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
   * El par de ids de Mongo (producto, variante) de una oferta. La oferta
   * ya no lleva llave foranea contra el catalogo (ver
   * migrations/005_ofertas.sql), asi que esto es una consulta directa a
   * `oferta`, no un JOIN.
   */
  private async resolverOferta(
    idOferta: number,
  ): Promise<{ idProductoMongo: number; idProductoVarianteMongo: number }> {
    try {
      const resultado = await pool.query<{
        id_producto_mongo: string;
        id_producto_variante_mongo: string;
      }>(
        'SELECT id_producto_mongo, id_producto_variante_mongo FROM oferta WHERE id_oferta = $1',
        [idOferta],
      );
      const fila = resultado.rows[0];

      if (fila == null) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }

      return {
        idProductoMongo: Number(fila.id_producto_mongo),
        idProductoVarianteMongo: Number(fila.id_producto_variante_mongo),
      };
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Compara cada linea del pedido contra la oferta tal como esta HOY:
   *
   *   - oferta ya no activa (la pausaron o la retiraron), variante
   *     desactivada, o sin stock suficiente -> bloqueante: no se puede
   *     comprar, sin importar nada mas.
   *   - precio de hoy distinto del que quedo congelado en la linea ->
   *     aviso: no bloquea (lo que se cobra sigue siendo el congelado),
   *     pero se informa antes de seguir.
   *
   * Comparar precio_actual contra precio_congelado es texto contra texto
   * (los dos numeric(12,2) de Postgres, formateados igual): exacto, sin
   * el redondeo binario de comparar como numero de JavaScript.
   *
   * El estado de la variante no vive en PostgreSQL (el catalogo esta en
   * Mongo): se resuelve aparte, con una sola consulta a
   * ProductosService.obtenerEstadosVariante() para todas las lineas del
   * pedido -- una variante que se desactivo despues de agregarla al
   * carrito se trata igual que si el producto entero estuviera oculto: no
   * se puede comprar (mismo criterio que agregarLinea, que ya la rechaza
   * al agregarla).
   *
   * Corre dentro de la transaccion de comprarPedido(), con el `cliente` de
   * esa transaccion (no con `pool` directo): el `FOR UPDATE OF o` deja
   * bloqueadas las filas de oferta que revisa hasta que esa transaccion
   * termine, para que nada las cambie entre este chequeo y la llamada a
   * comprar_pedido() que viene despues. Los errores de conexion no se
   * atrapan aqui: se dejan subir para que comprarPedido() decida el
   * rollback.
   */
  private async revisarCambiosAntesDeComprar(
    cliente: PoolClient,
    idPedido: number,
  ): Promise<{ bloqueantes: string[]; avisos: AvisoPrecioPedido[] }> {
    const resultado = await cliente.query<{
      id_pedido_producto: number;
      nombre_producto: string;
      nombre_variante: string;
      cantidad: number;
      precio_congelado: string;
      precio_actual: string;
      stock: number;
      estado_oferta_nombre: string;
      id_producto_mongo: string;
      id_producto_variante_mongo: string;
    }>(
      `SELECT pp.id_pedido_producto, pp.nombre_producto, pp.nombre_variante, pp.cantidad,
              pp.id_producto_mongo, pp.id_producto_variante_mongo,
              ph.precio AS precio_congelado, o.precio AS precio_actual, o.stock,
              eo.estado_oferta_nombre
       FROM pedido_producto pp
       JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
       JOIN oferta o ON o.id_oferta = ph.id_oferta
       JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
       WHERE pp.id_pedido = $1
       FOR UPDATE OF o`,
      [idPedido],
    );

    const estadosVariante = await this.productosService.obtenerEstadosVariante(
      resultado.rows.map((fila) => Number(fila.id_producto_mongo)),
    );

    const bloqueantes: string[] = [];
    const avisos: AvisoPrecioPedido[] = [];

    for (const fila of resultado.rows) {
      if (fila.estado_oferta_nombre !== 'activa') {
        bloqueantes.push(
          `La oferta de "${fila.nombre_variante}" ya no esta disponible (${fila.estado_oferta_nombre})`,
        );
        continue;
      }
      const estadoVariante = estadosVariante.get(
        `${fila.id_producto_mongo}:${fila.id_producto_variante_mongo}`,
      );
      if (estadoVariante !== 'activa') {
        bloqueantes.push(
          `La variante "${fila.nombre_variante}" ya no esta disponible`,
        );
        continue;
      }
      if (fila.stock < fila.cantidad) {
        bloqueantes.push(
          `No hay suficiente stock de "${fila.nombre_variante}": quedan ${fila.stock} y el pedido pide ${fila.cantidad}`,
        );
        continue;
      }
      if (fila.precio_actual !== fila.precio_congelado) {
        avisos.push({
          id_pedido_producto: fila.id_pedido_producto,
          nombre_producto: fila.nombre_producto,
          nombre_variante: fila.nombre_variante,
          precio_congelado: fila.precio_congelado,
          precio_actual: fila.precio_actual,
        });
      }
    }

    return { bloqueantes, avisos };
  }

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo.
      // No hay nada mas que hacer; sigue el error original de quien llamo.
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
