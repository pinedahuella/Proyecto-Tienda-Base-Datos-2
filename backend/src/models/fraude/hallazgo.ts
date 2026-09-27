/**
 * La forma comun que entrega cualquier detector de fraude, sea Cypher
 * (grafo), ClickHouse (eventos) o el login -- seccion 1 de
 * `docs/fraude-entrega3/02-reglas-backend.md`. Es la materia prima que el
 * agrupador de casos junta despues (union por cuentas compartidas,
 * puntaje, niveles) -- todavia no es un caso.
 */
export type FuenteHallazgo = 'grafo' | 'eventos' | 'login';

export interface Hallazgo {
  fuente: FuenteHallazgo;
  /**
   * El id real en su tabla de origen (`anillo_fraude` /
   * `hallazgo_evento_fraude` / `alerta_fraude`, segun `fuente`) -- para
   * poder enlazarlo despues en `evidencia_caso_fraude`
   * (`id_anillo_fraude`/`id_hallazgo_evento_fraude`/`id_alerta_fraude`,
   * exactamente una de las tres).
   */
  idOrigen: number;
  /** El nombre del tipo en su propio catalogo (`tipo_anillo_fraude_nombre`,
   * `tipo_hallazgo_evento_nombre` o `tipo_alerta_fraude_nombre`). */
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
