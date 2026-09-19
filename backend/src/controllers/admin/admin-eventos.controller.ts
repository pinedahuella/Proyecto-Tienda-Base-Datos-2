import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { ConsultarEventosQuery } from '../../dto/consultar-eventos';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { AdminEventosService } from '../../services/admin/admin-eventos.service';

/**
 * `GET /admin/eventos/*` -- explorador de las seis tablas de ClickHouse
 * (`elementos Generales/plan pendiente/eventos-clickhouse.md`), filas
 * CRUDAS en una ventana de dias hacia atras. Nunca agrupa ni calcula
 * tendencias -- para eso haria falta un panel aparte, no construido
 * todavia (ver ese documento).
 *
 * Mismos tres query params en las seis rutas:
 *
 *   dias     cuantos dias hacia atras mirar (defecto 7, tope 365)
 *   limite   cuantas filas como maximo (defecto 20, tope 200)
 *   orden    "recientes" (defecto, mas nuevas primero) | "antiguos"
 *
 * **Solo admin** (`SesionGuard` + `@Roles(ID_ROL_ADMIN)`, en la clase) --
 * no la tienda, mismo criterio que el resto de paneles de admin.
 *
 * Detalle del payload: `elementos Generales/endpoints/endpoints-eventos.md`.
 */
@Controller('admin/eventos')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class AdminEventosController {
  constructor(private readonly adminEventosService: AdminEventosService) {}

  // GET /admin/eventos/vista
  @Get('vista')
  async vista(@Query() query: ConsultarEventosQuery) {
    try {
      const filas = await this.adminEventosService.listarVistas(query);
      return exito(filas, 'Vistas de producto obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las vistas de producto');
    }
  }

  // GET /admin/eventos/carrito
  @Get('carrito')
  async carrito(@Query() query: ConsultarEventosQuery) {
    try {
      const filas = await this.adminEventosService.listarCarrito(query);
      return exito(filas, 'Eventos de carrito obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los eventos de carrito');
    }
  }

  // GET /admin/eventos/compra
  @Get('compra')
  async compra(@Query() query: ConsultarEventosQuery) {
    try {
      const filas = await this.adminEventosService.listarCompras(query);
      return exito(filas, 'Compras obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las compras');
    }
  }

  // GET /admin/eventos/devolucion
  @Get('devolucion')
  async devolucion(@Query() query: ConsultarEventosQuery) {
    try {
      const filas = await this.adminEventosService.listarDevoluciones(query);
      return exito(filas, 'Devoluciones obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las devoluciones');
    }
  }

  // GET /admin/eventos/busqueda
  @Get('busqueda')
  async busqueda(@Query() query: ConsultarEventosQuery) {
    try {
      const filas = await this.adminEventosService.listarBusquedas(query);
      return exito(filas, 'Busquedas obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las busquedas');
    }
  }

  // GET /admin/eventos/busqueda-clic
  @Get('busqueda-clic')
  async busquedaClic(@Query() query: ConsultarEventosQuery) {
    try {
      const filas = await this.adminEventosService.listarClicsBusqueda(query);
      return exito(filas, 'Clics de busqueda obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los clics de busqueda');
    }
  }
}
