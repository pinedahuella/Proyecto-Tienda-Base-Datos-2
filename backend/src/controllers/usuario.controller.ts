import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpException,
  HttpStatus,
  Post,
  Query,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { FastifyReply } from 'fastify';
import { UsuarioActual } from '../decorators/usuario-actual.decorator';
import { SesionGuard } from '../guards/sesion.guard';
import { fallo, exito } from '../helpers/respuesta';
import {
  ErrorConexion,
  ErrorConflicto,
  ErrorSesion,
  ErrorValidacion,
} from '../helpers/errores';
import { NOMBRE_COOKIE_TOKEN, OPCIONES_COOKIE_TOKEN } from '../helpers/token';
import type { LoginUsuarioPeticion } from '../models/login-usuario';
import type { RegistroUsuarioPeticion } from '../models/registro-usuario';
import type { TokenUsuario } from '../models/token-usuario';
import { UsuarioService } from '../services/usuario.service';

/**
 * Controlador de las rutas /usuario.
 *
 * El controlador no valida ni consulta nada: eso vive en UsuarioService.
 * Aqui solo se traduce lo que el servicio lanza a un codigo HTTP, y es
 * quien pone y borra la cookie del token (login y logout).
 */
@Controller('usuario')
export class UsuarioController {
  constructor(private readonly usuarioService: UsuarioService) {}

  // POST /usuario/registro
  @Post('registro')
  async registrar(@Body() cuerpo: RegistroUsuarioPeticion) {
    try {
      const usuario = await this.usuarioService.registrar(cuerpo);
      return exito(usuario, 'Usuario registrado correctamente');
    } catch (error) {
      this.manejarError(error, 'No se pudo registrar el usuario');
    }
  }

  // GET /usuario/registros-existentes
  @Get('registros-existentes')
  async verificarExistencia(
    @Query('correo') correo?: string,
    @Query('usuario') usuario?: string,
  ) {
    try {
      const resultado = await this.usuarioService.verificarExistencia(
        correo,
        usuario,
      );
      return exito(resultado, 'Disponibilidad consultada');
    } catch (error) {
      this.manejarError(error, 'No se pudo verificar el usuario');
    }
  }

  // POST /usuario/login
  // Nest manda 201 por defecto en todo @Post; aqui no se crea nada, asi que
  // el codigo correcto es 200.
  @Post('login')
  @HttpCode(HttpStatus.OK)
  async iniciarSesion(
    @Body() cuerpo: LoginUsuarioPeticion,
    @Res({ passthrough: true }) reply: FastifyReply,
  ) {
    // passthrough: true dice que este metodo no maneja la respuesta el
    // mismo (nada de reply.send): solo la usa para poner la cookie, y Nest
    // sigue encargandose de mandar lo que se retorne, igual que siempre.
    try {
      const { usuario, token } =
        await this.usuarioService.iniciarSesion(cuerpo);
      reply.setCookie(NOMBRE_COOKIE_TOKEN, token, OPCIONES_COOKIE_TOKEN);
      return exito(usuario, 'Sesion iniciada correctamente');
    } catch (error) {
      this.manejarError(error, 'No se pudo iniciar sesion');
    }
  }

  // POST /usuario/logout
  // Sin SesionGuard a proposito: cerrar sesion tiene que funcionar incluso
  // si el token ya vencio o vino mal. Solo borra la cookie del navegador.
  @Post('logout')
  @HttpCode(HttpStatus.OK)
  cerrarSesion(@Res({ passthrough: true }) reply: FastifyReply) {
    reply.clearCookie(NOMBRE_COOKIE_TOKEN, {
      path: OPCIONES_COOKIE_TOKEN.path,
    });
    return exito(null, 'Sesion cerrada');
  }

  // GET /usuario/yo
  // Protegida: SesionGuard exige una cookie valida antes de dejar pasar la
  // peticion, y deja el usuario del token listo para @UsuarioActual().
  @Get('yo')
  @UseGuards(SesionGuard)
  async obtenerYo(@UsuarioActual() usuarioToken: TokenUsuario) {
    try {
      const usuario = await this.usuarioService.obtenerPorId(
        usuarioToken.id_usuario,
      );
      return exito(usuario, 'Sesion activa');
    } catch (error) {
      this.manejarError(error, 'No se pudo obtener el usuario');
    }
  }

  /**
   * Traduce lo que lanza UsuarioService a un codigo HTTP. Las rutas de
   * arriba comparten los mismos tipos de error, asi que comparten este
   * mapeo; solo cambia el mensaje generico de 500 de cada una.
   */
  private manejarError(error: unknown, mensajePorDefecto: string): never {
    if (error instanceof ErrorValidacion) {
      throw new HttpException(fallo(error.message), HttpStatus.BAD_REQUEST);
    }
    if (error instanceof ErrorConflicto) {
      throw new HttpException(fallo(error.message), HttpStatus.CONFLICT);
    }
    if (error instanceof ErrorSesion) {
      throw new HttpException(fallo(error.message), HttpStatus.UNAUTHORIZED);
    }
    if (error instanceof ErrorConexion) {
      throw new HttpException(
        fallo(error.message),
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }

    throw new HttpException(
      fallo(mensajePorDefecto),
      HttpStatus.INTERNAL_SERVER_ERROR,
    );
  }
}
