/**
 * Cuerpo esperado en PATCH /direccion-usuario/:id.
 *
 * Cada campo es opcional. Si viene en null (o no viene), ese campo no se
 * toca; solo se actualiza lo que llega con un valor. Debe venir al menos
 * uno.
 */
export interface EditarDireccionPeticion {
  pais?: string | null;
  departamento?: string | null;
  ciudad?: string | null;
  direccion_exacta?: string | null;
  codigo_postal?: string | null;
}
