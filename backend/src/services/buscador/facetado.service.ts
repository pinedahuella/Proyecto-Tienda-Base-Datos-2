import { Injectable, Logger } from '@nestjs/common';
import { elasticClient, OPCIONES_BUSQUEDA } from '../../database/elastic';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import {
  pedirCorreccion,
  textoCorregido,
} from '../../helpers/correccion-busqueda';
import {
  buscarEnCopia,
  conRespaldoDeElastic,
} from '../../helpers/buscador-respaldo';
import {
  FiltrosElegidos,
  RANGOS_NOTA,
  RANGOS_PRECIO,
  leerFiltrosElegidos,
} from '../../helpers/facetas-buscador';
import { ResultadoBusquedaProducto } from '../../dto/buscar-productos';
import {
  BuscarProductosFacetadoQuery,
  FacetaCategoria,
  FacetaRango,
  RespuestaFacetada,
} from '../../dto/buscar-productos-facetado';
import { SugeridosBusquedaService } from './sugeridos.service';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';
const LIMITE_DEFECTO = 20;
const LIMITE_MAXIMO = 50;

/** Una clausula de Elasticsearch (query DSL). */
type ClausulaFiltro = Record<string, unknown>;

/** Mismo documento indexado que `BuscadorProductosService`. */
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
  /** El enlace de la foto de la tarjeta, o null. Guardado sin indexar. */
  imagen: string | null;
}

interface BucketTerms {
  key: number | string;
  doc_count: number;
  nombre?: { buckets: { key: string }[] };
}
interface BucketRango {
  doc_count: number;
}
interface Agregaciones {
  categoria: { buckets: BucketTerms[] };
  precio: { buckets: Record<string, BucketRango> };
  calificacion: { buckets: Record<string, BucketRango> };
  disponible: { doc_count: number };
}

/**
 * El buscador FACETADO (`GET /buscador/productos/facetado`), el de la pagina
 * /buscar. Puerto a TypeScript de `elastic/pruebas/facetas.py::consulta()` y
 * `facetas()`: la consulta a Elasticsearch es la misma, cambia solo el
 * lenguaje. Cuatro facetas: categoria, precio, calificacion y disponible.
 *
 * **Los filtros van en la consulta (2026-10-20, a pedido del profesor).** Hasta
 * ese dia los filtros elegidos iban en `post_filter`, que se aplica DESPUES de
 * las agregaciones, y cada faceta se contaba con los filtros de las otras. El
 * profesor lo observo: si el filtro ya se sabe, se filtra antes, en la
 * consulta, y los agregados se calculan sobre lo que ya quedo. Ahora los
 * filtros elegidos van en el `filter` del `bool` junto con el de `activo`, y
 * las agregaciones cuentan solo los productos que pasaron todos: cada numero
 * del panel dice cuantos resultados hay de verdad con esa opcion sumada a lo
 * ya elegido. Dentro de una faceta las opciones siguen sumandose con OR (dos
 * categorias), entre facetas con AND. La contra, aceptada: al elegir una
 * categoria las demas salen del panel, porque ya no hay resultados en ellas;
 * para cambiar de categoria se quita la elegida.
 *
 * Sin Elasticsearch, la busqueda sale de la copia del catalogo en PostgreSQL
 * (`buscarEnCopia`), con los mismos filtros y las mismas facetas contadas igual.
 *
 * Sin resultados y sin filtros elegidos, se suman los `sugeridos`
 * (`SugeridosBusquedaService`): la pagina nunca queda vacia, y el total sigue
 * siendo 0 para el reporte de busquedas sin resultados.
 *
 * `nombre` puede venir vacio: navegar solo por facetas, sin texto.
 */
@Injectable()
export class BuscadorFacetadoService {
  private readonly logger = new Logger(BuscadorFacetadoService.name);

  constructor(private readonly sugeridos: SugeridosBusquedaService) {}

  async buscar(
    query: BuscarProductosFacetadoQuery,
  ): Promise<RespuestaFacetada> {
    const texto = (query.nombre ?? '').trim();
    const elegidos = leerFiltrosElegidos(query);
    const limite = this.aLimite(query.limite);

    let respuesta: Omit<RespuestaFacetada, 'sugeridos' | 'sugeridos_desde'>;
    try {
      respuesta = await conRespaldoDeElastic(
        () => this.desdeElastic(texto, elegidos, limite),
        async () => {
          const copia = await buscarEnCopia({
            texto,
            limite,
            soloActivos: true,
            filtros: elegidos,
          });
          return {
            resultados: copia.resultados,
            total: copia.total,
            quisiste_decir: null,
            facetas: copia.facetas,
          };
        },
      );
    } catch (error) {
      manejarErrorConexionElastic(this.logger, error);
    }

    const sinFiltros =
      elegidos.categorias.length === 0 &&
      elegidos.precios.length === 0 &&
      elegidos.calificacionMinima == null &&
      !elegidos.disponible;
    const { productos: sugeridos, desde: sugeridos_desde } =
      respuesta.total === 0 && texto !== '' && sinFiltros
        ? await this.sugeridos.sugerir(texto)
        : { productos: [], desde: null };
    return { ...respuesta, sugeridos, sugeridos_desde };
  }

