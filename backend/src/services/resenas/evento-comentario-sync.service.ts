import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { elasticClient } from '../../database/elastic';
import { OLLAMA_MODELO } from '../../database/ollama';
import {
  DIMENSIONES_VECTOR,
  LOTE_VECTORES,
  md5,
  pedirVectores,
} from '../../helpers/vectores-ollama';

const INDICE = process.env.ELASTIC_INDICE_COMENTARIOS ?? 'mesh_comentarios';

/** Una fila pendiente de `evento_comentario`. `fecha` va como texto para no perder microsegundos. */
interface EventoPendiente {
  id_evento: string;
  id_comentario: string;
  fecha: string;
}

/** Un comentario con lo que hace falta para su documento: de que resena (y
 * de que producto) cuelga, subiendo por `id_comentario_padre` hasta la raiz. */
interface FilaComentario {
  id_comentario: string;
  id_comentario_padre: string | null;
  id_raiz: string;
  id_usuario: string;
  comentario: string;
  fecha_publicacion: Date;
  id_resena: string;
  id_producto_mongo: string;
  id_usuario_vendedor: string;
  calificacion: number;
}

/** Lo que el documento ya tiene del vector. */
interface VectorIndexado {
  vector_hash?: string;
}

/** Un documento por indexar, y el evento que lo pidio. */
interface PorIndexar {
  evento: EventoPendiente;
  fila: FilaComentario;
  texto: string;
  hash: string;
  /** `true` si el texto es lo bastante largo para tener significado. */
  vectorizable: boolean;
  /** `true` si el hash cambio (o no habia vector) y hay que llamar a Ollama. */
  recalcular: boolean;
}

/**
 * El worker que mantiene al dia el indice de comentarios (Elasticsearch,
 * `mesh_comentarios`): un documento por comentario, que es el texto de cada
 * resena (la raiz) o de una respuesta, con su vector. Vacia la cola
 * `evento_comentario`, que llenan los triggers de `comentario` y `resena` en
 * la misma transaccion del cambio. Ver
 * `elementos Generales/plan pendiente/evento-comentario.md`.
 *
 * Como `GrafoSyncService`, no guarda "alta" ni "baja" en el evento: mira si
 * el comentario todavia existe. Existe (y cuelga de una resena) -> lo indexa;
 * no existe -> borra el documento.
 *
 * Como `VectoresSyncService`, solo llama a Ollama si el texto cambio: compara
 * el md5 contra el `vector_hash` que ya tiene el documento. Y escribe con
 * `update` parcial, para no borrar lo que no toca.
 *
 * Una respuesta muy corta ("gracias") casi no tiene significado: se indexa
 * para la busqueda de texto pero sin vector (`MIN_CARACTERES_RESPUESTA`). La
 * raiz de una resena siempre lleva vector.
 *
 * Cada documento lleva tambien el `id_vendedor` de su resena (para contar por
 * vendedor con agregaciones). Y cuando el texto cambia y se recalcula el vector,
 * se borran `valoracion_texto`, `prob_mala` y `valoracion_modelo`: los vuelve a
 * poner `ValoracionComentariosService` desde el vector nuevo.
 *
 * La calificacion solo va en el documento de la raiz. Las respuestas guardan
 * el `id_resena` y el `id_producto` y no la copian: si la calificacion cambia,
 * no hay que refrescar todo el hilo.
 *
 * Mismo patron que `EventoProductoSyncService`: `@Interval` con una bandera
 * para que una corrida lenta no se pise con la siguiente, y la fila se marca
 * procesada solo si `fecha` sigue siendo la que se leyo.
 */
@Injectable()
export class EventoComentarioSyncService {
  private readonly logger = new Logger(EventoComentarioSyncService.name);

  private static readonly INTERVALO_MS = 10000;

  /** Tope por corrida: si hay mas pendientes, siguen en la proxima. */
  private static readonly MAX_POR_CORRIDA = 200;

  /**
   * Fallos (que no sean de conexion) tras los cuales un comentario se aparta:
   * deja de reintentarse hasta que un cambio nuevo lo reactive (el trigger
   * pone `intentos` en 0), para que no frene a los demas.
   */
  private static readonly MAX_INTENTOS = 5;

  /** Una respuesta con menos caracteres que esto no se vectoriza. */
  private static readonly MIN_CARACTERES_RESPUESTA = 15;

  private procesando = false;

  @Interval('evento-comentario', EventoComentarioSyncService.INTERVALO_MS)
  async sincronizar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      const { rows: eventos } = await pool.query<EventoPendiente>(
        `SELECT id_evento, id_comentario, fecha::text AS fecha
           FROM evento_comentario
          WHERE procesado_en IS NULL AND intentos < $1
          ORDER BY id_evento
          LIMIT $2`,
        [
          EventoComentarioSyncService.MAX_INTENTOS,
          EventoComentarioSyncService.MAX_POR_CORRIDA,
        ],
      );
      if (eventos.length === 0) {
        return;
      }

