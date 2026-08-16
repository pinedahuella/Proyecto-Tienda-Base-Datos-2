/**
 * Tabla log_registro. Desde donde se creo cada cuenta.
 *
 * Solo se inserta, nunca se actualiza.
 */
export interface LogRegistro {
  id_log_registro: string;
  id_usuario: string;
  ip_origen: string | null;
  fecha_registro: Date;
}
