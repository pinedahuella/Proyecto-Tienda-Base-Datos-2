import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Post,
  Put,
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
import type { ResponderResenaPeticion } from '../../dto/responder-resena';
import type { VotarComentarioPeticion } from '../../dto/votar-comentario';
import type { TokenUsuario } from '../../dto/token-usuario';
import { ResenasService } from '../../services/resenas/resenas.service';

/**
 * Las rutas de la parte social (migracion 011): la lista de resenas de un
 * producto, escribir una, responderla, votar (like/dislike) un comentario,
 * y dos consultas de estado para la cuenta logueada ("¿lo compre?",
 * "¿lo resene?").
 *
 * Sin prefijo de clase a proposito: lo de la ficha cuelga de
 * `/productos/:id/...`, las resenas de `/resenas` y los votos de
 * `/comentarios/:id/voto`. Cada metodo lleva su ruta completa.
 *
 * `GET /productos/:id/resenas` es la unica publica: se puede ver sin
 * sesion. Si hay cookie de sesion valida, el controlador la resuelve a
 * mano (sin guard) y se la pasa al servicio para que cada voto traiga `mio`
 * y salga `puede_calificar`.
 *
 * El resto piden sesion (SesionGuard por metodo, sin @Roles: ni calificar,
 * ni responder, ni votar son de un rol -- cualquiera con sesion puede,
 * igual que comprar). En particular RESPONDER una resena lo puede hacer
 * cualquiera, no solo el vendedor calificado (decision del equipo; ver
 * endpoints-resenas.md).
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

  // GET /productos/:id/comprado
  // ¿La cuenta logueada compro (y pago) este producto alguna vez?
  @Get('productos/:id/comprado')
  @UseGuards(SesionGuard)
  async comprado(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const datos = await this.resenasService.comproProducto(
        usuarioActual.id_usuario,
        id,
      );
      return exito(
        datos,
        datos.comprado
          ? 'Ya compraste este producto'
          : 'Todavia no has comprado este producto',
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo comprobar la compra');
    }
  }

  // GET /productos/:id/resenado
  // ¿La cuenta logueada ya reseño este producto (a cualquier vendedor)?
  @Get('productos/:id/resenado')
  @UseGuards(SesionGuard)
  async resenado(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const datos = await this.resenasService.resenoProducto(
        usuarioActual.id_usuario,
        id,
      );
      return exito(
        datos,
        datos.resenado
          ? 'Ya resenaste este producto'
          : 'Todavia no has resenado este producto',
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo comprobar la resena');
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

  // POST /resenas/:id/respuestas   (:id es id_resena)
  @Post('resenas/:id/respuestas')
  @UseGuards(SesionGuard)
  async responder(
    @Param('id') id: string,
    @Body() cuerpo: ResponderResenaPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const respuesta = await this.resenasService.responder(
        usuarioActual.id_usuario,
        id,
        cuerpo,
      );
      return exito(respuesta, 'Tu respuesta se publico');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo publicar la respuesta');
    }
  }

  // PUT /comentarios/:id/voto   (:id es id_comentario)
  @Put('comentarios/:id/voto')
  @UseGuards(SesionGuard)
  async votar(
    @Param('id') id: string,
    @Body() cuerpo: VotarComentarioPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const voto = await this.resenasService.votar(
        usuarioActual.id_usuario,
        id,
        cuerpo,
      );
      return exito(voto, 'Voto registrado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo registrar el voto');
    }
  }

  // DELETE /comentarios/:id/voto
  @Delete('comentarios/:id/voto')
  @UseGuards(SesionGuard)
  async quitarVoto(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const voto = await this.resenasService.quitarVoto(
        usuarioActual.id_usuario,
        id,
      );
      return exito(voto, 'Voto quitado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo quitar el voto');
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
