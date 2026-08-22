import { Injectable, Logger } from '@nestjs/common';
import { Decimal128, Filter } from 'mongodb';
import { mongoDb } from '../../database/mongo';
import { ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import {
  coercionarValorAtributo,
  esClaveAtributoValida,
  escaparRegex,
  validarDespuesDe,
  validarEnteroPositivo,
  validarLimite,
  validarPrecio,
} from '../../helpers/validaciones-productos';
import {
  ListarProductosQuery,
  ProductosPagina,
} from '../../dto/listar-productos';
import { Producto } from '../../models/producto';
import { ESTADOS_PRODUCTO_OCULTOS } from '../../models/estado-producto';

/**
 * Query params fijos de GET /productos. Cualquier otro que llegue se trata
 * como un filtro dinamico de caracteristicas_adicionales (ver
 * validaciones-productos.ts).
 */
const CLAVES_RESERVADAS = new Set([
  'limite',
  'despues_de',
  'nombre',
  'estado',
  'id_categoria',
  'id_vendedor',
  'precio_min',
  'precio_max',
  'estado_variante',
]);

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
   * estado de variante) y filtros dinamicos sobre caracteristicas_adicionales,
   * tanto del producto como de sus variantes.
   */
  async listar(query: ListarProductosQuery): Promise<ProductosPagina> {
    const limite = validarLimite(query.limite);
    const despuesDe = validarDespuesDe(query.despues_de);
    const idCategoria = validarEnteroPositivo(
      query.id_categoria,
      'id_categoria',
    );
    const idVendedor = validarEnteroPositivo(query.id_vendedor, 'id_vendedor');
    const precioMin = validarPrecio(query.precio_min, 'precio_min');
    const precioMax = validarPrecio(query.precio_max, 'precio_max');

    const filtro = this.construirFiltro(query, {
      despuesDe,
      idCategoria,
      idVendedor,
      precioMin,
      precioMax,
    });

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

  /** Arma el filtro de Mongo a partir de los query params ya validados. */
  private construirFiltro(
    query: ListarProductosQuery,
    fijos: {
      despuesDe: number | null;
      idCategoria: number | null;
      idVendedor: number | null;
      precioMin: string | null;
      precioMax: string | null;
    },
  ): Filter<Producto> {
    const filtro: Record<string, unknown> = {};

    if (fijos.despuesDe != null) {
      filtro._id = { $gt: fijos.despuesDe };
    }
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
    if (fijos.idCategoria != null) {
      filtro['categoria.id_categoria'] = fijos.idCategoria;
    }
    if (fijos.idVendedor != null) {
      filtro['vendedor.id_usuario'] = fijos.idVendedor;
    }

    // estado_variante y el rango de precio describen la MISMA variante, asi
    // que van juntos en un $elemMatch: sin esto, "activa" y "precio >= X"
    // podrian cumplirse en dos variantes distintas del mismo producto.
    const elemMatchVariante: Record<string, unknown> = {};
    if (query.estado_variante) {
      elemMatchVariante.estado = query.estado_variante;
    }
    if (fijos.precioMin != null || fijos.precioMax != null) {
      const rango: Record<string, Decimal128> = {};
      if (fijos.precioMin != null) {
        rango.$gte = Decimal128.fromString(fijos.precioMin);
      }
      if (fijos.precioMax != null) {
        rango.$lte = Decimal128.fromString(fijos.precioMax);
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

    return filtro as Filter<Producto>;
  }

  private construirFiltrosDinamicos(
    query: ListarProductosQuery,
  ): Record<string, unknown>[] {
    const condiciones: Record<string, unknown>[] = [];

    for (const [clave, valorCrudo] of Object.entries(query)) {
      if (CLAVES_RESERVADAS.has(clave) || valorCrudo == null) {
        continue;
      }
      if (!esClaveAtributoValida(clave)) {
        throw new ErrorValidacion(
          `El filtro "${clave}" no es un nombre de caracteristica valido`,
        );
      }

      const valor = coercionarValorAtributo(valorCrudo);
      condiciones.push({
        $or: [
          { [`caracteristicas_adicionales.${clave}`]: valor },
          { [`variantes.caracteristicas_adicionales.${clave}`]: valor },
        ],
      });
    }

    return condiciones;
  }
}
