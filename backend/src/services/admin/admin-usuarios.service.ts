import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { ErrorNoEncontrado, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import {
  validarApellido,
  validarFechaNacimiento,
  validarNombre,
} from '../../helpers/validaciones-perfil';
import { EditarUsuarioAdminPeticion } from '../../dto/editar-usuario-admin';
import { UsuarioRegistrado } from '../../dto/registro-usuario';

const REGEX_ID = /^\d+$/;

/**
 * Servicio de las rutas /admin/usuarios.
 *
 * Separado de UsuarioService a proposito: ese sirve al propio usuario
 * (registrarse, loguearse, ver su propio perfil), este sirve a un admin
 * viendo o gestionando las cuentas de los demas. Son casos de uso
 * distintos aunque lean de la misma tabla.
 */
@Injectable()
export class AdminUsuariosService {
  private readonly logger = new Logger(AdminUsuariosService.name);

  /**
   * Trae todos los usuarios menos el que esta haciendo la peticion: un
   * admin no necesita verse a si mismo en su propio listado de cuentas.
   *
   * No filtra por estado a proposito: un admin necesita ver tambien las
   * cuentas inactivas o suspendidas para poder gestionarlas.
   */
  async listar(idExcluido: string): Promise<UsuarioRegistrado[]> {
    try {
      const resultado = await pool.query<UsuarioRegistrado>(
        `SELECT id_usuario, correo_electronico, usuario, nombre, apellido,
                fecha_nacimiento, fecha_creacion, id_rol_usuario,
                id_estado_usuario
         FROM usuarios
         WHERE id_usuario != $1
         ORDER BY fecha_creacion DESC`,
        [idExcluido],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Actualiza nombre, apellido, fecha_nacimiento, rol y/o estado de un
   * usuario. Cada campo es independiente: el que venga en null (o no
   * venga) se queda igual que estaba, no se toca.
   *
   * nombre, apellido y fecha_nacimiento usan las mismas reglas que el
   * registro (validarNombre, validarApellido, validarFechaNacimiento), para
   * que un mismo dato nunca sea valido al registrarse e invalido al
   * editarlo despues, o al reves. id_rol_usuario e id_estado_usuario se
   * revisan contra sus catalogos (rol_usuario, estado_usuario): un id que
   * no existe ahi no sirve.
   *
   * Lanza ErrorValidacion si no viene ningun campo, si algun campo no pasa
   * su regla, si el id no tiene forma de id, o si el admin se esta
   * apuntando a si mismo. Lanza ErrorNoEncontrado si no existe un usuario
   * con ese id.
   */
  async actualizar(
    idUsuario: string,
    cambios: EditarUsuarioAdminPeticion,
    idQuienEdita: string,
  ): Promise<UsuarioRegistrado> {
    if (!REGEX_ID.test(idUsuario)) {
      throw new ErrorValidacion('El id no es valido');
    }

    if (idUsuario === idQuienEdita) {
      throw new ErrorValidacion('No puedes editar tu propia cuenta desde aqui');
    }

    const nombre = cambios.nombre ?? null;
    const apellido = cambios.apellido ?? null;
    const fechaNacimiento = cambios.fecha_nacimiento ?? null;
    const idRolUsuario = cambios.id_rol_usuario ?? null;
    const idEstadoUsuario = cambios.id_estado_usuario ?? null;

    if (
      nombre == null &&
      apellido == null &&
      fechaNacimiento == null &&
      idRolUsuario == null &&
      idEstadoUsuario == null
    ) {
      throw new ErrorValidacion(
        'Debes enviar al menos un campo para actualizar',
      );
    }

    if (nombre != null) {
      validarNombre(nombre);
    }
    validarApellido(apellido);
    validarFechaNacimiento(fechaNacimiento);

    if (idRolUsuario != null && !(await this.idRolValido(idRolUsuario))) {
      throw new ErrorValidacion('El rol no es valido');
    }
    if (
      idEstadoUsuario != null &&
      !(await this.idEstadoValido(idEstadoUsuario))
    ) {
      throw new ErrorValidacion('El estado no es valido');
    }

    let fila: UsuarioRegistrado | undefined;
    try {
      const resultado = await pool.query<UsuarioRegistrado>(
        `UPDATE usuarios
         SET nombre = COALESCE($1, nombre),
             apellido = COALESCE($2, apellido),
             fecha_nacimiento = COALESCE($3, fecha_nacimiento),
             id_rol_usuario = COALESCE($4, id_rol_usuario),
             id_estado_usuario = COALESCE($5, id_estado_usuario)
         WHERE id_usuario = $6
         RETURNING id_usuario, correo_electronico, usuario, nombre, apellido,
                   fecha_nacimiento, fecha_creacion, id_rol_usuario,
                   id_estado_usuario`,
        [
          nombre,
          apellido,
          fechaNacimiento,
          idRolUsuario,
          idEstadoUsuario,
          idUsuario,
        ],
      );
      fila = resultado.rows[0];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (fila == null) {
      throw new ErrorNoEncontrado('No existe un usuario con ese id');
    }

    return fila;
  }

  private async idRolValido(id: number): Promise<boolean> {
    try {
      const resultado = await pool.query(
        'SELECT 1 FROM rol_usuario WHERE id_rol_usuario = $1',
        [id],
      );
      return resultado.rows.length > 0;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async idEstadoValido(id: number): Promise<boolean> {
    try {
      const resultado = await pool.query(
        'SELECT 1 FROM estado_usuario WHERE id_estado_usuario = $1',
        [id],
      );
      return resultado.rows.length > 0;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}
