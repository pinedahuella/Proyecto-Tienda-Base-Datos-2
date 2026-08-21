import {
  Body,
  Controller,
  Get,
  HttpException,
  HttpStatus,
  Post,
  Query,
} from '@nestjs/common';
import { fallo, exito } from '../helpers/respuesta';
import {
  ErrorConexion,
  ErrorConflicto,
  ErrorValidacion,
} from '../helpers/errores';
import type { RegistroUsuarioPeticion } from '../models/registro-usuario';
import { UsuarioService } from '../services/usuario.service';

/**
 * Controlador de las rutas /usuario.
 *
 * El controlador no valida ni consulta nada: eso vive en UsuarioService.
 * Aqui solo se traduce lo que el servicio lanza a un codigo HTTP.
 */
@Controller('usuario')
export class UsuarioController {
  constructor(private readonly usuarioService: UsuarioService) {}

  // POST /usuario/registro
  @Post('registro')
  async registrar(@Body() cuerpo: RegistroUsuarioPeticion) {
    try {
      const usuario = await this.usuarioService.registrar(cuerpo);
      return exito(usuario, 'Usuario registrado correctamente');
    } catch (error) {
      this.manejarError(error, 'No se pudo registrar el usuario');
    }
  }

  // GET /usuario/registros-existentes
  @Get('registros-existentes')
  async verificarExistencia(
    @Query('correo') correo?: string,
    @Query('usuario') usuario?: string,
  ) {
    try {
      const resultado = await this.usuarioService.verificarExistencia(
        correo,
        usuario,
      );
      return exito(resultado, 'Disponibilidad consultada');
    } catch (error) {
      this.manejarError(error, 'No se pudo verificar el usuario');
    }
  }

  /**
   * Traduce lo que lanza UsuarioService a un codigo HTTP. Las dos rutas de
   * arriba comparten los mismos tipos de error, asi que comparten este
   * mapeo; solo cambia el mensaje generico de 500 de cada una.
   */
  private manejarError(error: unknown, mensajePorDefecto: string): never {
    if (error instanceof ErrorValidacion) {
      throw new HttpException(fallo(error.message), HttpStatus.BAD_REQUEST);
    }
    if (error instanceof ErrorConflicto) {
      throw new HttpException(fallo(error.message), HttpStatus.CONFLICT);
    }
    if (error instanceof ErrorConexion) {
      throw new HttpException(
        fallo(error.message),
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }

    throw new HttpException(
      fallo(mensajePorDefecto),
      HttpStatus.INTERNAL_SERVER_ERROR,
    );
  }
}
