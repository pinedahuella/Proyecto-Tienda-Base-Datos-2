import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';
import { BaseDatosVectoresService } from '../services/base-datos-vectores.service';

/**
 * Controlador de la ruta GET /vectores
 *
 * Sirve para saber si el backend esta conectado a Ollama (recomendacion
 * semantica, Entrega final). Mismo patron que GET /buscador, /grafo,
 * /clave-valor, /documental: si el servicio no responde, el codigo HTTP es
 * 503 y el cuerpo mantiene la forma { ok, mensaje, payload }.
 */
@Controller('vectores')
export class BaseDatosVectoresController {
  constructor(
    private readonly baseDatosVectoresService: BaseDatosVectoresService,
  ) {}

  // GET /vectores
  @Get()
  async verificarConexion() {
    const respuesta = await this.baseDatosVectoresService.verificarConexion();

    if (!respuesta.ok) {
      throw new HttpException(respuesta, HttpStatus.SERVICE_UNAVAILABLE);
    }

    return respuesta;
  }
}
