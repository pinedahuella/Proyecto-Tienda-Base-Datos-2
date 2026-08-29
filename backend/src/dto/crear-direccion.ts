/** Cuerpo esperado en POST /direccion-usuario. */
export interface CrearDireccionPeticion {
  pais: string;
  departamento: string;
  ciudad: string;
  /** Calle, numero, zona y referencias. Obligatoria: sin ella no se entrega un pedido. */
  direccion_exacta: string;
  codigo_postal?: string | null;
}
