import { Controller, Get, Query, Req } from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { idUsuarioDeCookieOpcional } from '../../helpers/sesion-opcional';
import type { BuscarProductosFacetadoQuery } from '../../dto/buscar-productos-facetado';
import {
  BuscadorFacetadoService,
  separarPorComas,
} from '../../services/buscador/facetado.service';
import { EventosService } from '../../services/eventos/eventos.service';

/**
 * `GET /buscador/productos/facetado` -- PUBLICA, igual que
 * `GET /buscador/productos`, pero con filtros por categoria/precio/
 * calificacion/disponibilidad y sus conteos (Entrega 3). Controlador
 * SEPARADO de `BuscadorProductosController` (mismo criterio que
 * `TambienVieronController`/`SimilaresController`).
 *
 * A diferencia de la busqueda simple, `nombre` puede venir vacio: sirve
 * para navegar solo por facetas, sin texto (decision del usuario,
 * 2026-09-26) -- por eso no valida nada antes de llamar al servicio.
 */
@Controller('buscador/productos')
export class BuscadorFacetadoController {
  constructor(
    private readonly buscadorFacetadoService: BuscadorFacetadoService,
    private readonly eventosService: EventosService,
  ) {}

  // GET /buscador/productos/facetado?nombre=...&categoria=...&precio=...&calificacion=...&disponible=...&limite=...&sesion=...
  @Get('facetado')
  async buscar(
    @Query() query: BuscarProductosFacetadoQuery,
    @Req() request: FastifyRequest,
  ) {
    try {
      const resultado = await this.buscadorFacetadoService.buscar(query);

      // Evento de analitica en ClickHouse, SIN ruta propia -- mismo criterio
      // que GET /buscador/productos. `facetada: true` y las facetas
      // elegidas van con `separarPorComas`, la misma funcion que ya uso
      // BuscadorFacetadoService para armar el filtro real -- no se vuelve a
      // parsear nada.
      if (typeof query.sesion === 'string' && query.sesion.trim() !== '') {
        void this.eventosService.registrarBusqueda({
          termino: query.nombre ?? '',
          resultados: resultado.total,
          idUsuario: await idUsuarioDeCookieOpcional(request),
          sesion: query.sesion.trim(),
          facetada: true,
          categorias: separarPorComas(query.categoria).map(Number),
          precios: separarPorComas(query.precio),
          calificaciones: separarPorComas(query.calificacion),
          disponible: separarPorComas(query.disponible).length > 0,
        });
      }

      return exito(resultado, 'Busqueda completada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo completar la busqueda');
    }
  }
}
