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
import { manejarErrorHttp } from '../helpers/manejar-error-http';
import { NOMBRE_COOKIE_TOKEN, verificarToken } from '../helpers/token';
import { UsuarioService } from '../services/usuario.service';

/**
 * Protege una ruta. Se usa con @UseGuards(SesionGuard) en el controller.
 *
 * Hace tres cosas, en orden:
 *
 * 1. Autenticacion: lee la cookie, verifica el token. Si no hay cookie o el
 *    token no sirve (firma invalida o vencido), corta la peticion con 401.
 * 2. Cuenta activa: el token es valido hasta por 2 horas sin importar lo
 *    que le pase a la cuenta mientras tanto. Esta consulta revisa el
 *    estado actual en la base; si ya no esta activa (la suspendieron
 *    despues de firmar el token), corta con 401 igual.
 * 3. Autorizacion (opcional): si la ruta ademas tiene @Roles(...), revisa
 *    que el rol del usuario este en esa lista. Si no, 403.
 *
 * Si todo pasa, deja el usuario del token en request.usuario, listo para
 * leerse con el decorator @UsuarioActual().
 */
@Injectable()
export class SesionGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly usuarioService: UsuarioService,
  ) {}

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

    let activo: boolean;
    try {
      activo = await this.usuarioService.estaActivo(request.usuario.id_usuario);
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo verificar la sesion');
    }

    if (!activo) {
      throw new HttpException(
        fallo('Token invalido o expirado'),
        HttpStatus.UNAUTHORIZED,
      );
    }

    // getAllAndOverride revisa el metodo primero y, si ahi no hay nada, la
    // clase. @Roles(...) puede ir en cualquiera de los dos: en este
    // proyecto va en la clase (protege todas las rutas del controller por
    // defecto), pero un metodo especifico podria sobreescribirla.
    const rolesPermitidos = this.reflector.getAllAndOverride<
      number[] | undefined
    >(ROLES_KEY, [contexto.getHandler(), contexto.getClass()]);

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
