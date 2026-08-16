import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';
import { BaseDatosService } from '../services/base-datos.service';

/**
 * Controlador de la ruta GET /db
 *
 * Sirve para saber si el backend esta conectado a PostgreSQL.
 */
@Controller('db')
export class BaseDatosController {
  constructor(private readonly baseDatosService: BaseDatosService) {}

  // GET /db
  @Get()
  async verificarConexion() {
    const respuesta = await this.baseDatosService.verificarConexion();

    // Si la base no responde, el codigo HTTP tambien lo dice (503). El cuerpo
    // no cambia de forma: sigue teniendo ok, mensaje y payload.
    //
    // Se usan los dos porque el codigo lo leen las herramientas (Docker,
    // monitoreo, logs) y el campo ok lo lee el frontend.
    if (!respuesta.ok) {
      throw new HttpException(respuesta, HttpStatus.SERVICE_UNAVAILABLE);
    }

    return respuesta;
  }
}
