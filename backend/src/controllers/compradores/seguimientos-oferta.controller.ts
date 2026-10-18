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
import { SesionGuard } from '../../guards/sesion.guard';
import { exito } from '../../helpers/respuesta';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import type { TokenUsuario } from '../../dto/token-usuario';
import type {
  CrearSeguimientoPeticion,
  ListarAvisosQuery,
  ListarSeguimientosQuery,
  MarcarAvisoPeticion,
} from '../../dto/seguimientos-oferta';
import { SeguimientosOfertaService } from '../../services/compradores/seguimientos-oferta.service';

/**
 * Controlador de las rutas /comprador/seguimientos: "avisame cuando llegue" y
 * "avisame cuando baje", y sus avisos.
 *
 * Sin @Roles, igual que /comprador/pedidos: comprar no es privilegio de un
 * rol, y seguir una oferta tampoco. Cada quien solo ve y toca lo suyo (el
 * filtro por id_usuario esta en SeguimientosOfertaService).
 *
 * `avisos` es un segmento literal y no hay ningun `GET :id` con el que pueda
 * chocar.
 */
@Controller('comprador/seguimientos')
@UseGuards(SesionGuard)
export class SeguimientosOfertaController {
  constructor(
    private readonly seguimientosOfertaService: SeguimientosOfertaService,
  ) {}

  // POST /comprador/seguimientos
  @Post()
  async crear(
    @Body() cuerpo: CrearSeguimientoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const seguimiento = await this.seguimientosOfertaService.crear(
        usuarioActual.id_usuario,
        cuerpo,
      );
      return exito(seguimiento, 'Te avisaremos cuando se cumpla');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo crear el seguimiento');
    }
  }

  // GET /comprador/seguimientos?estado=activos|cumplidos
  @Get()
  async listar(
    @Query() query: ListarSeguimientosQuery,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const seguimientos = await this.seguimientosOfertaService.listar(
        usuarioActual.id_usuario,
        query,
      );
      return exito(seguimientos, 'Seguimientos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los seguimientos');
    }
  }

  // GET /comprador/seguimientos/avisos?no_leidos=true
  @Get('avisos')
  async listarAvisos(
    @Query() query: ListarAvisosQuery,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const avisos = await this.seguimientosOfertaService.listarAvisos(
        usuarioActual.id_usuario,
        query,
      );
      return exito(avisos, 'Avisos obtenidos');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener los avisos');
    }
  }

  // PATCH /comprador/seguimientos/avisos/:id  { "leido": true | false }
  @Patch('avisos/:id')
  async marcarAviso(
    @Param('id') id: string,
    @Body() cuerpo: MarcarAvisoPeticion,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const aviso = await this.seguimientosOfertaService.marcarAviso(
        usuarioActual.id_usuario,
        id,
        cuerpo,
      );
      return exito(aviso, 'Aviso actualizado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar el aviso');
    }
  }

  // DELETE /comprador/seguimientos/:id
  @Delete(':id')
  async borrar(
    @Param('id') id: string,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      await this.seguimientosOfertaService.borrar(usuarioActual.id_usuario, id);
      return exito(null, 'Seguimiento borrado');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo borrar el seguimiento');
    }
  }
}
