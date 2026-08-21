import { createParamDecorator, ExecutionContext } from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import { TokenUsuario } from '../models/token-usuario';

/**
 * Da acceso, dentro de un controller, al usuario que SesionGuard ya
 * verifico:
 *
 *   @UseGuards(SesionGuard)
 *   @Get('yo')
 *   obtenerYo(@UsuarioActual() usuario: TokenUsuario) { ... }
 *
 * Solo tiene sentido en una ruta que ya tenga @UseGuards(SesionGuard): sin
 * el guard, request.usuario nunca se llena.
 */
export const UsuarioActual = createParamDecorator(
  (_datos: unknown, contexto: ExecutionContext): TokenUsuario => {
    const request = contexto.switchToHttp().getRequest<FastifyRequest>();
    return request.usuario as TokenUsuario;
  },
);
