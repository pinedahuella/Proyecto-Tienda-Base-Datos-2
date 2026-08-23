import { Injectable, Logger } from '@nestjs/common';
import { Decimal128, Document } from 'mongodb';
import { mongoDb } from '../../database/mongo';
import { ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
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
import { Producto, ProductoConStockTotal } from '../../models/producto';
import { ESTADOS_PRODUCTO_OCULTOS } from '../../models/estado-producto';

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
  'id_vendedor',
  'precio_min',
  'precio_max',
  'estado_variante',
  'stock_min',
  'stock_max',
]);

/** El campo agregado (no guardado en Mongo) con la suma de variantes[].stock. */
const CAMPO_STOCK_TOTAL = 'stock_total';

/** Los filtros que las dos rutas de listado tienen en comun. */
type FiltrosProductosQuery = Record<string, string | undefined>;

@Injectable()
export class ProductosService {
  private readonly logger = new Logger(ProductosService.name);

  /**
   * Lista productos paginados por cursor (por _id, que es el mismo
   * id_producto bigserial de PostgreSQL: siempre creciente). Pensado para
   * scroll infinito: cada tanda trae el cursor para pedir la siguiente, no
   * un numero de pagina.
   *
   * Admite filtros fijos (nombre, estado, categoria, vendedor, precio,
   * estado de variante, stock_total) y filtros dinamicos sobre
   * caracteristicas_adicionales, tanto del producto como de sus variantes.
   */
  async listar(query: ListarProductosQuery): Promise<ProductosPagina> {
    const limite = validarLimite(query.limite);
    const despuesDe = validarDespuesDe(query.despues_de);
    const filtro = this.construirFiltro(query);

    if (despuesDe != null) {
      filtro._id = { $gt: despuesDe };
    }

    const matchStock = this.construirMatchStockTotal(query);

    try {
      const pipeline: Document[] = [
        { $match: filtro },
        { $addFields: { [CAMPO_STOCK_TOTAL]: { $sum: '$variantes.stock' } } },
      ];
      if (matchStock != null) {
        pipeline.push({ $match: matchStock });
      }
      pipeline.push({ $sort: { _id: 1 } }, { $limit: limite });

      const productos = await mongoDb
        .collection<Producto>('productos')
        .aggregate<ProductoConStockTotal>(pipeline)
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
   * productos hay en total para calcular total_paginas. El conteo tiene que
   * pasar por el mismo $addFields/$match de stock_total que la tanda (por
   * eso $facet en vez de countDocuments): si no, el total no cuadraria con
   * lo que en verdad cumple el filtro de stock.
   */
  async listarPaginado(
    query: PaginarProductosQuery,
  ): Promise<ProductosPaginados> {
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const filtro = this.construirFiltro(query);
    const saltar = (pagina - 1) * limite;
    const matchStock = this.construirMatchStockTotal(query);

    try {
      const pipeline: Document[] = [
        { $match: filtro },
        { $addFields: { [CAMPO_STOCK_TOTAL]: { $sum: '$variantes.stock' } } },
      ];
      if (matchStock != null) {
        pipeline.push({ $match: matchStock });
      }
      pipeline.push({
        $facet: {
          productos: [{ $sort: { _id: 1 } }, { $skip: saltar }, { $limit: limite }],
          total: [{ $count: 'total' }],
        },
      });

      const [resultado] = await mongoDb
        .collection<Producto>('productos')
        .aggregate<{
          productos: ProductoConStockTotal[];
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
   */
  async obtenerPublico(
    idProductoParametro: string,
  ): Promise<ProductoConStockTotal> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    try {
      const producto = await mongoDb.collection<Producto>('productos').findOne({
        _id: idProducto,
        estado: { $nin: ESTADOS_PRODUCTO_OCULTOS },
      });

      if (producto == null) {
        throw new ErrorNoEncontrado('No existe un producto con ese id');
      }

      return { ...producto, stock_total: this.sumarStockVariantes(producto) };
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /** La suma de variantes[].stock; una variante sin stock cuenta como 0. */
  private sumarStockVariantes(producto: Producto): number {
    return producto.variantes.reduce(
      (total, variante) => total + (variante.stock ?? 0),
      0,
    );
  }

  /**
   * El $match de stock_min/stock_max sobre el stock_total ya agregado, o
   * null si no vinieron. Va DESPUES del $addFields en el pipeline: Mongo no
   * puede filtrar por un campo que todavia no existe.
   */
  private construirMatchStockTotal(
    query: FiltrosProductosQuery,
  ): Record<string, unknown> | null {
    const stockMin = validarEnteroPositivo(query.stock_min, 'stock_min');
    const stockMax = validarEnteroPositivo(query.stock_max, 'stock_max');

    if (stockMin == null && stockMax == null) {
      return null;
    }

    const rango: Record<string, number> = {};
    if (stockMin != null) {
      rango.$gte = stockMin;
    }
    if (stockMax != null) {
      rango.$lte = stockMax;
    }
    return { [CAMPO_STOCK_TOTAL]: rango };
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
    const idVendedor = validarEnteroPositivo(query.id_vendedor, 'id_vendedor');
    const precioMin = validarPrecio(query.precio_min, 'precio_min');
    const precioMax = validarPrecio(query.precio_max, 'precio_max');

    const filtro: Record<string, unknown> = {};

    if (query.nombre) {
      filtro.nombre = { $regex: escaparRegex(query.nombre), $options: 'i' };
    }
    // Inactivo y borrador nunca son parte de la busqueda publica, sin
    // importar que se pida: no es un filtro opcional, es una exclusion fija.
    const condicionEstado: Record<string, unknown> = {
      $nin: ESTADOS_PRODUCTO_OCULTOS,
    };
    if (query.estado) {
      condicionEstado.$eq = query.estado;
    }
    filtro.estado = condicionEstado;
    if (idCategoria != null) {
      filtro['categoria.id_categoria'] = idCategoria;
    }
    if (idVendedor != null) {
      filtro['vendedor.id_usuario'] = idVendedor;
    }

    // estado_variante y el rango de precio describen la MISMA variante, asi
    // que van juntos en un $elemMatch: sin esto, "activa" y "precio >= X"
    // podrian cumplirse en dos variantes distintas del mismo producto.
    const elemMatchVariante: Record<string, unknown> = {};
    if (query.estado_variante) {
      elemMatchVariante.estado = query.estado_variante;
    }
    if (precioMin != null || precioMax != null) {
      const rango: Record<string, Decimal128> = {};
      if (precioMin != null) {
        rango.$gte = Decimal128.fromString(precioMin);
      }
      if (precioMax != null) {
        rango.$lte = Decimal128.fromString(precioMax);
      }
      elemMatchVariante.precio = rango;
    }
    if (Object.keys(elemMatchVariante).length > 0) {
      filtro.variantes = { $elemMatch: elemMatchVariante };
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
          { 'variantes.caracteristicas_adicionales': { $elemMatch: elemMatch } },
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
