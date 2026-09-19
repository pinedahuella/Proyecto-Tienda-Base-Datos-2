import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { ConsultarTendenciasQuery } from '../../dto/consultar-tendencias';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { AdminTendenciasService } from '../../services/admin/admin-tendencias.service';

/**
 * `GET /admin/eventos/*` -- el ranking de tendencias de las seis tablas de
 * ClickHouse (`elementos Generales/plan pendiente/eventos-clickhouse.md`),
 * agregado por producto o por termino de busqueda, en una ventana de dias
 * hacia atras. Reemplaza la version anterior de filas crudas (que no
 * agregaba nada, solo listaba eventos ordenados por fecha) -- ver
 * `AdminTendenciasService` para el porque de la metrica de cada tabla.
 *
 * Mismos tres query params en las seis rutas:
 *
 *   dias        cuantos dias hacia atras mirar (defecto 7, tope 365)
 *   limite      cuantos resultados del ranking traer -- "M" (defecto 20, tope 200)
 *   direccion   "positivo" (defecto, los primeros M / mas alto) | "negativo"
 *               (los ultimos M / mas bajo)
 *
 * **Solo admin** (`SesionGuard` + `@Roles(ID_ROL_ADMIN)`, en la clase) --
 * no la tienda, mismo criterio que el resto de paneles de admin.
 *
 * Detalle del payload: `elementos Generales/endpoints/endpoints-eventos.md`.
 */
@Controller('admin/eventos')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class AdminTendenciasController {
  constructor(
    private readonly adminTendenciasService: AdminTendenciasService,
  ) {}

  // GET /admin/eventos/vista
  @Get('vista')
  async vista(@Query() query: ConsultarTendenciasQuery) {
    try {
      const ranking = await this.adminTendenciasService.rankingVistas(query);
      return exito(ranking, 'Tendencia de vistas obtenida');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener la tendencia de vistas');
    }
  }

  // GET /admin/eventos/carrito
  @Get('carrito')
  async carrito(@Query() query: ConsultarTendenciasQuery) {
    try {
      const ranking = await this.adminTendenciasService.rankingCarrito(query);
      return exito(ranking, 'Tendencia de carrito obtenida');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener la tendencia de carrito');
    }
  }

  // GET /admin/eventos/compra
  @Get('compra')
  async compra(@Query() query: ConsultarTendenciasQuery) {
    try {
      const ranking = await this.adminTendenciasService.rankingCompras(query);
      return exito(ranking, 'Tendencia de compras obtenida');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener la tendencia de compras');
    }
  }

  // GET /admin/eventos/devolucion
  @Get('devolucion')
  async devolucion(@Query() query: ConsultarTendenciasQuery) {
    try {
      const ranking =
        await this.adminTendenciasService.rankingDevoluciones(query);
      return exito(ranking, 'Tendencia de devoluciones obtenida');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudo obtener la tendencia de devoluciones',
      );
    }
  }

  // GET /admin/eventos/busqueda
  @Get('busqueda')
  async busqueda(@Query() query: ConsultarTendenciasQuery) {
    try {
      const ranking = await this.adminTendenciasService.rankingBusquedas(query);
      return exito(ranking, 'Tendencia de busquedas obtenida');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener la tendencia de busquedas');
    }
  }

  // GET /admin/eventos/busqueda-clic
  @Get('busqueda-clic')
  async busquedaClic(@Query() query: ConsultarTendenciasQuery) {
    try {
      const ranking =
        await this.adminTendenciasService.rankingClicsBusqueda(query);
      return exito(ranking, 'Tendencia de clics de busqueda obtenida');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudo obtener la tendencia de clics de busqueda',
      );
    }
  }
}
