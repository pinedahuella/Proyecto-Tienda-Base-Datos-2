import {
  CanActivate,
  ExecutionContext,
  HttpException,
  HttpStatus,
  Injectable,
  Logger,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { FastifyRequest } from 'fastify';
import { ROLES_KEY } from '../decorators/roles.decorator';
import {
  ErrorConexion,
  ErrorConexionRedis,
  ErrorSesion,
} from '../helpers/errores';
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
 *    despues de firmar el token), corta con 401 igual. Si PostgreSQL no
 *    responde, se cree al token (2026-10-20): la sesion abierta sigue y la
 *    tienda se puede mirar; lo que escribe en PostgreSQL, como pagar, falla
 *    por su lado.
 * 3. Autorizacion (opcional): si la ruta ademas tiene @Roles(...), revisa
 *    que el rol del usuario este en esa lista. Si no, 403.
 *
 * Si todo pasa, deja el usuario del token en request.usuario, listo para
 * leerse con el decorator @UsuarioActual().
 */
@Injectable()
export class SesionGuard implements CanActivate {
  private static readonly logger = new Logger('SesionGuard');
  /** Cuando se aviso por ultima vez de una sesion sin PostgreSQL. */
  private static ultimoAviso = 0;

  constructor(
    private readonly reflector: Reflector,
    private readonly usuarioService: UsuarioService,
  ) {}

  /**
   * Una linea en el registro, como mucho una por minuto, para que se vea que
   * las sesiones se estan aceptando sin preguntarle a PostgreSQL.
   */
  private avisarSesionSinPostgres(): void {
    const ahora = Date.now();
    if (ahora - SesionGuard.ultimoAviso < 60_000) {
      return;
    }
    SesionGuard.ultimoAviso = ahora;
    SesionGuard.logger.warn(
      'PostgreSQL no responde: las sesiones abiertas se aceptan por su token firmado, sin revisar si la cuenta sigue activa',
    );
  }

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
      // PostgreSQL no respondio (2026-10-20). La pregunta de la cuenta activa
      // no se pudo hacer, pero el token si se verifico: tiene firma y no
      // vencio, asi que fue PostgreSQL quien lo emitio hace menos de 2 horas
      // para una cuenta activa. Se le cree, y la persona sigue mirando la
      // tienda, su carrito y sus recomendaciones; comprar igual no se puede,
      // porque eso lo escribe PostgreSQL. Solo cuando la base NO CONTESTA: si
      // contesta que la cuenta esta suspendida, se corta como siempre (abajo).
      // En cuanto vuelve, la siguiente peticion pregunta otra vez.
      if (
        error instanceof ErrorConexion &&
        !(error instanceof ErrorConexionRedis)
      ) {
        this.avisarSesionSinPostgres();
        activo = true;
      } else {
        manejarErrorHttp(error, 'No se pudo verificar la sesion');
      }
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
