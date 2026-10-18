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
 * Las cuentas del hallazgo, del pivote `senal_fraude_cuenta` + `usuarios` --
 * mismo patron que `SQL_CUENTAS_DE_ANILLO`
 * (`fraude-anillos-persistidos.service.ts`). Necesita `s` (`senal_fraude`) en
 * el scope de quien use esta expresion.
 */
const SQL_CUENTAS_DE_HALLAZGO = `(
  SELECT COALESCE(json_agg(jsonb_build_object(
           'id_usuario', u.id_usuario::text, 'usuario', u.usuario,
           'es_nucleo', sc.es_nucleo
         ) ORDER BY u.usuario), '[]'::json)
    FROM senal_fraude_cuenta sc
    JOIN usuarios u ON u.id_usuario = sc.id_usuario
   WHERE sc.id_senal_fraude = s.id_senal_fraude
)`;

/** El producto (Mongo) del hallazgo -- F1 es el unico con uno, y de
 * uno solo; el resto da NULL. */
const SQL_PRODUCTO_DE_HALLAZGO = `(
  SELECT min(sp.id_producto_mongo)
    FROM senal_fraude_producto sp
   WHERE sp.id_senal_fraude = s.id_senal_fraude
)`;

/** Solo las senales de compras y navegacion (F1, F2, F3, F5 y la granja de
 * registros, que hoy sale de Elasticsearch). */
const SQL_SOLO_EVENTOS = `f.familia_senal_fraude_nombre = 'compras_navegacion'`;

/**
 * `GET`/`PATCH /admin/fraude/alertas-eventos` -- el panel de admin sobre
 * `senal_fraude` (la familia `compras_navegacion`: F1, F2, F3, F5 y la granja,
 * `elementos Generales/plan pendiente/refactor-fraude-senales.md`), los
 * hallazgos que ya detecto y guardo `HallazgosEventoFraudeDetectorService`.
 * Nombrado en paralelo con `alertas-login`/`alertas-resenas`: mismo
 * sustantivo, distinto dominio.
 *
 * Desde la etapa 7 del refactor el `id_hallazgo_evento_fraude` de la API es
 * el id de la SENAL, `contador` sale de `total_detecciones` y
 * `ventana_inicio` de `ultima_deteccion` (la ultima vez que el detector lo
 * vio).
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
      tipo === null ? '' : `AND t.tipo_senal_fraude_nombre = '${tipo}'`;

    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM senal_fraude s
           JOIN tipo_senal_fraude t
             ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
           JOIN familia_senal_fraude f
             ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
           JOIN estado_alerta_fraude eaf
             ON eaf.id_estado_alerta_fraude = s.id_estado_alerta_fraude
          WHERE ${SQL_SOLO_EVENTOS} ${condicionEstado} ${condicionTipo}`,
      );

      const pagina = await cliente.query<FilaHallazgoEventoFraude>(
        `SELECT s.id_senal_fraude AS id_hallazgo_evento_fraude,
                t.tipo_senal_fraude_nombre AS tipo,
                s.clave, ${SQL_CUENTAS_DE_HALLAZGO} AS cuentas,
                ${SQL_PRODUCTO_DE_HALLAZGO} AS id_producto_mongo, s.detalle,
                s.total_detecciones AS contador,
                s.ultima_deteccion AS ventana_inicio,
                eaf.estado_alerta_fraude_nombre AS estado,
                s.fecha_creacion, s.fecha_actualizacion
           FROM senal_fraude s
           JOIN tipo_senal_fraude t
             ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
           JOIN familia_senal_fraude f
             ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
           JOIN estado_alerta_fraude eaf
             ON eaf.id_estado_alerta_fraude = s.id_estado_alerta_fraude
          WHERE ${SQL_SOLO_EVENTOS} ${condicionEstado} ${condicionTipo}
          ORDER BY s.fecha_actualizacion DESC, s.id_senal_fraude DESC
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
        `UPDATE senal_fraude s
            SET id_estado_alerta_fraude = $2, fecha_actualizacion = now()
           FROM tipo_senal_fraude t
           JOIN familia_senal_fraude f
             ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
          WHERE t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
            AND ${SQL_SOLO_EVENTOS}
            AND s.id_senal_fraude = $1
            AND s.id_estado_alerta_fraude = $3
          RETURNING s.id_senal_fraude`,
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
        `SELECT 1
           FROM senal_fraude s
           JOIN tipo_senal_fraude t
             ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
           JOIN familia_senal_fraude f
             ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
          WHERE ${SQL_SOLO_EVENTOS} AND s.id_senal_fraude = $1`,
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
        `SELECT s.id_senal_fraude AS id_hallazgo_evento_fraude,
                t.tipo_senal_fraude_nombre AS tipo,
                s.clave, ${SQL_CUENTAS_DE_HALLAZGO} AS cuentas,
                ${SQL_PRODUCTO_DE_HALLAZGO} AS id_producto_mongo, s.detalle,
                s.total_detecciones AS contador,
                s.ultima_deteccion AS ventana_inicio,
                eaf.estado_alerta_fraude_nombre AS estado,
                s.fecha_creacion, s.fecha_actualizacion
           FROM senal_fraude s
           JOIN tipo_senal_fraude t
             ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
           JOIN familia_senal_fraude f
             ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
           JOIN estado_alerta_fraude eaf
             ON eaf.id_estado_alerta_fraude = s.id_estado_alerta_fraude
          WHERE ${SQL_SOLO_EVENTOS} AND s.id_senal_fraude = $1`,
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
