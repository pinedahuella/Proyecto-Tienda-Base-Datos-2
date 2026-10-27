import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import {
  PermisoOferta,
  PermisoResuelto,
} from '../../decorators/permiso-oferta.decorator';
import { Roles } from '../../decorators/roles.decorator';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import type { AplicarDescuentoPeticion } from '../../dto/aplicar-descuento';
import type { EditarOfertaPeticion } from '../../dto/editar-oferta';
import type { TokenUsuario } from '../../dto/token-usuario';
import { PermisoOfertaGuard } from '../../guards/permiso-oferta.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { ErrorValidacion } from '../../helpers/errores';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import type { PermisoOfertaResuelto } from '../../models/permiso-oferta';
import { ID_ROL_ADMIN, ID_ROL_VENDEDOR } from '../../models/rol-usuario';
import { AclOfertasService } from '../../services/acl/acl-ofertas.service';
import { OfertasVendedorService } from '../../services/vendedores/ofertas.service';

/**
 * Lo compartido conmigo: las ofertas de OTRAS cuentas sobre las que el ACL de
 * la aplicacion (migracion 049) me da algun permiso.
 *
 * Las rutas de lo propio (`/vendedor/ofertas`) no cambian. Estas son aparte, y
 * en todas manda `PermisoOfertaGuard`: sin una entrada vigente de esta cuenta,
 * esta oferta y este permiso, 404. Si deja pasar, la accion la hace
 * `OfertasVendedorService`, el mismo de siempre, A NOMBRE DEL DUENO (con su id
 * y como vendedor), asi que valen las mismas reglas de precio, descuento,
 * existencia y venta relampago. Despues se anota en el registro quien la hizo
 * de verdad.
 *
 *   GET    /compartidas/ofertas                  lista, cualquier permiso
 *   GET    /compartidas/ofertas/:id              ver
 *   PATCH  /compartidas/ofertas/:id              editar (precio y existencia)
 *   POST   /compartidas/ofertas/:id/descuento    descuento
 *   DELETE /compartidas/ofertas/:id/descuento    descuento
 */
@Controller('compartidas/ofertas')
@UseGuards(SesionGuard, PermisoOfertaGuard)
@Roles(ID_ROL_VENDEDOR, ID_ROL_ADMIN)
export class OfertasCompartidasController {
  constructor(
    private readonly aclOfertasService: AclOfertasService,
    private readonly ofertasVendedorService: OfertasVendedorService,
  ) {}

  // GET /compartidas/ofertas
  @Get()
  async listar(@UsuarioActual() usuarioActual: TokenUsuario) {
    try {
      const ofertas = await this.aclOfertasService.listarCompartidas(
        usuarioActual.id_usuario,
      );
      return exito(ofertas, 'Ofertas compartidas contigo');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron traer las ofertas compartidas');
    }
  }

  // GET /compartidas/ofertas/:id
  @Get(':id')
  @PermisoOferta('ver')
  async obtener(
    @UsuarioActual() usuarioActual: TokenUsuario,
    @PermisoResuelto() permiso: PermisoOfertaResuelto,
  ) {
    try {
      const oferta = await this.aclOfertasService.obtenerCompartida(
        usuarioActual.id_usuario,
        permiso.id_oferta,
      );
      return exito(oferta, 'Oferta compartida');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo traer la oferta');
    }
  }

  // PATCH /compartidas/ofertas/:id
  // Solo precio y ajuste_stock. El estado (retirar, reactivar) sigue siendo
  // solo del dueno.
  @Patch(':id')
  @PermisoOferta('editar')
  async editar(
    @Param('id') id: string,
    @Body() datos: EditarOfertaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
    @PermisoResuelto() permiso: PermisoOfertaResuelto,
  ) {
    try {
      if (datos?.estado != null) {
        throw new ErrorValidacion(
          'Por aqui solo se cambian el precio y la existencia',
        );
      }
      const cambios: EditarOfertaPeticion = {};
      if (datos?.precio != null) {
        cambios.precio = datos.precio;
      }
      if (datos?.ajuste_stock != null) {
        cambios.ajuste_stock = datos.ajuste_stock;
      }
      const oferta = await this.ofertasVendedorService.editar(
        permiso.id_dueno,
        ID_ROL_VENDEDOR,
        id,
        cambios,
      );
      await this.aclOfertasService.registrarSinFallar({
        id_oferta: permiso.id_oferta,
        id_usuario_actor: usuarioActual.id_usuario,
        id_usuario_dueno: permiso.id_dueno,
        accion: 'editar',
        permiso: 'editar',
        detalle: { ...cambios },
      });
      return exito(oferta, 'Oferta actualizada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar la oferta');
    }
  }

  // POST /compartidas/ofertas/:id/descuento
  @Post(':id/descuento')
  @PermisoOferta('descuento')
  async aplicarDescuento(
    @Param('id') id: string,
    @Body() datos: AplicarDescuentoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
    @PermisoResuelto() permiso: PermisoOfertaResuelto,
  ) {
    try {
      const oferta = await this.ofertasVendedorService.aplicarDescuento(
        permiso.id_dueno,
        ID_ROL_VENDEDOR,
        id,
        datos,
      );
      await this.aclOfertasService.registrarSinFallar({
        id_oferta: permiso.id_oferta,
        id_usuario_actor: usuarioActual.id_usuario,
        id_usuario_dueno: permiso.id_dueno,
        accion: 'poner_descuento',
        permiso: 'descuento',
        detalle: {
          porcentaje_descuento: datos?.porcentaje_descuento ?? null,
          duracion_segundos: datos?.duracion_segundos ?? null,
        },
      });
      return exito(oferta, 'Descuento aplicado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo aplicar el descuento');
    }
  }

  // DELETE /compartidas/ofertas/:id/descuento
  @Delete(':id/descuento')
  @PermisoOferta('descuento')
  async quitarDescuento(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
    @PermisoResuelto() permiso: PermisoOfertaResuelto,
  ) {
    try {
      const oferta = await this.ofertasVendedorService.quitarDescuento(
        permiso.id_dueno,
        ID_ROL_VENDEDOR,
        id,
      );
      await this.aclOfertasService.registrarSinFallar({
        id_oferta: permiso.id_oferta,
        id_usuario_actor: usuarioActual.id_usuario,
        id_usuario_dueno: permiso.id_dueno,
        accion: 'quitar_descuento',
        permiso: 'descuento',
      });
      return exito(oferta, 'Descuento retirado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo quitar el descuento');
    }
  }
}
