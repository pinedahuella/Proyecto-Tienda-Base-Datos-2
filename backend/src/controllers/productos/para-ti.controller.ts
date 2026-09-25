import { Controller, Get, UseGuards } from '@nestjs/common';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import { ParaTiService } from '../../services/productos/para-ti.service';

/**
 * `GET /productos/para-ti` -- R3 ("para ti"). A diferencia de R1
 * (`vistos-recientemente`, que acepta sesion anonima), esta pide sesion
 * SIEMPRE (`SesionGuard`, sin `@Roles`: cualquier cuenta tiene sus propias
 * recomendaciones, igual que el carrito) -- R3 no tiene sentido sin una
 * cuenta real de la que partir. `id_usuario` sale del token, nunca de un
 * parametro.
 */
@Controller('productos')
@UseGuards(SesionGuard)
export class ParaTiController {
  constructor(private readonly paraTiService: ParaTiService) {}

  // GET /productos/para-ti
  @Get('para-ti')
  async paraTi(@UsuarioActual() usuario: TokenUsuario) {
    try {
      const productos = await this.paraTiService.obtener(
        Number(usuario.id_usuario),
      );
      return exito(productos, 'Para ti obtenido');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener para ti');
    }
  }
}
