import { SincronizacionGrafo } from './grafo';

/**
 * Los tipos de la respuesta de `GET /admin/fraude/anillos` -- el panel de
 * deteccion de manipulacion de resenas de la Entrega 2.
 *
 * Los datos NO salen de PostgreSQL: salen del grafo de Neo4j (`neo4j/`),
 * que es una PROYECCION de la tabla `resena` cargada por el ETL
 * `etl/cargar_grafo.sh` o, ya al dia, por el worker del outbox
 * (`GrafoSyncService`). El backend solo CONSULTA el grafo, nunca le
 * escribe.
 *
 * La forma la fija el frontend, que ya esta escrito contra ella
 * (`frontend/src/lib/PanelFraude.svelte`): si cambia aqui, se rompe alla.
 */

/**
 * Que forma tiene el patron. No es cosmetico: cada forma la detecta una
 * consulta distinta del grafo y significa una cosa distinta.
 *
 *   ciclo       A califica a B, B a C, C vuelve a A (3+ cuentas).
 *   mutuo       dos cuentas se calificaron la una a la otra.
 *   reiterado   dos cuentas se califican mutuamente SOBRE EL MISMO PRODUCTO
 *               (la frase literal del enunciado).
 *   direccion   cuentas distintas registradas en la misma direccion (con calle).
 */
export type TipoAnillo = 'ciclo' | 'mutuo' | 'reiterado' | 'direccion';

/** Una cuenta dentro de un grupo senalado. */
export interface CuentaSenalada {
  id_usuario: number;
  usuario: string;
  correo_electronico: string;
  nombre: string;
  apellido: string;
}

/** Una resena concreta que forma parte del patron. */
export interface ResenaSenalada {
  id_resena: number;
  autor: string;
  vendedor: string;
  producto: string;
  calificacion: number;
  /** ISO 8601, tal cual la devuelve el grafo (`toString(datetime)`). */
  fecha: string;
}

/** Un producto que aparece en las resenas del patron. */
export interface ProductoSenalado {
  id_producto: number;
  nombre: string;
}

/** Un grupo de cuentas con un patron de calificaciones anomalo. */
export interface Anillo {
  /** `<tipo>-<ids ordenados>`, estable entre corridas. */
  id: string;
  tipo: TipoAnillo;
  /**
   * Cuantos saltos tiene el camino del grafo que une a las cuentas. Es el
   * dato que hace que esto sea un grafo y no una tabla.
   */
  saltos: number;
  cuentas: CuentaSenalada[];
  productos: ProductoSenalado[];
  resenas: ResenaSenalada[];
  /** Frases cortas, ya redactadas por el backend, que explican la sospecha. */
  senales: string[];
}

/**
 * El denominador del analisis: cuanto se recorrio para llegar al resultado.
 * Sin esto, un `anillos: []` se lee como "el panel esta roto" en vez de
 * "se analizo y no habia nada".
 */
export interface AnalisisFraude {
  cuentas: number;
  resenas: number;
  relaciones: number;
}

/** La respuesta completa de `GET /admin/fraude/anillos`. */
export interface RespuestaFraude {
  anillos: Anillo[];
  analizado: AnalisisFraude;
  /**
   * Que tan al dia esta el grafo respecto a PostgreSQL, para que el panel no
   * enseñe un analisis sobre datos incompletos sin decirlo. `null` si no se
   * pudo leer (Postgres caido, o `evento_grafo` todavia no existe porque
   * falta la migracion `015`) -- eso NO tumba el resto de la respuesta, ver
   * `GrafoSyncService.estadoSincronizacion()`.
   */
  sincronizacion: SincronizacionGrafo | null;
}
