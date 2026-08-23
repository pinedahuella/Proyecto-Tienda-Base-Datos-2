import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { ErrorConflicto, ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import {
  validarCantidadMovimiento,
  validarIdProductoVariante,
} from '../../helpers/validaciones-inventario';
import { validarIdProducto } from '../../helpers/validaciones-pedido';
import { AgregarLineaPeticion, LineaPedidoResultado } from '../../dto/agregar-linea-pedido';
import { CrearPedidoPeticion } from '../../dto/crear-pedido';
import { PedidoCompleto } from '../../dto/pedido-completo';
import { PedidoProducto } from '../../models/pedido-producto';
import { ProductosService } from '../productos/productos.service';

const REGEX_ID = /^\d+$/;

/**
 * Servicio de POST /comprador/pedidos, POST /comprador/pedidos/:id/detalles
 * y DELETE /comprador/pedidos/:id/detalles/:idDetalle.
 *
 * Sin restriccion de rol: cualquiera con sesion puede comprar (comprador,
 * vendedor o admin), a diferencia de /vendedor/productos o /admin/*.
 *
 * Las cuatro funciones del flujo de pedido viven en PostgreSQL
 * (migrations/007_flujo_pedido.sql, ver cambios-etl-productos.md) y no se
 * tocan: este servicio solo las llama, resolviendo antes lo que Postgres
 * no puede saber por su cuenta (el nombre/precio/comision de Mongo, y de
 * quien es el pedido, que ninguna de las funciones comprueba).
 */
@Injectable()
export class PedidosCompradorService {
  private readonly logger = new Logger(PedidosCompradorService.name);

  constructor(private readonly productosService: ProductosService) {}

  /**
   * Abre un pedido vacio en estado "pendiente", llamando a
   * crear_pedido(id_usuario, id_direccion_historial) de PostgreSQL
   * (migrations/007_flujo_pedido.sql). No toca stock todavia: eso pasa
   * despues, al agregar lineas y comprar.
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
    if (
      typeof datos.id_direccion !== 'number' ||
      !Number.isInteger(datos.id_direccion) ||
      datos.id_direccion <= 0
    ) {
      throw new ErrorValidacion(
        'El id_direccion es obligatorio y debe ser un numero entero mayor a 0',
      );
    }

    try {
      const resultadoHistorial = await pool.query<{
        id_direccion_historial: string;
      }>(
        `SELECT dh.id_direccion_historial
         FROM direccion_historial dh
         JOIN direcciones d ON d.id_direccion = dh.id_direccion
         WHERE dh.id_direccion = $1 AND d.id_usuario = $2
         ORDER BY dh.fecha_creacion DESC
         LIMIT 1`,
        [datos.id_direccion, idUsuario],
      );
      const historial = resultadoHistorial.rows[0];

      if (historial == null) {
        throw new ErrorNoEncontrado('No existe una direccion con ese id');
      }

      const resultado = await pool.query<{ crear_pedido: string }>(
        'SELECT crear_pedido($1, $2)',
        [idUsuario, historial.id_direccion_historial],
      );

      return resultado.rows[0].crear_pedido;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Agrega una variante al pedido (o le suma la cantidad, si ya estaba),
   * llamando a agregar_linea(id_pedido, linea_jsonb). Una variante por
   * llamada -- no admite lote.
   *
   * agregar_linea exige nombre_producto, nombre_variante, precio_unitario
   * y porcentaje_comision como parte de la linea, porque viven en Mongo y
   * Postgres no los puede leer: se sacan de ahi antes de llamar, y quedan
   * congelados en la linea desde ese momento (si el vendedor sube el
   * precio despues, este pedido conserva el que se le mostro).
   *
   * Ninguna funcion de pedido comprueba de quien es el pedido -- eso lo
   * hace esta funcion antes de llamar a agregar_linea: un pedido ajeno da
   * el mismo 404 que uno que no existe. El estado ("ya no se puede
   * cambiar") y el stock ("no hay suficiente") si los comprueba la propia
   * funcion de Postgres; esos errores se traducen a ErrorConflicto tal
   * cual vienen, porque su mensaje ya es claro y seguro de mostrar.
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

    const idProducto = validarIdProducto(datos.id_producto);
    const idProductoVariante = validarIdProductoVariante(datos.id_producto_variante);
    const cantidad = validarCantidadMovimiento(datos.cantidad);

    await this.verificarPedidoPropio(idPedido, idUsuario);

    // Publico, no "propio": cualquiera puede comprar cualquier producto
    // publicado, no solo los del vendedor logueado. Da el mismo 404 que
    // GET /productos/:id si el producto no existe o esta oculto
    // (borrador/inactivo).
    const producto = await this.productosService.obtenerPublico(String(idProducto));
    const variante = producto.variantes.find(
      (candidata) => candidata.id_producto_variante === idProductoVariante,
    );
    if (variante == null) {
      throw new ErrorNoEncontrado('No existe una variante con ese id en este producto');
    }

    const linea = {
      id_producto: idProducto,
      id_producto_variante: idProductoVariante,
      nombre_producto: producto.nombre,
      nombre_variante: variante.nombre_variante,
      precio_unitario: variante.precio.toString(),
      porcentaje_comision: producto.categoria.porcentaje_comision.toString(),
      cantidad,
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
   * Saca una linea del pedido, llamando a
   * quitar_linea(id_pedido, id_producto, id_producto_variante). Se recibe
   * el id propio de la linea (pedido_producto.id_pedido_producto), no el
   * par producto+variante -- se resuelve aqui, en la misma consulta que
   * comprueba que el pedido sea del usuario logueado (un detalle ajeno, o
   * de un pedido ajeno, da el mismo 404 que uno que no existe).
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
      const resultadoDetalle = await pool.query<{
        id_producto_mongo: string;
        id_producto_variante_mongo: string;
      }>(
        `SELECT pp.id_producto_mongo, pp.id_producto_variante_mongo
         FROM pedido_producto pp
         JOIN pedido p ON p.id_pedido = pp.id_pedido
         WHERE pp.id_pedido_producto = $1 AND pp.id_pedido = $2 AND p.id_usuario = $3`,
        [idDetalle, idPedido, idUsuario],
      );
      const detalle = resultadoDetalle.rows[0];

      if (detalle == null) {
        throw new ErrorNoEncontrado('No existe un detalle con ese id');
      }

      const resultado = await pool.query<{ quitar_linea: boolean }>(
        'SELECT quitar_linea($1, $2, $3)',
        [idPedido, detalle.id_producto_mongo, detalle.id_producto_variante_mongo],
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
   * Trae un pedido propio completo: el pedido, la version de la direccion
   * que regia al crearlo y sus lineas (vacio si todavia no tiene
   * ninguna). Consulta rapida, sin tocar Mongo -- lo que hace falta para
   * mostrar el pedido ya esta copiado en pedido_producto (nombre, precio,
   * comision), justo para no tener que ir a buscarlo.
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
        codigo_postal: string | null;
        direccion_fecha_creacion: Date;
      }>(
        `SELECT p.id_pedido, p.fecha_creacion AS pedido_fecha_creacion, p.id_usuario,
                p.id_direccion_historial, p.id_estado_pedido, ep.estado_pedido_nombre,
                dh.id_direccion, dh.pais, dh.departamento, dh.ciudad, dh.codigo_postal,
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

      const resultadoDetalles = await pool.query<PedidoProducto>(
        `SELECT id_pedido_producto, id_pedido, id_producto_mongo, id_producto_variante_mongo,
                nombre_producto, nombre_variante, precio_unitario, porcentaje_comision, cantidad
         FROM pedido_producto
         WHERE id_pedido = $1
         ORDER BY id_pedido_producto`,
        [idPedidoParametro],
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

  /** El pedido tiene que existir y ser del usuario logueado. */
  private async verificarPedidoPropio(
    idPedido: number,
    idUsuario: string,
  ): Promise<void> {
    try {
      const resultado = await pool.query<{ id_usuario: string }>(
        'SELECT id_usuario FROM pedido WHERE id_pedido = $1',
        [idPedido],
      );
      const pedido = resultado.rows[0];

      if (pedido == null || Number(pedido.id_usuario) !== Number(idUsuario)) {
        throw new ErrorNoEncontrado('No existe un pedido con ese id');
      }
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
   * pedido o el stock disponible.
   */
  private esErrorDeNegocio(error: unknown): boolean {
    const codigo = (error as { code?: string } | undefined)?.code;
    return codigo === '23503' || codigo === '23514';
  }
}
