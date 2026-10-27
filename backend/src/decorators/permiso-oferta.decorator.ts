import {
  createParamDecorator,
  ExecutionContext,
  SetMetadata,
} from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import type {
  PermisoOfertaNombre,
  PermisoOfertaResuelto,
} from '../models/permiso-oferta';

export const PERMISO_OFERTA_KEY = 'permiso_oferta';

/**
 * Marca una ruta con el permiso del ACL de ofertas que exige sobre la oferta
 * de su `:id`. Lo revisa `PermisoOfertaGuard`, que va DESPUES de
 * `SesionGuard`:
 *
 *   @UseGuards(SesionGuard, PermisoOfertaGuard)
 *   @PermisoOferta('editar')
 *   @Patch(':id')
 *
 * Una ruta sin esta marca pasa el guard sin preguntar nada (la lista de
 * compartidas conmigo no habla de una oferta en particular).
 */
export const PermisoOferta = (permiso: PermisoOfertaNombre) =>
  SetMetadata(PERMISO_OFERTA_KEY, permiso);

/**
 * Lo que dejo `PermisoOfertaGuard` al dejar pasar: la oferta y su dueno. Solo
 * tiene sentido en una ruta con `@PermisoOferta(...)`.
 */
export const PermisoResuelto = createParamDecorator(
  (_datos: unknown, contexto: ExecutionContext): PermisoOfertaResuelto => {
    const request = contexto.switchToHttp().getRequest<FastifyRequest>();
    return request.permisoOferta as PermisoOfertaResuelto;
  },
);
