import { Controller, Get, UseGuards } from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { GrafoSyncService } from '../../services/grafo/grafo-sync.service';

/**
 * `GET /admin/grafo/conciliacion` -- la red de seguridad de la
 * sincronizacion del grafo de Neo4j (Entrega 2 / 3).
 *
 * Compara los conteos de PostgreSQL (la verdad) contra los de Neo4j (la
 * proyeccion) y devuelve el informe: que cuadra, que falta, y que hacer si
 * hay deriva (`etl/cargar_grafo.sh --limpiar`). NO repara nada.
 *
 * `@UseGuards(SesionGuard, PermisoGuard)` y `@Permiso('sistema.ver')`, igual
 * que en `FraudeController` y `AdminReportesController`: SOLO ADMIN. No la
 * tienda -- es informacion de operacion de todo el sistema.
 *
 * Detalle del payload: `elementos Generales/endpoints-fraude.md`.
 */
@Controller('admin/grafo')
@UseGuards(SesionGuard, PermisoGuard)
export class GrafoController {
  constructor(private readonly grafoSyncService: GrafoSyncService) {}

  // GET /admin/grafo/conciliacion
  @Permiso('sistema.ver')
  @Get('conciliacion')
  async conciliacion() {
    try {
      const informe = await this.grafoSyncService.conciliar();
      return exito(
        informe,
        informe.cuadra
          ? 'El grafo esta al dia con PostgreSQL'
          : 'El grafo tiene deriva respecto a PostgreSQL',
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo conciliar el grafo');
    }
  }
}
