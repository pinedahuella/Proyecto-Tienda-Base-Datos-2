import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { ResultadoBusquedaProducto } from '../../dto/buscar-productos';
import {
  BuscarProductosFacetadoQuery,
  FacetaCategoria,
  FacetaRango,
  RespuestaFacetada,
} from '../../dto/buscar-productos-facetado';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';
const LIMITE_DEFECTO = 20;
const LIMITE_MAXIMO = 50;

type NombreFaceta = 'categoria' | 'precio' | 'calificacion' | 'disponible';
const FACETAS: NombreFaceta[] = [
  'categoria',
  'precio',
  'calificacion',
  'disponible',
];

interface RangoPrecio {
  key: string;
  from?: number;
  to?: number;
}
/** Los cortes salen de los percentiles medidos el 2026-09-25 sobre 3105
 * productos activos (ver `elastic/pruebas/facetas.py`). */
const RANGOS_PRECIO: RangoPrecio[] = [
  { key: 'hasta-250', to: 250 },
  { key: '250-500', from: 250, to: 500 },
  { key: '500-1000', from: 500, to: 1000 },
  { key: '1000-3000', from: 1000, to: 3000 },
  { key: 'desde-3000', from: 3000 },
];

interface RangoNota {
  key: string;
  from: number;
}
const RANGOS_NOTA: RangoNota[] = [
  { key: '4-o-mas', from: 4 },
  { key: '3-o-mas', from: 3 },
];

/** Una clausula de Elasticsearch (query DSL), o null si la faceta no tiene
 * ningun valor elegido. */
type ClausulaFiltro = Record<string, unknown>;

/**
 * `categoria=7,9` -> `['7','9']`. Vacio o ausente -> `[]`. Exportada
 * (no un metodo privado) para que `BuscadorFacetadoController` la reuse al
 * armar el evento de analitica en ClickHouse, sin volver a parsear el
 * mismo query param dos veces.
 */
export function separarPorComas(valor: string | undefined): string[] {
  return (valor ?? '')
    .split(',')
    .map((v) => v.trim())
    .filter((v) => v !== '');
}

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
  categoria: { valores: { buckets: BucketTerms[] } };
  precio: { valores: { buckets: Record<string, BucketRango> } };
  calificacion: { valores: { buckets: Record<string, BucketRango> } };
  disponible: { valores: { doc_count: number } };
}

/**
 * El buscador FACETADO de la Entrega 3 (`GET /buscador/productos/facetado`,
 * pendiente de conectar a un controller). Puerto a TypeScript de
 * `elastic/pruebas/facetas.py::consulta()`/`facetas()` -- la consulta a
 * Elasticsearch es EXACTAMENTE la misma, cambia solo el lenguaje. Cuatro
 * facetas (categoria, precio, calificacion, disponible): cada una se agrega
 * con los filtros de las OTRAS ya aplicados (nunca el suyo propio), asi que
 * elegir una opcion no hace desaparecer las demas del panel -- las opciones
 * se suman con OR dentro de una faceta, con AND entre facetas distintas
 * (`post_filter`).
 *
 * A diferencia de `BuscadorProductosService.buscar()`, aca `nombre` puede
 * venir vacio (navegar solo por facetas, sin texto) -- pendiente de decidir
 * si eso hace falta validarlo distinto cuando se conecte el controller.
 */
@Injectable()
export class BuscadorFacetadoService {
  private readonly logger = new Logger(BuscadorFacetadoService.name);

  async buscar(
    query: BuscarProductosFacetadoQuery,
  ): Promise<RespuestaFacetada> {
    const texto = (query.nombre ?? '').trim();
    const filtros: Record<NombreFaceta, ClausulaFiltro | null> = {
      categoria: this.filtroDe('categoria', separarPorComas(query.categoria)),
      precio: this.filtroDe('precio', separarPorComas(query.precio)),
      calificacion: this.filtroDe(
        'calificacion',
        separarPorComas(query.calificacion),
      ),
      disponible: this.filtroDe(
        'disponible',
        separarPorComas(query.disponible),
      ),
    };

    try {
      const respuesta = await elasticClient.search<DocumentoIndice>({
        index: INDICE,
        ...this.construirConsulta(texto, filtros, this.aLimite(query.limite)),
      });

      return {
        resultados: respuesta.hits.hits.map((hit) => this.aResultado(hit)),
        total: this.aNumeroTotal(respuesta.hits.total),
        facetas: this.aFacetas(
          respuesta.aggregations as unknown as Agregaciones,
        ),
      };
    } catch (error) {
      manejarErrorConexionElastic(this.logger, error);
    }
  }

