import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../database/postgres';
import { compararContrasena, hashearContrasena } from '../helpers/contrasena';
import {
  ErrorConflicto,
  ErrorInicioSesion,
  ErrorSesion,
  ErrorValidacion,
} from '../helpers/errores';
import { manejarErrorConexion } from '../helpers/manejar-error-db';
import { firmarToken } from '../helpers/token';
import {
  esTextoNoVacio,
  validarApellido,
  validarContrasena,
  validarFechaNacimiento,
  validarNombre,
} from '../helpers/validaciones-perfil';
import { ExistenciaUsuario } from '../dto/existencia-usuario';
import { LoginUsuarioPeticion } from '../dto/login-usuario';
import {
  RegistroUsuarioPeticion,
  UsuarioRegistrado,
} from '../dto/registro-usuario';
import { Usuario } from '../models/usuario';
import { ID_ROL_COMPRADOR } from '../models/rol-usuario';
import { ID_ESTADO_ACTIVO } from '../models/estado-usuario';

const REGEX_CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

interface FilaExistente {
  correo_electronico: string;
  usuario: string;
}

interface ResultadoLogin {
  usuario: UsuarioRegistrado;
  token: string;
}

/**
 * Servicio de las rutas /usuario.
 *
 * POST /usuario/registro valida los datos, comprueba que el correo y el
 * usuario no esten repetidos, hashea la contrasena y crea la fila en
 * usuarios. GET /usuario/registros-existentes hace esa misma comprobacion
 * de disponibilidad, pero sola, para que el frontend la use mientras el
 * usuario todavia esta llenando el formulario. POST /usuario/login revisa
 * el correo y la contrasena contra lo guardado y, si coinciden, firma el
 * token de sesion. GET /usuario/yo trae el perfil completo a partir del id
 * que ya vino verificado en el token (lo pone ahi SesionGuard).
 *
 * POST /usuario/logout no usa este servicio: borrar la cookie no necesita
 * tocar la base de datos, asi que esa ruta vive entera en el controller.
 */
@Injectable()
export class UsuarioService {
  private readonly logger = new Logger(UsuarioService.name);

  /**
   * Registra un usuario nuevo.
   *
   * Lanza ErrorValidacion si los datos no sirven y ErrorConflicto si el
   * correo o el usuario ya existen. El controlador convierte cada uno en su
   * codigo HTTP.
   */
  async registrar(datos: RegistroUsuarioPeticion): Promise<UsuarioRegistrado> {
    this.validar(datos);
    await this.comprobarDisponibilidad(datos);

    const contrasenaHash = await hashearContrasena(datos.contrasena);

    try {
      const resultado = await pool.query<UsuarioRegistrado>(
        `INSERT INTO usuarios
           (correo_electronico, usuario, nombre, apellido, contrasena_hash,
            fecha_nacimiento, id_rol_usuario, id_estado_usuario)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING id_usuario, correo_electronico, usuario, nombre, apellido,
                   fecha_nacimiento, fecha_creacion, id_rol_usuario,
                   id_estado_usuario`,
        [
          datos.correo_electronico,
          datos.usuario,
          datos.nombre,
          datos.apellido ?? null,
          contrasenaHash,
          datos.fecha_nacimiento ?? null,
          ID_ROL_COMPRADOR,
          ID_ESTADO_ACTIVO,
        ],
      );

      return resultado.rows[0];
    } catch (error) {
      this.manejarErrorBaseDatos(error);
    }
  }

