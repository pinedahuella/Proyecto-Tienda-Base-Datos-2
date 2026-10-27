import { TokenUsuario } from '../dto/token-usuario';
import { PermisoOfertaResuelto } from '../models/permiso-oferta';

/**
 * Le agrega el campo "usuario" al request de Fastify. Nadie lo llena solo:
 * SesionGuard lo deja puesto despues de verificar el token, para que el
 * controller lo pueda leer con @UsuarioActual().
 *
 * "permisoOferta" lo deja PermisoOfertaGuard cuando el ACL de ofertas deja
 * pasar: la oferta y su dueno. Se lee con @PermisoResuelto().
 */
declare module 'fastify' {
  interface FastifyRequest {
    usuario?: TokenUsuario;
    permisoOferta?: PermisoOfertaResuelto;
  }
}
