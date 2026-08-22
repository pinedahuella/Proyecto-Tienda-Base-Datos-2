/** Tabla estado_direccion. Catalogo: activa, inactiva. */
export interface EstadoDireccion {
  id_estado_direccion: number;
  estado_direccion_nombre: string;
}

// La migracion 002 inserta activa primero, por eso su id es 1. Toda
// direccion nueva entra activa de una vez.
export const ID_ESTADO_DIRECCION_ACTIVA = 1;
