import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { ConsultarTendenciasQuery } from '../../dto/consultar-tendencias';
import { AdminTendenciasService } from '../../services/admin/admin-tendencias.service';
import { AdminBusquedasSinResultadosService } from '../../services/admin/admin-busquedas-sin-resultados.service';

/**
 * `GET /admin/eventos/*` -- el ranking de tendencias de las seis tablas de
 * ClickHouse (`elementos Generales/plan pendiente/eventos-clickhouse.md`),
 * agregado por producto o por termino de busqueda, en una ventana de dias
 * hacia atras. Reemplaza la version anterior de filas crudas (que no
 * agregaba nada, solo listaba eventos ordenados por fecha) -- ver
 * `AdminTendenciasService` para el porque de la metrica de cada tabla.
 *
 * Tres rutas mas (`categorias-mas-buscadas`, `precios-mas-buscados`,
 * `calificaciones-mas-buscadas`, agregado 2026-09-26): el ranking de las
 * facetas elegidas en `GET /buscador/productos/facetado`
 * (`elementos Generales/plan pendiente/buscador-facetado-clickhouse.md`),
 * no de `busqueda_realizada` agrupada por termino. `disponible` queda
 * fuera -- es un si/no, no tiene un "top N" que rankear.
 *
 * Mismos tres query params en las nueve rutas:
 *
 *   dias        cuantos dias hacia atras mirar (defecto 7, tope 365)
 *   limite      cuantos resultados del ranking traer -- "M" (defecto 20, tope 200)
 *   direccion   "positivo" (defecto, los primeros M / mas alto) | "negativo"
 *               (los ultimos M / mas bajo)
 *
 * **Solo admin** (`PermisoGuard` + `@Permiso('tendencias.ver')`, en la clase) --
 * no la tienda, mismo criterio que el resto de paneles de admin.
 *
 * Detalle del payload: `elementos Generales/endpoints/endpoints-eventos.md`.
 */
@Controller('admin/eventos')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('tendencias.ver')
export class AdminTendenciasController {
  constructor(
    private readonly adminTendenciasService: AdminTendenciasService,
    private readonly adminBusquedasSinResultadosService: AdminBusquedasSinResultadosService,
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

  // GET /admin/eventos/busquedas-sin-resultados -- lo mas buscado que no
  // encontro nada, con las formas de escribirlo agrupadas. Usa `dias` y
  // `limite`; `direccion` no aplica.
  @Get('busquedas-sin-resultados')
  async busquedasSinResultados(@Query() query: ConsultarTendenciasQuery) {
    try {
      const busquedas =
        await this.adminBusquedasSinResultadosService.obtener(query);
      return exito(busquedas, 'Busquedas sin resultados obtenidas');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener las busquedas sin resultados',
      );
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

  // GET /admin/eventos/categorias-mas-buscadas
  @Get('categorias-mas-buscadas')
  async categoriasMasBuscadas(@Query() query: ConsultarTendenciasQuery) {
    try {
      const ranking =
        await this.adminTendenciasService.rankingCategoriasBuscadas(query);
      return exito(ranking, 'Tendencia de categorias mas buscadas obtenida');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudo obtener la tendencia de categorias mas buscadas',
      );
    }
  }

  // GET /admin/eventos/precios-mas-buscados
  @Get('precios-mas-buscados')
  async preciosMasBuscados(@Query() query: ConsultarTendenciasQuery) {
    try {
      const ranking =
        await this.adminTendenciasService.rankingPreciosBuscados(query);
      return exito(ranking, 'Tendencia de precios mas buscados obtenida');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudo obtener la tendencia de precios mas buscados',
      );
    }
  }

  // GET /admin/eventos/calificaciones-mas-buscadas
  @Get('calificaciones-mas-buscadas')
  async calificacionesMasBuscadas(@Query() query: ConsultarTendenciasQuery) {
    try {
      const ranking =
        await this.adminTendenciasService.rankingCalificacionesBuscadas(query);
      return exito(
        ranking,
        'Tendencia de calificaciones mas buscadas obtenida',
      );
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudo obtener la tendencia de calificaciones mas buscadas',
      );
    }
  }
}
