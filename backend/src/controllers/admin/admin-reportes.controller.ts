import { Controller, Get, UseGuards } from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { AdminReportesService } from '../../services/admin/admin-reportes.service';

/**
 * Los dos reportes del panel de admin (Entrega 2):
 *
 *   GET /admin/reportes/reservaciones   los pedidos abiertos y sin pagar
 *   GET /admin/reportes/ventas          el resumen de lo vendido y cobrado
 *
 * `@UseGuards(SesionGuard, PermisoGuard)` y `@Permiso('reportes.ver')` van en la clase, igual
 * que en `AdminUsuariosController` y `AdminCatalogosController`: cualquier
 * ruta que se agregue despues queda protegida por defecto. Solo admin --
 * son datos de todo el sistema, no de una cuenta.
 *
 * Detalle del payload: `elementos Generales/endpoints-reportes.md`.
 */
@Controller('admin/reportes')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('reportes.ver')
export class AdminReportesController {
  constructor(private readonly adminReportesService: AdminReportesService) {}

  // GET /admin/reportes/reservaciones
  @Get('reservaciones')
  async reservaciones() {
    try {
      const reporte = await this.adminReportesService.reservaciones();
      return exito(reporte, 'Reporte de reservaciones generado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo generar el reporte de reservaciones');
    }
  }

  // GET /admin/reportes/ventas
  @Get('ventas')
  async ventas() {
    try {
      const reporte = await this.adminReportesService.ventas();
      return exito(reporte, 'Reporte de ventas generado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo generar el reporte de ventas');
    }
  }
}
