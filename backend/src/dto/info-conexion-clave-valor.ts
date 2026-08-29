/** Datos que devuelve la comprobacion de conexion con Redis. */
export interface InfoConexionClaveValor {
  version: string;
  /** El modo del servidor: "standalone", "cluster" o "sentinel". */
  modo: string;
}
