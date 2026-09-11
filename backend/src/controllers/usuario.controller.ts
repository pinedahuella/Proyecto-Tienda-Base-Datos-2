import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { UsuarioActual } from '../decorators/usuario-actual.decorator';
import { SesionGuard } from '../guards/sesion.guard';
import { exito } from '../helpers/respuesta';
import { manejarErrorHttp } from '../helpers/manejar-error-http';
import {
  contextoDePeticion,
  type ContextoPeticion,
} from '../helpers/contexto-peticion';
import { ErrorInicioSesion, ErrorValidacion } from '../helpers/errores';
import {
  NOMBRE_COOKIE_TOKEN,
  OPCIONES_COOKIE_TOKEN,
  verificarToken,
} from '../helpers/token';
import type { LoginUsuarioPeticion } from '../dto/login-usuario';
import type { RegistroUsuarioPeticion } from '../dto/registro-usuario';
import type { TokenUsuario } from '../dto/token-usuario';
import { FraudeLoginService } from '../services/fraude-login/fraude-login.service';
import { LogService } from '../services/log.service';
import { UsuarioService } from '../services/usuario.service';

/**
 * Controlador de las rutas /usuario.
 *
 * El controlador no valida ni consulta nada: eso vive en UsuarioService.
 * Aqui solo se traduce lo que el servicio lanza a un codigo HTTP (con
 * manejarErrorHttp), es quien pone y borra la cookie del token (login y
 * logout), y quien deja el log de seguridad de cada registro, login y
 * logout (LogService -> coleccion eventos_autenticacion de Mongo).
 *
 * El log se llama SIN await a proposito: es best-effort y no debe retrasar
 * ni tumbar la respuesta (ver LogService). Cada intento de login (exito o
 * fallo) tambien se manda, igual sin await, a FraudeLoginService: contadores
 * de Redis que, si cruzan un umbral (fuerza bruta, multi-cuenta), dejan una
 * alerta en Postgres para que un admin la revise -- ver ese servicio.
 */
@Controller('usuario')
export class UsuarioController {
  constructor(
    private readonly usuarioService: UsuarioService,
    private readonly logService: LogService,
    private readonly fraudeLoginService: FraudeLoginService,
  ) {}

  // POST /usuario/registro
  @Post('registro')
  async registrar(
    @Body() cuerpo: RegistroUsuarioPeticion,
    @Req() request: FastifyRequest,
  ) {
    const contexto = contextoDePeticion(request);
    try {
      const usuario = await this.usuarioService.registrar(cuerpo);
      void this.logService.registrarRegistro(
        usuario.id_usuario,
        cuerpo?.correo_electronico ?? null,
        contexto,
      );
      return exito(usuario, 'Usuario registrado correctamente');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo registrar el usuario');
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
      manejarErrorHttp(error, 'No se pudo verificar el usuario');
    }
  }

  // POST /usuario/login
  // Nest manda 201 por defecto en todo @Post; aqui no se crea nada, asi que
  // el codigo correcto es 200.
  @Post('login')
  @HttpCode(HttpStatus.OK)
  async iniciarSesion(
    @Body() cuerpo: LoginUsuarioPeticion,
    @Req() request: FastifyRequest,
    @Res({ passthrough: true }) reply: FastifyReply,
  ) {
    // passthrough: true dice que este metodo no maneja la respuesta el
    // mismo (nada de reply.send): solo la usa para poner la cookie, y Nest
    // sigue encargandose de mandar lo que se retorne, igual que siempre.
    const contexto = contextoDePeticion(request);
    const identificador =
      typeof cuerpo?.identificador === 'string' ? cuerpo.identificador : null;
    try {
      const { usuario, token } =
        await this.usuarioService.iniciarSesion(cuerpo);
      reply.setCookie(NOMBRE_COOKIE_TOKEN, token, OPCIONES_COOKIE_TOKEN);
      void this.logService.registrarLoginExitoso(
        usuario.id_usuario,
        identificador,
        contexto,
      );
      void this.fraudeLoginService.registrarIntento({
        fallo: false,
        ip: contexto.ip,
        identificador,
        idUsuario: usuario.id_usuario,
      });
      return exito(usuario, 'Sesion iniciada correctamente');
    } catch (error) {
      this.registrarLoginFallido(error, identificador, contexto);
      manejarErrorHttp(error, 'No se pudo iniciar sesion');
    }
  }

  /**
   * Deja el evento de login fallido en el log de seguridad, clasificando el
   * motivo a partir del error que lanzo el servicio, y alimenta los
   * contadores de fraude con el mismo veredicto. Un ErrorInicioSesion ya
   * trae el motivo fino (y el id de la cuenta, si existe); una peticion sin
   * identificador o sin contrasena es un ErrorValidacion. Cualquier otra
   * cosa (Postgres caido, un 500) NO es un intento de login con veredicto,
   * asi que no se registra como evento de autenticacion ni cuenta para
   * fraude.
   */
  private registrarLoginFallido(
    error: unknown,
    identificador: string | null,
    contexto: ContextoPeticion,
  ): void {
    if (error instanceof ErrorInicioSesion) {
      void this.logService.registrarLoginFallido(
        error.motivo,
        error.idUsuario,
        identificador,
        contexto,
      );
      void this.fraudeLoginService.registrarIntento({
        fallo: true,
        ip: contexto.ip,
        identificador,
        idUsuario: error.idUsuario,
      });
      return;
    }
    if (error instanceof ErrorValidacion) {
      void this.logService.registrarLoginFallido(
        'datos_invalidos',
        null,
        identificador,
        contexto,
      );
      void this.fraudeLoginService.registrarIntento({
        fallo: true,
        ip: contexto.ip,
        identificador,
        idUsuario: null,
      });
    }
  }

  // POST /usuario/logout
  // Sin SesionGuard a proposito: cerrar sesion tiene que funcionar incluso
  // si el token ya vencio o vino mal. Siempre borra la cookie y responde
  // 200 igual; el intento de leer quien era (para el log) es aparte y no
  // cambia ese resultado.
  @Post('logout')
  @HttpCode(HttpStatus.OK)
  async cerrarSesion(
    @Req() request: FastifyRequest,
    @Res({ passthrough: true }) reply: FastifyReply,
  ) {
    const contexto = contextoDePeticion(request);
    const token = request.cookies[NOMBRE_COOKIE_TOKEN];
    if (token) {
      try {
        const usuario = await verificarToken(token);
        void this.logService.registrarLogout(usuario.id_usuario, contexto);
      } catch {
        // Token invalido o ya vencido: no hay a quien atribuirle el
        // logout, asi que no se guarda nada. No es un error de la
        // peticion, sigue cerrando sesion normal.
      }
    }

    reply.clearCookie(NOMBRE_COOKIE_TOKEN, {
      path: OPCIONES_COOKIE_TOKEN.path,
    });
    return exito(null, 'Sesion cerrada');
  }

  // GET /usuario/yo
  // Protegida: SesionGuard exige una cookie valida y una cuenta activa
  // antes de dejar pasar la peticion, y deja el usuario del token listo
  // para @UsuarioActual().
  @Get('yo')
  @UseGuards(SesionGuard)
  async obtenerYo(@UsuarioActual() usuarioToken: TokenUsuario) {
    try {
      const usuario = await this.usuarioService.obtenerPorId(
        usuarioToken.id_usuario,
      );
      return exito(usuario, 'Sesion activa');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el usuario');
    }
  }
}
