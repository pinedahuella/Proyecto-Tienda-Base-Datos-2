import { Controller, Get, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { FraudeService } from '../../services/fraude/fraude.service';

/**
 * `GET /admin/fraude/anillos` -- el panel de manipulacion de resenas de la
 * Entrega 2. Recorre el grafo de Neo4j (una proyeccion de `resena` que carga
 * `etl/cargar_grafo.sh`, y que el backend solo consulta) y devuelve los
 * grupos de cuentas con un patron de calificaciones anomalo.
 *
 * `@UseGuards(SesionGuard)` y `@Roles(ID_ROL_ADMIN)` van en la clase: SOLO
 * ADMIN. No la tienda -- la tienda es un vendedor mas, y ensenarle quien la
 * esta calificando de forma sospechosa le entrega justo la lista que no
 * deberia ver.
 *
 * Pantalla que lo consume: `frontend/src/lib/PanelFraude.svelte`.
 * Detalle del payload: `elementos Generales/endpoints-fraude.md`.
 */
@Controller('admin/fraude')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class FraudeController {
  constructor(private readonly fraudeService: FraudeService) {}

  // GET /admin/fraude/anillos
  @Get('anillos')
  async anillos() {
    try {
      const analisis = await this.fraudeService.analizar();
      return exito(analisis, 'Analisis completado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo completar el analisis de fraude');
    }
  }
}
