import { Controller, Get, Query } from '@nestjs/common';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { BuscarHibridaQuery } from '../../dto/buscar-hibrida';
import { BuscadorHibridoService } from '../../services/buscador/hibrida.service';

/**
 * `GET /buscador/productos/hibrida` -- PUBLICA, la busqueda hibrida: junta la
 * busqueda por palabras (difusa, sin tildes) con la busqueda por significado
 * (vectores) en una sola lista ordenada. Controlador SEPARADO de los demas del
 * prefijo `buscador/productos` (mismo criterio que sus rutas hermanas).
 */
@Controller('buscador/productos')
export class BuscadorHibridoController {
  constructor(
    private readonly buscadorHibridoService: BuscadorHibridoService,
  ) {}

  // GET /buscador/productos/hibrida?q=algo para escuchar musica corriendo&limite=20
  @Get('hibrida')
  async buscar(@Query() query: BuscarHibridaQuery) {
    try {
      const respuesta = await this.buscadorHibridoService.buscar(
        query.q,
        query.limite,
      );
      return exito(respuesta, 'Busqueda completada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo completar la busqueda');
    }
  }
}
