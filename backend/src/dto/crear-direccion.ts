/** Cuerpo esperado en POST /direccion-usuario. */
export interface CrearDireccionPeticion {
  pais: string;
  departamento: string;
  ciudad: string;
  codigo_postal?: string | null;
}
