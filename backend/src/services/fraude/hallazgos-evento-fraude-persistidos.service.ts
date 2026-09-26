import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { ErrorConflicto, ErrorNoEncontrado } from '../../helpers/errores';
import {
  validarFiltroEstadoAlerta,
  validarNuevoEstadoAlerta,
} from '../../helpers/validaciones-fraude';
import {
  validarFiltroTipoHallazgoEvento,
  validarIdHallazgoEventoFraude,
} from '../../helpers/validaciones-hallazgo-evento-fraude';
import {
  validarLimite,
  validarPagina,
} from '../../helpers/validaciones-productos';
import {
  ID_ESTADO_ALERTA_FRAUDE_DESCARTADA,
  ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
  ID_ESTADO_ALERTA_FRAUDE_REVISADA,
  EstadoAlertaFraude,
} from '../../models/alerta-fraude';
import {
  CuentaDeHallazgoEvento,
  HallazgoEventoFraude,
  TipoHallazgoEvento,
} from '../../models/hallazgo-evento-fraude';
import {
  HallazgosEventoFraudePaginados,
  PaginarHallazgosEventoFraudeQuery,
} from '../../dto/paginar-hallazgos-evento-fraude';

/**
 * Las cuentas del hallazgo, derivadas de `hallazgo_evento_fraude_cuenta` +
 * `usuarios` -- mismo patron que `SQL_CUENTAS_DE_ANILLO`
 * (`fraude-anillos-persistidos.service.ts`), mas simple: aqui la relacion
 * ya es directa (una tabla de pivote real), sin unir dos mitades por tipo.
 */
const SQL_CUENTAS_DE_HALLAZGO = `(
  SELECT COALESCE(json_agg(jsonb_build_object(
           'id_usuario', u.id_usuario::text, 'usuario', u.usuario,
           'es_nucleo', hc.es_nucleo
         ) ORDER BY u.usuario), '[]'::json)
    FROM hallazgo_evento_fraude_cuenta hc
    JOIN usuarios u ON u.id_usuario = hc.id_usuario
   WHERE hc.id_hallazgo_evento_fraude = h.id_hallazgo_evento_fraude
)`;

/**
 * `GET`/`PATCH /admin/fraude/alertas-eventos` -- el panel de admin sobre
 * `hallazgo_evento_fraude`/`hallazgo_evento_fraude_cuenta`
 * (`elementos Generales/plan pendiente/hallazgos-evento-fraude.sql`), los
 * hallazgos de F1-F6 que ya detecto y guardo
 * `HallazgosEventoFraudeDetectorService`. Nombrado en paralelo con
 * `alertas-login`/`alertas-resenas`: mismo sustantivo, distinto dominio.
 *
 * Sin ruta de "detalle" propia -- a diferencia de los anillos (que piden el
 * detalle real a Neo4j), toda la evidencia de un hallazgo de eventos ya
 * vive en Postgres (`detalle` jsonb + las cuentas del pivote), no hace
 * falta consultar otra base para ampliarla.
 */
@Injectable()
export class HallazgosEventoFraudePersistidosService {
  private readonly logger = new Logger(
    HallazgosEventoFraudePersistidosService.name,
  );

  // ---------------------------------------------------------------------
  // GET /admin/fraude/alertas-eventos
  // ---------------------------------------------------------------------

  async listarPaginado(
    query: PaginarHallazgosEventoFraudeQuery,
  ): Promise<HallazgosEventoFraudePaginados> {
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const estado = validarFiltroEstadoAlerta(query.estado);
    const tipo = validarFiltroTipoHallazgoEvento(query.tipo);
    const saltar = (pagina - 1) * limite;

    const { filas, total } = await this.consultarHallazgosPaginado(
      estado,
      tipo,
      limite,
      saltar,
    );
    const totalPaginas = total === 0 ? 0 : Math.ceil(total / limite);

    return {
      hallazgos: filas.map(aHallazgoEventoFraude),
      pagina,
      limite,
      total_hallazgos: total,
      total_paginas: totalPaginas,
    };
  }

