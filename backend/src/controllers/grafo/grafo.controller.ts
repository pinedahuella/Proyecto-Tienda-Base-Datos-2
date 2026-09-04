import { Controller, Get, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { GrafoSyncService } from '../../services/grafo/grafo-sync.service';

/**
 * `GET /admin/grafo/conciliacion` -- la red de seguridad de la
 * sincronizacion del grafo de Neo4j (Entrega 2 / 3).
 *
 * Compara los conteos de PostgreSQL (la verdad) contra los de Neo4j (la
 * proyeccion) y devuelve el informe: que cuadra, que falta, y que hacer si
 * hay deriva (`etl/cargar_grafo.sh --limpiar`). NO repara nada.
 *
 * `@UseGuards(SesionGuard)` y `@Roles(ID_ROL_ADMIN)` van en la clase, igual
 * que en `FraudeController` y `AdminReportesController`: SOLO ADMIN. No la
 * tienda -- es informacion de operacion de todo el sistema.
 *
 * Detalle del payload: `elementos Generales/endpoints-fraude.md`.
 */
@Controller('admin/grafo')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class GrafoController {
  constructor(private readonly grafoSyncService: GrafoSyncService) {}

  // GET /admin/grafo/conciliacion
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
