import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { pool } from '../../database/postgres';
import { ErrorConflicto, ErrorNoEncontrado } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import {
  validarFiltroIdUsuarioEvento,
  validarFiltroMotivoEvento,
  validarFiltroResultadoEvento,
  validarFiltroTextoEvento,
  validarFiltroTipoEvento,
  validarIdAlertaFraude,
  validarIncluirUsuarioEvento,
  validarNuevoEstadoAlerta,
  validarRangoFechasEvento,
} from '../../helpers/validaciones-fraude';
import { validarLimite, validarPagina } from '../../helpers/validaciones-productos';
import type {
  EventoAutenticacionAdmin,
  EventosAutenticacionPaginados,
  PaginarEventosAutenticacionQuery,
} from '../../dto/paginar-eventos-autenticacion';
import {
  AlertaFraude,
  FilaAlertaFraude,
  ID_ESTADO_ALERTA_FRAUDE_DESCARTADA,
  ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
  ID_ESTADO_ALERTA_FRAUDE_REVISADA,
} from '../../models/alerta-fraude';

const INDICE =
  process.env.ELASTIC_INDICE_EVENTOS ?? 'mesh_eventos_autenticacion';

/** Copia verbatim de `SQL_CUENTAS_AFECTADAS` en `fraude-login.service.ts` -- se duplica (chica) por el mismo motivo que el resto de este modulo, ver el comentario de clase. */
const SQL_CUENTAS_AFECTADAS = `(
  SELECT COALESCE(json_agg(json_build_object(
           'id_usuario', nf.id_usuario::text,
           'usuario', u.usuario,
           'fecha_lectura', nf.fecha_lectura
         ) ORDER BY u.usuario), '[]'::json)
    FROM notificacion_fraude nf
    JOIN usuarios u ON u.id_usuario = nf.id_usuario
   WHERE nf.id_alerta_fraude = af.id_alerta_fraude
)`;

interface FuenteEventoElastic {
  tipo: string;
  resultado: string;
  motivo: string | null;
  id_usuario: string | null;
  identificador_intentado: string | null;
  ip: string | null;
  user_agent: string | null;
  huella_cliente: string | null;
  geo_punto: { lat: number; lon: number } | null;
  geo_pais: string | null;
  geo_ciudad: string | null;
  fecha: string;
}

/**
 * El panel de exploracion manual pendiente en
 * `elementos Generales/plan pendiente/fraude-login-eventos.md` (punto 3,
 * "todo lo que hizo esta cuenta"), mas la escritura que le faltaba al mismo
 * plan (punto 5: `PATCH` para marcar una alerta revisada/descartada).
 *
 * Dos piezas sin relacion entre si mas que vivir en el mismo panel de admin:
 *
 *   - `listarEventosPaginado` LEE Elasticsearch (`mesh_eventos_autenticacion`),
 *     los logs crudos -- nunca Mongo, que es el origen pero no el que se
 *     consulta (mismo criterio que el buscador de productos).
 *   - `marcarAlerta` ESCRIBE en `alerta_fraude` de Postgres -- nada que ver
 *     con Elasticsearch ni Redis, es la misma tabla que ya lee
 *     `FraudeLoginService.listarAlertasPaginado`.
 *
 * Este modulo (fraude por IP/cuenta en el login) es solo Elasticsearch +
 * Redis: no toca el panel de anillos de resenas (`FraudeService`, Neo4j).
 */
@Injectable()
export class FraudeLoginExploracionService {
  private readonly logger = new Logger(FraudeLoginExploracionService.name);

  // -----------------------------------------------------------------------
  // GET /admin/fraude/eventos-login
  // -----------------------------------------------------------------------

  async listarEventosPaginado(
    query: PaginarEventosAutenticacionQuery,
  ): Promise<EventosAutenticacionPaginados> {
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);
    const tipo = validarFiltroTipoEvento(query.tipo);
    const resultado = validarFiltroResultadoEvento(query.resultado);
    const motivo = validarFiltroMotivoEvento(query.motivo);
    const idUsuario = validarFiltroIdUsuarioEvento(query.id_usuario);
    const identificador = validarFiltroTextoEvento(query.identificador);
    const ip = validarFiltroTextoEvento(query.ip);
    const huellaCliente = validarFiltroTextoEvento(query.huella_cliente);
    const geoPais = validarFiltroTextoEvento(query.geo_pais);
    const { desde, hasta } = validarRangoFechasEvento(
      query.fecha_desde,
      query.fecha_hasta,
    );
    const incluirUsuario = validarIncluirUsuarioEvento(query.incluir_usuario);

