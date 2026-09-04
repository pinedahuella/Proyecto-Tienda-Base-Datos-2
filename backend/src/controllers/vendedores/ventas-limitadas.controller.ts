import {
  Body,
  Controller,
  Delete,
  Param,
  Post,
  UseGuards,
} from '@nestjs/common';
import { Roles } from '../../decorators/roles.decorator';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import type { AbrirVentaLimitadaPeticion } from '../../dto/abrir-venta-limitada';
import { ID_ROL_VENDEDOR, ID_ROL_ADMIN } from '../../models/rol-usuario';
import { VentasLimitadasService } from '../../services/vendedores/ventas-limitadas.service';

/**
 * `POST` / `DELETE /vendedor/ofertas/:id/venta-limitada` -- el vendedor
 * abre o cierra la venta relampago (inventario limitado en Redis) de UNA
 * oferta suya. Es el paso 2 de
 * `elementos Generales/plan pendiente/inventario-limitado.md` y lo unico
 * que bloqueaba el boton del panel del vendedor.
 *
 * Comparte el prefijo `/vendedor/ofertas`, el guard y los roles con
 * `OfertasVendedorController`, pero vive en su propio controlador/servicio:
 * el mecanismo no tiene nada que ver con el CRUD de ofertas de PostgreSQL.
 *
 * Un admin actua como la cuenta de la tienda (igual que el resto de
 * `/vendedor/ofertas`). Una oferta ajena o inexistente da el 404 generico.
 */
@Controller('vendedor/ofertas')
@UseGuards(SesionGuard)
@Roles(ID_ROL_VENDEDOR, ID_ROL_ADMIN)
export class VentasLimitadasController {
  constructor(
    private readonly ventasLimitadasService: VentasLimitadasService,
  ) {}

  // POST /vendedor/ofertas/:id/venta-limitada
  @Post(':id/venta-limitada')
  async abrir(
    @Param('id') id: string,
    @Body() datos: AbrirVentaLimitadaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const abierta = await this.ventasLimitadasService.abrir(
        id,
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
        datos ?? {},
      );
      return exito(abierta, 'Venta relampago abierta');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo abrir la venta relampago');
    }
  }

  // DELETE /vendedor/ofertas/:id/venta-limitada
  @Delete(':id/venta-limitada')
  async cerrar(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      await this.ventasLimitadasService.cerrar(
        id,
        usuarioActual.id_usuario,
        usuarioActual.id_rol_usuario,
      );
      return exito(null, 'Venta relampago cerrada');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo cerrar la venta relampago');
    }
  }
}