      const filas = await this.leerComentarios(
        eventos.map((e) => e.id_comentario),
      );
      const hashesPrevios = await this.leerHashesIndexados(
        eventos.map((e) => e.id_comentario),
      );

      const borrar: EventoPendiente[] = [];
      const porIndexar: PorIndexar[] = [];
      for (const evento of eventos) {
        const fila = filas.get(evento.id_comentario);
        if (fila == null) {
          // Ya no existe, o su raiz no es una resena: no hay nada que indexar.
          borrar.push(evento);
          continue;
        }
        const texto = fila.comentario;
        const hash = md5(texto);
        const vectorizable = this.esVectorizable(fila, texto);
        porIndexar.push({
          evento,
          fila,
          texto,
          hash,
          vectorizable,
          recalcular:
            vectorizable &&
            hashesPrevios.get(evento.id_comentario)?.vector_hash !== hash,
        });
      }

      const vectores = await this.calcularVectores(porIndexar);
      const hechos: EventoPendiente[] = [];
      const fallidos: { evento: EventoPendiente; motivo: string }[] = [];

      const operaciones = this.armarOperaciones(borrar, porIndexar, vectores);
      if (operaciones.length > 0) {
        const respuesta = await elasticClient.bulk({
          operations: operaciones.flatMap((o) => o.lineas),
        });
        respuesta.items.forEach((item, k) => {
          const evento = operaciones[k].evento;
          const resultado = item.update ?? item.delete;
          // Un borrado de algo que nunca estuvo indexado (404) esta bien: ya
          // no hay documento, que es lo que se queria.
          if (resultado?.error && resultado.status !== 404) {
            fallidos.push({
              evento,
              motivo: resultado.error.reason ?? resultado.error.type,
            });
            return;
          }
          hechos.push(evento);
        });
      }

      await this.marcarProcesados(hechos);
      await this.marcarFallidos(fallidos);

