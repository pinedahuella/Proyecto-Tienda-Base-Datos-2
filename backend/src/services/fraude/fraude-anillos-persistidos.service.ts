import { Injectable, Logger } from '@nestjs/common';
import neo4j from 'neo4j-driver';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { consultarGrafo } from '../../database/neo4j';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorGrafo } from '../../helpers/manejar-error-grafo';
import { ErrorConflicto, ErrorNoEncontrado } from '../../helpers/errores';
import { conLimiteDeTiempo } from '../../helpers/limite-tiempo';
import {
  validarFiltroEstadoAlerta,
  validarNuevoEstadoAlerta,
} from '../../helpers/validaciones-fraude';
import {
  validarFiltroTipoAnillo,
  validarIdAnilloFraude,
} from '../../helpers/validaciones-anillo-fraude';
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
  AnilloFraude,
  CuentaDeAnillo,
  DetalleAnilloGrafo,
  ResenaDeAnilloGrafo,
  TipoAnilloFraude,
} from '../../models/anillo-fraude';
import {
  AnillosFraudePaginados,
  PaginarAnillosFraudeQuery,
} from '../../dto/paginar-anillos-fraude';

/**
 * Las cuentas del caso, derivadas de sus resenas (ver el comentario de
 * `CuentaDeAnillo`). El vendedor de la evidencia (`id_usuario_vendedor`) se
 * suma como sospechoso SALVO en `coordinados` (B.6): ahi los dos autores
 * coinciden calificando a un vendedor que es un tercero ajeno al patron, no
 * un sospechoso -- sumarlo aca lo implicaria por error. Necesita `taf`
 * (join a `tipo_anillo_fraude`) en el scope de quien use esta expresion.
 */
const SQL_CUENTAS_DE_ANILLO = `(
  SELECT COALESCE(json_agg(jsonb_build_object(
           'id_usuario', u.id_usuario::text, 'usuario', u.usuario
         ) ORDER BY u.usuario), '[]'::json)
    FROM (
      SELECT r.id_usuario AS id_usuario
        FROM anillo_fraude_resena afr
        JOIN resena r ON r.id_resena = afr.id_resena
       WHERE afr.id_anillo_fraude = af.id_anillo_fraude
      UNION
      SELECT r.id_usuario_vendedor
        FROM anillo_fraude_resena afr
        JOIN resena r ON r.id_resena = afr.id_resena
       WHERE afr.id_anillo_fraude = af.id_anillo_fraude
         AND taf.tipo_anillo_fraude_nombre <> 'coordinados'
    ) cuentas
    JOIN usuarios u ON u.id_usuario = cuentas.id_usuario
)`;

/** Los ids de resena que son la evidencia del anillo, ordenados. */
const SQL_RESENAS_DE_ANILLO = `(
  SELECT COALESCE(json_agg(afr.id_resena ORDER BY afr.id_resena), '[]'::json)
    FROM anillo_fraude_resena afr
   WHERE afr.id_anillo_fraude = af.id_anillo_fraude
)`;

/**
 * `GET`/`PATCH /admin/fraude/alertas-resenas` -- el panel de admin sobre
 * `anillo_fraude`/`anillo_fraude_resena`
 * (`elementos Generales/plan pendiente/anillos-fraude-persistencia.sql`),
 * los anillos `mutuo`/`ciclo`/`reiterado` que ya detectó y guardó
 * `AnillosDetectorService`. Nombrado en paralelo con `alertas-login`: mismo
 * sustantivo, distinto dominio.
 */
@Injectable()
export class FraudeAnillosPersistidosService {
  private readonly logger = new Logger(FraudeAnillosPersistidosService.name);

  private static readonly LIMITE_MS_GRAFO = 15000;

  // ---------------------------------------------------------------------
  // GET /admin/fraude/alertas-resenas
  // ---------------------------------------------------------------------

