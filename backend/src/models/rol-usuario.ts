/** Tabla rol_usuario. Catalogo: comprador, vendedor, admin. */
export interface RolUsuario {
  id_rol_usuario: number;
  rol_usuario_nombre: string;
}

// La migracion 001 inserta comprador primero y admin al final, en ese
// orden, por eso sus id son estos. Un catalogo tan chico no cambia sin una
// migracion nueva, asi que es seguro fijarlos aqui en vez de consultarlos
// cada vez.
export const ID_ROL_COMPRADOR = 1;
export const ID_ROL_ADMIN = 3;
