import { SetMetadata } from '@nestjs/common';
import type { CodigoPermiso } from '../models/permiso';

export const PERMISO_KEY = 'permiso_funcion';

/**
 * La accion que hace una ruta, en el ACL de funcionalidades (migracion 050).
 * La revisa `PermisoGuard`, que va DESPUES de `SesionGuard`:
 *
 *   @UseGuards(SesionGuard, PermisoGuard)
 *   @Permiso('ofertas.publicar')
 *   @Post()
 *
 * Puede ir en la clase (vale para todas sus rutas) y en un metodo (manda
 * sobre la de la clase). Una ruta con `PermisoGuard` y sin `@Permiso` se
 * niega: negar por defecto tambien cuando alguien se olvida de declararla.
 */
export const Permiso = (codigo: CodigoPermiso) =>
  SetMetadata(PERMISO_KEY, codigo);
