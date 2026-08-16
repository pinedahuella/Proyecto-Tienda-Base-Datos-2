/**
 * Tabla usuarios.
 *
 * id_usuario es bigserial y el driver pg devuelve los bigint como string, no
 * como number, para no perder precision. Por eso va tipado como string: si se
 * declara number, una comparacion como id === 1 falla en silencio porque en
 * realidad llega "1".
 */
export interface Usuario {
  id_usuario: string;
  correo_electronico: string;
  usuario: string;
  nombre: string;
  apellido: string | null;
  contrasena_hash: string;
  fecha_nacimiento: Date | null;
  fecha_creacion: Date;
  id_rol_usuario: number;
  id_estado_usuario: number;
}
