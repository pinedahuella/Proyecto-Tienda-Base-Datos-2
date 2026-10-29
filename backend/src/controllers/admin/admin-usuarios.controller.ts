import { Body, Controller, Get, Param, Patch, UseGuards } from '@nestjs/common';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import type { EditarUsuarioAdminPeticion } from '../../dto/editar-usuario-admin';
import type { TokenUsuario } from '../../dto/token-usuario';
import { AdminUsuariosService } from '../../services/admin/admin-usuarios.service';

/**
 * Controlador de las rutas /admin/usuarios.
 *
 * @UseGuards(SesionGuard, PermisoGuard) y @Permiso('usuarios.ver') van en la clase, no en
 * cada metodo: asi cualquier ruta que se agregue despues a este
 * controlador queda protegida por defecto, sin tener que acordarse de
 * ponerlo en cada una.
 */
@Controller('admin/usuarios')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('usuarios.ver')
export class AdminUsuariosController {
  constructor(private readonly adminUsuariosService: AdminUsuariosService) {}

  // GET /admin/usuarios
  @Get()
  async listar(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const usuarios = await this.adminUsuariosService.listar(
        usuarioActual.id_usuario,
      );
      return exito(usuarios, 'Usuarios obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener la lista de usuarios');
    }
  }

  // PATCH /admin/usuarios/:id
  // PATCH y no PUT: se cambia solo lo que venga, no se reemplaza el
  // usuario completo.
  @Permiso('usuarios.editar')
  @Patch(':id')
  async actualizar(
    @Param('id') id: string,
    @Body() cuerpo: EditarUsuarioAdminPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const usuario = await this.adminUsuariosService.actualizar(
        id,
        cuerpo,
        usuarioActual.id_usuario,
      );
      return exito(usuario, 'Usuario actualizado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar el usuario');
    }
  }
}
