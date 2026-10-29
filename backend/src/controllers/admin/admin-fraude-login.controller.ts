import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Query,
  UseGuards,
} from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { MarcarAlertaFraudeBody } from '../../dto/marcar-alerta-fraude';
import type { PaginarEventosAutenticacionQuery } from '../../dto/paginar-eventos-autenticacion';
import { FraudeLoginExploracionService } from '../../services/fraude-login/fraude-login-exploracion.service';

/**
 * El explorador manual del modulo de fraude de login -- punto 3 (parte
 * pendiente) y punto 5 de
 * `elementos Generales/plan pendiente/fraude-login-eventos.md`. Este modulo
 * (fraude por IP/cuenta en el login) es solo Elasticsearch + Redis; no toca
 * el panel de anillos de resenas (`AdminFraudeAnillosController`, Neo4j),
 * que vive en su propio controller.
 *
 * `GET /admin/fraude/eventos-login` -- los logs crudos de
 * `mesh_eventos_autenticacion` (Elasticsearch), paginados y filtrados.
 * `PATCH /admin/fraude/alertas-login/:id` -- marcar una alerta ya existente
 * (de cualquiera de las 9 senales) como revisada o descartada.
 *
 * `@UseGuards(SesionGuard, PermisoGuard)` y `@Permiso('fraude.ver')` en la clase
 * (marcar pide `fraude.resolver`), mismo criterio que `FraudeController`: en
 * `rol_permiso`, solo el admin.
 */
@Controller('admin/fraude')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('fraude.ver')
export class AdminFraudeLoginController {
  constructor(
    private readonly fraudeLoginExploracionService: FraudeLoginExploracionService,
  ) {}

  // GET /admin/fraude/eventos-login
  @Get('eventos-login')
  async eventosLogin(@Query() query: PaginarEventosAutenticacionQuery) {
    try {
      const pagina =
        await this.fraudeLoginExploracionService.listarEventosPaginado(query);
      return exito(pagina, 'Eventos de autenticacion obtenidos');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener los eventos de autenticacion',
      );
    }
  }

  // PATCH /admin/fraude/alertas-login/:id
  @Permiso('fraude.resolver')
  @Patch('alertas-login/:id')
  async marcarAlerta(
    @Param('id') id: string,
    @Body() body: MarcarAlertaFraudeBody,
  ) {
    try {
      const alerta = await this.fraudeLoginExploracionService.marcarAlerta(
        id,
        body.estado,
      );
      return exito(alerta, 'Alerta actualizada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar la alerta');
    }
  }
}
