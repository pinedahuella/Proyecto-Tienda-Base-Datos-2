import { Controller, Get } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { OfertasDestacadasService } from '../../services/productos/ofertas-destacadas.service';

/**
 * `GET /productos/ofertas/descuento` y `GET /productos/ofertas/venta-relampago`
 * -- PUBLICAS, sin sesion: son vitrina, igual que `GET /productos/mas-vendidos`.
 *
 * Controlador SEPARADO de `ProductosController` a proposito (mismo criterio
 * que `MasVendidosController`): estas dos rutas no consultan Mongo ni
 * Postgres con los filtros de siempre, leen directo los dos HASH de Redis
 * que mantiene `RegistroOfertasRedisService` (ver ese archivo) -- ni
 * siquiera tienen fallback a otra base si Redis esta caido, a diferencia
 * del resto del catalogo.
 *
 * Tres segmentos (`ofertas/descuento`, `ofertas/venta-relampago`), asi que
 * no chocan con `GET /productos/ofertas/:id/historial` de
 * `ProductosController` (esa exige un tercer segmento literal
 * `historial`) ni con `GET /productos/:id` (un solo segmento).
 */
@Controller('productos/ofertas')
export class OfertasDestacadasController {
  constructor(
    private readonly ofertasDestacadasService: OfertasDestacadasService,
  ) {}

  // GET /productos/ofertas/descuento
  @Get('descuento')
  async obtenerConDescuento() {
    try {
      const ofertas = await this.ofertasDestacadasService.obtenerConDescuento();
      return exito(ofertas, 'Ofertas con descuento obtenidas');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener las ofertas con descuento',
      );
    }
  }

  // GET /productos/ofertas/venta-relampago
  @Get('venta-relampago')
  async obtenerVentaRelampago() {
    try {
      const ofertas =
        await this.ofertasDestacadasService.obtenerVentaRelampago();
      return exito(ofertas, 'Ventas relampago obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las ventas relampago');
    }
  }
}
