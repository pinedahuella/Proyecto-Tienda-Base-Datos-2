import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { ErrorValidacion } from '../../helpers/errores';
import {
  pedirCorreccion,
  textoCorregido,
} from '../../helpers/correccion-busqueda';
import {
  RespuestaBusquedaProductos,
  ResultadoBusquedaProducto,
} from '../../dto/buscar-productos';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';
const LIMITE_DEFECTO = 20;
const LIMITE_MAXIMO = 50;

/** La forma del documento del indice de busqueda. Ver etl/extraer_busqueda.js. */
interface DocumentoIndice {
  nombre: string;
  descripcion: string | null;
  estado: string;
  categoria_nombre: string | null;
  precio_desde: number | null;
  precio_tienda: number | null;
  hay_descuento: boolean;
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
 *
 * El indice guarda TODOS los estados (activo, inactivo, borrador,
 * en_revision, rechazado) -- ver
 * `cambio_propuestas/2026-09-04_2208-elastic-indexar-todos-los-estados.md`.
 * Lo que separa lo publico de lo que ve un admin no es el indice, es esta
 * clase: `buscar()` SIEMPRE agrega `estado: activo` como `filter`, fijo en
 * el codigo y no condicionado a ningun parametro de la peticion (misma
 * "lista blanca, no lista negra" que ya usa `ProductosService` sobre
 * Mongo). `buscarAdmin()` es la unica que puede saltarselo.
 */
@Injectable()
export class BuscadorProductosService {
  private readonly logger = new Logger(BuscadorProductosService.name);

  /** GET /buscador/productos -- publica. Nunca ve nada que no sea `activo`. */
  async buscar(
    nombre: string | undefined,
    limite: string | undefined,
  ): Promise<RespuestaBusquedaProductos> {
    return this.ejecutar(nombre, limite, true);
  }

  /**
   * GET /buscador/productos/admin -- protegida (solo admin, en el
   * controller). Mismo texto, misma difusa, pero sin el filtro de estado:
   * trae cualquier producto en cualquier estado.
   */
  async buscarAdmin(
    nombre: string | undefined,
    limite: string | undefined,
  ): Promise<ResultadoBusquedaProducto[]> {
    const { resultados } = await this.ejecutar(nombre, limite, false);
    return resultados;
  }

  /**
   * `quisiste_decir` solo se calcula en la ruta publica: la de admin sigue
   * devolviendo la lista sola.
   */
  private async ejecutar(
    nombre: string | undefined,
    limite: string | undefined,
    soloActivos: boolean,
  ): Promise<RespuestaBusquedaProductos> {
    const texto = (nombre ?? '').trim();
    if (!texto) {
      throw new ErrorValidacion('Escribe el nombre del producto que buscas');
    }

    const textoQuery = {
      multi_match: {
        query: texto,
        fields: ['nombre^3', 'descripcion', 'variantes'],
        fuzziness: 'AUTO',
      },
    };

    try {
      const respuesta = await elasticClient.search<DocumentoIndice>({
        index: INDICE,
        size: this.aLimite(limite),
        suggest: soloActivos ? pedirCorreccion(texto) : undefined,
        query: soloActivos
          ? {
              bool: {
                must: [textoQuery],
                filter: [{ term: { estado: 'activo' } }],
              },
            }
          : textoQuery,
      });

      return {
        resultados: respuesta.hits.hits.map((hit) => this.aResultado(hit)),
        quisiste_decir: textoCorregido(
          texto,
          respuesta.suggest as Parameters<typeof textoCorregido>[1],
        ),
      };
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
      estado: fuente?.estado ?? '',
      categoria: fuente?.categoria_nombre ?? null,
      precio_desde: fuente?.precio_desde ?? null,
      precio_tienda: fuente?.precio_tienda ?? null,
      hay_descuento: fuente?.hay_descuento ?? false,
      stock_total: fuente?.stock_total ?? 0,
      resenas_promedio: fuente?.resenas_promedio ?? 0,
      resenas_total: fuente?.resenas_total ?? 0,
    };
  }
}
