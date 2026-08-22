import { UsuarioRegistrado } from './registro-usuario';

/**
 * Respuesta de GET /perfil.
 *
 * Es lo mismo que UsuarioRegistrado (lo que ya devuelve GET /usuario/yo),
 * mas el nombre del rol y del estado: /usuario/yo solo trae los ids
 * (id_rol_usuario, id_estado_usuario), y aqui hace falta tambien el texto
 * para mostrarlo directo en el perfil sin que el frontend tenga que
 * cruzarlo con /admin/roles o /admin/estados (que ademas son solo para
 * admin).
 */
export interface PerfilUsuario extends UsuarioRegistrado {
  rol_usuario_nombre: string;
  estado_usuario_nombre: string;
}
