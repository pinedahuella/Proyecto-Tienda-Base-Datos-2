import { BuscarProductosFacetadoQuery } from '../dto/buscar-productos-facetado';

/**
 * Las cuatro facetas del buscador (categoria, precio, calificacion y
 * disponible) y como se leen las opciones elegidas. Las comparten la consulta
 * a Elasticsearch (`BuscadorFacetadoService`) y la de la copia del catalogo en
 * PostgreSQL (`buscador-respaldo.ts`), para que las dos filtren y cuenten
 * igual. Los cortes son los de `elastic/pruebas/facetas.py`.
 */

export interface RangoPrecio {
  key: string;
  from?: number;
  to?: number;
}

/**
 * Los cortes salen de los percentiles medidos el 2026-09-25 sobre 3105
 * productos activos: la mediana de precio_desde es 496 y el percentil 90 es
 * 3500.
 */
export const RANGOS_PRECIO: RangoPrecio[] = [
  { key: 'hasta-250', to: 250 },
  { key: '250-500', from: 250, to: 500 },
  { key: '500-1000', from: 500, to: 1000 },
  { key: '1000-3000', from: 1000, to: 3000 },
  { key: 'desde-3000', from: 3000 },
];

export interface RangoNota {
  key: string;
  from: number;
}

export const RANGOS_NOTA: RangoNota[] = [
  { key: '4-o-mas', from: 4 },
  { key: '3-o-mas', from: 3 },
];

/** Lo elegido en el panel de filtros, ya leido y validado. */
export interface FiltrosElegidos {
  /** Las categorias, sumadas con OR. Vacio = cualquiera. */
  categorias: number[];
  /** Los rangos de precio, sumados con OR. Vacio = cualquiera. */
  precios: RangoPrecio[];
  /**
   * La nota minima. Las opciones se contienen (4 o mas cabe en 3 o mas), asi
   * que vale la mas baja. `null` = cualquiera.
   */
  calificacionMinima: number | null;
  /** Solo los que tienen existencias. */
  disponible: boolean;
}

/** `"7, 8,"` -> `['7', '8']`. Lo que llega por la URL como lista. */
export function separarPorComas(valor: string | undefined): string[] {
  return (valor ?? '')
    .split(',')
    .map((v) => v.trim())
    .filter((v) => v !== '');
}

/**
 * Las opciones elegidas de la query. Lo que no se reconoce (un rango de precio
 * que no existe, una categoria que no es numero) se ignora, igual que hacia
 * `filtroDe()` antes de compartirse.
 */
export function leerFiltrosElegidos(
  query: BuscarProductosFacetadoQuery,
): FiltrosElegidos {
  const rangos = new Map(RANGOS_PRECIO.map((r) => [r.key, r]));
  const minimos = separarPorComas(query.calificacion)
    .map((valor) => Number(valor.split('-')[0]))
    .filter((numero) => !Number.isNaN(numero));
  return {
    categorias: separarPorComas(query.categoria)
      .map(Number)
      .filter((n) => Number.isInteger(n)),
    precios: separarPorComas(query.precio)
      .map((valor) => rangos.get(valor))
      .filter((rango): rango is RangoPrecio => rango != null),
    calificacionMinima: minimos.length > 0 ? Math.min(...minimos) : null,
    disponible: separarPorComas(query.disponible).length > 0,
  };
}
