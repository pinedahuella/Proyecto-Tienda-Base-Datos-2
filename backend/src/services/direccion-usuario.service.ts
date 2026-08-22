import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../database/postgres';
import { ErrorNoEncontrado, ErrorValidacion } from '../helpers/errores';
import { manejarErrorConexion } from '../helpers/manejar-error-db';
import {
  validarCiudad,
  validarCodigoPostal,
  validarDepartamento,
  validarPais,
} from '../helpers/validaciones-direccion';
import { esTextoNoVacio } from '../helpers/validaciones-perfil';
import { CrearDireccionPeticion } from '../dto/crear-direccion';
import { EditarDireccionPeticion } from '../dto/editar-direccion';
import { Direccion } from '../models/direccion';
import { ID_ESTADO_DIRECCION_ACTIVA } from '../models/estado-direccion';

const REGEX_ID = /^\d+$/;

/**
 * Servicio de las rutas /direccion-usuario.
 *
 * Crear y editar una direccion siempre hacen dos cosas juntas: tocan la
 * fila vigente en direcciones, y agregan una version (el snapshot) en
 * direccion_historial. Van en una sola transaccion (BEGIN/COMMIT con un
 * cliente dedicado, no con pool.query) para que nunca quede una direccion
 * sin una version que la respalde: si el segundo paso fallara, el primero
 * tambien se deshace.
 */
@Injectable()
export class DireccionUsuarioService {
  private readonly logger = new Logger(DireccionUsuarioService.name);

  /**
   * Crea una direccion para el usuario logueado (el id sale del token, no
   * del cuerpo de la peticion), siempre con estado activa, y su primera
   * fila en direccion_historial.
   */
  async crear(
    idUsuario: string,
    datos: CrearDireccionPeticion,
  ): Promise<Direccion> {
    validarPais(datos.pais);
    validarDepartamento(datos.departamento);
    validarCiudad(datos.ciudad);
    validarCodigoPostal(datos.codigo_postal);

    const codigoPostal = esTextoNoVacio(datos.codigo_postal)
      ? datos.codigo_postal
      : null;

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const resultado = await cliente.query<Direccion>(
        `INSERT INTO direcciones
           (id_usuario, pais, departamento, ciudad, codigo_postal, id_estado_direccion)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id_direccion, id_usuario, pais, departamento, ciudad,
                   codigo_postal, fecha_creacion, id_estado_direccion`,
        [
          idUsuario,
          datos.pais,
          datos.departamento,
          datos.ciudad,
          codigoPostal,
          ID_ESTADO_DIRECCION_ACTIVA,
        ],
      );
      const direccion = resultado.rows[0];

      await this.guardarSnapshot(cliente, direccion);
      await cliente.query('COMMIT');
      return direccion;
    } catch (error) {
      await this.intentarRollback(cliente);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }

  /**
   * Edita pais, departamento, ciudad y/o codigo_postal de una direccion
   * del usuario logueado. Cada campo es independiente: el que venga en
   * null (o no venga) se queda igual que estaba. Debe venir al menos uno.
   *
   * Solo puede editar sus propias direcciones: el UPDATE exige que
   * id_direccion sea de ese id_usuario a la vez, asi que la direccion de
   * otro usuario da el mismo ErrorNoEncontrado que un id que no existe (no
   * hay forma de usar esta ruta para confirmar que direcciones tiene otra
   * persona).
   *
   * Deja una fila nueva en direccion_historial con los valores ya
   * actualizados (el estado completo de la direccion en ese momento, no
   * solo los campos que llegaron en la peticion).
   */
  async actualizar(
    idDireccion: string,
    idUsuario: string,
    cambios: EditarDireccionPeticion,
  ): Promise<Direccion> {
    if (!REGEX_ID.test(idDireccion)) {
      throw new ErrorValidacion('El id no es valido');
    }

    const pais = cambios.pais ?? null;
    const departamento = cambios.departamento ?? null;
    const ciudad = cambios.ciudad ?? null;
    const codigoPostal = cambios.codigo_postal ?? null;

    if (
      pais == null &&
      departamento == null &&
      ciudad == null &&
      codigoPostal == null
    ) {
      throw new ErrorValidacion(
        'Debes enviar al menos un campo para actualizar',
      );
    }

    if (pais != null) {
      validarPais(pais);
    }
    if (departamento != null) {
      validarDepartamento(departamento);
    }
    if (ciudad != null) {
      validarCiudad(ciudad);
    }
    validarCodigoPostal(codigoPostal);

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const resultado = await cliente.query<Direccion>(
        `UPDATE direcciones
         SET pais = COALESCE($1, pais),
             departamento = COALESCE($2, departamento),
             ciudad = COALESCE($3, ciudad),
             codigo_postal = COALESCE($4, codigo_postal)
         WHERE id_direccion = $5 AND id_usuario = $6
         RETURNING id_direccion, id_usuario, pais, departamento, ciudad,
                   codigo_postal, fecha_creacion, id_estado_direccion`,
        [pais, departamento, ciudad, codigoPostal, idDireccion, idUsuario],
      );
      const direccion = resultado.rows[0];

      if (direccion == null) {
        throw new ErrorNoEncontrado('No existe una direccion con ese id');
      }

      await this.guardarSnapshot(cliente, direccion);
      await cliente.query('COMMIT');
      return direccion;
    } catch (error) {
      await this.intentarRollback(cliente);
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }

  /** Agrega una fila a direccion_historial con el estado actual de la direccion. */
  private async guardarSnapshot(
    cliente: PoolClient,
    direccion: Direccion,
  ): Promise<void> {
    await cliente.query(
      `INSERT INTO direccion_historial
         (id_direccion, pais, departamento, ciudad, codigo_postal)
       VALUES ($1, $2, $3, $4, $5)`,
      [
        direccion.id_direccion,
        direccion.pais,
        direccion.departamento,
        direccion.ciudad,
        direccion.codigo_postal,
      ],
    );
  }

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo.
      // No hay nada mas que hacer; sigue el error original de quien llamo.
    }
  }
}
