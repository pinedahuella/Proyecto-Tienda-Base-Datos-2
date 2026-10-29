import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { PaginarAlertasFraudeQuery } from '../../dto/paginar-alertas-fraude';
import { FraudeLoginService } from '../../services/fraude-login/fraude-login.service';

/**
 * `GET /admin/fraude/alertas-login` -- las alertas de fuerza bruta /
 * multi-cuenta que detecta `FraudeLoginService` con contadores de Redis en
 * el propio login (ver ese servicio).
 *
 * `@UseGuards(SesionGuard, PermisoGuard)` y `@Permiso('fraude.ver')`: en `rol_permiso`, SOLO
 * ADMIN. No la tienda -- la tienda es un vendedor mas, y ensenarle quien la
 * esta calificando (o intentando entrar) de forma sospechosa le entrega
 * justo la lista que no deberia ver.
 *
 * Detalle del payload: `elementos Generales/endpoints/endpoints-fraude.md`.
 */
@Controller('admin/fraude')
@UseGuards(SesionGuard, PermisoGuard)
export class FraudeController {
  constructor(private readonly fraudeLoginService: FraudeLoginService) {}

  // GET /admin/fraude/alertas-login
  @Permiso('fraude.ver')
  @Get('alertas-login')
  async alertasLogin(@Query() query: PaginarAlertasFraudeQuery) {
    try {
      const pagina = await this.fraudeLoginService.listarAlertasPaginado(query);
      return exito(pagina, 'Alertas de login obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las alertas de login');
    }
  }
}
