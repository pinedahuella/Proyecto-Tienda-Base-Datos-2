import { Body, Controller, Get, Patch, UseGuards } from '@nestjs/common';
import { UsuarioActual } from '../decorators/usuario-actual.decorator';
import { SesionGuard } from '../guards/sesion.guard';
import { manejarErrorHttp } from '../helpers/manejar-error-http';
import { exito } from '../helpers/respuesta';
import type { CambiarContrasenaPeticion } from '../dto/cambiar-contrasena';
import type { EditarPerfilPeticion } from '../dto/editar-perfil';
import type { TokenUsuario } from '../dto/token-usuario';
import { PerfilService } from '../services/perfil.service';

/**
 * Controlador de las rutas /perfil.
 *
 * Protegido en la clase: cualquier ruta que se agregue aqui despues queda
 * protegida por defecto.
 */
@Controller('perfil')
@UseGuards(SesionGuard)
export class PerfilController {
  constructor(private readonly perfilService: PerfilService) {}

  // GET /perfil
  @Get()
  async obtener(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const perfil = await this.perfilService.obtener(usuarioActual.id_usuario);
      return exito(perfil, 'Perfil obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el perfil');
    }
  }

  // PATCH /perfil
  @Patch()
  async actualizar(
    @Body() cuerpo: EditarPerfilPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const perfil = await this.perfilService.actualizar(
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(perfil, 'Perfil actualizado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar el perfil');
    }
  }

  // PATCH /perfil/contrasena
  @Patch('contrasena')
  async cambiarContrasena(
    @Body() cuerpo: CambiarContrasenaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      await this.perfilService.cambiarContrasena(
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(null, 'Contrasena actualizada correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar la contrasena');
    }
  }
}
