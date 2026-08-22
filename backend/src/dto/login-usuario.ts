/**
 * Cuerpo esperado en POST /usuario/login.
 *
 * identificador puede ser el correo electronico o el usuario: el frontend
 * manda lo que la persona haya escrito, sin adivinar cual de los dos es.
 */
export interface LoginUsuarioPeticion {
  identificador: string;
  contrasena: string;
}
