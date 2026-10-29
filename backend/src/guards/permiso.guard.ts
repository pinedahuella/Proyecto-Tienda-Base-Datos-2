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
import { PERMISO_KEY } from '../decorators/permiso.decorator';
import { fallo } from '../helpers/respuesta';
import { manejarErrorHttp } from '../helpers/manejar-error-http';
import { PermisosService } from '../services/acl/permisos.service';

/**
 * El ACL de funcionalidades, en la puerta de cada ruta privada (migracion
 * 050, ADR-26).
 *
 * Va despues de `SesionGuard`, que ya dijo QUIEN es (401 si nadie). Este dice
 * QUE PUEDE: lee el `@Permiso(...)` de la ruta y le pregunta a `rol_permiso`,
 * en ese momento, si el rol de la cuenta lo tiene. Si no, 403 con el codigo
 * que falto, y el intento queda en `auditoria_permiso`.
 *
 * Negar por defecto: una ruta con este guard y sin `@Permiso` tambien se
 * niega (y avisa en el log), para que olvidarse de declararla no la deje
 * abierta. pruebas/permisos_cobertura.cjs revisa que no haya ninguna.
 *
 * En /compartidas/ofertas va antes de `PermisoOfertaGuard`: primero la
 * funcion (por rol), despues la oferta (por persona, migracion 049).
 */
@Injectable()
export class PermisoGuard implements CanActivate {
  private static readonly logger = new Logger('PermisoGuard');

  constructor(
    private readonly reflector: Reflector,
    private readonly permisosService: PermisosService,
  ) {}

  async canActivate(contexto: ExecutionContext): Promise<boolean> {
    const request = contexto.switchToHttp().getRequest<FastifyRequest>();
    if (request.usuario == null) {
      // Sin SesionGuard delante; no deberia pasar nunca.
      throw new HttpException(
        fallo('No hay sesion activa'),
        HttpStatus.UNAUTHORIZED,
      );
    }

    const codigo = this.reflector.getAllAndOverride<string | undefined>(
      PERMISO_KEY,
      [contexto.getHandler(), contexto.getClass()],
    );
    if (codigo == null) {
      PermisoGuard.logger.error(
        `${request.method} ${request.url} no declara su @Permiso: se niega`,
      );
      throw new HttpException(
        fallo('Esta ruta no declara su permiso'),
        HttpStatus.FORBIDDEN,
      );
    }

    const { id_usuario, id_rol_usuario } = request.usuario;
    let tiene: boolean;
    try {
      tiene = await this.permisosService.tiene(id_rol_usuario, codigo);
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo revisar el permiso');
    }

    if (!tiene) {
      await this.permisosService.registrarNegado(
        id_usuario,
        id_rol_usuario,
        codigo,
        request.method,
        request.url,
      );
      throw new HttpException(
        fallo(`No tienes permiso para hacer esto (falta ${codigo})`),
        HttpStatus.FORBIDDEN,
      );
    }
    return true;
  }
}
