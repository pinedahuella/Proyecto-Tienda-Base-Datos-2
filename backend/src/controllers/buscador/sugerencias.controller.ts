import { Controller, Get, Query } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { BuscarSugerenciasQuery } from '../../dto/buscar-sugerencias';
import { BuscadorSugerenciasService } from '../../services/buscador/sugerencias.service';

/**
 * `GET /buscador/productos/sugerencias` -- PUBLICA, el autocompletado del
 * buscador (Entrega 3): sugiere nombres mientras se escribe, antes de
 * buscar de verdad. Controlador SEPARADO de `BuscadorProductosController`/
 * `BuscadorFacetadoController` (mismo criterio que el resto de rutas
 * hermanas de este prefijo).
 */
@Controller('buscador/productos')
export class BuscadorSugerenciasController {
  constructor(
    private readonly buscadorSugerenciasService: BuscadorSugerenciasService,
  ) {}

  // GET /buscador/productos/sugerencias?prefijo=lap&limite=8
  @Get('sugerencias')
  async sugerir(@Query() query: BuscarSugerenciasQuery) {
    try {
      const sugerencias = await this.buscadorSugerenciasService.sugerir(
        query.prefijo,
        query.limite,
      );
      return exito(sugerencias, 'Sugerencias obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las sugerencias');
    }
  }
}
