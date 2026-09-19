import type { FastifyRequest } from 'fastify';
import { NOMBRE_COOKIE_TOKEN, verificarToken } from './token';

/**
 * Si la peticion trae una cookie de sesion VALIDA, devuelve el id de esa
 * cuenta; si no hay cookie, o el token no sirve (vencido, invalido), `null`
 * -- nunca un 401. Para rutas PUBLICAS donde un visitante sin cuenta es un
 * caso normal, no un error (`POST /eventos/vista`, `GET /buscador/productos`
 * al registrar el evento de busqueda).
 *
 * Nunca se confia en un id que venga en el cuerpo/query de la peticion --
 * eso permitiria reportar eventos a nombre de otra cuenta. `id_usuario`
 * SIEMPRE sale de un token ya firmado por el backend.
 */
export async function idUsuarioDeCookieOpcional(
  request: FastifyRequest,
): Promise<string | null> {
  const token = request.cookies[NOMBRE_COOKIE_TOKEN];
  if (!token) {
    return null;
  }
  try {
    const usuario = await verificarToken(token);
    return usuario.id_usuario;
  } catch {
    return null;
  }
}
