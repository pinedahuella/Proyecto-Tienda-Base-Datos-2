/**
 * La forma comun que entrega cualquier detector de fraude, sea Cypher
 * (grafo), ClickHouse (eventos) o el login -- seccion 1 de
 * `docs/fraude-entrega3/02-reglas-backend.md`. Es la materia prima que el
 * agrupador de casos junta despues (union por cuentas compartidas,
 * puntaje, niveles) -- todavia no es un caso.
 */
export type FuenteHallazgo = 'grafo' | 'eventos' | 'login' | 'elastic';

export interface Hallazgo {
  fuente: FuenteHallazgo;
  /**
   * El id de la senal (`senal_fraude.id_senal_fraude`) -- para poder
   * enlazarla despues en `evidencia_caso_fraude.id_senal_fraude`.
   */
  idOrigen: number;
  /** El nombre del tipo en el catalogo unico (`tipo_senal_fraude_nombre`). */
  tipo: string;
  /** Los ids de usuario involucrados, sin duplicados, sin ordenar. */
  cuentas: number[];
  /** Esos mismos ids, sin duplicados, ordenados numericamente y unidos
   * con guion -- mismo criterio que `anillo_fraude.clave`. */
  clave: string;
  /** Los numeros que dio la consulta original (horas, vueltas,
   * exclusividad, etc.) -- vienen tal cual del `detalle`/`clave` de la
   * fuente, distinto por tipo, solo se muestran. */
  metricas: Record<string, unknown>;
  ultimaEvidencia: Date;
}
