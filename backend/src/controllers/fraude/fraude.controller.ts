import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { PaginarAlertasFraudeQuery } from '../../dto/paginar-alertas-fraude';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { FraudeLoginService } from '../../services/fraude-login/fraude-login.service';
import { FraudeService } from '../../services/fraude/fraude.service';

/**
 * `GET /admin/fraude/anillos` -- el panel de manipulacion de resenas de la
 * Entrega 2. Recorre el grafo de Neo4j (una proyeccion de `resena` que carga
 * `etl/cargar_grafo.sh`, y que el backend solo consulta) y devuelve los
 * grupos de cuentas con un patron de calificaciones anomalo.
 *
 * `GET /admin/fraude/alertas-login` -- las alertas de fuerza bruta /
 * multi-cuenta que detecta `FraudeLoginService` con contadores de Redis en
 * el propio login (ver ese servicio). Distinto mecanismo, distinta fuente
 * (Postgres, no Neo4j), mismo panel de admin.
 *
 * `@UseGuards(SesionGuard)` y `@Roles(ID_ROL_ADMIN)` van en la clase: SOLO
 * ADMIN. No la tienda -- la tienda es un vendedor mas, y ensenarle quien la
 * esta calificando (o intentando entrar) de forma sospechosa le entrega
 * justo la lista que no deberia ver.
 *
 * Pantalla que lo consume: `frontend/src/lib/PanelFraude.svelte`.
 * Detalle del payload: `elementos Generales/endpoints-fraude.md`.
 */
@Controller('admin/fraude')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class FraudeController {
  constructor(
    private readonly fraudeService: FraudeService,
    private readonly fraudeLoginService: FraudeLoginService,
  ) {}

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

  // GET /admin/fraude/alertas-login
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
