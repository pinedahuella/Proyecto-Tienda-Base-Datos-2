import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import { ParaTiService } from '../../services/productos/para-ti.service';

/**
 * `GET /productos/para-ti` -- lo que compraron las cuentas que compraron lo
 * mismo que tu (Neo4j, `ParaTiService`). A diferencia de R1
 * (`vistos-recientemente`, que acepta sesion anonima), esta pide sesion
 * SIEMPRE (`SesionGuard` y `productos.para_ti`, que tienen los tres roles: cualquier cuenta tiene sus propias
 * recomendaciones, igual que el carrito) -- no tiene sentido sin una cuenta
 * real de la que partir. `id_usuario` sale del token, nunca de un parametro.
 * `max_productos` (opcional): de cuantos de tus productos comprados mas
 * recientes se parte.
 */
@Controller('productos')
@UseGuards(SesionGuard, PermisoGuard)
export class ParaTiController {
  constructor(private readonly paraTiService: ParaTiService) {}

  // GET /productos/para-ti
  @Permiso('productos.para_ti')
  @Get('para-ti')
  async paraTi(
    @UsuarioActual() usuario: TokenUsuario,
    @Query('max_productos') maxProductos?: string,
  ) {
    try {
      const productos = await this.paraTiService.obtener(
        Number(usuario.id_usuario),
        maxProductos,
      );
      return exito(productos, 'Para ti obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener para ti');
    }
  }
}
