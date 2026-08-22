import { Controller, Get, UseGuards } from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { AdminCatalogosService } from '../../services/admin/admin-catalogos.service';

/**
 * Controlador de las rutas /admin/roles y /admin/estados.
 *
 * Igual que AdminUsuariosController: protegido en la clase, no en cada
 * metodo.
 */
@Controller('admin')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class AdminCatalogosController {
  constructor(private readonly adminCatalogosService: AdminCatalogosService) {}

  // GET /admin/roles
  @Get('roles')
  async listarRoles() {
    try {
      const roles = await this.adminCatalogosService.listarRoles();
      return exito(roles, 'Roles obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener los roles');
    }
  }

  // GET /admin/estados
  @Get('estados')
  async listarEstados() {
    try {
      const estados = await this.adminCatalogosService.listarEstados();
      return exito(estados, 'Estados obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener los estados');
    }
  }
}
