import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Query,
  UseGuards,
} from '@nestjs/common';
import { UsuarioActual } from '../decorators/usuario-actual.decorator';
import { Permiso } from '../decorators/permiso.decorator';
import { PermisoGuard } from '../guards/permiso.guard';
import { SesionGuard } from '../guards/sesion.guard';
import { manejarErrorHttp } from '../helpers/manejar-error-http';
import { exito } from '../helpers/respuesta';
import type { CambiarContrasenaPeticion } from '../dto/cambiar-contrasena';
import type { EditarPerfilPeticion } from '../dto/editar-perfil';
import type { TokenUsuario } from '../dto/token-usuario';
import type { PaginarAlertasFraudeUsuarioQuery } from '../dto/alertas-fraude-usuario';
import { PerfilService } from '../services/perfil.service';
import { FraudeLoginService } from '../services/fraude-login/fraude-login.service';

/**
 * Controlador de las rutas /perfil.
 *
 * Protegido en la clase: cualquier ruta que se agregue aqui despues queda
 * protegida por defecto.
 *
 * `/perfil/alertas-fraude` (GET y PATCH) son "mis datos" igual que el resto
 * de este controller: las alertas de fraude sobre la PROPIA cuenta del
 * usuario logueado -- nunca reciben un id de cuenta por parametro, ver
 * `elementos Generales/plan pendiente/notificacion-fraude-usuario.md`. La
 * consulta/escritura vive en `FraudeLoginService` (ya es dueno de
 * `alerta_fraude` del lado de lectura), no en `PerfilService`.
 */
@Controller('perfil')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('cuenta.ver')
export class PerfilController {
  constructor(
    private readonly perfilService: PerfilService,
    private readonly fraudeLoginService: FraudeLoginService,
  ) {}

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
  @Permiso('cuenta.editar')
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
  @Permiso('cuenta.editar')
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

  // GET /perfil/alertas-fraude
  @Get('alertas-fraude')
  async alertasFraude(
    @Query() query: PaginarAlertasFraudeUsuarioQuery,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const pagina = await this.fraudeLoginService.listarAlertasPaginadoUsuario(
        usuarioActual.id_usuario,
        query,
      );
      return exito(pagina, 'Alertas de fraude obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las alertas de fraude');
    }
  }

  // PATCH /perfil/alertas-fraude/:id
  @Permiso('cuenta.editar')
  @Patch('alertas-fraude/:id')
  async marcarAlertaFraudeLeida(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const alerta = await this.fraudeLoginService.marcarLeida(
        id,
        usuarioActual.id_usuario,
      );
      return exito(alerta, 'Alerta marcada como leida');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo marcar la alerta como leida');
    }
  }
}
