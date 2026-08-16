/** Datos que devuelve la comprobacion de conexion con PostgreSQL. */
export interface InfoConexion {
  base: string;
  hora: Date;
  version: string;
}