  async listarPaginado(
    query: PaginarAnillosFraudeQuery,
  ): Promise<AnillosFraudePaginados> {
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const estado = validarFiltroEstadoAlerta(query.estado);
    const tipo = validarFiltroTipoAnillo(query.tipo);
    const saltar = (pagina - 1) * limite;

    const { filas, total } = await this.consultarAnillosPaginado(
      estado,
      tipo,
      limite,
      saltar,
    );
    const totalPaginas = total === 0 ? 0 : Math.ceil(total / limite);

    return {
      anillos: filas.map(aAnilloFraude),
      pagina,
      limite,
      total_anillos: total,
      total_paginas: totalPaginas,
    };
  }

  /**
   * Conteo + página en la misma transacción REPEATABLE READ de solo
   * lectura -- mismo patrón que `FraudeLoginService.consultarAlertasPaginado`.
   * `estado`/`tipo` ya vinieron validados contra sus listas cerradas, por
   * eso se interpolan tal cual.
   */
  private async consultarAnillosPaginado(
    estado: EstadoAlertaFraude | null,
    tipo: TipoAnilloFraude | null,
    limite: number,
    saltar: number,
  ): Promise<{ filas: FilaAnilloFraude[]; total: number }> {
    const condicionEstado =
      estado === null
        ? ''
        : `AND eaf.estado_alerta_fraude_nombre = '${estado}'`;
    const condicionTipo =
      tipo === null ? '' : `AND taf.tipo_anillo_fraude_nombre = '${tipo}'`;

    const cliente = await pool.connect();
    try {
      await cliente.query(
        'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
      );

      const conteo = await cliente.query<{ total: string }>(
        `SELECT count(*) AS total
           FROM anillo_fraude af
           JOIN tipo_anillo_fraude taf
             ON taf.id_tipo_anillo_fraude = af.id_tipo_anillo_fraude
           JOIN estado_alerta_fraude eaf
             ON eaf.id_estado_alerta_fraude = af.id_estado_alerta_fraude
          WHERE true ${condicionEstado} ${condicionTipo}`,
      );

      const pagina = await cliente.query<FilaAnilloFraude>(
        `SELECT af.id_anillo_fraude, taf.tipo_anillo_fraude_nombre AS tipo,
                af.clave, ${SQL_CUENTAS_DE_ANILLO} AS cuentas,
                ${SQL_RESENAS_DE_ANILLO} AS resenas,
                eaf.estado_alerta_fraude_nombre AS estado,
                af.fecha_creacion, af.ultima_vez_confirmado_activo,
                af.fecha_actualizacion
           FROM anillo_fraude af
           JOIN tipo_anillo_fraude taf
             ON taf.id_tipo_anillo_fraude = af.id_tipo_anillo_fraude
           JOIN estado_alerta_fraude eaf
             ON eaf.id_estado_alerta_fraude = af.id_estado_alerta_fraude
          WHERE true ${condicionEstado} ${condicionTipo}
          ORDER BY af.ultima_vez_confirmado_activo DESC, af.id_anillo_fraude DESC
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
  // PATCH /admin/fraude/alertas-resenas/:id
  // ---------------------------------------------------------------------

  /**
   * Marca un anillo revisado/descartado -- solo si está `pendiente`, mismo
   * criterio que `FraudeLoginExploracionService.marcarAlerta`: un anillo ya
   * revisado o descartado no se reabre desde esta ruta.
   */
  async marcarAnillo(
    idAnilloFraudeParametro: string,
    estadoSolicitado: string | undefined,
  ): Promise<AnilloFraude> {
    const id = validarIdAnilloFraude(idAnilloFraudeParametro);
    const nuevoEstado = validarNuevoEstadoAlerta(estadoSolicitado);
    const idEstadoDestino =
      nuevoEstado === 'revisada'
        ? ID_ESTADO_ALERTA_FRAUDE_REVISADA
        : ID_ESTADO_ALERTA_FRAUDE_DESCARTADA;

    let actualizado;
    try {
      actualizado = await pool.query(
        `UPDATE anillo_fraude
            SET id_estado_alerta_fraude = $2, fecha_actualizacion = now()
          WHERE id_anillo_fraude = $1
            AND id_estado_alerta_fraude = $3
          RETURNING id_anillo_fraude`,
        [id, idEstadoDestino, ID_ESTADO_ALERTA_FRAUDE_PENDIENTE],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (actualizado.rowCount === 0) {
      await this.explicarPorQueNoActualizo(id);
    }

    return this.obtenerAnilloPorId(id);
  }

  /** Distingue 404 (no existe) de 409 (existe, pero ya no está pendiente) -- siempre lanza. */
  private async explicarPorQueNoActualizo(id: string): Promise<never> {
    let existente;
    try {
      existente = await pool.query(
        'SELECT 1 FROM anillo_fraude WHERE id_anillo_fraude = $1',
        [id],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (existente.rowCount === 0) {
      throw new ErrorNoEncontrado('No existe un anillo con ese id');
    }
    throw new ErrorConflicto('El anillo ya no está pendiente de revisión');
  }

  private async obtenerAnilloPorId(id: string): Promise<AnilloFraude> {
    let fila;
    try {
      fila = await pool.query<FilaAnilloFraude>(
        `SELECT af.id_anillo_fraude, taf.tipo_anillo_fraude_nombre AS tipo,
                af.clave, ${SQL_CUENTAS_DE_ANILLO} AS cuentas,
                ${SQL_RESENAS_DE_ANILLO} AS resenas,
                eaf.estado_alerta_fraude_nombre AS estado,
                af.fecha_creacion, af.ultima_vez_confirmado_activo,
                af.fecha_actualizacion
           FROM anillo_fraude af
           JOIN tipo_anillo_fraude taf
             ON taf.id_tipo_anillo_fraude = af.id_tipo_anillo_fraude
           JOIN estado_alerta_fraude eaf
             ON eaf.id_estado_alerta_fraude = af.id_estado_alerta_fraude
          WHERE af.id_anillo_fraude = $1`,
        [id],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    return aAnilloFraude(fila.rows[0]);
  }

  // ---------------------------------------------------------------------
  // GET /admin/fraude/alertas-resenas/:id/detalle-grafo
  // ---------------------------------------------------------------------

  /**
   * El detalle REAL del anillo, consultado en vivo contra Neo4j a partir de
   * los ids de `anillo_fraude_resena` -- no vuelve a correr A.1/A.2 (ya se
   * sabe cuáles son las resenas de este anillo), solo pide esas resenas
   * puntuales con su autor/vendedor/producto/fecha/calificación.
   */
  async obtenerDetalleGrafo(
    idAnilloFraudeParametro: string,
  ): Promise<DetalleAnilloGrafo> {
    const id = validarIdAnilloFraude(idAnilloFraudeParametro);

    let fila;
    try {
      fila = await pool.query<{
        tipo: TipoAnilloFraude;
        clave: string;
        id_resena: string;
      }>(
        `SELECT taf.tipo_anillo_fraude_nombre AS tipo, af.clave, afr.id_resena
           FROM anillo_fraude af
           JOIN tipo_anillo_fraude taf
             ON taf.id_tipo_anillo_fraude = af.id_tipo_anillo_fraude
           LEFT JOIN anillo_fraude_resena afr
             ON afr.id_anillo_fraude = af.id_anillo_fraude
          WHERE af.id_anillo_fraude = $1`,
        [id],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (fila.rows.length === 0) {
      throw new ErrorNoEncontrado('No existe un anillo con ese id');
    }

    const { tipo, clave } = fila.rows[0];
    const idsResena = fila.rows
      .map((f) => f.id_resena)
      .filter((idResena): idResena is string => idResena != null);

    if (idsResena.length === 0) {
      return { id_anillo_fraude: id, tipo, clave, resenas: [] };
    }

    let filasGrafo: FilaResenaGrafo[];
    try {
      filasGrafo = await conLimiteDeTiempo(
        consultarGrafo<FilaResenaGrafo>(CYPHER_DETALLE_RESENAS, {
          ids: idsResena.map((idResena) => neo4j.int(idResena)),
        }),
        FraudeAnillosPersistidosService.LIMITE_MS_GRAFO,
        'Neo4j',
      );
    } catch (error) {
      manejarErrorGrafo(this.logger, error);
    }

    return {
      id_anillo_fraude: id,
      tipo,
      clave,
      resenas: filasGrafo
        .map(aResenaDeAnilloGrafo)
        .sort((a, b) => a.fecha.localeCompare(b.fecha)),
    };
  }
}

// =====================================================================
// Filas crudas / conversion
// =====================================================================

interface FilaAnilloFraude {
  id_anillo_fraude: string;
  tipo: TipoAnilloFraude;
  clave: string;
  cuentas: CuentaDeAnillo[];
  resenas: number[];
  estado: EstadoAlertaFraude;
  fecha_creacion: Date;
  ultima_vez_confirmado_activo: Date;
  fecha_actualizacion: Date;
}

function aAnilloFraude(fila: FilaAnilloFraude): AnilloFraude {
  return {
    id_anillo_fraude: fila.id_anillo_fraude,
    tipo: fila.tipo,
    clave: fila.clave,
    cuentas: fila.cuentas,
    resenas: fila.resenas,
    estado: fila.estado,
    fecha_creacion: fila.fecha_creacion,
    ultima_vez_confirmado_activo: fila.ultima_vez_confirmado_activo,
    fecha_actualizacion: fila.fecha_actualizacion,
  };
}

interface FilaResenaGrafo {
  id_resena: unknown;
  autor: string | null;
  correo_autor: string | null;
  vendedor: string | null;
  correo_vendedor: string | null;
  producto: string | null;
  calificacion: unknown;
  fecha: string;
}

function aResenaDeAnilloGrafo(fila: FilaResenaGrafo): ResenaDeAnilloGrafo {
  return {
    id_resena: aNumero(fila.id_resena),
    autor: fila.autor,
    correo_autor: fila.correo_autor,
    vendedor: fila.vendedor,
    correo_vendedor: fila.correo_vendedor,
    producto: fila.producto,
    calificacion: aNumero(fila.calificacion),
    fecha: fila.fecha,
  };
}

/**
 * Neo4j devuelve los enteros como su propio tipo `Integer`. Mismo criterio
 * que `anillos-detector.service.ts`.
 */
function aNumero(valor: unknown): number {
  if (neo4j.isInt(valor)) {
    return (valor as { toNumber(): number }).toNumber();
  }
  return typeof valor === 'number' ? valor : 0;
}

/**
 * El detalle puntual de un conjunto YA CONOCIDO de resenas -- a diferencia
 * de las consultas de deteccion de `anillos-detector.service.ts`, esta
 * consulta NO busca ningun patron: solo trae, para cada resena de la lista,
 * quien la escribio, a quien califica y sobre que producto.
 */
const CYPHER_DETALLE_RESENAS = `
MATCH (r:Resena) WHERE r.id IN $ids
OPTIONAL MATCH (a:Usuario)-[:ESCRIBIO]->(r)
OPTIONAL MATCH (r)-[:CALIFICA_A]->(v:Usuario)
OPTIONAL MATCH (r)-[:SOBRE]->(p:Producto)
RETURN
  r.id AS id_resena,
  a.usuario AS autor, a.correo AS correo_autor,
  v.usuario AS vendedor, v.correo AS correo_vendedor,
  p.nombre AS producto,
  r.calificacion AS calificacion,
  toString(r.fecha) AS fecha
`;
