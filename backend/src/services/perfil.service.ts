import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../database/postgres';
import { compararContrasena, hashearContrasena } from '../helpers/contrasena';
import { ErrorSesion, ErrorValidacion } from '../helpers/errores';
import { manejarErrorConexion } from '../helpers/manejar-error-db';
import {
  esTextoNoVacio,
  validarApellido,
  validarContrasena,
  validarNombre,
} from '../helpers/validaciones-perfil';
import { CambiarContrasenaPeticion } from '../dto/cambiar-contrasena';
import { EditarPerfilPeticion } from '../dto/editar-perfil';
import { PerfilUsuario } from '../dto/perfil-usuario';

/**
 * Servicio de las rutas /perfil.
 *
 * Separado de UsuarioService a proposito: ese resuelve login, registro y
 * el "yo" liviano detras del token; este arma la vista completa del
 * perfil, cruzando usuarios con sus dos catalogos, y deja que el propio
 * usuario edite su nombre, apellido y contrasena.
 */
@Injectable()
export class PerfilService {
  private readonly logger = new Logger(PerfilService.name);

  /**
   * Trae el perfil del usuario, con el nombre de su rol y de su estado
   * ademas de los ids.
   *
   * Si el id no existe (la cuenta se borro despues de firmar el token) se
   * trata igual que un token invalido: la sesion ya no sirve. Mismo caso
   * que UsuarioService.obtenerPorId.
   */
  async obtener(idUsuario: string): Promise<PerfilUsuario> {
    let fila: PerfilUsuario | undefined;
    try {
      const resultado = await pool.query<PerfilUsuario>(
        `SELECT u.id_usuario, u.correo_electronico, u.usuario, u.nombre,
                u.apellido, u.fecha_nacimiento, u.fecha_creacion,
                u.id_rol_usuario, u.id_estado_usuario,
                r.rol_usuario_nombre, e.estado_usuario_nombre
         FROM usuarios u
         JOIN rol_usuario r ON r.id_rol_usuario = u.id_rol_usuario
         JOIN estado_usuario e ON e.id_estado_usuario = u.id_estado_usuario
         WHERE u.id_usuario = $1`,
        [idUsuario],
      );
      fila = resultado.rows[0];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (fila == null) {
      throw new ErrorSesion('Token invalido o expirado');
    }

    return fila;
  }

  /**
   * Deja que el usuario cambie su propio nombre y/o apellido. Cada uno es
   * independiente: el que venga en null (o no venga) se queda igual que
   * estaba. Debe venir al menos uno.
   *
   * Mismas reglas que en el registro (validarNombre, validarApellido): un
   * dato que se acepta al registrarse no puede rechazarse al editarlo
   * despues, ni al reves.
   */
  async actualizar(
    idUsuario: string,
    cambios: EditarPerfilPeticion,
  ): Promise<PerfilUsuario> {
    const nombre = cambios.nombre ?? null;
    const apellido = cambios.apellido ?? null;

    if (nombre == null && apellido == null) {
      throw new ErrorValidacion(
        'Debes enviar al menos un campo para actualizar',
      );
    }

    if (nombre != null) {
      validarNombre(nombre);
    }
    validarApellido(apellido);

    let fila: PerfilUsuario | undefined;
    try {
      const resultado = await pool.query<PerfilUsuario>(
        `WITH actualizado AS (
           UPDATE usuarios
           SET nombre = COALESCE($1, nombre),
               apellido = COALESCE($2, apellido)
           WHERE id_usuario = $3
           RETURNING id_usuario, correo_electronico, usuario, nombre,
                     apellido, fecha_nacimiento, fecha_creacion,
                     id_rol_usuario, id_estado_usuario
         )
         SELECT a.*, r.rol_usuario_nombre, e.estado_usuario_nombre
         FROM actualizado a
         JOIN rol_usuario r ON r.id_rol_usuario = a.id_rol_usuario
         JOIN estado_usuario e ON e.id_estado_usuario = a.id_estado_usuario`,
        [nombre, apellido, idUsuario],
      );
      fila = resultado.rows[0];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (fila == null) {
      throw new ErrorSesion('Token invalido o expirado');
    }

    return fila;
  }

  /**
   * Cambia la contrasena del usuario. Pide la actual (para confirmar que
   * es de verdad quien dice ser, no solo alguien con la sesion abierta en
   * una computadora que no es la suya) y la nueva dos veces, para agarrar
   * un error de tipeo antes de guardarla.
   *
   * La nueva contrasena sigue las mismas reglas que en el registro
   * (validarContrasena), y ademas tiene que ser distinta de la actual.
   *
   * Lanza ErrorValidacion si falta algun campo, si las dos nuevas no
   * coinciden, si la actual no es correcta, si la nueva es igual a la
   * actual, o si la nueva no cumple sus reglas.
   */
  async cambiarContrasena(
    idUsuario: string,
    datos: CambiarContrasenaPeticion,
  ): Promise<void> {
    if (!esTextoNoVacio(datos.contrasena_actual)) {
      throw new ErrorValidacion('La contrasena actual es obligatoria');
    }
    if (!esTextoNoVacio(datos.contrasena_nueva)) {
      throw new ErrorValidacion('La nueva contrasena es obligatoria');
    }
    if (!esTextoNoVacio(datos.contrasena_nueva_confirmacion)) {
      throw new ErrorValidacion(
        'La confirmacion de la nueva contrasena es obligatoria',
      );
    }
    if (datos.contrasena_nueva !== datos.contrasena_nueva_confirmacion) {
      throw new ErrorValidacion('Las contrasenas nuevas no coinciden');
    }

    let hashActual: string | undefined;
    try {
      const resultado = await pool.query<{ contrasena_hash: string }>(
        'SELECT contrasena_hash FROM usuarios WHERE id_usuario = $1',
        [idUsuario],
      );
      hashActual = resultado.rows[0]?.contrasena_hash;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (hashActual == null) {
      throw new ErrorSesion('Token invalido o expirado');
    }

    if (!(await compararContrasena(datos.contrasena_actual, hashActual))) {
      throw new ErrorValidacion('La contrasena actual no es correcta');
    }

    // Ya se confirmo que contrasena_actual es la de verdad, asi que
    // compararla como texto plano contra la nueva alcanza: no hace falta
    // otra vuelta de hashing solo para esta comparacion.
    if (datos.contrasena_nueva === datos.contrasena_actual) {
      throw new ErrorValidacion(
        'La nueva contrasena debe ser diferente a la actual',
      );
    }

    validarContrasena(datos.contrasena_nueva);

    const hashNuevo = await hashearContrasena(datos.contrasena_nueva);

    try {
      await pool.query(
        'UPDATE usuarios SET contrasena_hash = $1 WHERE id_usuario = $2',
        [hashNuevo, idUsuario],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}
