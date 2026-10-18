import { Controller, Get } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { CombosService } from '../../services/productos/combos.service';

/**
 * `GET /productos/combos` -- PUBLICA, sin sesion: los grupos de 2 y 3
 * productos que mas se compran en el mismo pedido, en toda la tienda. Lee
 * directo de Redis lo que dejo `CombosSyncService` (ClickHouse + Mongo).
 * Controlador separado, mismo criterio que `MasVendidosController`.
 */
@Controller('productos')
export class CombosController {
  constructor(private readonly combosService: CombosService) {}

  // GET /productos/combos
  @Get('combos')
  async obtener() {
    try {
      const combos = await this.combosService.obtener();
      return exito(combos, 'Combos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los combos');
    }
  }
}
