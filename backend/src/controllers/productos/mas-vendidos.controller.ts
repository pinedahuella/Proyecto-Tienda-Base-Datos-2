import { Controller, Get } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { MasVendidosService } from '../../services/productos/mas-vendidos.service';

/**
 * `GET /productos/mas-vendidos` -- PUBLICA, sin sesion: el ranking de mas
 * vendidos es un dato de vitrina, tan publico como el resto del catalogo.
 *
 * Controlador SEPARADO de `ProductosController` a proposito (mismo
 * criterio que `OfertasVendedorController`/`VentasLimitadasController`,
 * que ya comparten el prefijo `vendedor/ofertas`): esta ruta no consulta
 * Mongo directo con los filtros de siempre, primero pasa por el ZSET de
 * Redis que mantiene `MasVendidosSyncService`
 * (`elementos Generales/plan pendiente/eventos-clickhouse.md`). Fastify
 * prioriza rutas estaticas sobre parametricas sin importar el orden de
 * registro, asi que `mas-vendidos` nunca choca con `GET /productos/:id`
 * de la otra clase.
 */
@Controller('productos')
export class MasVendidosController {
  constructor(private readonly masVendidosService: MasVendidosService) {}

  // GET /productos/mas-vendidos
  @Get('mas-vendidos')
  async obtener() {
    try {
      const productos = await this.masVendidosService.obtener();
      return exito(productos, 'Productos mas vendidos obtenidos');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener los productos mas vendidos',
      );
    }
  }
}
