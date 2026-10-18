import { Controller, Get, Param } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { ErrorValidacion } from '../../helpers/errores';
import { TambienCompraronService } from '../../services/productos/tambien-compraron.service';

const REGEX_ID = /^\d+$/;

/**
 * `GET /productos/:id/tambien-compraron` -- PUBLICA, sin sesion: "quienes
 * compraron esto tambien compraron", pensada para cuando se agrega un producto
 * al carrito. Sale del grafo de Neo4j, en vivo (ver `TambienCompraronService`).
 * Controlador separado, mismo criterio que `TambienVieronController`.
 */
@Controller('productos')
export class TambienCompraronController {
  constructor(
    private readonly tambienCompraronService: TambienCompraronService,
  ) {}

  // GET /productos/:id/tambien-compraron
  @Get(':id/tambien-compraron')
  async tambienCompraron(@Param('id') id: string) {
    try {
      if (!REGEX_ID.test(id)) {
        throw new ErrorValidacion('El id no es valido');
      }
      const productos = await this.tambienCompraronService.obtener(Number(id));
      return exito(productos, 'Tambien compraron obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener tambien compraron');
    }
  }
}
