/**
 * Tabla direccion_historial. Cada version por la que ha pasado una
 * direccion.
 *
 * Solo se inserta, nunca se actualiza ni se borra: una fila nueva por cada
 * vez que se crea o se edita una direccion. No lleva estado (eso vive en
 * la fila vigente de direcciones) ni una fecha de actualizacion:
 * fecha_creacion marca desde cuando rige esa version, no cuando se toco
 * por ultima vez.
 */
export interface DireccionHistorial {
  id_direccion_historial: string;
  id_direccion: string;
  pais: string;
  departamento: string;
  ciudad: string;
  codigo_postal: string | null;
  fecha_creacion: Date;
}
