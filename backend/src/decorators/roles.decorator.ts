import { SetMetadata } from '@nestjs/common';

export const ROLES_KEY = 'roles';

/**
 * Marca una ruta como restringida a ciertos roles (los id_rol_usuario del
 * catalogo rol_usuario: 1 comprador, 2 vendedor, 3 admin).
 *
 * Se usa junto con SesionGuard, que es quien de verdad revisa esta marca:
 *
 *   @Roles(3)
 *   @UseGuards(SesionGuard)
 *   @Get('solo-para-admin')
 *
 * Una ruta con @UseGuards(SesionGuard) pero sin @Roles(...) solo exige
 * estar logueado, sin importar el rol.
 */
export const Roles = (...roles: number[]) => SetMetadata(ROLES_KEY, roles);
