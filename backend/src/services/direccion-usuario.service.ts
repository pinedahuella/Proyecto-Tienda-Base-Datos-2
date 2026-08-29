import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../database/postgres';
import { ErrorNoEncontrado, ErrorValidacion } from '../helpers/errores';
import { manejarErrorConexion } from '../helpers/manejar-error-db';
import {
  validarCiudad,
  validarCodigoPostal,
  validarDepartamento,
  validarDireccionExacta,
  validarFechaHistorial,
  validarPais,
} from '../helpers/validaciones-direccion';
import { esTextoNoVacio } from '../helpers/validaciones-perfil';
import { CrearDireccionPeticion } from '../dto/crear-direccion';
import { DireccionConHistorial } from '../dto/direccion-con-historial';
import { EditarDireccionPeticion } from '../dto/editar-direccion';
import { Direccion } from '../models/direccion';
import { DireccionHistorial } from '../models/direccion-historial';
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
    validarDireccionExacta(datos.direccion_exacta);
    validarCodigoPostal(datos.codigo_postal);

    const codigoPostal = esTextoNoVacio(datos.codigo_postal)
      ? datos.codigo_postal
      : null;

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const resultado = await cliente.query<Direccion>(
        `INSERT INTO direcciones
           (id_usuario, pais, departamento, ciudad, direccion_exacta, codigo_postal, id_estado_direccion)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id_direccion, id_usuario, pais, departamento, ciudad,
                   direccion_exacta, codigo_postal, fecha_creacion, id_estado_direccion`,
        [
          idUsuario,
          datos.pais,
          datos.departamento,
          datos.ciudad,
          datos.direccion_exacta,
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
   * Edita pais, departamento, ciudad, direccion_exacta y/o codigo_postal de
   * una direccion del usuario logueado. Cada campo es independiente: el que
   * venga en null (o no venga) se queda igual que estaba. Debe venir al
   * menos uno.
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
    const direccionExacta = cambios.direccion_exacta ?? null;
    const codigoPostal = cambios.codigo_postal ?? null;

    if (
      pais == null &&
      departamento == null &&
      ciudad == null &&
      direccionExacta == null &&
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
    if (direccionExacta != null) {
      validarDireccionExacta(direccionExacta);
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
             direccion_exacta = COALESCE($4, direccion_exacta),
             codigo_postal = COALESCE($5, codigo_postal)
         WHERE id_direccion = $6 AND id_usuario = $7
         RETURNING id_direccion, id_usuario, pais, departamento, ciudad,
                   direccion_exacta, codigo_postal, fecha_creacion, id_estado_direccion`,
        [
          pais,
          departamento,
          ciudad,
          direccionExacta,
          codigoPostal,
          idDireccion,
          idUsuario,
        ],
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

  /**
   * Lista las direcciones vigentes del usuario logueado. Solo las suyas: el
   * WHERE exige ese id_usuario, asi que no hay forma de traer direcciones de
   * otra persona.
   */
  async listar(idUsuario: string): Promise<Direccion[]> {
    try {
      const resultado = await pool.query<Direccion>(
        `SELECT id_direccion, id_usuario, pais, departamento, ciudad,
                direccion_exacta, codigo_postal, fecha_creacion, id_estado_direccion
         FROM direcciones
         WHERE id_usuario = $1
         ORDER BY fecha_creacion DESC`,
        [idUsuario],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Trae una direccion del usuario logueado con todo su historial de
   * cambios (mas reciente primero). Solo si es suya: el WHERE de la
   * direccion exige ese id_usuario, asi que la de otra persona da el mismo
   * ErrorNoEncontrado que un id que no existe.
   */
  async obtenerConHistorial(
    idDireccion: string,
    idUsuario: string,
  ): Promise<DireccionConHistorial> {
    if (!REGEX_ID.test(idDireccion)) {
      throw new ErrorValidacion('El id no es valido');
    }

    try {
      const resultadoDireccion = await pool.query<Direccion>(
        `SELECT id_direccion, id_usuario, pais, departamento, ciudad,
                direccion_exacta, codigo_postal, fecha_creacion, id_estado_direccion
         FROM direcciones
         WHERE id_direccion = $1 AND id_usuario = $2`,
        [idDireccion, idUsuario],
      );
      const direccion = resultadoDireccion.rows[0];

      if (direccion == null) {
        throw new ErrorNoEncontrado('No existe una direccion con ese id');
      }

      const resultadoHistorial = await pool.query<DireccionHistorial>(
        `SELECT id_direccion_historial, id_direccion, pais, departamento,
                ciudad, direccion_exacta, codigo_postal, fecha_creacion
         FROM direccion_historial
         WHERE id_direccion = $1
         ORDER BY fecha_creacion DESC`,
        [idDireccion],
      );

      return { direccion, historial: resultadoHistorial.rows };
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Reconstruye como estaban las direcciones del usuario logueado en una
   * fecha especifica: para cada una, la version de direccion_historial mas
   * reciente que ya regia ese dia (DISTINCT ON se queda con la primera fila
   * de cada id_direccion, y el ORDER BY deja esa fila como la mas reciente).
   * Si una direccion se creo despues de esa fecha, no sale: todavia no
   * existia.
   *
   * Solo las suyas: el JOIN exige que la direccion sea de ese id_usuario.
   */
  async obtenerHistorial(
    idUsuario: string,
    fecha: string | undefined,
  ): Promise<DireccionHistorial[]> {
    validarFechaHistorial(fecha);

    try {
      const resultado = await pool.query<DireccionHistorial>(
        `SELECT DISTINCT ON (dh.id_direccion)
                dh.id_direccion_historial, dh.id_direccion, dh.pais,
                dh.departamento, dh.ciudad, dh.direccion_exacta,
                dh.codigo_postal, dh.fecha_creacion
         FROM direccion_historial dh
         JOIN direcciones d ON d.id_direccion = dh.id_direccion
         WHERE d.id_usuario = $1
           AND dh.fecha_creacion < ($2::date + interval '1 day')
         ORDER BY dh.id_direccion, dh.fecha_creacion DESC`,
        [idUsuario, fecha],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** Agrega una fila a direccion_historial con el estado actual de la direccion. */
  private async guardarSnapshot(
    cliente: PoolClient,
    direccion: Direccion,
  ): Promise<void> {
    await cliente.query(
      `INSERT INTO direccion_historial
         (id_direccion, pais, departamento, ciudad, direccion_exacta, codigo_postal)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [
        direccion.id_direccion,
        direccion.pais,
        direccion.departamento,
        direccion.ciudad,
        direccion.direccion_exacta,
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
