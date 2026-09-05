/** Datos que devuelve la comprobacion de conexion con Elasticsearch. */
export interface InfoConexionBuscador {
  version: string;
  /**
   * verde, amarillo o rojo. Con un solo nodo (ver docker-compose.yml)
   * "amarillo" es lo normal, no un fallo: las replicas no se pueden asignar
   * a ningun lado.
   */
  estado_cluster: string;
  /**
   * Cuantos documentos tiene el indice del buscador ahora mismo. No es solo
   * un dato de adorno: el indice es una proyeccion que carga el ETL
   * (etl/cargar_busqueda.sh), y uno vacio (0) es un fallo comun -- el
   * backend conecta pero no hay nada que buscar.
   */
  documentos: number;
}
