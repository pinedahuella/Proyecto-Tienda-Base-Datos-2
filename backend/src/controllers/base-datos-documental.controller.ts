import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';
import { BaseDatosDocumentalService } from '../services/base-datos-documental.service';

/**
 * Controlador de la ruta GET /documental
 *
 * Sirve para saber si el backend esta conectado a MongoDB.
 */
@Controller('documental')
export class BaseDatosDocumentalController {
  constructor(
    private readonly baseDatosDocumentalService: BaseDatosDocumentalService,
  ) {}

  // GET /documental
  @Get()
  async verificarConexion() {
    const respuesta = await this.baseDatosDocumentalService.verificarConexion();

    if (!respuesta.ok) {
      throw new HttpException(respuesta, HttpStatus.SERVICE_UNAVAILABLE);
    }

    return respuesta;
  }
}
