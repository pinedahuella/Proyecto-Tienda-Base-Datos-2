/**
 * Tipos de la sincronizacion del grafo de Neo4j con PostgreSQL.
 *
 * El grafo es una PROYECCION de la tabla `resena`: lo carga el ETL
 * (`etl/cargar_grafo.sh`) o, cuando este el worker del outbox, se mantiene
 * al dia solo. La CONCILIACION es la red de seguridad: compara los conteos
 * de las dos bases y AVISA de la deriva -- no repara.
 */

/** Una fila de la tabla de comparacion: un recurso, cuantos hay en cada lado. */
export interface FilaConciliacion {
  /** Que se compara: "resenas", "productos resenados", "relacion ESCRIBIO"... */
  recurso: string;
  /** Cuantos deberia haber, segun PostgreSQL (la verdad). */
  postgres: number;
  /** Cuantos hay en Neo4j (la proyeccion). */
  neo4j: number;
  /** `neo4j - postgres`. 0 = al dia. Negativo = al grafo le faltan. */
  diferencia: number;
  /**
   * `true` si esta fila entra en el veredicto `cuadra`. Las resenas y sus
   * tres relaciones si; los nodos de producto/usuario/direccion NO -- el
   * worker incremental puede dejar nodos huerfanos (una resena borrada deja
   * su `:Producto` sin tocar) y el ETL completo carga TODOS los usuarios,
   * no solo los que aparecen en una resena. Un exceso ahi no es un error.
   */
  cuenta_para_veredicto: boolean;
}

/** Un evento del outbox que fallo 5 veces y quedo apartado -- para revisar a mano. */
export interface EventoGrafoApartado {
  id_evento: number;
  id_resena: number;
  intentos: number;
  ultimo_error: string | null;
  /** Cuando se encolo (ISO 8601). */
  fecha: string;
}

/** El estado de la cola del outbox (`evento_grafo`). */
export interface EstadoColaGrafo {
  /** Eventos sin aplicar todavia (`procesado_en IS NULL`, `intentos < 5`). */
  pendientes: number;
  /** Eventos apartados por fallar 5 veces (`intentos >= 5`). */
  apartados: number;
}

/** Lo que devuelve `GET /admin/grafo/conciliacion`. */
export interface ConciliacionGrafo {
  /**
   * `true` si el grafo tiene exactamente las resenas y las relaciones que
   * dice PostgreSQL. Los nodos sueltos de producto/usuario no lo tumban
   * (ver `FilaConciliacion.cuenta_para_veredicto`).
   */
  cuadra: boolean;
  /** Cuando se corrio esta comprobacion (ISO 8601). */
  verificado_en: string;
  /**
   * El evento del outbox procesado mas reciente (`max(procesado_en)`), o
   * `null` si ninguno se ha procesado todavia (o si la tabla aun no existe).
   */
  ultima_sincronizacion: string | null;
  /** El estado de la cola, o `null` si `evento_grafo` todavia no existe. */
  cola: EstadoColaGrafo | null;
  /** El estado de la cola de las compras, o `null` si `evento_grafo_compra`
   * todavia no existe. */
  cola_compras: EstadoColaGrafo | null;
  /** Una fila por recurso comparado. */
  comparacion: FilaConciliacion[];
  /** Los eventos apartados, si los hay. */
  eventos_apartados: EventoGrafoApartado[];
  /**
   * Frase lista para la pantalla cuando algo no cuadra (qué falta y qué
   * hacer). `null` cuando `cuadra` es `true`.
   */
  sugerencia: string | null;
}
