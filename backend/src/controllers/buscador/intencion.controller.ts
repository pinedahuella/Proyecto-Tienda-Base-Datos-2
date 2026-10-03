import { Controller, Get, Query } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { BuscarIntencionQuery } from '../../dto/buscar-intencion';
import { BuscadorIntencionService } from '../../services/buscador/intencion.service';

/**
 * `GET /buscador/productos/intencion` -- PUBLICA, la busqueda por intencion:
 * la persona dice lo que quiere lograr con sus palabras y se le muestran
 * productos cuyas resenas o descripcion se parecen en significado, no por las
 * palabras. Controlador SEPARADO de `BuscadorProductosController`/
 * `BuscadorFacetadoController`/`BuscadorSugerenciasController` (mismo criterio
 * que el resto de rutas hermanas de este prefijo).
 */
@Controller('buscador/productos')
export class BuscadorIntencionController {
  constructor(
    private readonly buscadorIntencionService: BuscadorIntencionService,
  ) {}

  // GET /buscador/productos/intencion?q=mi ventana esta muy solitaria&limite=10
  @Get('intencion')
  async buscar(@Query() query: BuscarIntencionQuery) {
    try {
      const resultados = await this.buscadorIntencionService.buscar(
        query.q,
        query.limite,
        query.calificacion_minima,
      );
      return exito(resultados, 'Productos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo hacer la busqueda por intencion');
    }
  }
}