  private async desdeElastic(
    texto: string,
    elegidos: FiltrosElegidos,
    limite: number,
  ): Promise<Omit<RespuestaFacetada, 'sugeridos' | 'sugeridos_desde'>> {
    const respuesta = await elasticClient.search<DocumentoIndice>(
      {
        index: INDICE,
        ...this.construirConsulta(texto, elegidos, limite),
      },
      OPCIONES_BUSQUEDA,
    );

    return {
      resultados: respuesta.hits.hits.map((hit) => this.aResultado(hit)),
      total: this.aNumeroTotal(respuesta.hits.total),
      quisiste_decir:
        texto === ''
          ? null
          : textoCorregido(
              texto,
              respuesta.suggest as Parameters<typeof textoCorregido>[1],
            ),
      facetas: this.aFacetas(respuesta.aggregations as unknown as Agregaciones),
    };
  }

  /**
   * El cuerpo de la busqueda -- mismo `consulta()` de `facetas.py`. El texto va
   * en el `must`, difuso; los filtros elegidos y el de `activo`, en el
   * `filter`; las agregaciones, sueltas, sobre lo que quedo.
   *
   * Con texto vacio se usa `match_all`: un `multi_match` con `query: ''` no es
   * "sin filtro de texto", es "no encuentra nada" (probado en vivo:
   * `?categoria=7` solo, sin `nombre`, daba `total: 0`; decision del usuario,
   * 2026-09-26).
   */
  private construirConsulta(
    texto: string,
    elegidos: FiltrosElegidos,
    tamano: number,
  ) {
    const textoQuery =
      texto === ''
        ? { match_all: {} }
        : {
            multi_match: {
              query: texto,
              fields: ['nombre^3', 'descripcion', 'variantes'],
              fuzziness: 'AUTO',
            },
          };

    return {
      size: tamano,
      suggest: texto === '' ? undefined : pedirCorreccion(texto),
      query: {
        bool: {
          must: [textoQuery],
          filter: [
            { term: { estado: 'activo' } },
            ...this.clausulasDeFiltro(elegidos),
          ],
        },
      },
      aggs: {
        categoria: {
          terms: { field: 'id_categoria', size: 50 },
          aggs: {
            nombre: { terms: { field: 'categoria_nombre.exacto', size: 1 } },
          },
        },
        precio: {
          range: { field: 'precio_desde', keyed: true, ranges: RANGOS_PRECIO },
        },
        calificacion: {
          range: {
            field: 'resenas_promedio',
            keyed: true,
            ranges: RANGOS_NOTA,
          },
        },
        disponible: { filter: { range: { stock_total: { gt: 0 } } } },
      },
    };
  }

  /**
   * Una clausula por faceta con algo elegido -- mismo `filtro_de()` de
   * `facetas.py`. Las opciones de una misma faceta se suman con OR; las
   * clausulas, entre si, con AND (van todas en el `filter`).
   */
  private clausulasDeFiltro(elegidos: FiltrosElegidos): ClausulaFiltro[] {
    const clausulas: ClausulaFiltro[] = [];
    if (elegidos.categorias.length > 0) {
      clausulas.push({ terms: { id_categoria: elegidos.categorias } });
    }
    if (elegidos.precios.length > 0) {
      clausulas.push({
        bool: {
          should: elegidos.precios.map((rango) => {
            const range: Record<string, number> = {};
            if (rango.from != null) {
              range.gte = rango.from;
            }
            if (rango.to != null) {
              range.lt = rango.to;
            }
            return { range: { precio_desde: range } };
          }),
          minimum_should_match: 1,
        },
      });
    }
    if (elegidos.calificacionMinima != null) {
      clausulas.push({
        range: { resenas_promedio: { gte: elegidos.calificacionMinima } },
      });
    }
    if (elegidos.disponible) {
      clausulas.push({ range: { stock_total: { gt: 0 } } });
    }
    return clausulas;
  }

  /** `limite` sin validar puede venir vacio, negativo o gigante: se acota. */
  private aLimite(valor: string | undefined): number {
    const numero = Number(valor);
    if (!Number.isFinite(numero) || numero <= 0) {
      return LIMITE_DEFECTO;
    }
    return Math.min(Math.trunc(numero), LIMITE_MAXIMO);
  }

  private aNumeroTotal(total: number | { value: number } | undefined): number {
    if (total == null) {
      return 0;
    }
    return typeof total === 'number' ? total : total.value;
  }

  /** La respuesta de ES en la forma que espera la pantalla -- mismo
   * `facetas()` de `facetas.py`, pero como arreglos en vez de objetos. */
  private aFacetas(aggregations: Agregaciones): RespuestaFacetada['facetas'] {
    const categoria: FacetaCategoria[] = aggregations.categoria.buckets.map(
      (bucket) => ({
        id: Number(bucket.key),
        nombre: bucket.nombre?.buckets[0]?.key ?? '?',
        cantidad: bucket.doc_count,
      }),
    );
    // En el orden de RANGOS_PRECIO y RANGOS_NOTA y no en el de la respuesta:
    // Elasticsearch ordena los tramos por `from`, y la calificacion salia
    // 3 o mas antes que 4 o mas, al reves que en el respaldo sin Elasticsearch
    // (buscador-respaldo.ts, visto el 2026-10-20).
    const aRango = (
      rangos: { key: string }[],
      buckets: Record<string, BucketRango>,
    ): FacetaRango[] =>
      rangos.map((r) => ({
        clave: r.key,
        cantidad: buckets[r.key]?.doc_count ?? 0,
      }));

    return {
      categoria,
      precio: aRango(RANGOS_PRECIO, aggregations.precio.buckets),
      calificacion: aRango(RANGOS_NOTA, aggregations.calificacion.buckets),
      disponible: aggregations.disponible.doc_count,
    };
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
      imagen: fuente?.imagen ?? null,
    };
  }
}
