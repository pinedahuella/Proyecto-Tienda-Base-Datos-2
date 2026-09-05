import { Controller, Get, Query } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { BuscarProductosQuery } from '../../dto/buscar-productos';
import { BuscadorProductosService } from '../../services/buscador/productos.service';

/**
 * Controlador de la ruta /buscador/productos.
 *
 * Publico, igual que /productos: el catalogo se puede buscar sin haber
 * iniciado sesion.
 */
@Controller('buscador/productos')
export class BuscadorProductosController {
  constructor(
    private readonly buscadorProductosService: BuscadorProductosService,
  ) {}

  // GET /buscador/productos?nombre=...&limite=...
  @Get()
  async buscar(@Query() query: BuscarProductosQuery) {
    try {
      const resultados = await this.buscadorProductosService.buscar(
        query.nombre,
        query.limite,
      );
      return exito(resultados, 'Busqueda completada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo completar la busqueda');
    }
  }
}
