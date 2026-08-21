import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../database/postgres';
import { compararContrasena, hashearContrasena } from '../helpers/contrasena';
import {
  ErrorConexion,
  ErrorConflicto,
  ErrorSesion,
  ErrorValidacion,
} from '../helpers/errores';
import { firmarToken } from '../helpers/token';
import { ExistenciaUsuario } from '../models/existencia-usuario';
import { LoginUsuarioPeticion } from '../models/login-usuario';
import {
  RegistroUsuarioPeticion,
  UsuarioRegistrado,
} from '../models/registro-usuario';
import { Usuario } from '../models/usuario';

// Catalogo rol_usuario: comprador se inserta primero en la migracion 001, y
// por eso su id es 1. Todo usuario nuevo entra como comprador; para vender
// hace falta otro paso que todavia no existe.
const ID_ROL_COMPRADOR = 1;

// Catalogo estado_usuario: activo se inserta primero en la migracion 001,
// por eso su id es 1. Una cuenta nueva entra activa de una vez.
const ID_ESTADO_ACTIVO = 1;

const REGEX_CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const REGEX_FECHA = /^\d{4}-\d{2}-\d{2}$/;

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
   * base y, si coinciden, firma un token de sesion.
   *
   * Lanza ErrorSesion tanto si el identificador no existe como si la
   * contrasena no coincide, y con el mismo mensaje en los dos casos: si se
   * distinguiera, cualquiera podria usar este endpoint para averiguar que
   * correos o usuarios estan registrados probando uno por uno.
   */
  async iniciarSesion(datos: LoginUsuarioPeticion): Promise<ResultadoLogin> {
    if (!this.esTextoNoVacio(datos.identificador)) {
      throw new ErrorValidacion(
        'El correo electronico o el usuario es obligatorio',
      );
    }
    if (!this.esTextoNoVacio(datos.contrasena)) {
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

    const coincide =
      fila != null &&
      (await compararContrasena(datos.contrasena, fila.contrasena_hash));

    if (!coincide) {
      throw new ErrorSesion(
        'Correo electronico, usuario o contrasena incorrectos',
      );
    }

    // A este punto TypeScript ya sabe que fila no es undefined: "coincide"
    // solo puede ser true si fila existe, y si no coincide ya se lanzo.
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
    if (!this.esTextoNoVacio(datos.correo_electronico)) {
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

    if (!this.esTextoNoVacio(datos.usuario)) {
      throw new ErrorValidacion('El usuario es obligatorio');
    }
    if (datos.usuario.length > 50) {
      throw new ErrorValidacion(
        'El usuario no puede tener mas de 50 caracteres',
      );
    }

    if (!this.esTextoNoVacio(datos.nombre)) {
      throw new ErrorValidacion('El nombre es obligatorio');
    }
    if (datos.nombre.length > 100) {
      throw new ErrorValidacion(
        'El nombre no puede tener mas de 100 caracteres',
      );
    }

    if (
      datos.apellido != null &&
      datos.apellido !== '' &&
      datos.apellido.length > 100
    ) {
      throw new ErrorValidacion(
        'El apellido no puede tener mas de 100 caracteres',
      );
    }

    if (!this.esTextoNoVacio(datos.contrasena)) {
      throw new ErrorValidacion('La contrasena es obligatoria');
    }
    if (datos.contrasena.length < 8) {
      throw new ErrorValidacion(
        'La contrasena debe tener al menos 8 caracteres',
      );
    }
    if (!/[A-Z]/.test(datos.contrasena)) {
      throw new ErrorValidacion(
        'La contrasena debe tener al menos una letra mayuscula',
      );
    }
    if (!/[^A-Za-z0-9]/.test(datos.contrasena)) {
      throw new ErrorValidacion(
        'La contrasena debe tener al menos un caracter especial',
      );
    }

    if (datos.fecha_nacimiento != null && datos.fecha_nacimiento !== '') {
      if (!REGEX_FECHA.test(datos.fecha_nacimiento)) {
        throw new ErrorValidacion(
          'La fecha de nacimiento debe tener el formato AAAA-MM-DD',
        );
      }
      if (Number.isNaN(Date.parse(datos.fecha_nacimiento))) {
        throw new ErrorValidacion('La fecha de nacimiento no es valida');
      }
      if (!this.esMayorDeEdad(datos.fecha_nacimiento)) {
        throw new ErrorValidacion('El usuario debe ser mayor de 18 anos');
      }
    }
  }

  /**
   * Le suma 18 anos a la fecha de nacimiento y compara contra hoy. Usar
   * setUTCFullYear en vez de restar anos a mano evita errores con anos
   * bisiestos: si nacio el 29 de febrero, Date ajusta sola la fecha limite.
   */
  private esMayorDeEdad(fechaNacimiento: string): boolean {
    const nacimiento = new Date(`${fechaNacimiento}T00:00:00Z`);
    const limite = new Date(nacimiento);
    limite.setUTCFullYear(limite.getUTCFullYear() + 18);
    return new Date() >= limite;
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
    const correoLimpio = this.esTextoNoVacio(correo) ? correo : null;
    const usuarioLimpio = this.esTextoNoVacio(usuario) ? usuario : null;

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

  private esTextoNoVacio(valor: unknown): valor is string {
    return typeof valor === 'string' && valor.trim().length > 0;
  }

  /**
   * Convierte cualquier error que venga de una consulta en el error de
   * dominio correcto, y lo deja logueado. Se llama desde cada catch que
   * envuelve un pool.query.
   *
   * 23505 es una violacion de restriccion unica: aunque comprobarDisponibilidad
   * ya reviso antes, dos peticiones pueden pasar esa comprobacion al mismo
   * tiempo, y la base de datos es la que de verdad lo impide.
   *
   * El resto de codigos de conexion (el pool no logra hablar con Postgres, o
   * las credenciales del backend estan mal) se agrupan en ErrorConexion: el
   * detalle tecnico se loguea, pero al cliente solo le interesa que la base
   * no esta disponible ahora mismo.
   */
  private manejarErrorBaseDatos(error: unknown): never {
    if (this.tieneCodigo(error, '23505')) {
      throw new ErrorConflicto(
        'El correo electronico o el usuario ya estan registrados',
      );
    }

    this.logger.error(this.describirError(error));

    if (this.esFalloDeConexion(error)) {
      throw new ErrorConexion('No se pudo conectar con PostgreSQL');
    }

    throw error;
  }

  private tieneCodigo(error: unknown, codigo: string): boolean {
    return (
      typeof error === 'object' &&
      error !== null &&
      (error as { code?: string }).code === codigo
    );
  }

  /**
   * 08*: clase de error de conexion de Postgres. 28P01: contrasena
   * incorrecta. 3D000: la base no existe. Los demas (ECONNREFUSED,
   * ETIMEDOUT, ENOTFOUND) los tira el driver, no Postgres, cuando ni
   * siquiera logra abrir el socket. AggregateError aparece cuando el driver
   * intenta varias direcciones y todas fallan.
   */
  private esFalloDeConexion(error: unknown): boolean {
    if (error instanceof AggregateError) {
      return true;
    }

    const codigo = (error as NodeJS.ErrnoException | undefined)?.code;
    if (!codigo) {
      return false;
    }

    return (
      codigo.startsWith('08') ||
      codigo === '28P01' ||
      codigo === '3D000' ||
      codigo === 'ECONNREFUSED' ||
      codigo === 'ETIMEDOUT' ||
      codigo === 'ENOTFOUND'
    );
  }

  /** Igual que en BaseDatosService: desempaqueta el error para el log. */
  private describirError(error: unknown): string {
    if (error instanceof AggregateError) {
      const causas = error.errors
        .map((e) => this.describirError(e))
        .filter(Boolean);
      return causas.join(' | ') || 'Error de conexion desconocido';
    }

    if (error instanceof Error) {
      const codigo = (error as NodeJS.ErrnoException).code;
      return codigo ? `${codigo}: ${error.message}` : error.message;
    }
    return String(error);
  }
}
