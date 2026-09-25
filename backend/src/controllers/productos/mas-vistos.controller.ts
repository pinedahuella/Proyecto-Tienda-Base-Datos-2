import { Controller, Get } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { MasVistosService } from '../../services/productos/mas-vistos.service';

/**
 * `GET /productos/mas-vistos` -- PUBLICA, sin sesion: mismo criterio que
 * `MasVendidosController` (dato de vitrina, tan publico como el resto del
 * catalogo). Controlador separado a proposito, mismo criterio que
 * `MasVendidosController`.
 *
 * Sirve como plan B publico para cuando "para ti" (`ParaTiController`)
 * viene vacio: el ranking equivalente de vistas en `AdminTendenciasService`
 * solo lo puede pedir un admin, esta ruta lee un ranking aparte
 * (`MasVistosSyncService`) pensado para el catalogo publico.
 */
@Controller('productos')
export class MasVistosController {
  constructor(private readonly masVistosService: MasVistosService) {}

  // GET /productos/mas-vistos
  @Get('mas-vistos')
  async obtener() {
    try {
      const productos = await this.masVistosService.obtener();
      return exito(productos, 'Productos mas vistos obtenidos');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener los productos mas vistos',
      );
    }
  }
}