    const filtros: Record<string, unknown>[] = [];
    if (tipo != null) filtros.push({ term: { 'tipo.keyword': tipo } });
    if (resultado != null)
      filtros.push({ term: { 'resultado.keyword': resultado } });
    if (motivo != null) filtros.push({ term: { 'motivo.keyword': motivo } });
    if (idUsuario != null)
      filtros.push({ term: { 'id_usuario.keyword': idUsuario } });
    if (identificador != null)
      filtros.push({
        term: { 'identificador_intentado.keyword': identificador },
      });
    if (ip != null) filtros.push({ term: { 'ip.keyword': ip } });
    if (huellaCliente != null)
      filtros.push({ term: { 'huella_cliente.keyword': huellaCliente } });
    if (geoPais != null)
      filtros.push({ term: { 'geo_pais.keyword': geoPais } });
    if (desde != null || hasta != null) {
      filtros.push({
        range: {
          fecha: {
            ...(desde != null ? { gte: desde.toISOString() } : {}),
            ...(hasta != null ? { lte: hasta.toISOString() } : {}),
          },
        },
      });
    }

    const saltar = (pagina - 1) * limite;

    let respuesta;
    try {
      respuesta = await elasticClient.search<FuenteEventoElastic, unknown>({
        index: INDICE,
        from: saltar,
        size: limite,
        track_total_hits: true,
        sort: [{ fecha: 'desc' }],
        query: filtros.length > 0 ? { bool: { filter: filtros } } : { match_all: {} },
      });
    } catch (error) {
      this.logger.error(`explorador de eventos de login: ${mensajeCorto(error)}`);
      throw error;
    }

    const total =
      typeof respuesta.hits.total === 'number'
        ? respuesta.hits.total
        : respuesta.hits.total?.value ?? 0;
    const totalPaginas = total === 0 ? 0 : Math.ceil(total / limite);

    const eventosBase = respuesta.hits.hits.map(aEventoAutenticacionAdmin);

    // Dos versiones a proposito (ver el comentario de clase y el punto 3
    // de la conversacion que dio origen a este servicio): con
    // `incluirUsuario=false` se evita el viaje extra a Postgres; con
    // `true` se paga ese viaje a cambio del nombre de usuario ya resuelto.
    // Conviven para poder medir el costo real de una contra la otra.
    const eventos = incluirUsuario
      ? await this.enriquecerConUsuario(eventosBase)
      : eventosBase;