      this.logger.log(
        `worker de comentarios: ${eventos.length} evento(s), ${hechos.length} al dia, ${vectores.size} vector(es) calculados, ${borrar.length} borrados del indice, ${fallidos.length} con error`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de comentarios: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  private esVectorizable(fila: FilaComentario, texto: string): boolean {
    const esRaiz = fila.id_comentario_padre == null;
    return (
      esRaiz ||
      texto.length >= EventoComentarioSyncService.MIN_CARACTERES_RESPUESTA
    );
  }

  /**
   * Los comentarios que existen, con su raiz y su resena. Sube por
   * `id_comentario_padre` hasta la raiz (una CTE recursiva). Un comentario
   * cuya raiz no tiene resena no sale: no pertenece a ninguna.
   */
  private async leerComentarios(
    ids: string[],
  ): Promise<Map<string, FilaComentario>> {
    const { rows } = await pool.query<FilaComentario>(
      `WITH RECURSIVE subida (id, actual, padre) AS (
         SELECT c.id_comentario, c.id_comentario, c.id_comentario_padre
           FROM comentario c
          WHERE c.id_comentario = ANY($1::bigint[])
         UNION ALL
         SELECT s.id, p.id_comentario, p.id_comentario_padre
           FROM subida s
           JOIN comentario p ON p.id_comentario = s.padre
       )
       SELECT c.id_comentario, c.id_comentario_padre, s.actual AS id_raiz,
              c.id_usuario, c.comentario, c.fecha_publicacion,
              r.id_resena, r.id_producto_mongo, r.id_usuario_vendedor,
              r.calificacion
         FROM subida s
         JOIN comentario c ON c.id_comentario = s.id
         JOIN resena r ON r.id_comentario = s.actual
        WHERE s.padre IS NULL`,
      [ids],
    );
    return new Map(
      rows.map((fila) => [
        fila.id_comentario,
        { ...fila, comentario: fila.comentario.trim() },
      ]),
    );
  }

  /** El `vector_hash` que ya tienen los documentos. Uno que no existe no sale. */
  private async leerHashesIndexados(
    ids: string[],
  ): Promise<Map<string, VectorIndexado>> {
    const resultado = new Map<string, VectorIndexado>();
    const respuesta = await elasticClient.mget<VectorIndexado>({
      index: INDICE,
      ids,
      _source: ['vector_hash'],
    });
    for (const doc of respuesta.docs) {
      if ('found' in doc && doc.found) {
        resultado.set(String(doc._id), doc._source ?? {});
      }
    }
    return resultado;
  }

  /** Pide a Ollama los vectores de los textos que cambiaron, por lotes. Los
   * lotes que fallan quedan fuera del mapa y esos eventos se reintentan. */
  private async calcularVectores(
    porIndexar: PorIndexar[],
  ): Promise<Map<string, number[]>> {
    const vectores = new Map<string, number[]>();
    const pendientes = porIndexar.filter((p) => p.recalcular);
    for (let i = 0; i < pendientes.length; i += LOTE_VECTORES) {
      const lote = pendientes.slice(i, i + LOTE_VECTORES);
      let respuesta: number[][];
      try {
        respuesta = await pedirVectores(lote.map((p) => p.texto));
      } catch (error) {
        // Ollama caido: no es culpa de los comentarios, no suma intentos.
        this.logger.warn(
          `worker de comentarios: Ollama fallo en el lote que empieza en ${i} (${mensajeCorto(error)})`,
        );
        continue;
      }
      lote.forEach((p, k) => {
        const vector = respuesta[k];
        if (Array.isArray(vector) && vector.length === DIMENSIONES_VECTOR) {
          vectores.set(p.evento.id_comentario, vector);
        } else {
          this.logger.warn(
            `worker de comentarios: el modelo devolvio ${vector?.length ?? 0} dimensiones para el comentario ${p.evento.id_comentario}, se esperaban ${DIMENSIONES_VECTOR}`,
          );
        }
      });
    }
    return vectores;
  }

  /** Las lineas del `_bulk`, de a una operacion por evento. Un comentario que
   * necesitaba vector y no lo consiguio (Ollama) se salta: se reintenta. */
  private armarOperaciones(
    borrar: EventoPendiente[],
    porIndexar: PorIndexar[],
    vectores: Map<string, number[]>,
  ): { evento: EventoPendiente; lineas: object[] }[] {
    const operaciones: { evento: EventoPendiente; lineas: object[] }[] = [];

    for (const evento of borrar) {
      operaciones.push({
        evento,
        lineas: [{ delete: { _index: INDICE, _id: evento.id_comentario } }],
      });
    }

    for (const p of porIndexar) {
      const doc: Record<string, unknown> = {
        id_comentario: Number(p.fila.id_comentario),
        id_comentario_padre:
          p.fila.id_comentario_padre == null
            ? null
            : Number(p.fila.id_comentario_padre),
        id_raiz: Number(p.fila.id_raiz),
        id_resena: Number(p.fila.id_resena),
        id_producto: Number(p.fila.id_producto_mongo),
        id_vendedor: Number(p.fila.id_usuario_vendedor),
        id_usuario: Number(p.fila.id_usuario),
        es_respuesta: p.fila.id_comentario_padre != null,
        calificacion:
          p.fila.id_comentario_padre == null ? p.fila.calificacion : null,
        comentario: p.texto,
        fecha_publicacion: p.fila.fecha_publicacion,
      };

      if (!p.vectorizable) {
        // Antes pudo tener vector (el texto era mas largo): se quita.
        doc.vector = null;
        doc.vector_hash = null;
        doc.vector_modelo = null;
        this.borrarValoracion(doc);
      } else if (p.recalcular) {
        const vector = vectores.get(p.evento.id_comentario);
        if (vector == null) {
          // Ollama no dio el vector: sin el no se indexa a medias, se reintenta.
          this.logger.warn(
            `worker de comentarios: sin vector para el comentario ${p.evento.id_comentario}, se reintenta en la proxima corrida`,
          );
          continue;
        }
        doc.vector = vector;
        doc.vector_hash = p.hash;
        doc.vector_modelo = OLLAMA_MODELO;
        // El texto cambio: la valoracion que tenia ya no vale.
        // `ValoracionComentariosService` la vuelve a calcular con el vector nuevo.
        this.borrarValoracion(doc);
      }
      // Si el hash no cambio no se tocan los campos del vector.

      operaciones.push({
        evento: p.evento,
        lineas: [
          { update: { _index: INDICE, _id: p.evento.id_comentario } },
          { doc, doc_as_upsert: true },
        ],
      });
    }
    return operaciones;
  }

  private borrarValoracion(doc: Record<string, unknown>): void {
    doc.valoracion_texto = null;
    doc.prob_mala = null;
    doc.valoracion_modelo = null;
  }

  /** Solo si `fecha` sigue siendo la que se leyo: si el comentario cambio
   * mientras se indexaba, la fila queda pendiente y se vuelve a hacer. */
  private async marcarProcesados(eventos: EventoPendiente[]): Promise<void> {
    if (eventos.length === 0) {
      return;
    }
    await pool.query(
      `UPDATE evento_comentario e SET procesado_en = now()
         FROM unnest($1::bigint[], $2::timestamptz[]) AS t (id, fecha)
        WHERE e.id_evento = t.id AND e.fecha = t.fecha
          AND e.procesado_en IS NULL`,
      [eventos.map((e) => e.id_evento), eventos.map((e) => e.fecha)],
    );
  }

  private async marcarFallidos(
    fallidos: { evento: EventoPendiente; motivo: string }[],
  ): Promise<void> {
    for (const { evento, motivo } of fallidos) {
      await pool.query(
        `UPDATE evento_comentario
            SET intentos = intentos + 1, ultimo_error = $2
          WHERE id_evento = $1`,
        [evento.id_evento, motivo.slice(0, 300)],
      );
      this.logger.warn(
        `worker de comentarios: fallo el comentario ${evento.id_comentario}: ${motivo}`,
      );
    }
  }
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
