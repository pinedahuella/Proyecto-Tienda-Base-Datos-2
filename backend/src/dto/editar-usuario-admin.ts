/**
 * Cuerpo esperado en PATCH /admin/usuarios/:id.
 *
 * Cada campo es opcional. Si viene en null (o no viene), ese campo no se
 * toca; solo se actualiza lo que llega con un valor.
 */
export interface EditarUsuarioAdminPeticion {
  nombre?: string | null;
  apellido?: string | null;
  fecha_nacimiento?: string | null;
  id_rol_usuario?: number | null;
  id_estado_usuario?: number | null;
}
