import { Controller, Get } from '@nestjs/common';
import { InicioService } from '../services/inicio.service';

/**
 * Controlador de la ruta raiz: GET /
 *
 * El controlador solo recibe la peticion y devuelve lo que le da el servicio.
 * No tiene logica propia; esa vive en InicioService.
 */
@Controller()
export class InicioController {
  constructor(private readonly inicioService: InicioService) {}

  // GET /
  @Get()
  obtenerEstado() {
    return this.inicioService.obtenerEstado();
  }
}
