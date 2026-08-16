/**
 * Tabla log_login. Cada entrada y salida de un usuario.
 *
 * Solo se inserta, nunca se actualiza: es un registro historico.
 * ip_origen es tipo inet en PostgreSQL y el driver lo entrega como string.
 */
export interface LogLogin {
  id_log_login: string;
  id_usuario: string;
  id_tipo_login: number;
  ip_origen: string | null;
  fecha_login: Date;
}
