import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { ConsultarTendenciaAscensoQuery } from '../../dto/consultar-tendencia-ascenso';
import type { ConsultarTendenciaVentanaQuery } from '../../dto/consultar-tendencia-ventana';
import { AdminTendenciasAvanzadasService } from '../../services/admin/admin-tendencias-avanzadas.service';

/**
 * Las tres consultas de "Tendencias" que propuso el companero en
 * `docs/fraude-entrega3/03-consultas-clickhouse.md` (T1, T2, T3) --
 * distintas de `AdminTendenciasController` (el ranking generico de una
 * sola tabla): estas cruzan varias tablas o comparan dos ventanas de
 * tiempo entre si, cosa que el generico no puede hacer.
 *
 * Mismo prefijo de ruta que `AdminTendenciasController` (`/admin/eventos`)
 * porque es el mismo dominio, pero clase separada (pedido explicito del
 * usuario). Mismo criterio de autorizacion: solo admin.
 *
 * Detalle de cada consulta y las pruebas en vivo:
 * `elementos Generales/endpoints/endpoints-eventos.md`.
 */
@Controller('admin/eventos')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('tendencias.ver')
export class AdminTendenciasAvanzadasController {
  constructor(
    private readonly adminTendenciasAvanzadasService: AdminTendenciasAvanzadasService,
  ) {}

  // GET /admin/eventos/tendencias
  @Get('tendencias')
  async tendencias(@Query() query: ConsultarTendenciaAscensoQuery) {
    try {
      const productos =
        await this.adminTendenciasAvanzadasService.enAscenso(query);
      return exito(productos, 'Productos en ascenso obtenidos');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener los productos en ascenso',
      );
    }
  }

  // GET /admin/eventos/embudo
  @Get('embudo')
  async embudo(@Query() query: ConsultarTendenciaVentanaQuery) {
    try {
      const productos =
        await this.adminTendenciasAvanzadasService.embudo(query);
      return exito(productos, 'Embudo de productos obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el embudo de productos');
    }
  }

  // GET /admin/eventos/busquedas-sin-respuesta
  @Get('busquedas-sin-respuesta')
  async busquedasSinRespuesta(@Query() query: ConsultarTendenciaVentanaQuery) {
    try {
      const terminos =
        await this.adminTendenciasAvanzadasService.busquedasSinRespuesta(query);
      return exito(terminos, 'Busquedas sin respuesta obtenidas');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener las busquedas sin respuesta',
      );
    }
  }
}
