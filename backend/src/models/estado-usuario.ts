/** Tabla estado_usuario. Catalogo: activo, inactivo, suspendido. */
export interface EstadoUsuario {
  id_estado_usuario: number;
  estado_usuario_nombre: string;
}

// La migracion 001 inserta activo primero, por eso su id es 1.
export const ID_ESTADO_ACTIVO = 1;
