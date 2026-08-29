/** Datos que devuelve la comprobacion de conexion con Neo4j. */
export interface InfoConexionGrafo {
  version: string;
  /**
   * Cuantos nodos tiene el grafo ahora mismo. No es solo un dato de adorno:
   * el grafo es una proyeccion que se carga con el ETL, y uno vacio (0) es
   * un fallo comun -- el backend conecta pero no hay nada que consultar.
   */
  nodos: number;
}
