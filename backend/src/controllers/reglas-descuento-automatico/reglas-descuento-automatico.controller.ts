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
import { Roles } from '../../decorators/roles.decorator';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import type { CrearReglaDescuentoPeticion } from '../../dto/crear-regla-descuento';
import type { EditarReglaDescuentoPeticion } from '../../dto/editar-regla-descuento';
import type { PaginarReglasDescuentoQuery } from '../../dto/paginar-reglas-descuento';
import { ID_ROL_VENDEDOR, ID_ROL_ADMIN } from '../../models/rol-usuario';
import { ReglasDescuentoAutomaticoService } from '../../services/reglas-descuento-automatico/reglas-descuento-automatico.service';

/**
 * Controlador de las rutas /vendedor/reglas-descuento -- el CRUD de
 * `regla_descuento_automatico` (ver ese modelo y el servicio). Solo la
 * configuracion: el disparo real contra ClickHouse todavia no existe.
 *
 * Mismo criterio de autorizacion que OfertasVendedorController: cualquier
 * vendedor o admin, y un admin actua como la cuenta de la tienda
 * (ReglasDescuentoAutomaticoService.resolverIdEfectivo()) -- nunca bajo su
 * propia cuenta.
 */
@Controller('vendedor/reglas-descuento')
@UseGuards(SesionGuard)
@Roles(ID_ROL_VENDEDOR, ID_ROL_ADMIN)
export class ReglasDescuentoAutomaticoController {
  constructor(
    private readonly reglasDescuentoService: ReglasDescuentoAutomaticoService,
  ) {}

  // POST /vendedor/reglas-descuento
  @Post()
  async crear(
    @Body() datos: CrearReglaDescuentoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const regla = await this.reglasDescuentoService.crear(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        datos,
      );
      return exito(regla, 'Regla de descuento automatico creada');
    } catch (error) {
      manejarErrorHttp(
        error,
        'No se pudo crear la regla de descuento automatico',
      );
    }
  }

  // GET /vendedor/reglas-descuento
  @Get()
  async listar(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const reglas = await this.reglasDescuentoService.listarPropias(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
      );
      return exito(reglas, 'Reglas de descuento obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las reglas de descuento');
    }
  }

  // GET /vendedor/reglas-descuento/paginado
  @Get('paginado')
  async listarPaginado(
    @Query() query: PaginarReglasDescuentoQuery,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const pagina = await this.reglasDescuentoService.listarPropiasPaginado(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        query,
      );
      return exito(pagina, 'Reglas de descuento obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las reglas de descuento');
    }
  }

  // PATCH /vendedor/reglas-descuento/:id
  @Patch(':id')
  async editar(
    @Param('id') id: string,
    @Body() datos: EditarReglaDescuentoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const regla = await this.reglasDescuentoService.editar(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        id,
        datos,
      );
      return exito(regla, 'Regla de descuento actualizada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar la regla de descuento');
    }
  }

  // DELETE /vendedor/reglas-descuento/:id
  @Delete(':id')
  async eliminar(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      await this.reglasDescuentoService.eliminar(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        id,
      );
      return exito(null, 'Regla de descuento eliminada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo eliminar la regla de descuento');
    }
  }
}
