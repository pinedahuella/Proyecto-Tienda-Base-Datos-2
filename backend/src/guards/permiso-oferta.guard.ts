import {
  CanActivate,
  ExecutionContext,
  HttpException,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { FastifyRequest } from 'fastify';
import { PERMISO_OFERTA_KEY } from '../decorators/permiso-oferta.decorator';
import { fallo } from '../helpers/respuesta';
import { manejarErrorHttp } from '../helpers/manejar-error-http';
import type { PermisoOfertaNombre } from '../models/permiso-oferta';
import { AclOfertasService } from '../services/acl/acl-ofertas.service';

/**
 * El ACL de la aplicacion, en la puerta de cada ruta de /compartidas/ofertas.
 *
 * Va despues de `SesionGuard` (que ya dejo `request.usuario`) y antes del
 * controller. Si la ruta lleva `@PermisoOferta(...)`, pregunta a
 * `AclOfertasService.comprobar()` si la cuenta tiene una entrada vigente con
 * ese permiso sobre la oferta del `:id`:
 *
 * - Si la tiene, deja en `request.permisoOferta` la oferta y su dueno, y el
 *   controller actua a nombre del dueno con los mismos servicios de siempre.
 * - Si no, contesta 404, el mismo de una oferta ajena o que no existe: no se
 *   le confirma a nadie que la oferta existe. El intento queda en el registro.
 *
 * Negar por defecto: sin entrada no hay paso, tambien para un admin y tambien
 * para el dueno (lo suyo va por /vendedor/ofertas).
 */
@Injectable()
export class PermisoOfertaGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly aclOfertasService: AclOfertasService,
  ) {}

  async canActivate(contexto: ExecutionContext): Promise<boolean> {
    const permiso = this.reflector.getAllAndOverride<
      PermisoOfertaNombre | undefined
    >(PERMISO_OFERTA_KEY, [contexto.getHandler(), contexto.getClass()]);
    if (permiso == null) {
      return true;
    }

    const request = contexto.switchToHttp().getRequest<FastifyRequest>();
    if (request.usuario == null) {
      // Sin SesionGuard delante; no deberia pasar nunca.
      throw new HttpException(
        fallo('No hay sesion activa'),
        HttpStatus.UNAUTHORIZED,
      );
    }
    const idOferta = (request.params as Record<string, string> | undefined)?.id;

    try {
      request.permisoOferta = await this.aclOfertasService.comprobar(
        request.usuario.id_usuario,
        idOferta ?? '',
        permiso,
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo revisar el permiso');
    }
    return true;
  }
}
