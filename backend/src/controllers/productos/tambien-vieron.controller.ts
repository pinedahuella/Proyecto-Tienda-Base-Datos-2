import { Controller, Get, Param } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { ErrorValidacion } from '../../helpers/errores';
import { TambienVieronService } from '../../services/productos/tambien-vieron.service';

const REGEX_ID = /^\d+$/;

/**
 * `GET /productos/:id/tambien-vieron` -- PUBLICA, sin sesion: R2
 * ("quienes vieron esto tambien vieron"), pensada para la ficha de
 * producto. Controlador SEPARADO (mismo criterio que
 * `MasVendidosController`/`VistosRecientementeController`) -- lee
 * directo de Redis, nunca calcula nada en vivo (ver `TambienVieronService`).
 */
@Controller('productos')
export class TambienVieronController {
  constructor(private readonly tambienVieronService: TambienVieronService) {}

  // GET /productos/:id/tambien-vieron
  @Get(':id/tambien-vieron')
  async tambienVieron(@Param('id') id: string) {
    try {
      if (!REGEX_ID.test(id)) {
        throw new ErrorValidacion('El id no es valido');
      }
      const productos = await this.tambienVieronService.obtener(Number(id));
      return exito(productos, 'Tambien vieron obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener tambien vieron');
    }
  }
}
