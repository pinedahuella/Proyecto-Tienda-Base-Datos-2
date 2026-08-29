import {
  Body,
  Controller,
  Get,
  Param,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { NOMBRE_COOKIE_TOKEN, verificarToken } from '../../helpers/token';
import type { CrearResenaPeticion } from '../../dto/crear-resena';
import type { TokenUsuario } from '../../dto/token-usuario';
import { ResenasService } from '../../services/resenas/resenas.service';

/**
 * Las rutas de la parte social (migracion 011): la lista de resenas de un
 * producto y escribir una.
 *
 * Sin prefijo de clase a proposito: la lista cuelga de `/productos/:id` (es
 * parte de la ficha) y escribir cuelga de `/resenas`. Cada metodo lleva su
 * ruta completa.
 *
 * `POST /resenas` pide sesion (SesionGuard, sin @Roles: calificar no es de
 * un rol, cualquiera con sesion puede -- igual que comprar).
 * `GET /productos/:id/resenas` es publica: se puede ver sin sesion. Si hay
 * cookie de sesion valida, el controlador la resuelve a mano (sin guard) y
 * se la pasa al servicio para que cada voto traiga `mio` y salga
 * `puede_calificar`.
 */
@Controller()
export class ResenasController {
  constructor(private readonly resenasService: ResenasService) {}

  // GET /productos/:id/resenas
  @Get('productos/:id/resenas')
  async listar(@Param('id') id: string, @Req() request: FastifyRequest) {
    try {
      const idUsuarioSesion = await this.idUsuarioSiHaySesion(request);
      const datos = await this.resenasService.listarDeProducto(
        id,
        idUsuarioSesion,
      );
      return exito(datos, 'Resenas obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las resenas');
    }
  }

  // POST /resenas
  @Post('resenas')
  @UseGuards(SesionGuard)
  async crear(
    @Body() cuerpo: CrearResenaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const resena = await this.resenasService.crear(
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(resena, 'Tu resena se publico');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo publicar la resena');
    }
  }

  /**
   * Lee la cookie de sesion sin exigirla: devuelve el id del usuario si el
   * token es valido, o `null` si no hay cookie o el token no sirve. No
   * comprueba que la cuenta siga activa -- en una ruta publica de solo
   * lectura, lo unico que la sesion agrega es `voto.mio` y `puede_calificar`.
   */
  private async idUsuarioSiHaySesion(
    request: FastifyRequest,
  ): Promise<string | null> {
    const token = request.cookies[NOMBRE_COOKIE_TOKEN];
    if (!token) {
      return null;
    }
    try {
      const usuario = await verificarToken(token);
      return usuario.id_usuario;
    } catch {
      return null;
    }
  }
}
