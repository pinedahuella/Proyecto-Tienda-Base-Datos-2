import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Post,
  Query,
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
 * Protegido en la clase: cualquier usuario logueado puede ver, crear y
 * editar sus propias direcciones, no hace falta ser admin.
 */
@Controller('direccion-usuario')
@UseGuards(SesionGuard)
export class DireccionUsuarioController {
  constructor(
    private readonly direccionUsuarioService: DireccionUsuarioService,
  ) {}

  // GET /direccion-usuario
  @Get()
  async listar(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const direcciones = await this.direccionUsuarioService.listar(
        usuarioActual.id_usuario,
      );
      return exito(direcciones, 'Direcciones obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener las direcciones');
    }
  }

  // GET /direccion-usuario/historial
  @Get('historial')
  async obtenerHistorial(
    @Query('fecha') fecha: string | undefined,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const direcciones = await this.direccionUsuarioService.obtenerHistorial(
        usuarioActual.id_usuario,
        fecha,
      );
      return exito(direcciones, 'Historial de direcciones obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el historial de direcciones');
    }
  }

  // GET /direccion-usuario/:id
  @Get(':id')
  async obtener(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.direccionUsuarioService.obtenerConHistorial(
        id,
        usuarioActual.id_usuario,
      );
      return exito(resultado, 'Direccion obtenida');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener la direccion');
    }
  }

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
