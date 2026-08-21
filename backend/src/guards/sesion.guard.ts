import {
  CanActivate,
  ExecutionContext,
  HttpException,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { FastifyRequest } from 'fastify';
import { ROLES_KEY } from '../decorators/roles.decorator';
import { ErrorSesion } from '../helpers/errores';
import { fallo } from '../helpers/respuesta';
import { NOMBRE_COOKIE_TOKEN, verificarToken } from '../helpers/token';

/**
 * Protege una ruta. Se usa con @UseGuards(SesionGuard) en el controller.
 *
 * Hace dos cosas, en orden:
 *
 * 1. Autenticacion: lee la cookie, verifica el token. Si no hay cookie o el
 *    token no sirve, corta la peticion con 401 antes de que llegue al
 *    controller.
 * 2. Autorizacion (opcional): si la ruta ademas tiene @Roles(...), revisa
 *    que el rol del usuario este en esa lista. Si no, 403.
 *
 * Si todo pasa, deja el usuario del token en request.usuario, listo para
 * leerse con el decorator @UsuarioActual().
 */
@Injectable()
export class SesionGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  async canActivate(contexto: ExecutionContext): Promise<boolean> {
    const request = contexto.switchToHttp().getRequest<FastifyRequest>();
    const token = request.cookies[NOMBRE_COOKIE_TOKEN];

    if (!token) {
      throw new HttpException(
        fallo('No hay sesion activa'),
        HttpStatus.UNAUTHORIZED,
      );
    }

    try {
      request.usuario = await verificarToken(token);
    } catch (error) {
      const mensaje =
        error instanceof ErrorSesion
          ? error.message
          : 'Token invalido o expirado';
      throw new HttpException(fallo(mensaje), HttpStatus.UNAUTHORIZED);
    }

    const rolesPermitidos = this.reflector.get<number[] | undefined>(
      ROLES_KEY,
      contexto.getHandler(),
    );

    const hayRestriccionDeRol =
      rolesPermitidos != null && rolesPermitidos.length > 0;

    if (
      hayRestriccionDeRol &&
      !rolesPermitidos.includes(request.usuario.id_rol_usuario)
    ) {
      throw new HttpException(
        fallo('No tienes permiso para hacer esto'),
        HttpStatus.FORBIDDEN,
      );
    }

    return true;
  }
}