  /**
   * El cuerpo de la busqueda -- mismo `consulta()` de `facetas.py`, con UNA
   * diferencia real: `facetas.py` siempre recibe un texto (sus pruebas
   * nunca mandan uno vacio), pero aca `nombre` puede venir vacio a
   * proposito (navegar solo por facetas, sin texto -- decision del
   * usuario, 2026-09-26). Un `multi_match` con `query: ''` no es "sin
   * filtro de texto", es "no encuentra nada" (probado en vivo: `?categoria=7`
   * solo, sin `nombre`, daba `total: 0` con este cambio sin hacer). Por eso,
   * con texto vacio, se usa `match_all` en vez de `multi_match`.
   */
  private construirConsulta(
    texto: string,
    filtros: Record<NombreFaceta, ClausulaFiltro | null>,
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
    const todos = FACETAS.map((faceta) => filtros[faceta]).filter(
      (clausula): clausula is ClausulaFiltro => clausula != null,
    );

    return {
      size: tamano,
      query: {
        bool: {
          must: [textoQuery],
          filter: [{ term: { estado: 'activo' } }],
        },
      },
      post_filter: { bool: { filter: todos } },
      aggs: {
        categoria: this.envolver('categoria', filtros, {
          terms: { field: 'id_categoria', size: 50 },
          aggs: {
            nombre: { terms: { field: 'categoria_nombre.exacto', size: 1 } },
          },
        }),
        precio: this.envolver('precio', filtros, {
          range: { field: 'precio_desde', keyed: true, ranges: RANGOS_PRECIO },
        }),
        calificacion: this.envolver('calificacion', filtros, {
          range: {
            field: 'resenas_promedio',
            keyed: true,
            ranges: RANGOS_NOTA,
          },
        }),
        disponible: this.envolver('disponible', filtros, {
          filter: { range: { stock_total: { gt: 0 } } },
        }),
      },
    };
  }

  /** Envuelve la agregacion de una faceta con los filtros de las DEMAS
   * (nunca el suyo) -- mismo `envolver()`/`menos()` de `facetas.py`. */
  private envolver(
    faceta: NombreFaceta,
    filtros: Record<NombreFaceta, ClausulaFiltro | null>,
    agregacion: Record<string, unknown>,
  ) {
    const menos = FACETAS.filter((otra) => otra !== faceta)
      .map((otra) => filtros[otra])
      .filter((clausula): clausula is ClausulaFiltro => clausula != null);

    return {
      filter: { bool: { filter: menos } },
      aggs: { valores: agregacion },
    };
  }

  /** El filtro de UNA faceta, con sus valores sumados con OR. `null` si no
   * hay nada elegido -- mismo `filtro_de()` de `facetas.py`. */
  private filtroDe(
    faceta: NombreFaceta,
    valores: string[],
  ): ClausulaFiltro | null {
    if (valores.length === 0) {
      return null;
    }
    switch (faceta) {
      case 'categoria':
        return { terms: { id_categoria: valores.map(Number) } };

      case 'precio': {
        const rangos = new Map(RANGOS_PRECIO.map((r) => [r.key, r]));
        const should = valores
          .map((valor) => rangos.get(valor))
          .filter((rango): rango is RangoPrecio => rango != null)
          .map((rango) => {
            const range: Record<string, number> = {};
            if (rango.from != null) {
              range.gte = rango.from;
            }
            if (rango.to != null) {
              range.lt = rango.to;
            }
            return { range: { precio_desde: range } };
          });
        return should.length > 0
          ? { bool: { should, minimum_should_match: 1 } }
          : null;
      }

      case 'calificacion': {
        // Las opciones se contienen (4-o-mas cabe dentro de 3-o-mas), asi
        // que vale la mas baja -- el numero sale del propio valor, no de
        // RANGOS_NOTA (que solo describe la agregacion).
        const minimos = valores
          .map((valor) => Number(valor.split('-')[0]))
          .filter((numero) => !Number.isNaN(numero));
        return minimos.length > 0
          ? { range: { resenas_promedio: { gte: Math.min(...minimos) } } }
          : null;
      }

      case 'disponible':
        return { range: { stock_total: { gt: 0 } } };
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

  private aNumeroTotal(total: number | { value: number } | undefined): number {
    if (total == null) {
      return 0;
    }
    return typeof total === 'number' ? total : total.value;
  }

  /** La respuesta de ES en la forma que espera la pantalla -- mismo
   * `facetas()` de `facetas.py`, pero como arreglos en vez de objetos. */
  private aFacetas(aggregations: Agregaciones): RespuestaFacetada['facetas'] {
    const categoria: FacetaCategoria[] =
      aggregations.categoria.valores.buckets.map((bucket) => ({
        id: Number(bucket.key),
        nombre: bucket.nombre?.buckets[0]?.key ?? '?',
        cantidad: bucket.doc_count,
      }));
    const aRango = (buckets: Record<string, BucketRango>): FacetaRango[] =>
      Object.entries(buckets).map(([clave, bucket]) => ({
        clave,
        cantidad: bucket.doc_count,
      }));

    return {
      categoria,
      precio: aRango(aggregations.precio.valores.buckets),
      calificacion: aRango(aggregations.calificacion.valores.buckets),
      disponible: aggregations.disponible.valores.doc_count,
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
    };
  }
}
