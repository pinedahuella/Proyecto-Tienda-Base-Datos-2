import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../database/postgres';
import { hashearContrasena } from '../helpers/contrasena';
import {
  ErrorConexion,
  ErrorConflicto,
  ErrorValidacion,
} from '../helpers/errores';
import { ExistenciaUsuario } from '../models/existencia-usuario';
import {
  RegistroUsuarioPeticion,
  UsuarioRegistrado,
} from '../models/registro-usuario';

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

/**
 * Servicio de las rutas /usuario.
 *
 * POST /usuario/registro valida los datos, comprueba que el correo y el
 * usuario no esten repetidos, hashea la contrasena y crea la fila en
 * usuarios. GET /usuario/registros-existentes hace esa misma comprobacion
 * de disponibilidad, pero sola, para que el frontend la use mientras el
 * usuario todavia esta llenando el formulario.
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