  /**
   * Conteo + pagina en la misma transaccion REPEATABLE READ de solo
   * lectura -- mismo patron que `FraudeAnillosPersistidosService
   * .consultarAnillosPaginado`. `estado`/`tipo` ya vinieron validados
   * contra sus listas cerradas, por eso se interpolan tal cual.
   */
  private async consultarHallazgosPaginado(
    estado: EstadoAlertaFraude | null,
    tipo: TipoHallazgoEvento | null,
    limite: number,
    saltar: number,
  ): Promise<{ filas: FilaHallazgoEventoFraude[]; total: number }> {
    const condicionEstado =
      estado === null
        ? ''
        : `AND eaf.estado_alerta_fraude_nombre = '${estado}'`;
    const condicionTipo =
      tipo === null ? '' : `AND the.tipo_hallazgo_evento_nombre = '${tipo}'`;

    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM hallazgo_evento_fraude h
           JOIN tipo_hallazgo_evento the
             ON the.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
           JOIN estado_alerta_fraude eaf
             ON eaf.id_estado_alerta_fraude = h.id_estado_alerta_fraude
          WHERE true ${condicionEstado} ${condicionTipo}`,
      );

      const pagina = await cliente.query<FilaHallazgoEventoFraude>(
        `SELECT h.id_hallazgo_evento_fraude,
                the.tipo_hallazgo_evento_nombre AS tipo,
                h.clave, ${SQL_CUENTAS_DE_HALLAZGO} AS cuentas,
                h.id_producto_mongo, h.detalle, h.contador, h.ventana_inicio,
                eaf.estado_alerta_fraude_nombre AS estado,
                h.fecha_creacion, h.fecha_actualizacion
           FROM hallazgo_evento_fraude h
           JOIN tipo_hallazgo_evento the
             ON the.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
           JOIN estado_alerta_fraude eaf
             ON eaf.id_estado_alerta_fraude = h.id_estado_alerta_fraude
          WHERE true ${condicionEstado} ${condicionTipo}
          ORDER BY h.fecha_actualizacion DESC, h.id_hallazgo_evento_fraude DESC
          LIMIT $1 OFFSET $2`,
        [limite, saltar],
      );

      await cliente.query('COMMIT');
      return { filas: pagina.rows, total: Number(conteo.rows[0].total) };
    } catch (error) {
      await this.intentarRollback(cliente);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo. No
      // hay nada mas que hacer; sigue el error original de quien llamo.
    }
  }

  // ---------------------------------------------------------------------
  // PATCH /admin/fraude/alertas-eventos/:id
  // ---------------------------------------------------------------------

  /**
   * Marca un hallazgo revisado/descartado -- solo si esta `pendiente`,
   * mismo criterio que `FraudeAnillosPersistidosService.marcarAnillo`: uno
   * ya revisado o descartado no se reabre desde esta ruta.
   */
  async marcarHallazgo(
    idHallazgoParametro: string,
    estadoSolicitado: string | undefined,
  ): Promise<HallazgoEventoFraude> {
    const id = validarIdHallazgoEventoFraude(idHallazgoParametro);
    const nuevoEstado = validarNuevoEstadoAlerta(estadoSolicitado);
    const idEstadoDestino =
      nuevoEstado === 'revisada'
        ? ID_ESTADO_ALERTA_FRAUDE_REVISADA
        : ID_ESTADO_ALERTA_FRAUDE_DESCARTADA;

    let actualizado;
    try {
      actualizado = await pool.query(
        `UPDATE hallazgo_evento_fraude
            SET id_estado_alerta_fraude = $2, fecha_actualizacion = now()
          WHERE id_hallazgo_evento_fraude = $1
            AND id_estado_alerta_fraude = $3
          RETURNING id_hallazgo_evento_fraude`,
        [id, idEstadoDestino, ID_ESTADO_ALERTA_FRAUDE_PENDIENTE],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (actualizado.rowCount === 0) {
      await this.explicarPorQueNoActualizo(id);
    }

    return this.obtenerHallazgoPorId(id);
  }

  /** Distingue 404 (no existe) de 409 (existe, pero ya no esta pendiente) -- siempre lanza. */
  private async explicarPorQueNoActualizo(id: string): Promise<never> {
    let existente;
    try {
      existente = await pool.query(
        'SELECT 1 FROM hallazgo_evento_fraude WHERE id_hallazgo_evento_fraude = $1',
        [id],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (existente.rowCount === 0) {
      throw new ErrorNoEncontrado('No existe un hallazgo con ese id');
    }
    throw new ErrorConflicto('El hallazgo ya no esta pendiente de revision');
  }

  private async obtenerHallazgoPorId(
    id: string,
  ): Promise<HallazgoEventoFraude> {
    let fila;
    try {
      fila = await pool.query<FilaHallazgoEventoFraude>(
        `SELECT h.id_hallazgo_evento_fraude,
                the.tipo_hallazgo_evento_nombre AS tipo,
                h.clave, ${SQL_CUENTAS_DE_HALLAZGO} AS cuentas,
                h.id_producto_mongo, h.detalle, h.contador, h.ventana_inicio,
                eaf.estado_alerta_fraude_nombre AS estado,
                h.fecha_creacion, h.fecha_actualizacion
           FROM hallazgo_evento_fraude h
           JOIN tipo_hallazgo_evento the
             ON the.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
           JOIN estado_alerta_fraude eaf
             ON eaf.id_estado_alerta_fraude = h.id_estado_alerta_fraude
          WHERE h.id_hallazgo_evento_fraude = $1`,
        [id],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    return aHallazgoEventoFraude(fila.rows[0]);
  }
}

// =====================================================================
// Filas crudas / conversion
// =====================================================================

interface FilaHallazgoEventoFraude {
  id_hallazgo_evento_fraude: string;
  tipo: TipoHallazgoEvento;
  clave: string;
  cuentas: CuentaDeHallazgoEvento[];
  id_producto_mongo: string | null;
  detalle: Record<string, unknown>;
  contador: number;
  ventana_inicio: Date;
  estado: EstadoAlertaFraude;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}

function aHallazgoEventoFraude(
  fila: FilaHallazgoEventoFraude,
): HallazgoEventoFraude {
  return {
    id_hallazgo_evento_fraude: fila.id_hallazgo_evento_fraude,
    tipo: fila.tipo,
    clave: fila.clave,
    cuentas: fila.cuentas,
    id_producto_mongo:
      fila.id_producto_mongo != null ? Number(fila.id_producto_mongo) : null,
    detalle: fila.detalle,
    contador: fila.contador,
    ventana_inicio: fila.ventana_inicio,
    estado: fila.estado,
    fecha_creacion: fila.fecha_creacion,
    fecha_actualizacion: fila.fecha_actualizacion,
  };
}
