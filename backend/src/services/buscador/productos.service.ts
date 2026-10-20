import { Injectable, Logger } from '@nestjs/common';
import { elasticClient, OPCIONES_BUSQUEDA } from '../../database/elastic';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { ErrorValidacion } from '../../helpers/errores';
import {
  buscarEnCopia,
  conRespaldoDeElastic,
} from '../../helpers/buscador-respaldo';
import {
  pedirCorreccion,
  textoCorregido,
} from '../../helpers/correccion-busqueda';
import {
  RespuestaBusquedaProductos,
  ResultadoBusquedaProducto,
} from '../../dto/buscar-productos';
import { unoPorProducto } from '../../helpers/copias-de-lote';
import { SugeridosBusquedaService } from './sugeridos.service';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';
const LIMITE_DEFECTO = 20;
const LIMITE_MAXIMO = 50;
/**
 * El `bool_prefix` puntua fijo (su peso), y la difusa de "lap" contra "las"
 * llega a 8.2: con 20 el principio de palabra queda siempre arriba. Medido el
 * 2026-10-20 con los 1000 productos de la PC de Jose David (con 3, "lap"
 * seguia dando El camino de las nubes primero).
 */
const PESO_PREFIJO = 20;

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

  constructor(private readonly sugeridos: SugeridosBusquedaService) {}

  /**
   * GET /buscador/productos -- publica. Nunca ve nada que no sea `activo`.
   * Sin resultados, suma los `sugeridos` (`SugeridosBusquedaService`, a pedido
   * del profesor el 2026-10-19: buscar una locura trae al menos un producto).
   */
  async buscar(
    nombre: string | undefined,
    limite: string | undefined,
    escribiendo = false,
  ): Promise<RespuestaBusquedaProductos> {
    const respuesta = await this.ejecutar(nombre, limite, true, escribiendo);
    const { productos: sugeridos, desde: sugeridos_desde } =
      respuesta.resultados.length === 0
        ? await this.sugeridos.sugerir((nombre ?? '').trim())
        : { productos: [], desde: null };
    return { ...respuesta, sugeridos, sugeridos_desde };
  }

  /**
   * GET /buscador/productos/admin -- protegida (solo admin, en el
   * controller). Mismo texto, misma difusa, pero sin el filtro de estado:
   * trae cualquier producto en cualquier estado.
   */
  async buscarAdmin(
    nombre: string | undefined,
    limite: string | undefined,
    escribiendo = false,
  ): Promise<ResultadoBusquedaProducto[]> {
    const { resultados } = await this.ejecutar(
      nombre,
      limite,
      false,
      escribiendo,
    );
    return resultados;
  }

  /**
   * `quisiste_decir` solo se calcula en la ruta publica: la de admin sigue
   * devolviendo la lista sola.
   *
   * `escribiendo` es la lista que cuelga del buscador de la cabecera, que
   * busca con cada letra. La difusa sola piensa que la palabra ya esta
   * entera: "lap" era "las" mal escrito (El camino de las nubes) y "lapt" no
   * daba nada. Asi se suma el principio de palabra del autocompletado
   * (`bool_prefix` sobre `nombre.escribiendo`, como `BuscadorSugerenciasService`)
   * con peso PESO_PREFIJO, sin quitar la difusa, que es la que encuentra
   * "labtop". Y queda un resultado por producto (`unoPorProducto`).
   */
  private async ejecutar(
    nombre: string | undefined,
    limite: string | undefined,
    soloActivos: boolean,
    escribiendo: boolean,
  ): Promise<
    Omit<RespuestaBusquedaProductos, 'sugeridos' | 'sugeridos_desde'>
  > {
    const texto = (nombre ?? '').trim();
    if (!texto) {
      throw new ErrorValidacion('Escribe el nombre del producto que buscas');
    }

    const difusa = {
      multi_match: {
        query: texto,
        fields: ['nombre^3', 'descripcion', 'variantes'],
        fuzziness: 'AUTO',
      },
    };
    const textoQuery = escribiendo
      ? {
          bool: {
            should: [
              {
                multi_match: {
                  query: texto,
                  type: 'bool_prefix' as const,
                  fields: [
                    'nombre.escribiendo',
                    'nombre.escribiendo._2gram',
                    'nombre.escribiendo._3gram',
                  ],
                  boost: PESO_PREFIJO,
                },
              },
              difusa,
            ],
            minimum_should_match: 1,
          },
        }
      : difusa;

    const tope = this.aLimite(limite);
    // Escribiendo se piden muchos mas: unas 10 copias de lote por original.
    const pedidos = escribiendo ? Math.min(tope * 15, 200) : tope;
    const final = (resultados: ResultadoBusquedaProducto[]) =>
      escribiendo ? unoPorProducto(resultados, tope) : resultados;
    try {
      // Sin Elasticsearch, de la copia del catalogo en PostgreSQL
      // (buscador-respaldo.ts), sin el "quisiste decir".
      return await conRespaldoDeElastic(
        async () => {
          const respuesta = await elasticClient.search<DocumentoIndice>(
            {
              index: INDICE,
              size: pedidos,
              suggest: soloActivos ? pedirCorreccion(texto) : undefined,
              query: soloActivos
                ? {
                    bool: {
                      must: [textoQuery],
                      filter: [{ term: { estado: 'activo' } }],
                    },
                  }
                : textoQuery,
              // El principio de palabra puntua igual a todos: en el empate
              // va primero el que tiene mas resenas, y el original antes que
              // sus copias, que no tienen.
              sort: escribiendo
                ? [
                    { _score: { order: 'desc' as const } },
                    { resenas_total: { order: 'desc' as const } },
                  ]
                : undefined,
            },
            OPCIONES_BUSQUEDA,
          );

          return {
            resultados: final(
              respuesta.hits.hits.map((hit) => this.aResultado(hit)),
            ),
            quisiste_decir: textoCorregido(
              texto,
              respuesta.suggest as Parameters<typeof textoCorregido>[1],
            ),
          };
        },
        async () => ({
          resultados: final(
            (
              await buscarEnCopia({
                texto,
                limite: pedidos,
                soloActivos,
                prefijo: escribiendo,
              })
            ).resultados,
          ),
          quisiste_decir: null,
        }),
      );
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
