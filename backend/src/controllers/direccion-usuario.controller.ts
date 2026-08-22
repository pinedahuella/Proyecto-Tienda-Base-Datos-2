import {
  Body,
  Controller,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { UsuarioActual } from '../decorators/usuario-actual.decorator';
import { SesionGuard } from '../guards/sesion.guard';
import { manejarErrorHttp } from '../helpers/manejar-error-http';
import { exito } from '../helpers/respuesta';
import type { CrearDireccionPeticion } from '../dto/crear-direccion';
import type { EditarDireccionPeticion } from '../dto/editar-direccion';
import type { TokenUsuario } from '../dto/token-usuario';
import { DireccionUsuarioService } from '../services/direccion-usuario.service';

/**
 * Controlador de las rutas /direccion-usuario.
 *
 * Protegido en la clase: cualquier usuario logueado puede crear y editar
 * sus propias direcciones, no hace falta ser admin.
 */
@Controller('direccion-usuario')
@UseGuards(SesionGuard)
export class DireccionUsuarioController {
  constructor(
    private readonly direccionUsuarioService: DireccionUsuarioService,
  ) {}

  // POST /direccion-usuario
  @Post()
  async crear(
    @Body() cuerpo: CrearDireccionPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const direccion = await this.direccionUsuarioService.crear(
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(direccion, 'Direccion creada correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo crear la direccion');
    }
  }

  // PATCH /direccion-usuario/:id
  @Patch(':id')
  async actualizar(
    @Param('id') id: string,
    @Body() cuerpo: EditarDireccionPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const direccion = await this.direccionUsuarioService.actualizar(
        id,
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(direccion, 'Direccion actualizada correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar la direccion');
    }
  }
}
