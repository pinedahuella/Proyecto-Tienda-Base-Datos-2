import {
  Controller,
  Delete,
  Get,
  Param,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { Permiso } from '../../decorators/permiso.decorator';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import type { TokenUsuario } from '../../dto/token-usuario';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import { PermisosService } from '../../services/acl/permisos.service';

/**
 * El ACL de funcionalidades visto por el admin (migracion 050, ADR-26): que
 * rol puede que, dar y quitar, y el registro de intentos negados.
 *
 *   GET    /admin/permisos                       la matriz: roles y permisos por modulo
 *   GET    /admin/permisos/registro?limite=50    lo ultimo de auditoria_permiso
 *   POST   /admin/permisos/:idRol/:idPermiso     darle el permiso al rol
 *   DELETE /admin/permisos/:idRol/:idPermiso     quitarselo (409 si esta protegido)
 *
 * Se protege con su propio ACL: permisos.ver y permisos.administrar.
 */
@Controller('admin/permisos')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('permisos.ver')
export class AdminPermisosController {
  constructor(private readonly permisosService: PermisosService) {}

  // GET /admin/permisos
  @Get()
  async matriz() {
    try {
      return exito(await this.permisosService.matriz(), 'Permisos por rol');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo leer la matriz de permisos');
    }
  }

  // GET /admin/permisos/registro
  @Get('registro')
  async registro(@Query('limite') limite?: string) {
    try {
      return exito(
        await this.permisosService.registro(limite),
        'Registro de permisos',
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo leer el registro de permisos');
    }
  }

  // POST /admin/permisos/:idRol/:idPermiso
  @Permiso('permisos.administrar')
  @Post(':idRol/:idPermiso')
  async otorgar(
    @Param('idRol') idRol: string,
    @Param('idPermiso') idPermiso: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.permisosService.otorgar(
        usuarioActual.id_usuario,
        idRol,
        idPermiso,
      );
      return exito(
        resultado,
        resultado.cambio
          ? `El rol ${resultado.rol} ya tiene ${resultado.codigo}`
          : `El rol ${resultado.rol} ya tenia ${resultado.codigo}`,
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo dar el permiso');
    }
  }

  // DELETE /admin/permisos/:idRol/:idPermiso
  @Permiso('permisos.administrar')
  @Delete(':idRol/:idPermiso')
  async revocar(
    @Param('idRol') idRol: string,
    @Param('idPermiso') idPermiso: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.permisosService.revocar(
        usuarioActual.id_usuario,
        idRol,
        idPermiso,
      );
      return exito(
        resultado,
        `El rol ${resultado.rol} ya no tiene ${resultado.codigo}`,
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo quitar el permiso');
    }
  }
}
