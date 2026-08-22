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
  codigo_postal: string | null;
  fecha_creacion: Date;
  id_estado_direccion: number;
}
