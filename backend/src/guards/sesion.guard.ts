import {
  CanActivate,
  ExecutionContext,
  HttpException,
  HttpStatus,
  Injectable,
  Logger,
} from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
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
 * Protege una ruta: dice QUIEN es la cuenta, o 401. Se usa con
 * @UseGuards(SesionGuard, PermisoGuard) en el controller; lo que la cuenta
 * PUEDE hacer lo decide PermisoGuard despues, con el ACL de funcionalidades
 * de la migracion 050 (403). Hasta el 2026-10-28 este guard tambien revisaba
 * los @Roles(...) de cada ruta; esa lista paso a la tabla rol_permiso.
 *
 * Hace dos cosas, en orden:
 *
 * 1. Autenticacion: lee la cookie, verifica el token. Si no hay cookie o el
 *    token no sirve (firma invalida o vencido), corta la peticion con 401.
 * 2. Cuenta activa y su rol de hoy: el token es valido hasta por 2 horas sin
 *    importar lo que le pase a la cuenta mientras tanto. Esta consulta revisa
 *    el estado y el rol actuales en la base; si ya no esta activa (la
 *    suspendieron despues de firmar el token), corta con 401 igual, y si le
 *    cambiaron el rol, vale el nuevo desde esta peticion (2026-11-02). Si
 *    PostgreSQL no responde, se cree al token (2026-10-20): la sesion abierta
 *    sigue con el rol del token y la tienda se puede mirar; lo que escribe en
 *    PostgreSQL, como pagar, falla por su lado.
 *
 * Si todo pasa, deja el usuario del token, con el rol de hoy, en
 * request.usuario, listo para leerse con el decorator @UsuarioActual().
 */
@Injectable()
export class SesionGuard implements CanActivate {
  private static readonly logger = new Logger('SesionGuard');
  /** Cuando se aviso por ultima vez de una sesion sin PostgreSQL. */
  private static ultimoAviso = 0;
  /**
   * Los cambios de rol ya anotados en el registro (cuenta, rol del token, rol
   * de hoy), para escribir una linea por cambio y no una por peticion.
   */
  private static readonly rolesCambiadosAvisados = new Set<string>();

  constructor(private readonly usuarioService: UsuarioService) {}

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

    let cuenta: { activo: boolean; id_rol_usuario: number } | null;
    try {
      cuenta = await this.usuarioService.estadoDeSesion(
        request.usuario.id_usuario,
      );
    } catch (error) {
      // PostgreSQL no respondio (2026-10-20). La pregunta de la cuenta activa
      // no se pudo hacer, pero el token si se verifico: tiene firma y no
      // vencio, asi que fue PostgreSQL quien lo emitio hace menos de 2 horas
      // para una cuenta activa. Se le cree, y la persona sigue mirando la
      // tienda, su carrito y sus recomendaciones; comprar igual no se puede,
      // porque eso lo escribe PostgreSQL. Solo cuando la base NO CONTESTA: si
      // contesta que la cuenta esta suspendida, se corta como siempre (abajo).
      // En cuanto vuelve, la siguiente peticion pregunta otra vez. Mientras
      // tanto el rol que vale es el del token, el ultimo que se conoce.
      if (
        error instanceof ErrorConexion &&
        !(error instanceof ErrorConexionRedis)
      ) {
        this.avisarSesionSinPostgres();
        cuenta = {
          activo: true,
          id_rol_usuario: request.usuario.id_rol_usuario,
        };
      } else {
        manejarErrorHttp(error, 'No se pudo verificar la sesion');
      }
    }

    if (cuenta == null || !cuenta.activo) {
      throw new HttpException(
        fallo('Token invalido o expirado'),
        HttpStatus.UNAUTHORIZED,
      );
    }

    // El rol de AHORA, el de la base, y no el que tenia al entrar (2026-11-02).
    // PermisoGuard y todo lo que lee @UsuarioActual() usan este: si el admin
    // le cambia el rol a una cuenta, vale en su peticion siguiente, igual que
    // quitar una fila de rol_permiso, sin esperar a que el token venza.
    if (cuenta.id_rol_usuario !== request.usuario.id_rol_usuario) {
      const clave = `${request.usuario.id_usuario}:${request.usuario.id_rol_usuario}:${cuenta.id_rol_usuario}`;
      if (!SesionGuard.rolesCambiadosAvisados.has(clave)) {
        SesionGuard.rolesCambiadosAvisados.add(clave);
        SesionGuard.logger.log(
          `La cuenta ${request.usuario.id_usuario} entro con el rol ${request.usuario.id_rol_usuario} y hoy tiene el ${cuenta.id_rol_usuario}: vale el de hoy`,
        );
      }
      request.usuario.id_rol_usuario = cuenta.id_rol_usuario;
    }

    return true;
  }
}
