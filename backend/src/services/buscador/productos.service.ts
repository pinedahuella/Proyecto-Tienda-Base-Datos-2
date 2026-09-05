import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { ErrorValidacion } from '../../helpers/errores';
import { ResultadoBusquedaProducto } from '../../dto/buscar-productos';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';
const LIMITE_DEFECTO = 20;
const LIMITE_MAXIMO = 50;

/** La forma del documento del indice de busqueda. Ver etl/extraer_busqueda.js. */
interface DocumentoIndice {
  nombre: string;
  descripcion: string | null;
  categoria_nombre: string | null;
  precio_desde: number | null;
  precio_tienda: number | null;
  stock_total: number;
  resenas_promedio: number;
  resenas_total: number;
}

/**
 * El buscador de productos de la Entrega 3 (GET /buscador/productos).
 *
 * Consulta el indice `mesh_productos` de Elasticsearch, que carga
 * `etl/cargar_busqueda.sh` desde el catalogo de MongoDB. El backend solo LEE
 * -- el indice es una proyeccion que se reconstruye entera en cada corrida
 * del ETL, igual que el grafo de Neo4j.
 *
 * Devuelve un RESUMEN por producto (lo que hace falta para pintar una
 * tarjeta de resultados: nombre, categoria, precio, stock, nota), no el
 * producto completo. El documento indexado tampoco trae imagenes ni
 * caracteristicas -- para el detalle entero esta GET /productos/:id contra
 * MongoDB, que sigue siendo la fuente de verdad del catalogo.
 *
 * La busqueda es difusa (tolera errores de tecleo, `fuzziness: AUTO`) y sin
 * tildes (el indice usa el analizador `espanol_llano`, que hace
 * asciifolding), sobre tres campos: `nombre` (con mas peso), `descripcion` y
 * `variantes` (los nombres de las presentaciones).
 */
@Injectable()
export class BuscadorProductosService {
  private readonly logger = new Logger(BuscadorProductosService.name);

  async buscar(
    nombre: string | undefined,
    limite: string | undefined,
  ): Promise<ResultadoBusquedaProducto[]> {
    const texto = (nombre ?? '').trim();
    if (!texto) {
      throw new ErrorValidacion('Escribe el nombre del producto que buscas');
    }

    try {
      const respuesta = await elasticClient.search<DocumentoIndice>({
        index: INDICE,
        size: this.aLimite(limite),
        query: {
          multi_match: {
            query: texto,
            fields: ['nombre^3', 'descripcion', 'variantes'],
            fuzziness: 'AUTO',
          },
        },
      });

      return respuesta.hits.hits.map((hit) => this.aResultado(hit));
    } catch (error) {
      manejarErrorConexionElastic(this.logger, error);
    }
  }

  /** `limite` sin validar puede venir vacio, negativo o gigante: se acota. */
  private aLimite(valor: string | undefined): number {
    const numero = Number(valor);
    if (!Number.isFinite(numero) || numero <= 0) {
      return LIMITE_DEFECTO;
    }
    return Math.min(Math.trunc(numero), LIMITE_MAXIMO);
  }

  private aResultado(hit: {
    _id?: string;
    _source?: DocumentoIndice;
  }): ResultadoBusquedaProducto {
    const fuente = hit._source;
    return {
      id_producto: Number(hit._id),
      nombre: fuente?.nombre ?? '',
      categoria: fuente?.categoria_nombre ?? null,
      precio_desde: fuente?.precio_desde ?? null,
      precio_tienda: fuente?.precio_tienda ?? null,
      stock_total: fuente?.stock_total ?? 0,
      resenas_promedio: fuente?.resenas_promedio ?? 0,
      resenas_total: fuente?.resenas_total ?? 0,
    };
  }
}
