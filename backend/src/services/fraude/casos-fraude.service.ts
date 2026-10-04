import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { ErrorConflicto, ErrorNoEncontrado } from '../../helpers/errores';
import {
  validarLimite,
  validarPagina,
} from '../../helpers/validaciones-productos';
import {
  validarFiltroNivelCaso,
  validarFiltroEstadoCaso,
  validarIdCasoFraude,
  validarNuevoEstadoCaso,
  validarMotivoCaso,
} from '../../helpers/validaciones-caso-fraude';
import {
  ActualizarCasoFraudePeticion,
  CasosFraudePaginados,
  PaginarCasosFraudeQuery,
} from '../../dto/paginar-casos-fraude';
import {
  CasoFraudeDetalle,
  CasoFraudeResumen,
  CuentaCasoFraude,
  EstadoCasoFraude,
  EvidenciaCasoFraude,
  NivelCasoFraude,
} from '../../models/fraude/caso-fraude';
import { construirClave } from './hallazgo-fraude-adaptador.service';

/** La `fuente` que muestra la API (`grafo`/`eventos`/`login`/`elastic`) sale
 * de la fuente del tipo de la senal (`tipo_senal_fraude`) -- mismo mapa que
 * `FUENTE_POR_CATALOGO` del adaptador. Necesita el alias `t` en la consulta. */
const SQL_FUENTE_DEL_TIPO = `(SELECT CASE fu.fuente_senal_fraude_nombre
           WHEN 'clickhouse' THEN 'eventos'
           WHEN 'login' THEN 'login'
           WHEN 'elastic' THEN 'elastic'
           WHEN 'postgres' THEN 'postgres'
           ELSE 'grafo' END
           FROM fuente_senal_fraude fu
          WHERE fu.id_fuente_senal_fraude = t.id_fuente_senal_fraude)`;

/** La misma evidencia, resuelta contra su senal -- `senal_fraude` no se
 * toca, solo se lee (`evidencia_caso_fraude.id_senal_fraude`). */
const SQL_EVIDENCIA = `(
  SELECT COALESCE(json_agg(jsonb_build_object(
           'id_evidencia_caso_fraude', ev.id_evidencia_caso_fraude,
           'fuente', ${SQL_FUENTE_DEL_TIPO},
           'tipo', t.tipo_senal_fraude_nombre,
           'clave', s.clave,
           'metricas', s.detalle,
           'puntos', ev.puntos,
           'ultima_evidencia', ev.ultima_evidencia
         ) ORDER BY ev.ultima_evidencia DESC), '[]'::json)
    FROM evidencia_caso_fraude ev
    JOIN senal_fraude s ON s.id_senal_fraude = ev.id_senal_fraude
    JOIN tipo_senal_fraude t ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
    JOIN familia_senal_fraude f ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
   WHERE ev.id_caso_fraude = cf.id_caso_fraude
)`;

const SQL_CUENTAS = `(
  SELECT COALESCE(json_agg(jsonb_build_object(
           'id_usuario', u.id_usuario::text, 'usuario', u.usuario, 'es_nucleo', c.es_nucleo
         ) ORDER BY c.es_nucleo DESC, u.usuario), '[]'::json)
    FROM (
      SELECT ec.id_usuario, bool_or(ec.es_nucleo) AS es_nucleo
        FROM evidencia_caso_fraude ev
        JOIN evidencia_caso_fraude_cuenta ec ON ec.id_evidencia_caso_fraude = ev.id_evidencia_caso_fraude
       WHERE ev.id_caso_fraude = cf.id_caso_fraude
       GROUP BY ec.id_usuario
    ) c
    JOIN usuarios u ON u.id_usuario = c.id_usuario
)`;

/**
 * Paso 7 (parte de servicio) del agrupador de casos de fraude:
 * `GET /admin/fraude/casos`, `GET .../casos/:id`, `PATCH .../casos/:id`.
 * Solo lee y actualiza estado/motivo -- la agrupacion, el puntaje y las
 * reglas los arma `AgrupadorFraudeWorkerService`, no esta clase.
 */
@Injectable()
export class CasosFraudeService {
  private readonly logger = new Logger(CasosFraudeService.name);

  async listarPaginado(
    query: PaginarCasosFraudeQuery,
  ): Promise<CasosFraudePaginados> {
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const nivel = validarFiltroNivelCaso(query.nivel);
    const estado = validarFiltroEstadoCaso(query.estado);
    const saltar = (pagina - 1) * limite;

    const { filas, total } = await this.consultarCasosPaginado(
      nivel,
      estado,
      limite,
      saltar,
    );
    const totalPaginas = total === 0 ? 0 : Math.ceil(total / limite);

    return {
      casos: filas,
      pagina,
      limite,
      total_casos: total,
      total_paginas: totalPaginas,
    };
  }

