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
import type { MarcarHallazgoEventoFraudeBody } from '../../dto/marcar-hallazgo-evento-fraude';
import type { PaginarHallazgosEventoFraudeQuery } from '../../dto/paginar-hallazgos-evento-fraude';
import { HallazgosEventoFraudePersistidosService } from '../../services/fraude/hallazgos-evento-fraude-persistidos.service';

/**
 * El panel de admin sobre los hallazgos de F1-F6
 * (`hallazgo_evento_fraude`/`hallazgo_evento_fraude_cuenta`, ver
 * `elementos Generales/plan pendiente/hallazgos-evento-fraude.sql`).
 * Nombrado en paralelo con `alertas-login`/`alertas-resenas`: mismo
 * sustantivo, distinto dominio (eventos de ClickHouse en vez de login o
 * grafo).
 *
 * `GET /admin/fraude/alertas-eventos` -- paginado, filtrable por `estado`
 * (`pendiente`/`revisada`/`descartada`) y `tipo` (uno de los seis de F1-F6).
 * `PATCH /admin/fraude/alertas-eventos/:id` -- marcar un hallazgo revisado
 * o descartado (solo si esta `pendiente`).
 *
 * `@UseGuards(SesionGuard, PermisoGuard)` y `@Permiso('fraude.ver')` en la clase
 * (marcar pide `fraude.resolver`), mismo criterio que el resto de
 * `admin/fraude/*`: en `rol_permiso`, solo el admin.
 */
@Controller('admin/fraude')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('fraude.ver')
export class AdminFraudeEventosController {
  constructor(
    private readonly hallazgosEventoFraudePersistidosService: HallazgosEventoFraudePersistidosService,
  ) {}

  // GET /admin/fraude/alertas-eventos
  @Get('alertas-eventos')
  async listar(@Query() query: PaginarHallazgosEventoFraudeQuery) {
    try {
      const pagina =
        await this.hallazgosEventoFraudePersistidosService.listarPaginado(
          query,
        );
      return exito(pagina, 'Hallazgos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los hallazgos');
    }
  }

  // PATCH /admin/fraude/alertas-eventos/:id
  @Permiso('fraude.resolver')
  @Patch('alertas-eventos/:id')
  async marcar(
    @Param('id') id: string,
    @Body() body: MarcarHallazgoEventoFraudeBody,
  ) {
    try {
      const hallazgo =
        await this.hallazgosEventoFraudePersistidosService.marcarHallazgo(
          id,
          body.estado,
        );
      return exito(hallazgo, 'Hallazgo actualizado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar el hallazgo');
    }
  }
}
