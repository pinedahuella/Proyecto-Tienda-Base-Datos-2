import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import type { CrearReglaDescuentoPeriodoPeticion } from '../../dto/crear-regla-descuento-periodo';
import type { EditarReglaDescuentoPeriodoPeticion } from '../../dto/editar-regla-descuento-periodo';
import type { PaginarReglasDescuentoPeriodoQuery } from '../../dto/paginar-reglas-descuento-periodo';
import { ReglasDescuentoPeriodoService } from '../../services/reglas-descuento-periodo/reglas-descuento-periodo.service';

/**
 * Controlador de las rutas /vendedor/reglas-descuento-periodos -- el CRUD
 * de `regla_descuento_periodo` (ver ese modelo y el servicio). Solo la
 * configuracion: el disparador real (revisar la fecha de hoy contra las
 * reglas activas) todavia no existe.
 *
 * Mismo criterio de autorizacion que ReglasDescuentoAutomaticoController:
 * cualquier vendedor o admin, y un admin actua como la cuenta de la tienda
 * (ReglasDescuentoPeriodoService.resolverIdEfectivo()) -- nunca bajo su
 * propia cuenta.
 */
@Controller('vendedor/reglas-descuento-periodos')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('reglas.ver')
export class ReglasDescuentoPeriodoController {
  constructor(
    private readonly reglasDescuentoPeriodoService: ReglasDescuentoPeriodoService,
  ) {}

  // POST /vendedor/reglas-descuento-periodos
  @Permiso('reglas.administrar')
  @Post()
  async crear(
    @Body() datos: CrearReglaDescuentoPeriodoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const regla = await this.reglasDescuentoPeriodoService.crear(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        datos,
      );
      return exito(regla, 'Regla de descuento por periodo creada');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudo crear la regla de descuento por periodo',
      );
    }
  }

  // GET /vendedor/reglas-descuento-periodos
  @Get()
  async listar(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const reglas = await this.reglasDescuentoPeriodoService.listarPropias(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
      );
      return exito(reglas, 'Reglas de descuento por periodo obtenidas');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener las reglas de descuento por periodo',
      );
    }
  }

  // GET /vendedor/reglas-descuento-periodos/paginado
  @Get('paginado')
  async listarPaginado(
    @Query() query: PaginarReglasDescuentoPeriodoQuery,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const pagina =
        await this.reglasDescuentoPeriodoService.listarPropiasPaginado(
          usuarioActual.id_usuario,
          usuarioActual.id_rol_usuario,
          query,
        );
      return exito(pagina, 'Reglas de descuento por periodo obtenidas');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudieron obtener las reglas de descuento por periodo',
      );
    }
  }

  // PATCH /vendedor/reglas-descuento-periodos/:id
  @Permiso('reglas.administrar')
  @Patch(':id')
  async editar(
    @Param('id') id: string,
    @Body() datos: EditarReglaDescuentoPeriodoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const regla = await this.reglasDescuentoPeriodoService.editar(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        id,
        datos,
      );
      return exito(regla, 'Regla de descuento por periodo actualizada');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudo actualizar la regla de descuento por periodo',
      );
    }
  }

  // DELETE /vendedor/reglas-descuento-periodos/:id
  @Permiso('reglas.administrar')
  @Delete(':id')
  async eliminar(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      await this.reglasDescuentoPeriodoService.eliminar(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        id,
      );
      return exito(null, 'Regla de descuento por periodo eliminada');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudo eliminar la regla de descuento por periodo',
      );
    }
  }
}
