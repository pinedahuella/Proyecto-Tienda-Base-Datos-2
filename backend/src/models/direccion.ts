/**
 * Tabla direcciones. La version vigente de cada direccion de envio.
 *
 * No se borra nunca (direccion_historial la referencia con RESTRICT): para
 * quitarla de en medio se le cambia el estado a inactiva.
 *
 * id_direccion e id_usuario son bigint/bigserial y el driver pg los entrega
 * como string, no como number, para no perder precision.
 */
export interface Direccion {
  id_direccion: string;
  id_usuario: string;
  pais: string;
  departamento: string;
  ciudad: string;
  /**
   * Calle, numero, zona y referencias en una sola linea. La API la exige
   * al crear una direccion; la columna es varchar(255) y todavia nullable
   * en la base (la migracion real la dejara NOT NULL), de ahi el `| null`.
   */
  direccion_exacta: string | null;
  codigo_postal: string | null;
  fecha_creacion: Date;
  id_estado_direccion: number;
}
