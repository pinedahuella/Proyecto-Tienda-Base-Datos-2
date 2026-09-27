import { Hallazgo } from './hallazgo';

/**
 * El resultado del paso 2 del agrupador de casos de fraude (union por
 * cuentas compartidas) -- todavia no es un `caso_fraude` persistido, es
 * la agrupacion en memoria que el paso 3 (puntaje) recibe.
 */
export interface GrupoFraude {
  /** Cada cuenta que toca este grupo, y si es nucleo (`true`) o
   * periferia (`false`). */
  cuentas: Map<number, boolean>;
  hallazgos: Hallazgo[];
}
