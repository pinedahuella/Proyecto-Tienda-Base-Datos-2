import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import type { BuscarOfertasQuery } from '../../dto/buscar-ofertas';
import { BuscarOfertasService } from '../../services/vendedores/buscar-ofertas.service';

/**
 * Controlador de GET /vendedor/ofertas/buscar, el buscador de ofertas sobre
 * Elasticsearch. Mismos roles que OfertasVendedorController (vendedor o
 * admin); quien ve que lo decide BuscarOfertasService.
 *
 * Va en su propio archivo y no en OfertasVendedorController porque consulta
 * otra base (Elasticsearch, no PostgreSQL). `buscar` es un segmento literal y
 * aquel controller no tiene un `GET :id` suelto con el que pudiera chocar.
 */
@Controller('vendedor/ofertas/buscar')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('ofertas.ver')
export class BuscarOfertasController {
  constructor(private readonly buscarOfertasService: BuscarOfertasService) {}

  // GET /vendedor/ofertas/buscar?q=...&alcance=...&estado=...&orden=...
  @Get()
  async buscar(
    @Query() query: BuscarOfertasQuery,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.buscarOfertasService.buscar(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        query,
      );
      return exito(resultado, 'Busqueda completada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo completar la busqueda de ofertas');
    }
  }
}
