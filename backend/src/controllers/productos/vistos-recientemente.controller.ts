import { Controller, Get, Query, Req } from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { idUsuarioDeCookieOpcional } from '../../helpers/sesion-opcional';
import type { ConsultarVistosRecientementeQuery } from '../../dto/consultar-vistos-recientemente';
import { VistosRecientementeService } from '../../services/productos/vistos-recientemente.service';

/**
 * `GET /productos/vistos-recientemente` -- publica, sin sesion obligatoria
 * (mismo criterio que `GET /buscador/productos`): un visitante sin cuenta
 * es un caso normal, no un error. Ver `VistosRecientementeService` para el
 * diseno completo.
 */
@Controller('productos')
export class VistosRecientementeController {
  constructor(
    private readonly vistosRecientementeService: VistosRecientementeService,
  ) {}

  // GET /productos/vistos-recientemente?sesion=...&dias_historial=...&limite=...
  @Get('vistos-recientemente')
  async vistosRecientemente(
    @Query() query: ConsultarVistosRecientementeQuery,
    @Req() request: FastifyRequest,
  ) {
    try {
      const idUsuario = await idUsuarioDeCookieOpcional(request);
      const productos = await this.vistosRecientementeService.listar(
        idUsuario,
        query,
      );
      return exito(productos, 'Vistos recientemente obtenidos');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener los vistos recientemente',
      );
    }
  }
}