  /**
   * Revisa el identificador (correo o usuario) y la contrasena contra la
   * base y, si coinciden y la cuenta esta activa, firma un token de sesion.
   *
   * Lanza ErrorInicioSesion, con el mismo mensaje en los tres casos, si el
   * identificador no existe, si la contrasena no coincide, o si la cuenta no
   * esta activa. Es a proposito que las tres den el mismo mensaje: si la
   * cuenta suspendida dijera algo distinto, cualquiera podria usar este
   * endpoint para confirmar la contrasena de una cuenta que no puede usar,
   * probando contrasenas hasta que el mensaje cambiara. El `motivo` real (y
   * el id de la cuenta, si se conoce) viaja dentro del error solo para el
   * log de seguridad, nunca a la respuesta HTTP.
   */
  async iniciarSesion(datos: LoginUsuarioPeticion): Promise<ResultadoLogin> {
    if (!esTextoNoVacio(datos.identificador)) {
      throw new ErrorValidacion(
        'El correo electronico o el usuario es obligatorio',
      );
    }
    if (!esTextoNoVacio(datos.contrasena)) {
      throw new ErrorValidacion('La contrasena es obligatoria');
    }

    let fila: Usuario | undefined;
    try {
      const resultado = await pool.query<Usuario>(
        `SELECT id_usuario, correo_electronico, usuario, nombre, apellido,
                contrasena_hash, fecha_nacimiento, fecha_creacion,
                id_rol_usuario, id_estado_usuario
         FROM usuarios
         WHERE correo_electronico = $1 OR usuario = $1`,
        [datos.identificador],
      );
      fila = resultado.rows[0];
    } catch (error) {
      this.manejarErrorBaseDatos(error);
    }

    // Si no hay cuenta con ese identificador se corta aqui, antes de gastar
    // el compararContrasena (bcrypt): mismo comportamiento de siempre, y de
    // paso TypeScript ya sabe que fila no es undefined mas abajo.
    if (fila == null) {
      throw new ErrorInicioSesion('usuario_inexistente');
    }

    const contrasenaCoincide = await compararContrasena(
      datos.contrasena,
      fila.contrasena_hash,
    );
    if (!contrasenaCoincide) {
      throw new ErrorInicioSesion('credenciales_invalidas', fila.id_usuario);
    }

    if (fila.id_estado_usuario !== ID_ESTADO_ACTIVO) {
      throw new ErrorInicioSesion('cuenta_inactiva', fila.id_usuario);
    }

    const usuario = fila;

    const token = await firmarToken({
      id_usuario: usuario.id_usuario,
      id_rol_usuario: usuario.id_rol_usuario,
    });

    return { usuario: this.aUsuarioRegistrado(usuario), token };
  }

  /**
   * Trae el perfil completo a partir del id que vino en el token. La usa
   * GET /usuario/yo, ya detras de SesionGuard.
   *
   * Si el id no existe (la cuenta se borro despues de firmar el token, algo
   * raro pero posible) se trata igual que un token invalido: la sesion ya
   * no sirve.
   */
  async obtenerPorId(idUsuario: string): Promise<UsuarioRegistrado> {
    let fila: Usuario | undefined;
    try {
      const resultado = await pool.query<Usuario>(
        `SELECT id_usuario, correo_electronico, usuario, nombre, apellido,
                contrasena_hash, fecha_nacimiento, fecha_creacion,
                id_rol_usuario, id_estado_usuario
         FROM usuarios
         WHERE id_usuario = $1`,
        [idUsuario],
      );
      fila = resultado.rows[0];
    } catch (error) {
      this.manejarErrorBaseDatos(error);
    }

    if (fila == null) {
      throw new ErrorSesion('Token invalido o expirado');
    }

    return this.aUsuarioRegistrado(fila);
  }

  /**
   * Dice si la cuenta sigue activa ahora mismo. La usa SesionGuard en cada
   * peticion protegida, no solo en el login: el token es valido por 2 horas
   * sin importar lo que pase con la cuenta mientras tanto, asi que si a
   * alguien lo suspenden a mitad de esas 2 horas, su token seguiria
   * pasando la verificacion de firma. Esta consulta es la unica forma de
   * cortarlo antes de que expire solo.
   */
  async estaActivo(idUsuario: string): Promise<boolean> {
    let fila: { id_estado_usuario: number } | undefined;
    try {
      const resultado = await pool.query<{ id_estado_usuario: number }>(
        'SELECT id_estado_usuario FROM usuarios WHERE id_usuario = $1',
        [idUsuario],
      );
      fila = resultado.rows[0];
    } catch (error) {
      this.manejarErrorBaseDatos(error);
    }

    return fila != null && fila.id_estado_usuario === ID_ESTADO_ACTIVO;
  }

  /** Quita el hash de la contrasena antes de mandar el usuario para afuera. */
  private aUsuarioRegistrado(fila: Usuario): UsuarioRegistrado {
    return {
      id_usuario: fila.id_usuario,
      correo_electronico: fila.correo_electronico,
      usuario: fila.usuario,
      nombre: fila.nombre,
      apellido: fila.apellido,
      fecha_nacimiento: fila.fecha_nacimiento,
      fecha_creacion: fila.fecha_creacion,
      id_rol_usuario: fila.id_rol_usuario,
      id_estado_usuario: fila.id_estado_usuario,
    };
  }

