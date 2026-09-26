import { Controller, Get, Param } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { ErrorValidacion } from '../../helpers/errores';
import { SimilaresService } from '../../services/productos/similares.service';

const REGEX_ID = /^\d+$/;

/**
 * `GET /productos/:id/similares` -- PUBLICA, sin sesion: recomendacion
 * semantica de la Entrega final ("parecidos a este"), pensada para la ficha
 * de producto. Controlador SEPARADO (mismo criterio que
 * `TambienVieronController`) -- solo lee, nunca calcula el vector aqui.
 */
@Controller('productos')
export class SimilaresController {
  constructor(private readonly similaresService: SimilaresService) {}

  // GET /productos/:id/similares
  @Get(':id/similares')
  async similares(@Param('id') id: string) {
    try {
      if (!REGEX_ID.test(id)) {
        throw new ErrorValidacion('El id no es valido');
      }
      const productos = await this.similaresService.obtener(Number(id));
      return exito(productos, 'Similares obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener los similares');
    }
  }
}