    return {
      eventos,
      pagina,
      limite,
      total_eventos: total,
      total_paginas: totalPaginas,
      incluyo_usuario: incluirUsuario,
    };
  }

  /**
   * La version CON el lookup a Postgres: junta los `id_usuario` distintos de
   * la pagina (nunca mas de `limite`) y trae su `usuario` en una sola
   * consulta -- nunca una consulta por evento.
   */
  private async enriquecerConUsuario(
    eventos: EventoAutenticacionAdmin[],
  ): Promise<EventoAutenticacionAdmin[]> {
    const idsUnicos = [
      ...new Set(
        eventos
          .map((evento) => evento.id_usuario)
          .filter((id): id is string => id != null),
      ),
    ];

    if (idsUnicos.length === 0) {
      return eventos.map((evento) => ({ ...evento, cuenta_involucrada: null }));
    }

    let filas;
    try {
      filas = await pool.query<{ id_usuario: string; usuario: string }>(
        `SELECT id_usuario, usuario FROM usuarios WHERE id_usuario = ANY($1::bigint[])`,
        [idsUnicos],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    const usuariosPorId = new Map(
      filas.rows.map((fila) => [fila.id_usuario, fila.usuario]),
    );

    return eventos.map((evento) => ({
      ...evento,
      cuenta_involucrada:
        evento.id_usuario != null && usuariosPorId.has(evento.id_usuario)
          ? { id_usuario: evento.id_usuario, usuario: usuariosPorId.get(evento.id_usuario)! }
          : null,
    }));
  }

  // -----------------------------------------------------------------------
  // PATCH /admin/fraude/alertas-login/:id
  // -----------------------------------------------------------------------

  async marcarAlerta(
    idAlertaFraude: string,
    estadoSolicitado: string | undefined,
  ): Promise<AlertaFraude> {
    const id = validarIdAlertaFraude(idAlertaFraude);
    const nuevoEstado = validarNuevoEstadoAlerta(estadoSolicitado);
    const idEstadoDestino =
      nuevoEstado === 'revisada'
        ? ID_ESTADO_ALERTA_FRAUDE_REVISADA
        : ID_ESTADO_ALERTA_FRAUDE_DESCARTADA;

    let actualizado;
    try {
      actualizado = await pool.query(
        `UPDATE alerta_fraude
            SET id_estado_alerta_fraude = $2, fecha_actualizacion = now()
          WHERE id_alerta_fraude = $1
            AND id_estado_alerta_fraude = $3
          RETURNING id_alerta_fraude`,
        [id, idEstadoDestino, ID_ESTADO_ALERTA_FRAUDE_PENDIENTE],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (actualizado.rowCount === 0) {
      await this.explicarPorQueNoActualizo(id);
    }

    return this.obtenerAlertaPorId(id);
  }

  /** Distingue 404 (no existe) de 409 (existe, pero ya no esta pendiente) -- siempre lanza. */
  private async explicarPorQueNoActualizo(id: string): Promise<never> {
    let existente;
    try {
      existente = await pool.query(
        'SELECT 1 FROM alerta_fraude WHERE id_alerta_fraude = $1',
        [id],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (existente.rowCount === 0) {
      throw new ErrorNoEncontrado('No existe una alerta con ese id');
    }
    throw new ErrorConflicto('La alerta ya no esta pendiente de revision');
  }

  private async obtenerAlertaPorId(id: string): Promise<AlertaFraude> {
    let fila;
    try {
      fila = await pool.query<FilaAlertaFraude>(
        `SELECT af.id_alerta_fraude, ta.tipo_alerta_fraude_nombre AS tipo_alerta,
                af.clave, af.detalle, af.contador,
                af.ventana_inicio, ea.estado_alerta_fraude_nombre AS estado,
                af.fecha_creacion, af.fecha_actualizacion,
                ${SQL_CUENTAS_AFECTADAS} AS cuentas_afectadas
           FROM alerta_fraude af
           JOIN tipo_alerta_fraude ta
             ON ta.id_tipo_alerta_fraude = af.id_tipo_alerta_fraude
           JOIN estado_alerta_fraude ea
             ON ea.id_estado_alerta_fraude = af.id_estado_alerta_fraude
          WHERE af.id_alerta_fraude = $1`,
        [id],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    return aAlertaFraude(fila.rows[0]);
  }
}

function aEventoAutenticacionAdmin(hit: {
  _id?: string;
  _source?: FuenteEventoElastic;
}): EventoAutenticacionAdmin {
  const fuente = hit._source!;
  return {
    id: hit._id!,
    tipo: fuente.tipo as EventoAutenticacionAdmin['tipo'],
    resultado: fuente.resultado as EventoAutenticacionAdmin['resultado'],
    motivo: fuente.motivo as EventoAutenticacionAdmin['motivo'],
    id_usuario: fuente.id_usuario,
    identificador_intentado: fuente.identificador_intentado,
    ip: fuente.ip,
    user_agent: fuente.user_agent,
    huella_cliente: fuente.huella_cliente,
    geo: fuente.geo_punto
      ? {
          lat: fuente.geo_punto.lat,
          lon: fuente.geo_punto.lon,
          pais: fuente.geo_pais,
          ciudad: fuente.geo_ciudad,
        }
      : null,
    fecha: fuente.fecha,
  };
}

/** Mismo mapeo que `aAlertaFraude` en `fraude-login.service.ts` -- se duplica (chico) para no tocar ese archivo, mismo criterio que `mensajeCorto` repetido por el resto del modulo. */
function aAlertaFraude(fila: FilaAlertaFraude): AlertaFraude {
  return {
    id_alerta_fraude: fila.id_alerta_fraude,
    tipo_alerta: fila.tipo_alerta,
    clave: fila.clave,
    cuentas_afectadas: fila.cuentas_afectadas,
    detalle: fila.detalle,
    contador: fila.contador,
    ventana_inicio: fila.ventana_inicio,
    estado: fila.estado,
    fecha_creacion: fila.fecha_creacion,
    fecha_actualizacion: fila.fecha_actualizacion,
  };
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
