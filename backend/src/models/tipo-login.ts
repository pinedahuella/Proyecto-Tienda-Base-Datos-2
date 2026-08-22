/** Tabla tipo_login. Catalogo: login, logout. */
export interface TipoLogin {
  id_tipo_login: number;
  tipo_login_nombre: string;
}

// La migracion 001 inserta login primero y logout despues, por eso sus id
// son estos.
export const ID_TIPO_LOGIN = 1;
export const ID_TIPO_LOGOUT = 2;
