import { Controller, Get, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { AdminReportesService } from '../../services/admin/admin-reportes.service';

/**
 * Los dos reportes del panel de admin (Entrega 2):
 *
 *   GET /admin/reportes/reservaciones   los pedidos abiertos y sin pagar
 *   GET /admin/reportes/ventas          el resumen de lo vendido y cobrado
 *
 * `@UseGuards(SesionGuard)` y `@Roles(ID_ROL_ADMIN)` van en la clase, igual
 * que en `AdminUsuariosController` y `AdminCatalogosController`: cualquier
 * ruta que se agregue despues queda protegida por defecto. Solo admin --
 * son datos de todo el sistema, no de una cuenta.
 *
 * Detalle del payload: `elementos Generales/endpoints-reportes.md`.
 */
@Controller('admin/reportes')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
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