  /** Revisa presencia, tipo y formato de cada campo. */
  private validar(datos: RegistroUsuarioPeticion): void {
    if (!esTextoNoVacio(datos.correo_electronico)) {
      throw new ErrorValidacion('El correo electronico es obligatorio');
    }
    if (datos.correo_electronico.length > 255) {
      throw new ErrorValidacion(
        'El correo electronico no puede tener mas de 255 caracteres',
      );
    }
    if (!REGEX_CORREO.test(datos.correo_electronico)) {
      throw new ErrorValidacion('El correo electronico no es valido');
    }

    if (!esTextoNoVacio(datos.usuario)) {
      throw new ErrorValidacion('El usuario es obligatorio');
    }
    if (datos.usuario.length > 50) {
      throw new ErrorValidacion(
        'El usuario no puede tener mas de 50 caracteres',
      );
    }

    validarNombre(datos.nombre);
    validarApellido(datos.apellido);

    validarContrasena(datos.contrasena);
    validarFechaNacimiento(datos.fecha_nacimiento);
  }

  /** Busca si el correo o el usuario ya estan tomados y dice cual. */
  private async comprobarDisponibilidad(
    datos: RegistroUsuarioPeticion,
  ): Promise<void> {
    const filas = await this.buscarExistentes(
      datos.correo_electronico,
      datos.usuario,
    );

    const correoTomado = filas.some(
      (fila) => fila.correo_electronico === datos.correo_electronico,
    );
    const usuarioTomado = filas.some((fila) => fila.usuario === datos.usuario);

    if (correoTomado && usuarioTomado) {
      throw new ErrorConflicto(
        'El correo electronico y el usuario ya estan registrados',
      );
    }
    if (correoTomado) {
      throw new ErrorConflicto('El correo electronico ya esta registrado');
    }
    if (usuarioTomado) {
      throw new ErrorConflicto('El usuario ya esta registrado');
    }
  }

  /**
   * Dice si un correo y/o un usuario ya estan registrados, sin bloquear
   * nada. Pensada para que el frontend la llame mientras se llena el
   * formulario, antes de mandar el POST de registro.
   *
   * Al menos uno de los dos parametros debe venir, si no no hay nada que
   * consultar.
   */
  async verificarExistencia(
    correo?: string,
    usuario?: string,
  ): Promise<ExistenciaUsuario> {
    const correoLimpio = esTextoNoVacio(correo) ? correo : null;
    const usuarioLimpio = esTextoNoVacio(usuario) ? usuario : null;

    if (correoLimpio == null && usuarioLimpio == null) {
      throw new ErrorValidacion(
        'Debes indicar un correo electronico o un usuario a verificar',
      );
    }

    const filas = await this.buscarExistentes(correoLimpio, usuarioLimpio);

    return {
      correo_existente:
        correoLimpio != null &&
        filas.some((fila) => fila.correo_electronico === correoLimpio),
      usuario_existente:
        usuarioLimpio != null &&
        filas.some((fila) => fila.usuario === usuarioLimpio),
    };
  }

  /**
   * Trae las filas de usuarios cuyo correo o usuario coincidan con lo que se
   * pase. Un parametro en null se ignora: no compara contra NULL, esa mitad
   * del OR simplemente no aplica.
   */
  private async buscarExistentes(
    correo: string | null,
    usuario: string | null,
  ): Promise<FilaExistente[]> {
    try {
      const resultado = await pool.query<FilaExistente>(
        `SELECT correo_electronico, usuario FROM usuarios
         WHERE ($1::text IS NOT NULL AND correo_electronico = $1)
            OR ($2::text IS NOT NULL AND usuario = $2)`,
        [correo, usuario],
      );
      return resultado.rows;
    } catch (error) {
      this.manejarErrorBaseDatos(error);
    }
  }

  /**
   * Convierte cualquier error que venga de una consulta en el error de
   * dominio correcto. Se llama desde cada catch que envuelve un pool.query.
   *
   * 23505 es una violacion de restriccion unica: aunque comprobarDisponibilidad
   * ya reviso antes, dos peticiones pueden pasar esa comprobacion al mismo
   * tiempo, y la base de datos es la que de verdad lo impide. Es especifico
   * de este servicio (nace de un INSERT en usuarios), por eso se revisa
   * aqui y no en el helper compartido. Todo lo demas (conexion, y loguear
   * el detalle tecnico) lo resuelve manejarErrorConexion.
   */
  private manejarErrorBaseDatos(error: unknown): never {
    if (this.tieneCodigo(error, '23505')) {
      throw new ErrorConflicto(
        'El correo electronico o el usuario ya estan registrados',
      );
    }

    manejarErrorConexion(this.logger, error);
  }

  private tieneCodigo(error: unknown, codigo: string): boolean {
    return (
      typeof error === 'object' &&
      error !== null &&
      (error as { code?: string }).code === codigo
    );
  }
}
