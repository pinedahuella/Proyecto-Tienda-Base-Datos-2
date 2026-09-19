import { Injectable, Logger } from '@nestjs/common';
import { Decimal128, Document } from 'mongodb';
import { mongoDb } from '../../database/mongo';
import { pool } from '../../database/postgres';
import { ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { CORREO_TIENDA } from '../../helpers/constantes';
import { validarFechaHistorial } from '../../helpers/validaciones-direccion';
import { interpretarMomentoHistorial } from '../../helpers/momento-historial';
import {
  esNombreCaracteristicaValido,
  escaparRegex,
  interpretarFiltroCaracteristica,
  validarDespuesDe,
  validarEnteroPositivo,
  validarLimite,
  validarPagina,
  validarPrecio,
} from '../../helpers/validaciones-productos';
import {
  ListarProductosQuery,
  ProductosPagina,
} from '../../dto/listar-productos';
import {
  PaginarProductosQuery,
  ProductosPaginados,
} from '../../dto/paginar-productos';
import { Producto, ProductoConOfertas } from '../../models/producto';
import { OfertaVendedor, OfertaHistorial } from '../../models/oferta';
import { ESTADO_PRODUCTO_VISIBLE } from '../../models/estado-producto';
import { InventarioLimitadoService } from '../inventario-limitado/inventario-limitado.service';

/** Fila cruda que devuelve la consulta de ofertas, antes de agrupar el vendedor. */
interface FilaOferta {
  id_oferta: string;
  id_producto_variante_mongo: string;
  id_usuario: string;
  usuario: string;
  nombre: string;
  apellido: string | null;
  es_tienda: boolean;
  es_inventario_limitado: boolean;
  precio: string;
  stock: number;
  fecha_actualizacion: Date;
}

/** Los cinco numeros calculados de una variante, ya agregados por Postgres. */
interface FilaCalculoVariante {
  id_producto_variante_mongo: string;
  precio_tienda: string | null;
  precio_desde: string | null;
  stock_tienda: number;
  stock_total: number;
  total_ofertas: number;
}

/**
 * Query params fijos de GET /productos y GET /productos/paginacion.
 * Cualquier otro que llegue se trata como un filtro dinamico de
 * caracteristicas_adicionales (ver validaciones-productos.ts). Las dos
 * rutas comparten esta misma lista: "pagina" no le estorba a la ruta por
 * cursor ni "despues_de" a la de paginacion, porque cada una simplemente no
 * manda el query param de la otra.
 */
const REGEX_ID = /^\d+$/;

const CLAVES_RESERVADAS = new Set([
  'limite',
  'despues_de',
  'pagina',
  'nombre',
  'estado',
  'id_categoria',
  'precio_min',
  'precio_max',
  'precio_tienda_min',
  'precio_tienda_max',
  'estado_variante',
  'stock_min',
  'stock_max',
  'stock_tienda_min',
  'stock_tienda_max',
  'resenas_promedio_min',
  'resenas_promedio_max',
  'resenas_total_min',
  'resenas_total_max',
]);

/** Los filtros que las dos rutas de listado tienen en comun. */
type FiltrosProductosQuery = Record<string, string | undefined>;

@Injectable()
export class ProductosService {
  private readonly logger = new Logger(ProductosService.name);

  constructor(private readonly inventarioLimitado: InventarioLimitadoService) {}

  /**
   * Lista productos paginados por cursor (por _id, que es el mismo
   * id_producto bigserial de PostgreSQL: siempre creciente). Pensado para
   * scroll infinito: cada tanda trae el cursor para pedir la siguiente, no
   * un numero de pagina.
   *
   * Admite filtros fijos (nombre, estado, categoria, precio, estado de
   * variante, stock total y de la tienda, nota media y numero de resenas) y
   * filtros dinamicos sobre caracteristicas_adicionales, tanto del producto
   * como de sus variantes. precio_tienda, precio_desde, stock_tienda,
   * stock_total, total_ofertas, resenas_promedio y resenas_total ya vienen
   * calculados en el documento (los mantiene al dia el ETL y el backend
   * cuando cambia una oferta o se publica una resena), asi que filtrar por
   * ellos es un $match directo, sin agregacion previa.
   */
  async listar(query: ListarProductosQuery): Promise<ProductosPagina> {
    const limite = validarLimite(query.limite);
    const despuesDe = validarDespuesDe(query.despues_de);
    const filtro = this.construirFiltro(query);

    if (despuesDe != null) {
      filtro._id = { $gt: despuesDe };
    }

    try {
      const productos = await mongoDb
        .collection<Producto>('productos')
        .find(filtro)
        .sort({ _id: 1 })
        .limit(limite)
        .toArray();

      const siguienteCursor =
        productos.length === limite
          ? productos[productos.length - 1]._id
          : null;

      return { productos, siguiente_cursor: siguienteCursor };
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Lo mismo que listar(), mismos filtros y mismo comportamiento, pero
   * paginado por numero de pagina en vez de por cursor: admite saltar
   * directo a cualquier pagina, a cambio de tener que contar cuantos
   * productos hay en total para calcular total_paginas. Se usa $facet para
   * que la tanda y el conteo salgan de la misma foto del filtro, en vez de
   * dos consultas separadas que podrian ver estados distintos.
   */
  async listarPaginado(
    query: PaginarProductosQuery,
  ): Promise<ProductosPaginados> {
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const filtro = this.construirFiltro(query);
    const saltar = (pagina - 1) * limite;

    try {
      const pipeline: Document[] = [
        { $match: filtro },
        {
          $facet: {
            productos: [
              { $sort: { _id: 1 } },
              { $skip: saltar },
              { $limit: limite },
            ],
            total: [{ $count: 'total' }],
          },
        },
      ];

      const [resultado] = await mongoDb
        .collection<Producto>('productos')
        .aggregate<{
          productos: Producto[];
          total: { total: number }[];
        }>(pipeline)
        .toArray();

      const totalProductos = resultado.total[0]?.total ?? 0;
      const totalPaginas =
        totalProductos === 0 ? 0 : Math.ceil(totalProductos / limite);

      return {
        productos: resultado.productos,
        pagina,
        limite,
        total_productos: totalProductos,
        total_paginas: totalPaginas,
      };
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Un producto por id, publico. Igual que el listado, un producto
   * `inactivo` o `borrador` nunca aparece aqui: pedirlo directo por id da el
   * mismo 404 que un id que no existe, para no confirmar por otra via que
   * el producto existe pero esta oculto.
   *
   * Trae el documento de Mongo (los cinco numeros calculados de la
   * tienda/el total/lo mas barato) y le agrega sus ofertas reales -- quien la vende, a
   * como y con cuantas unidades -- pedidas a PostgreSQL en el momento, con
   * una sola consulta indexada (ver docs/base-de-datos.md, "El catalogo se
   * mudo a MongoDB"). No se copian a Mongo: precio, stock y estado cambian
   * en cada venta, y una copia ahi se desfasaria.
   */
  async obtenerPublico(
    idProductoParametro: string,
  ): Promise<ProductoConOfertas> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    let producto: Producto;
    try {
      const encontrado = await mongoDb
        .collection<Producto>('productos')
        .findOne({
          _id: idProducto,
          estado: ESTADO_PRODUCTO_VISIBLE,
        });

      if (encontrado == null) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }
      producto = encontrado;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }

    const ofertas = await this.obtenerOfertasReales(idProducto);

    return { ...producto, ofertas };
  }

  /**
   * El estado de cada variante de estos productos, indexado por
   * "id_producto:id_producto_variante". Usado por
   * PedidosCompradorService.revisarCambiosAntesDeComprar para rechazar la
   * compra si alguna variante se desactivo despues de que la linea se
   * agrego al carrito -- el estado de PRODUCTO ya lo protege
   * obtenerPublico() (y por transitividad, agregarLinea), pero el de cada
   * VARIANTE no se copia a PostgreSQL, asi que hay que volver a consultar
   * Mongo antes de comprar.
   *
   * Una sola consulta con `$in`, sin importar cuantas lineas tenga el
   * pedido -- mismo criterio que el resto del backend (nunca una consulta
   * a Mongo por linea).
   */
  async obtenerEstadosVariante(
    idsProducto: number[],
  ): Promise<Map<string, string>> {
    const idsUnicos = [...new Set(idsProducto)];
    try {
      const productos = await mongoDb
        .collection<Producto>('productos')
        .find(
          { _id: { $in: idsUnicos } },
          {
            projection: {
              _id: 1,
              'variantes.id_producto_variante': 1,
              'variantes.estado': 1,
            },
          },
        )
        .toArray();

      const estados = new Map<string, string>();
      for (const producto of productos) {
        for (const variante of producto.variantes) {
          estados.set(
            `${producto._id}:${variante.id_producto_variante}`,
            variante.estado,
          );
        }
      }
      return estados;
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Reconstruye un producto **como estaba en un momento específico**: toma
   * el evento de creación y todos los de modificación hasta ese momento, en
   * orden, y los fusiona uno encima del otro con el framework de agregación
   * de Mongo ($match, $sort, $group, $reduce, $mergeObjects) -- sin traer
   * los eventos a Node.js para combinarlos ahí.
   *
   * El query param `fecha` acepta `AAAA-MM-DD` (todo ese día, como siempre)
   * o `AAAA-MM-DDTHH:MM[:SS]` (hasta ese instante inclusive, hora en UTC);
   * ver `interpretarMomentoHistorial`.
   *
   * Ruta general, sin restricción de rol ni de dueño: cualquiera con
   * sesión puede pedir el historial de cualquier producto (el mismo
   * criterio que GET /productos/:id, público). Por eso no filtra por
   * estado ni por vendedor -- a diferencia de obtenerPublico(), tampoco
   * oculta `borrador`/`inactivo`: un pedido viejo tiene que poder mostrar
   * el producto tal como se veía al comprarlo, aunque hoy esté oculto o ya
   * no exista en el catálogo activo. Es la misma reconstrucción que ya
   * usaba `ProductosVendedorService.obtenerHistorialPropio` (antes
   * restringida a la tienda); ahora vive aquí porque ya no es una acción
   * de administración del catálogo, es solo lectura de un dato histórico.
   *
   * Cada evento aporta "datos" (solo la creación) o "cambios" (solo las
   * modificaciones); como cada uno es el estado completo de lo que cambió
   * (nunca un campo suelto), fusionarlos en orden con $mergeObjects
   * reconstruye el documento tal como estaba en ese momento.
   */
  async reconstruirEnFecha(
    idProductoParametro: string,
    fecha: string | undefined,
  ): Promise<Producto> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const momento = interpretarMomentoHistorial(fecha);
    const idProducto = Number(idProductoParametro);

    try {
      const productoActual = await mongoDb
        .collection<Producto>('productos')
        .findOne({ _id: idProducto });

      if (productoActual == null) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }

      const resultado = await mongoDb
        .collection('productos_eventos')
        .aggregate([
          {
            $match: {
              id_producto: idProducto,
              fecha: { [momento.comparador]: momento.limite },
            },
          },
          { $sort: { numero: 1 } },
          {
            $group: {
              _id: '$id_producto',
              eventos: { $push: { datos: '$datos', cambios: '$cambios' } },
            },
          },
          {
            $project: {
              _id: 0,
              producto: {
                $reduce: {
                  input: '$eventos',
                  initialValue: {},
                  in: {
                    $mergeObjects: [
                      '$$value',
                      { $ifNull: ['$$this.datos', {}] },
                      { $ifNull: ['$$this.cambios', {}] },
                    ],
                  },
                },
              },
            },
          },
        ])
        .toArray();

      if (resultado.length === 0) {
        throw new ErrorNoEncontrado('El producto no existia en esa fecha');
      }

      return {
        _id: idProducto,
        ...(resultado[0].producto as object),
      } as Producto;
    } catch (error) {
      if (
        error instanceof ErrorValidacion ||
        error instanceof ErrorNoEncontrado
      ) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Precio y stock de una oferta especifica, reconstruidos **como estaban
   * en una fecha especifica** -- mismo espiritu que reconstruirEnFecha(),
   * pero del lado economico (precio_historial + stock_movimiento), que
   * vive en PostgreSQL, no en Mongo. De cualquier oferta, no solo la de la
   * tienda: sirve para reconstruir un pedido viejo tal como se vio, sin
   * importar de que vendedor era la oferta que se compro.
   *
   * Publica, sin restriccion de rol ni de dueño -- mismo criterio que
   * reconstruirEnFecha(): cualquiera con sesion puede pedir el historial
   * de cualquier oferta.
   *
   * Dos consultas, ambas hasta la misma fecha limite (medianoche del dia
   * siguiente, zona Guatemala -06:00, igual que reconstruirEnFecha):
   *
   *   - precio: la ultima fila de precio_historial antes de esa fecha.
   *     Como el trigger oferta_registrar_precio (005_ofertas.sql) siempre
   *     escribe una fila al nacer la oferta, que no aparezca ninguna
   *     significa que la oferta todavia no existia en esa fecha -- de ahi
   *     sale el 404 "La oferta no existia en esa fecha".
   *   - stock: la ultima fila de stock_movimiento antes de esa fecha. A
   *     diferencia del precio, que no aparezca ninguna fila NO es un
   *     error: una oferta creada sin stock inicial nunca escribe una fila
   *     hasta la primera reposicion (ver OfertasVendedorService.crear), asi
   *     que "ninguna fila todavia" significa stock 0, no que la oferta no
   *     existiera.
   */
  async reconstruirOfertaEnFecha(
    idOfertaParametro: string,
    fecha: string | undefined,
  ): Promise<OfertaHistorial> {
    if (!REGEX_ID.test(idOfertaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    validarFechaHistorial(fecha);

    try {
      const existe = await pool.query<{ id_oferta: string }>(
        'SELECT id_oferta FROM oferta WHERE id_oferta = $1',
        [idOfertaParametro],
      );
      if (existe.rows.length === 0) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }

      // "hasta ese dia completo": mismo limite y misma zona horaria que
      // reconstruirEnFecha (ver el comentario ahi).
      const fechaLimite = new Date(`${fecha}T00:00:00.000-06:00`);
      fechaLimite.setUTCDate(fechaLimite.getUTCDate() + 1);

      const [precioResultado, stockResultado] = await Promise.all([
        pool.query<{ precio: string }>(
          `SELECT precio FROM precio_historial
           WHERE id_oferta = $1 AND fecha_creacion < $2
           ORDER BY fecha_creacion DESC LIMIT 1`,
          [idOfertaParametro, fechaLimite],
        ),
        pool.query<{ stock_resultante: number }>(
          `SELECT stock_resultante FROM stock_movimiento
           WHERE id_oferta = $1 AND fecha_movimiento < $2
           ORDER BY fecha_movimiento DESC LIMIT 1`,
          [idOfertaParametro, fechaLimite],
        ),
      ]);

      if (precioResultado.rows.length === 0) {
        throw new ErrorNoEncontrado('La oferta no existia en esa fecha');
      }

      return {
        id_oferta: idOfertaParametro,
        precio: precioResultado.rows[0].precio,
        stock: stockResultado.rows[0]?.stock_resultante ?? 0,
      };
    } catch (error) {
      if (
        error instanceof ErrorValidacion ||
        error instanceof ErrorNoEncontrado
      ) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Las ofertas de verdad de un producto: quien lo vende, a como y con
   * cuantas unidades, con el vendedor ya resuelto (JOIN a usuarios). Solo
   * las activas -- una pausada o retirada no se puede comprar, y ensenarla
   * en la ficha publica confundiria a quien compra. Ordenadas por variante
   * y despues por precio (la mas barata primero): el indice
   * idx_oferta_catalogo_precio de 005_ofertas.sql ya viene en ese orden.
   */
  private async obtenerOfertasReales(
    idProducto: number,
  ): Promise<OfertaVendedor[]> {
    try {
      const resultado = await pool.query<FilaOferta>(
        `SELECT o.id_oferta, o.id_producto_variante_mongo, o.id_usuario,
                u.usuario, u.nombre, u.apellido,
                (u.correo_electronico = $2) AS es_tienda,
                o.es_inventario_limitado,
                o.precio, o.stock, o.fecha_actualizacion
         FROM oferta o
         JOIN usuarios u ON u.id_usuario = o.id_usuario
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         WHERE o.id_producto_mongo = $1
           AND eo.estado_oferta_nombre = 'activa'
         ORDER BY o.id_producto_variante_mongo, o.precio`,
        [idProducto, CORREO_TIENDA],
      );

      const ofertas: OfertaVendedor[] = resultado.rows.map((fila) => ({
        id_oferta: fila.id_oferta,
        id_producto_variante_mongo: fila.id_producto_variante_mongo,
        vendedor: {
          id_usuario: fila.id_usuario,
          usuario: fila.usuario,
          nombre: fila.nombre,
          apellido: fila.apellido,
        },
        es_tienda: fila.es_tienda,
        es_inventario_limitado: fila.es_inventario_limitado,
        precio: fila.precio,
        stock: fila.stock,
        stock_disponible: null,
        fecha_actualizacion: fila.fecha_actualizacion,
      }));

      // En una oferta en venta relampago el `stock` de arriba es el de
      // PostgreSQL, que queda congelado desde que se abrio la venta. Las
      // unidades de verdad las lleva Redis: se piden con la operacion
      // `estado` del `.lua`, una por oferta limitada (suelen ser pocas por
      // producto). Si Redis no responde, `estado` devuelve null y la ficha
      // se pinta igual con el stock de PostgreSQL.
      await Promise.all(
        ofertas
          .filter((oferta) => oferta.es_inventario_limitado)
          .map(async (oferta) => {
            const estado = await this.inventarioLimitado.estado(
              Number(oferta.id_oferta),
            );
            oferta.stock_disponible = estado?.stock ?? null;
          }),
      );

      return ofertas;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Recalcula los campos que Mongo guarda como copia de lo que vive en
   * PostgreSQL y los deja al dia con $set:
   *
   *   - de las ofertas (`oferta`): precio_tienda, precio_desde, stock_tienda,
   *     stock_total y total_ofertas, tanto en la raiz como en cada variante.
   *   - de las resenas (`resena`): resenas_promedio y resenas_total, solo en
   *     la raiz (una resena apunta a producto + vendedor, nunca a una
   *     variante).
   *
   * Hay que llamarla despues de cualquier cosa que cambie una oferta
   * (comprar, cancelar, publicar una oferta nueva, cambiarle el precio o el
   * estado) y despues de publicar una resena. Son copias, no la verdad (ver
   * docs/base-de-datos.md) -- por eso hay que recalcularlas a mano en vez de
   * esperar a la proxima corrida del ETL.
   *
   * Un producto a la vez: despues de comprar_pedido()/cancelar_pedido() o de
   * una resena normalmente es uno o dos productos distintos, nunca el
   * catalogo entero, asi que no hace falta una sola consulta masiva.
   */
  async recalcularCamposCalculados(idsProductoMongo: number[]): Promise<void> {
    const idsUnicos = [...new Set(idsProductoMongo)];
    for (const idProducto of idsUnicos) {
      await this.recalcularUnProducto(idProducto);
    }
  }

  private async recalcularUnProducto(idProducto: number): Promise<void> {
    try {
      const [porVariante, totalEnRaiz, resumenResenas] = await Promise.all([
        pool.query<FilaCalculoVariante>(
          `WITH tienda AS (
             SELECT id_usuario FROM usuarios WHERE correo_electronico = $2
           ),
           activa AS (
             SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = 'activa'
           )
           SELECT
             o.id_producto_variante_mongo,
             MAX(CASE WHEN o.id_usuario = (SELECT id_usuario FROM tienda)
                      THEN o.precio END)::text AS precio_tienda,
             MIN(CASE WHEN o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                      THEN o.precio END)::text AS precio_desde,
             COALESCE(SUM(CASE WHEN o.id_usuario = (SELECT id_usuario FROM tienda)
                               AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                          THEN o.stock ELSE 0 END), 0)::int AS stock_tienda,
             COALESCE(SUM(CASE WHEN o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                          THEN o.stock ELSE 0 END), 0)::int AS stock_total,
             COUNT(DISTINCT CASE WHEN o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                             THEN o.id_usuario END)::int AS total_ofertas
           FROM oferta o
           WHERE o.id_producto_mongo = $1
           GROUP BY o.id_producto_variante_mongo`,
          [idProducto, CORREO_TIENDA],
        ),
        pool.query<{ total_ofertas: number }>(
          `SELECT COUNT(DISTINCT o.id_usuario)::int AS total_ofertas
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
           WHERE o.id_producto_mongo = $1 AND eo.estado_oferta_nombre = 'activa'`,
          [idProducto],
        ),
        // Nota media y total de resenas del producto (todas, entre todos los
        // vendedores). AVG da NULL y COUNT da 0 cuando no hay ninguna.
        pool.query<{ promedio: string | null; total: number }>(
          `SELECT ROUND(AVG(calificacion), 2)::text AS promedio,
                  COUNT(*)::int AS total
           FROM resena
           WHERE id_producto_mongo = $1`,
          [idProducto],
        ),
      ]);

      const resenasTotal = resumenResenas.rows[0]?.total ?? 0;
      const resenasPromedio =
        resenasTotal > 0 ? Number(resumenResenas.rows[0].promedio) : 0;

      // Sin ofertas (nunca deberia pasar para un producto que ya tuvo una
      // compra, pero por si acaso): no hay campos de oferta que recalcular,
      // pero los de resenas si -- un producto puede recibir su primera
      // resena sin que nada cambie del lado de las ofertas.
      if (porVariante.rows.length === 0) {
        const soloResenas: Record<string, unknown> = {
          resenas_promedio: resenasPromedio,
          resenas_total: resenasTotal,
          pendiente_busqueda: true,
        };
        await mongoDb
          .collection<Producto>('productos')
          .updateOne({ _id: idProducto }, { $set: soloResenas });
        return;
      }

      const precios = porVariante.rows
        .map((fila) => fila.precio_tienda)
        .filter((precio): precio is string => precio != null)
        .map(Number);
      const precioTiendaRaiz =
        precios.length > 0 ? Math.min(...precios).toFixed(2) : null;

      // El minimo de los minimos de cada variante es el minimo del producto
      // entero: mismo resultado que consultarlo aparte sin agrupar por
      // variante (ver etl/extraer.sql), sin una segunda consulta.
      const preciosDesde = porVariante.rows
        .map((fila) => fila.precio_desde)
        .filter((precio): precio is string => precio != null)
        .map(Number);
      const precioDesdeRaiz =
        preciosDesde.length > 0 ? Math.min(...preciosDesde).toFixed(2) : null;

      const stockTiendaRaiz = porVariante.rows.reduce(
        (total, fila) => total + fila.stock_tienda,
        0,
      );
      const stockTotalRaiz = porVariante.rows.reduce(
        (total, fila) => total + fila.stock_total,
        0,
      );

      const conjuntoSet: Record<string, unknown> = {
        precio_tienda:
          precioTiendaRaiz != null
            ? Decimal128.fromString(precioTiendaRaiz)
            : null,
        precio_desde:
          precioDesdeRaiz != null
            ? Decimal128.fromString(precioDesdeRaiz)
            : null,
        stock_tienda: stockTiendaRaiz,
        stock_total: stockTotalRaiz,
        total_ofertas: totalEnRaiz.rows[0]?.total_ofertas ?? 0,
        resenas_promedio: resenasPromedio,
        resenas_total: resenasTotal,
        pendiente_busqueda: true,
      };
      const arrayFilters: Record<string, unknown>[] = [];

      porVariante.rows.forEach((fila, indice) => {
        const marcador = `v${indice}`;
        conjuntoSet[`variantes.$[${marcador}].precio_tienda`] =
          fila.precio_tienda != null
            ? Decimal128.fromString(fila.precio_tienda)
            : null;
        conjuntoSet[`variantes.$[${marcador}].precio_desde`] =
          fila.precio_desde != null
            ? Decimal128.fromString(fila.precio_desde)
            : null;
        conjuntoSet[`variantes.$[${marcador}].stock_tienda`] =
          fila.stock_tienda;
        conjuntoSet[`variantes.$[${marcador}].stock_total`] = fila.stock_total;
        conjuntoSet[`variantes.$[${marcador}].total_ofertas`] =
          fila.total_ofertas;
        arrayFilters.push({
          [`${marcador}.id_producto_variante`]: Number(
            fila.id_producto_variante_mongo,
          ),
        });
      });

      await mongoDb
        .collection<Producto>('productos')
        .updateOne(
          { _id: idProducto },
          { $set: conjuntoSet },
          { arrayFilters },
        );
    } catch (error) {
      // No se relanza: cuando esto se llama, la compra o la cancelacion ya
      // se confirmaron en PostgreSQL. Que falle la actualizacion de la
      // copia de lectura no puede deshacer una venta ya hecha -- dejar la
      // tarjeta del catalogo con un numero viejo un rato es peor UI, no un
      // dato incorrecto en la base de verdad.
      this.logger.error(
        `No se pudieron recalcular los campos calculados (precio/stock/resenas) del producto ${idProducto}: ` +
          (error instanceof Error ? error.message : String(error)),
      );
    }
  }

  /**
   * Arma el filtro de Mongo a partir de los query params ya validados. Lo
   * comparten listar() y listarPaginado(): los mismos filtros fijos y
   * dinamicos aplican en las dos rutas, solo cambia como se pagina despues.
   */
  private construirFiltro(
    query: FiltrosProductosQuery,
  ): Record<string, unknown> {
    const idCategoria = validarEnteroPositivo(
      query.id_categoria,
      'id_categoria',
    );
    const precioMin = validarPrecio(query.precio_min, 'precio_min');
    const precioMax = validarPrecio(query.precio_max, 'precio_max');
    const precioTiendaMin = validarPrecio(
      query.precio_tienda_min,
      'precio_tienda_min',
    );
    const precioTiendaMax = validarPrecio(
      query.precio_tienda_max,
      'precio_tienda_max',
    );
    const stockMin = validarEnteroPositivo(query.stock_min, 'stock_min');
    const stockMax = validarEnteroPositivo(query.stock_max, 'stock_max');
    const stockTiendaMin = validarEnteroPositivo(
      query.stock_tienda_min,
      'stock_tienda_min',
    );
    const stockTiendaMax = validarEnteroPositivo(
      query.stock_tienda_max,
      'stock_tienda_max',
    );
    const resenasPromedioMin = validarPrecio(
      query.resenas_promedio_min,
      'resenas_promedio_min',
    );
    const resenasPromedioMax = validarPrecio(
      query.resenas_promedio_max,
      'resenas_promedio_max',
    );
    const resenasTotalMin = validarEnteroPositivo(
      query.resenas_total_min,
      'resenas_total_min',
    );
    const resenasTotalMax = validarEnteroPositivo(
      query.resenas_total_max,
      'resenas_total_max',
    );

    const filtro: Record<string, unknown> = {};

    if (query.nombre) {
      filtro.nombre = { $regex: escaparRegex(query.nombre), $options: 'i' };
    }
    // Lista blanca, no lista negra: solo ESTADO_PRODUCTO_VISIBLE es parte de
    // la busqueda publica, sin importar que se pida -- no es un filtro
    // opcional que se pueda ampliar. Si ?estado= pide cualquier otro valor,
    // no hay (ni puede haber) ningun producto que lo cumpla a la vez que sea
    // visible: $in: [] es el idiom estandar de Mongo para "nunca hace match",
    // asi que la respuesta sigue siendo una lista vacia, nunca un error.
    const condicionEstado: Record<string, unknown> =
      query.estado != null && query.estado !== ESTADO_PRODUCTO_VISIBLE
        ? { $in: [] }
        : { $eq: ESTADO_PRODUCTO_VISIBLE };
    filtro.estado = condicionEstado;
    if (idCategoria != null) {
      filtro['categoria.id_categoria'] = idCategoria;
    }

    // Los dos precios ya vienen calculados en la raiz del documento: no hace
    // falta (ni se puede, desde el giro multi-vendedor) filtrar por el precio
    // de una variante suelta.
    //
    // precio_min/precio_max van sobre precio_desde, el mas barato que se puede
    // PAGAR, y no sobre el de la tienda. Es lo que espera quien busca: la
    // tarjeta ensena el precio de la tienda, pero si otro vendedor lo tiene
    // mas barato, el producto si le sirve a quien puso un tope. Con el filtro
    // sobre precio_tienda quedaban fuera 21 de los 34 productos del conjunto
    // de datos, cada uno con alguien vendiendolo mas barato.
    //
    // Quien de verdad quiera filtrar solo lo de la tienda tiene
    // precio_tienda_min/max, igual que stock_tienda_min/max para el stock.
    const rangoPrecio = this.construirRangoDecimal(precioMin, precioMax);
    if (rangoPrecio != null) {
      filtro.precio_desde = rangoPrecio;
    }

    const rangoPrecioTienda = this.construirRangoDecimal(
      precioTiendaMin,
      precioTiendaMax,
    );
    if (rangoPrecioTienda != null) {
      filtro.precio_tienda = rangoPrecioTienda;
    }

    if (query.estado_variante) {
      filtro.variantes = { $elemMatch: { estado: query.estado_variante } };
    }

    // stock_total (entre todos los vendedores activos) y stock_tienda (solo
    // la tienda) ya vienen calculados en la raiz: son dos preguntas
    // distintas ("hay quien lo venda" contra "lo tiene la tienda"), asi que
    // van en dos campos y no se combinan.
    if (stockMin != null || stockMax != null) {
      const rango: Record<string, number> = {};
      if (stockMin != null) {
        rango.$gte = stockMin;
      }
      if (stockMax != null) {
        rango.$lte = stockMax;
      }
      filtro.stock_total = rango;
    }
    if (stockTiendaMin != null || stockTiendaMax != null) {
      const rango: Record<string, number> = {};
      if (stockTiendaMin != null) {
        rango.$gte = stockTiendaMin;
      }
      if (stockTiendaMax != null) {
        rango.$lte = stockTiendaMax;
      }
      filtro.stock_tienda = rango;
    }

    // resenas_promedio (nota media, 1 a 5) y resenas_total (cuantas resenas)
    // ya vienen calculados en la raiz del documento -- las resenas apuntan a
    // producto + vendedor, nunca a una variante, asi que estos dos numeros no
    // bajan a variantes[]. resenas_promedio se compara como numero normal (es
    // un double en el documento, no Decimal128: no es dinero).
    const rangoResenasTotal: Record<string, number> = {};
    if (resenasTotalMin != null) {
      rangoResenasTotal.$gte = resenasTotalMin;
    }
    if (resenasTotalMax != null) {
      rangoResenasTotal.$lte = resenasTotalMax;
    }

    if (resenasPromedioMin != null || resenasPromedioMax != null) {
      const rango: Record<string, number> = {};
      if (resenasPromedioMin != null) {
        rango.$gte = Number(resenasPromedioMin);
      }
      if (resenasPromedioMax != null) {
        rango.$lte = Number(resenasPromedioMax);
      }
      filtro.resenas_promedio = rango;
      // Filtrar por nota implica "tiene notas": un producto sin resenas
      // (resenas_promedio = 0) no debe colarse en un resenas_promedio_max
      // bajo. Se exige >= 1 resena, sin pisar un resenas_total_min mayor que
      // el cliente ya haya pedido.
      if (rangoResenasTotal.$gte == null || rangoResenasTotal.$gte < 1) {
        rangoResenasTotal.$gte = 1;
      }
    }

    if (Object.keys(rangoResenasTotal).length > 0) {
      filtro.resenas_total = rangoResenasTotal;
    }

    // Filtros dinamicos: cualquier query param que no sea uno de los fijos
    // es una caracteristica adicional. Se busca tanto en el producto como en
    // sus variantes, sin exigir que sea la misma variante entre si de otros
    // filtros dinamicos.
    const condicionesDinamicas = this.construirFiltrosDinamicos(query);
    if (condicionesDinamicas.length > 0) {
      filtro.$and = condicionesDinamicas;
    }

    return filtro;
  }

  /**
   * Un rango de Mongo a partir de un minimo y un maximo ya validados, o null
   * si no vino ninguno de los dos. Existe para no repetir el mismo armado en
   * cada filtro de precio.
   *
   * El dinero se compara como Decimal128 y no como numero de JavaScript: el
   * documento lo guarda asi, y comparar decimal contra double obliga a Mongo a
   * convertir y puede perder centavos en el borde del rango.
   */
  private construirRangoDecimal(
    min: string | null,
    max: string | null,
  ): Record<string, Decimal128> | null {
    if (min == null && max == null) {
      return null;
    }
    const rango: Record<string, Decimal128> = {};
    if (min != null) {
      rango.$gte = Decimal128.fromString(min);
    }
    if (max != null) {
      rango.$lte = Decimal128.fromString(max);
    }
    return rango;
  }

  /**
   * caracteristicas_adicionales y caracteristicas_personalizadas son arrays
   * de { nombre, valor, unidad } (ver productos_subproductos.md): filtrar por
   * una caracteristica es buscar, dentro de ese array, un elemento cuyo
   * "nombre" sea la clave del query param (sin su prefijo de operador, ver
   * interpretarFiltroCaracteristica) y cuyo "valor" coincida — con
   * $elemMatch, para exigir que sean del MISMO elemento y no de dos
   * distintos. Se busca en las cuatro ubicaciones posibles (adicionales y
   * personalizadas, del producto y de cada variante) sin exigir que sea la
   * misma variante entre si de otros filtros dinamicos.
   *
   * Filtro universal: ademas de igualdad (`ram=16`), un prefijo pide
   * min_/max_/contiene_ (`min_ram=8`, `contiene_color=roj`), el mismo
   * operador para adicionales y personalizadas, sin necesidad de conocer su
   * tipo_dato de antemano — si el operador no calza con lo guardado en
   * Mongo, simplemente no hace match.
   *
   * Nota de seguridad: la clave y el valor del query param nunca se usan
   * para armar un nombre de campo (nunca algo como `objeto[clave]`); siempre
   * entran como VALORES dentro de llaves fijas (`nombre`, `valor`) que
   * escribe este codigo, nunca el usuario. Por eso no hace falta restringir
   * que caracteres trae el nombre de una caracteristica: aunque alguien
   * mande un query param con un "$" adentro, Mongo lo compara como texto
   * literal, nunca como operador.
   */
  private construirFiltrosDinamicos(
    query: FiltrosProductosQuery,
  ): Record<string, unknown>[] {
    const condiciones: Record<string, unknown>[] = [];

    for (const [clave, valorCrudo] of Object.entries(query)) {
      if (CLAVES_RESERVADAS.has(clave) || valorCrudo == null) {
        continue;
      }
      // Defensa adicional: si el parser de query alguna vez entrega algo
      // que no sea texto plano (por ejemplo, un array por un parametro
      // repetido), se descarta en vez de usarlo.
      if (typeof clave !== 'string' || typeof valorCrudo !== 'string') {
        continue;
      }

      const { nombreCaracteristica, condicionValor } =
        interpretarFiltroCaracteristica(clave, valorCrudo);

      if (!esNombreCaracteristicaValido(nombreCaracteristica)) {
        throw new ErrorValidacion(
          `El filtro "${nombreCaracteristica}" no es un nombre de caracteristica valido`,
        );
      }

      const elemMatch = { nombre: nombreCaracteristica, valor: condicionValor };

      condiciones.push({
        $or: [
          { caracteristicas_adicionales: { $elemMatch: elemMatch } },
          { caracteristicas_personalizadas: { $elemMatch: elemMatch } },
          {
            'variantes.caracteristicas_adicionales': { $elemMatch: elemMatch },
          },
          {
            'variantes.caracteristicas_personalizadas': {
              $elemMatch: elemMatch,
            },
          },
        ],
      });
    }

    return condiciones;
  }
}
