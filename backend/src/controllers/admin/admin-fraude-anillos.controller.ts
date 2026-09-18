import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Query,
  UseGuards,
} from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { MarcarAnilloFraudeBody } from '../../dto/marcar-anillo-fraude';
import type { PaginarAnillosFraudeQuery } from '../../dto/paginar-anillos-fraude';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { FraudeAnillosPersistidosService } from '../../services/fraude/fraude-anillos-persistidos.service';

/**
 * El panel de admin sobre los anillos de fraude en reseñas
 * (`anillo_fraude`/`anillo_fraude_resena`, ver
 * `elementos Generales/plan pendiente/anillos-fraude-persistencia.sql`).
 * Nombrado en paralelo con las rutas de fraude de login (`alertas-login`,
 * `eventos-login`): mismo sustantivo, distinto dominio.
 *
 * `GET /admin/fraude/alertas-resenas` -- paginado, filtrable por `estado`
 * (`pendiente`/`revisada`/`descartada`) y `tipo` (`mutuo`/`ciclo`/`reiterado`).
 * `PATCH /admin/fraude/alertas-resenas/:id` -- marcar un anillo revisado o
 * descartado (solo si está `pendiente`).
 * `GET /admin/fraude/alertas-resenas/:id/detalle-grafo` -- el detalle real
 * de ESE anillo (autor/vendedor/producto/fecha/calificación de cada reseña
 * de su evidencia), consultado en vivo contra Neo4j.
 *
 * `@UseGuards(SesionGuard)` y `@Roles(ID_ROL_ADMIN)` en la clase, mismo
 * criterio que `FraudeController`/`AdminFraudeLoginController`: solo admin.
 */
@Controller('admin/fraude')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class AdminFraudeAnillosController {
  constructor(
    private readonly fraudeAnillosPersistidosService: FraudeAnillosPersistidosService,
  ) {}

  // GET /admin/fraude/alertas-resenas
  @Get('alertas-resenas')
  async listar(@Query() query: PaginarAnillosFraudeQuery) {
    try {
      const pagina =
        await this.fraudeAnillosPersistidosService.listarPaginado(query);
      return exito(pagina, 'Anillos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los anillos');
    }
  }

  // PATCH /admin/fraude/alertas-resenas/:id
  @Patch('alertas-resenas/:id')
  async marcar(@Param('id') id: string, @Body() body: MarcarAnilloFraudeBody) {
    try {
      const anillo = await this.fraudeAnillosPersistidosService.marcarAnillo(
        id,
        body.estado,
      );
      return exito(anillo, 'Anillo actualizado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar el anillo');
    }
  }

  // GET /admin/fraude/alertas-resenas/:id/detalle-grafo
  @Get('alertas-resenas/:id/detalle-grafo')
  async detalleGrafo(@Param('id') id: string) {
    try {
      const detalle =
        await this.fraudeAnillosPersistidosService.obtenerDetalleGrafo(id);
      return exito(detalle, 'Detalle del anillo obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el detalle del anillo');
    }
  }
}
