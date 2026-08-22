/** Cuerpo esperado en PATCH /perfil/contrasena. */
export interface CambiarContrasenaPeticion {
  contrasena_actual: string;
  contrasena_nueva: string;
  contrasena_nueva_confirmacion: string;
}
