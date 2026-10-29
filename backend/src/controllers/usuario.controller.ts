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
import { Permiso } from '../decorators/permiso.decorator';
import { PermisoGuard } from '../guards/permiso.guard';
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
import { FraudeLoginRetrospectivoService } from '../services/fraude-login/fraude-login-retrospectivo.service';
import { TomaCuentaService } from '../services/fraude-login/toma-cuenta.service';
import { ViajeImposibleService } from '../services/fraude-login/viaje-imposible.service';
import { EventosAutenticacionSyncService } from '../services/eventos-autenticacion/eventos-autenticacion-sync.service';
import { LogService } from '../services/log.service';
import { PermisosService } from '../services/acl/permisos.service';
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
 * de Redis que, si cruzan un umbral (fuerza bruta, multi-cuenta, rotacion de
 * IP), dejan una alerta en Postgres para que un admin la revise -- ver ese
 * servicio. Un login EXITOSO ademas dispara, tambien sin await:
 * TomaCuentaService (compara la IP actual contra todo el historial de la
 * cuenta, no solo los ultimos minutos) y ViajeImposibleService (compara la
 * ubicacion del login actual contra el login exitoso inmediatamente
 * anterior, y marca si la velocidad implicita es mayor a la de un vuelo
 * comercial).
 *
 * Ademas, cada intento (exito o fallo) encadena -- tambien sin await, ver
 * `dispararRevisionElasticInmediata` -- la sincronizacion inmediata de ESE
 * evento a Elasticsearch y un chequeo acotado a esa cuenta/IP sobre las
 * mismas tres senales "lentas" que normalmente espera el worker de 15 min
 * (`FraudeLoginRetrospectivoService`): no reemplaza ese worker, solo evita
 * que haya que esperarlo para las senales que ya se pueden ver con el
 * historial de ESTE login.
 */
@Controller('usuario')
export class UsuarioController {
  constructor(
    private readonly usuarioService: UsuarioService,
    private readonly logService: LogService,
    private readonly fraudeLoginService: FraudeLoginService,
    private readonly fraudeLoginRetrospectivoService: FraudeLoginRetrospectivoService,
    private readonly tomaCuentaService: TomaCuentaService,
    private readonly viajeImposibleService: ViajeImposibleService,
    private readonly eventosAutenticacionSyncService: EventosAutenticacionSyncService,
    private readonly permisosService: PermisosService,
  ) {}

  /**
   * Encadena, sin bloquear nada, la sincronizacion inmediata del evento de
   * login recien escrito a Elasticsearch y el chequeo acotado a esa
   * cuenta/IP -- ver el comentario de clase. Se cuelga de la PROMESA del
   * log (no de `void`) porque el evento tiene que existir ya en Mongo
   * antes de poder sincronizarlo; la escritura del log en si no cambia de
   * comportamiento, solo se retiene su promesa para encadenar despues.
   */
  private dispararRevisionElasticInmediata(
    logPromesa: Promise<void>,
    identificador: string | null,
    ip: string | null,
    idUsuario: string | null,
  ): void {
    void logPromesa
      .then(() => this.eventosAutenticacionSyncService.sincronizarAhora())
      .then(() =>
        this.fraudeLoginRetrospectivoService.evaluarInmediato({
          identificador,
          ip,
          idUsuario,
        }),
      )
      .catch(() => {
        // Best-effort: ni sincronizarAhora() ni evaluarInmediato() deberian
        // lanzar (ambos ya atrapan sus propios errores), esto es solo un
        // respaldo para no dejar una promesa rechazada sin manejar.
      });
  }

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
      const logPromesa = this.logService.registrarLoginExitoso(
        usuario.id_usuario,
        identificador,
        contexto,
      );
      this.dispararRevisionElasticInmediata(
        logPromesa,
        identificador,
        contexto.ip,
        usuario.id_usuario,
      );
      void this.fraudeLoginService.registrarIntento({
        fallo: false,
        ip: contexto.ip,
        identificador,
        idUsuario: usuario.id_usuario,
      });
      void this.tomaCuentaService.revisarLogin({
        idUsuario: usuario.id_usuario,
        identificador,
        ip: contexto.ip,
        huellaCliente: contexto.huellaCliente,
      });
      void this.viajeImposibleService.revisarLogin({
        idUsuario: usuario.id_usuario,
        identificador,
        geo: contexto.geo,
        fecha: new Date(),
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
      const logPromesa = this.logService.registrarLoginFallido(
        error.motivo,
        error.idUsuario,
        identificador,
        contexto,
      );
      this.dispararRevisionElasticInmediata(
        logPromesa,
        identificador,
        contexto.ip,
        error.idUsuario,
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
      const logPromesa = this.logService.registrarLoginFallido(
        'datos_invalidos',
        null,
        identificador,
        contexto,
      );
      this.dispararRevisionElasticInmediata(
        logPromesa,
        identificador,
        contexto.ip,
        null,
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
  // para @UsuarioActual(). Suma `permisos`, los codigos del ACL de
  // funcionalidades que tiene su rol (migracion 050), para que el frontend
  // no ensene lo que el backend le va a negar.
  @Permiso('cuenta.ver')
  @Get('yo')
  @UseGuards(SesionGuard, PermisoGuard)
  async obtenerYo(@UsuarioActual() usuarioToken: TokenUsuario) {
    try {
      const [usuario, permisos] = await Promise.all([
        this.usuarioService.obtenerPorId(usuarioToken.id_usuario),
        this.permisosService.codigosDe(usuarioToken.id_rol_usuario),
      ]);
      return exito({ ...usuario, permisos }, 'Sesion activa');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo obtener el usuario');
    }
  }
}
