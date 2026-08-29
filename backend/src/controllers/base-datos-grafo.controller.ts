import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';
import { BaseDatosGrafoService } from '../services/base-datos-grafo.service';

/**
 * Controlador de la ruta GET /grafo
 *
 * Sirve para saber si el backend esta conectado a Neo4j. Mismo patron que
 * GET /db (PostgreSQL) y GET /documental (MongoDB): si la base no responde,
 * el codigo HTTP es 503 y el cuerpo mantiene la forma { ok, mensaje,
 * payload }.
 */
@Controller('grafo')
export class BaseDatosGrafoController {
  constructor(private readonly baseDatosGrafoService: BaseDatosGrafoService) {}

  // GET /grafo
  @Get()
  async verificarConexion() {
    const respuesta = await this.baseDatosGrafoService.verificarConexion();

    if (!respuesta.ok) {
      throw new HttpException(respuesta, HttpStatus.SERVICE_UNAVAILABLE);
    }

    return respuesta;
  }
}
