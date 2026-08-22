/** Respuesta de GET /usuario/registros-existentes. */
export interface ExistenciaUsuario {
  correo_existente: boolean;
  usuario_existente: boolean;
}