  private async consultarCasosPaginado(
    nivel: NivelCasoFraude | null,
    estado: EstadoCasoFraude | null,
    limite: number,
    saltar: number,
  ): Promise<{ filas: CasoFraudeResumen[]; total: number }> {
    // nivel/estado ya vinieron validados contra listas cerradas.
    const condicionNivel =
      nivel === null ? '' : `AND n.nivel_caso_fraude_nombre = '${nivel}'`;
    const condicionEstado =
      estado === null
        ? ''
        : `AND eaf.estado_alerta_fraude_nombre = '${estado}'`;

    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM caso_fraude cf
           JOIN nivel_caso_fraude n ON n.id_nivel_caso_fraude = cf.id_nivel_caso_fraude
           JOIN estado_alerta_fraude eaf ON eaf.id_estado_alerta_fraude = cf.id_estado_alerta_fraude
          WHERE true ${condicionNivel} ${condicionEstado}`,
      );

      const pagina = await cliente.query<FilaCasoFraude>(
        `SELECT cf.id_caso_fraude, n.nivel_caso_fraude_nombre AS nivel, cf.puntaje,
                eaf.estado_alerta_fraude_nombre AS estado,
                COALESCE(
                  (SELECT array_agg(r.regla_casi_confirmado_nombre)
                     FROM caso_fraude_regla cfr
                     JOIN regla_casi_confirmado r ON r.id_regla_casi_confirmado = cfr.id_regla_casi_confirmado
                    WHERE cfr.id_caso_fraude = cf.id_caso_fraude),
                  '{}'
                ) AS reglas_cumplidas,
                (SELECT count(*) FROM evidencia_caso_fraude e WHERE e.id_caso_fraude = cf.id_caso_fraude) AS cantidad_evidencias,
                (SELECT count(DISTINCT ec.id_usuario)
                   FROM evidencia_caso_fraude e
                   JOIN evidencia_caso_fraude_cuenta ec ON ec.id_evidencia_caso_fraude = e.id_evidencia_caso_fraude
                  WHERE e.id_caso_fraude = cf.id_caso_fraude) AS cantidad_cuentas,
                cf.ultima_evidencia, cf.fecha_creacion, cf.fecha_actualizacion
           FROM caso_fraude cf
           JOIN nivel_caso_fraude n ON n.id_nivel_caso_fraude = cf.id_nivel_caso_fraude
           JOIN estado_alerta_fraude eaf ON eaf.id_estado_alerta_fraude = cf.id_estado_alerta_fraude
          WHERE true ${condicionNivel} ${condicionEstado}
          ORDER BY n.id_nivel_caso_fraude DESC, cf.puntaje DESC, cf.ultima_evidencia DESC
          LIMIT $1 OFFSET $2`,
        [limite, saltar],
      );

      await cliente.query('COMMIT');
      return {
        filas: pagina.rows.map(aResumen),
        total: Number(conteo.rows[0].total),
      };
    } catch (error) {
      await this.intentarRollback(cliente);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }

  async obtenerDetalle(idParametro: string): Promise<CasoFraudeDetalle> {
    const id = validarIdCasoFraude(idParametro);
    const fila = await this.consultarDetallePorId(id);
    if (fila == null) {
      throw new ErrorNoEncontrado('No existe un caso con ese id');
    }
    return aDetalle(fila);
  }

  private async consultarDetallePorId(
    id: number,
  ): Promise<FilaCasoFraudeDetalle | null> {
    try {
      const resultado = await pool.query<FilaCasoFraudeDetalle>(
        `SELECT cf.id_caso_fraude, n.nivel_caso_fraude_nombre AS nivel, cf.puntaje,
                eaf.estado_alerta_fraude_nombre AS estado, cf.motivo,
                COALESCE(
                  (SELECT array_agg(r.regla_casi_confirmado_nombre)
                     FROM caso_fraude_regla cfr
                     JOIN regla_casi_confirmado r ON r.id_regla_casi_confirmado = cfr.id_regla_casi_confirmado
                    WHERE cfr.id_caso_fraude = cf.id_caso_fraude),
                  '{}'
                ) AS reglas_cumplidas,
                (SELECT count(*) FROM evidencia_caso_fraude e WHERE e.id_caso_fraude = cf.id_caso_fraude) AS cantidad_evidencias,
                (SELECT count(DISTINCT ec.id_usuario)
                   FROM evidencia_caso_fraude e
                   JOIN evidencia_caso_fraude_cuenta ec ON ec.id_evidencia_caso_fraude = e.id_evidencia_caso_fraude
                  WHERE e.id_caso_fraude = cf.id_caso_fraude) AS cantidad_cuentas,
                cf.ultima_evidencia, cf.fecha_creacion, cf.fecha_actualizacion,
                ${SQL_CUENTAS} AS cuentas,
                ${SQL_EVIDENCIA} AS evidencia
           FROM caso_fraude cf
           JOIN nivel_caso_fraude n ON n.id_nivel_caso_fraude = cf.id_nivel_caso_fraude
           JOIN estado_alerta_fraude eaf ON eaf.id_estado_alerta_fraude = cf.id_estado_alerta_fraude
          WHERE cf.id_caso_fraude = $1`,
        [id],
      );
      return resultado.rows[0] ?? null;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** Solo se puede mover desde `pendiente` -- mismo criterio que ya usan
   * `hallazgo_evento_fraude`/`anillo_fraude`. Descartar exige `motivo` y
   * guarda la firma de la evidencia de ese momento (para reabrir despues
   * si cambia, ver `PersistenciaCasoFraudeService`). */
  async actualizar(
    idParametro: string,
    peticion: ActualizarCasoFraudePeticion,
  ): Promise<CasoFraudeDetalle> {
    const id = validarIdCasoFraude(idParametro);
    const estadoDestino = validarNuevoEstadoCaso(peticion.estado);
    const motivo = validarMotivoCaso(peticion.motivo, estadoDestino);

    const firma =
      estadoDestino === 'descartada'
        ? await this.construirFirmaActual(id)
        : null;

    let actualizado;
    try {
      actualizado = await pool.query(
        `UPDATE caso_fraude
            SET id_estado_alerta_fraude = (
                  SELECT id_estado_alerta_fraude FROM estado_alerta_fraude
                   WHERE estado_alerta_fraude_nombre = $2
                ),
                motivo = $3,
                firma_al_descartar = $4,
                fecha_actualizacion = now()
          WHERE id_caso_fraude = $1
            AND id_estado_alerta_fraude = (
                  SELECT id_estado_alerta_fraude FROM estado_alerta_fraude
                   WHERE estado_alerta_fraude_nombre = 'pendiente'
                )
          RETURNING id_caso_fraude`,
        [id, estadoDestino, motivo, firma],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (actualizado.rowCount === 0) {
      await this.explicarPorQueNoActualizo(id);
    }

    return this.obtenerDetalle(String(id));
  }

  /** Mismo formato exacto que `PersistenciaCasoFraudeService.construirFirma()`
   * (`fuente:tipo:clave` por hallazgo, ordenado y unido) -- tiene que dar
   * el mismo resultado para que la comparacion de "cambio la evidencia"
   * tenga sentido. La `clave` se recalcula desde las cuentas reales de
   * cada evidencia (`construirClave`), no se lee la cruda de la fuente:
   * para login, la cruda es una IP/identificador, no las cuentas. */
  private async construirFirmaActual(idCaso: number): Promise<string> {
    try {
      const resultado = await pool.query<{
        fuente: string;
        tipo: string;
        cuentas: string[];
      }>(
        `SELECT
           ${SQL_FUENTE_DEL_TIPO} AS fuente,
           t.tipo_senal_fraude_nombre AS tipo,
           array_agg(DISTINCT ec.id_usuario::text) AS cuentas
         FROM evidencia_caso_fraude ev
         JOIN senal_fraude s ON s.id_senal_fraude = ev.id_senal_fraude
         JOIN tipo_senal_fraude t ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
         JOIN familia_senal_fraude f ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
         JOIN evidencia_caso_fraude_cuenta ec ON ec.id_evidencia_caso_fraude = ev.id_evidencia_caso_fraude
        WHERE ev.id_caso_fraude = $1
        GROUP BY ev.id_evidencia_caso_fraude, fuente, tipo`,
        [idCaso],
      );
      return resultado.rows
        .map(
          (fila) =>
            `${fila.fuente}:${fila.tipo}:${construirClave(fila.cuentas.map(Number))}`,
        )
        .sort()
        .join('|');
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async explicarPorQueNoActualizo(id: number): Promise<never> {
    let existente;
    try {
      existente = await pool.query(
        'SELECT 1 FROM caso_fraude WHERE id_caso_fraude = $1',
        [id],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    if (existente.rowCount === 0) {
      throw new ErrorNoEncontrado('No existe un caso con ese id');
    }
    throw new ErrorConflicto('El caso ya no esta pendiente de revision');
  }

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo.
    }
  }
}

// ===========================================================================
// Filas crudas / conversion
// ===========================================================================

interface FilaCasoFraude {
  id_caso_fraude: string;
  nivel: NivelCasoFraude;
  puntaje: string;
  estado: EstadoCasoFraude;
  reglas_cumplidas: string[];
  cantidad_evidencias: string;
  cantidad_cuentas: string;
  ultima_evidencia: Date;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}

interface FilaCasoFraudeDetalle extends FilaCasoFraude {
  motivo: string | null;
  cuentas: CuentaCasoFraude[];
  evidencia: EvidenciaCasoFraude[];
}

function aResumen(fila: FilaCasoFraude): CasoFraudeResumen {
  return {
    id_caso_fraude: Number(fila.id_caso_fraude),
    nivel: fila.nivel,
    puntaje: Number(fila.puntaje),
    estado: fila.estado,
    reglas_cumplidas: fila.reglas_cumplidas,
    cantidad_evidencias: Number(fila.cantidad_evidencias),
    cantidad_cuentas: Number(fila.cantidad_cuentas),
    ultima_evidencia: fila.ultima_evidencia,
    fecha_creacion: fila.fecha_creacion,
    fecha_actualizacion: fila.fecha_actualizacion,
  };
}

function aDetalle(fila: FilaCasoFraudeDetalle): CasoFraudeDetalle {
  return {
    ...aResumen(fila),
    motivo: fila.motivo,
    cuentas: fila.cuentas,
    evidencia: fila.evidencia,
  };
}
