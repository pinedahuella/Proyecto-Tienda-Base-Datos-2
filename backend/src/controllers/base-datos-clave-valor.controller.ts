import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';
import { BaseDatosClaveValorService } from '../services/base-datos-clave-valor.service';

/**
 * Controlador de la ruta GET /clave-valor
 *
 * Sirve para saber si el backend esta conectado a Redis. Mismo patron que
 * GET /db (PostgreSQL) y GET /documental (MongoDB): si la base no responde,
 * el codigo HTTP es 503 y el cuerpo mantiene la forma { ok, mensaje,
 * payload }.
 */
@Controller('clave-valor')
export class BaseDatosClaveValorController {
  constructor(
    private readonly baseDatosClaveValorService: BaseDatosClaveValorService,
  ) {}

  // GET /clave-valor
  @Get()
  async verificarConexion() {
    const respuesta = await this.baseDatosClaveValorService.verificarConexion();

    if (!respuesta.ok) {
      throw new HttpException(respuesta, HttpStatus.SERVICE_UNAVAILABLE);
    }

    return respuesta;
  }
}
