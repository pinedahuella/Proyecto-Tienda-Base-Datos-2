import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';
import { BaseDatosBuscadorService } from '../services/base-datos-buscador.service';

/**
 * Controlador de la ruta GET /buscador
 *
 * Sirve para saber si el backend esta conectado a Elasticsearch. Mismo
 * patron que GET /db (PostgreSQL), GET /documental (MongoDB), GET
 * /clave-valor (Redis) y GET /grafo (Neo4j): si la base no responde, el
 * codigo HTTP es 503 y el cuerpo mantiene la forma { ok, mensaje, payload }.
 */
@Controller('buscador')
export class BaseDatosBuscadorController {
  constructor(
    private readonly baseDatosBuscadorService: BaseDatosBuscadorService,
  ) {}

  // GET /buscador
  @Get()
  async verificarConexion() {
    const respuesta = await this.baseDatosBuscadorService.verificarConexion();

    if (!respuesta.ok) {
      throw new HttpException(respuesta, HttpStatus.SERVICE_UNAVAILABLE);
    }

    return respuesta;
  }
}
