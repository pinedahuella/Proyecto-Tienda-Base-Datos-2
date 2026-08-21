import { TokenUsuario } from '../models/token-usuario';

/**
 * Le agrega el campo "usuario" al request de Fastify. Nadie lo llena solo:
 * SesionGuard lo deja puesto despues de verificar el token, para que el
 * controller lo pueda leer con @UsuarioActual().
 */
declare module 'fastify' {
  interface FastifyRequest {
    usuario?: TokenUsuario;
  }
}
