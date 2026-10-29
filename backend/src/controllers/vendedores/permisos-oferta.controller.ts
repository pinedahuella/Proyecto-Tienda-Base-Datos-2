import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Post,
  UseGuards,
} from '@nestjs/common';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import type { TokenUsuario } from '../../dto/token-usuario';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import {
  AclOfertasService,
  type OtorgarPermisoPeticion,
} from '../../services/acl/acl-ofertas.service';

/**
 * El dueno reparte el ACL de una oferta suya (migracion 049): a quien le
 * comparte, con que permisos (ver, editar, descuento) y hasta cuando. Solo el
 * dueno, o un admin a nombre de la tienda; una oferta ajena da el 404 de
 * siempre. Controller aparte de `OfertasVendedorController`, que no cambia.
 *
 *   GET    /vendedor/ofertas/:id/permisos              entradas y registro
 *   POST   /vendedor/ofertas/:id/permisos              { correo, permisos, fecha_vencimiento? }
 *   DELETE /vendedor/ofertas/:id/permisos/:idPermiso   quitar una entrada
 */
@Controller('vendedor/ofertas')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('ofertas.compartir')
export class PermisosOfertaController {
  constructor(private readonly aclOfertasService: AclOfertasService) {}

  // GET /vendedor/ofertas/:id/permisos
  @Get(':id/permisos')
  async listar(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.aclOfertasService.listarPermisos(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        id,
      );
      return exito(resultado, 'Permisos de la oferta');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron traer los permisos');
    }
  }

  // POST /vendedor/ofertas/:id/permisos
  @Post(':id/permisos')
  async otorgar(
    @Param('id') id: string,
    @Body() datos: OtorgarPermisoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.aclOfertasService.otorgar(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        id,
        datos,
      );
      return exito(resultado, 'Permisos dados');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron dar los permisos');
    }
  }

  // DELETE /vendedor/ofertas/:id/permisos/:idPermiso
  @Delete(':id/permisos/:idPermiso')
  async revocar(
    @Param('id') id: string,
    @Param('idPermiso') idPermiso: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resultado = await this.aclOfertasService.revocar(
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        id,
        idPermiso,
      );
      return exito(resultado, 'Permiso quitado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo quitar el permiso');
    }
  }
}
