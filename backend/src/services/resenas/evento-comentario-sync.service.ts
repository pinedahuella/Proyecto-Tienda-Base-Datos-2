import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { OLLAMA_MODELO } from '../../database/ollama';
import { esFalloDeConexion } from '../../helpers/manejar-error-db';
import {
  DIMENSIONES_VECTOR,
  LOTE_VECTORES,
  md5,
  pedirVectores,
} from '../../helpers/vectores-ollama';
import { aVectorPg } from '../../helpers/vectores-pgvector';

/** Una fila pendiente de `evento_comentario`. `fecha` va como texto para no perder microsegundos. */
interface EventoPendiente {
  id_evento: string;
  id_comentario: string;
  fecha: string;
}

/** Un comentario que cuelga de una resena, con lo que hace falta para su vector. */
interface FilaComentario {
  id_comentario: string;
  id_comentario_padre: string | null;
  comentario: string;
}

/** Un comentario que sigue colgando de una resena, y el evento que lo pidio. */
interface PorRevisar {
  evento: EventoPendiente;
  texto: string;
  hash: string;
  /** `true` si el texto es lo bastante largo para tener significado. */
  vectorizable: boolean;
  /** `true` si el hash cambio (o no habia vector) y hay que llamar a Ollama. */
  recalcular: boolean;
}

/**
 * El worker que mantiene al dia `vector_comentario` (PostgreSQL, pgvector): el
 * vector de cada comentario, que es el texto de cada resena (la raiz) o de una
 * respuesta. Vacia la cola `evento_comentario`, que llenan los triggers de
 * `comentario` y `resena` en la misma transaccion del cambio. Ver
 * `elementos Generales/plan pendiente/vectores-pgvector.md`.
 *
 * Como `GrafoSyncService`, no guarda "alta" ni "baja" en el evento: mira si
 * el comentario todavia existe y cuelga de una resena. Si no (se borro, o se
 * borro su resena), le quita el vector. Borrar el comentario ya se lleva su
 * fila por la FK; esto cubre el comentario que se queda sin resena.
 *
 * Como `VectoresSyncService`, solo llama a Ollama si el texto cambio: compara
 * el md5 contra el `texto_hash` que ya tiene la fila.
 *
 * Una respuesta muy corta ("gracias") casi no tiene significado: no lleva
 * vector (`MIN_CARACTERES_RESPUESTA`). La raiz de una resena siempre lo lleva.
 *
 * Cuando el texto cambia y se recalcula el vector, se borra la valoracion
 * (`valoracion_texto`, `prob_mala`, `valoracion_modelo`): la vuelve a poner
 * `ValoracionComentariosService` desde el vector nuevo.
 *
 * Mismo patron que `EventoProductoSyncService`: `@Interval` con una bandera
 * para que una corrida lenta no se pise con la siguiente, y la fila se marca
 * procesada solo si `fecha` sigue siendo la que se leyo. Cada comentario se
 * escribe por separado: uno que falla suma `intentos` y no frena a los demas.
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

  /** La pasada en curso, o `null` si no hay ninguna. */
  private pasada: Promise<void> | null = null;

  @Interval('evento-comentario', EventoComentarioSyncService.INTERVALO_MS)
  async sincronizar(): Promise<void> {
    if (this.pasada != null) {
      return;
    }
    await this.arrancarPasada();
  }

  /**
   * Calcula YA lo pendiente, sin esperar el reloj de 10 s, y termina cuando el
   * vector ya esta guardado. La llama `ResenasService` justo despues de crear
   * una resena, igual que `GrafoSyncService.procesarAhora()`. Si ya hay una
   * pasada en curso, espera a que termine y hace OTRA: la resena nueva pudo
   * quedar fuera de la que ya habia empezado.
   *
   * Si Ollama o PostgreSQL fallan no lanza nada: el evento queda pendiente y
   * lo toma la proxima pasada del reloj.
   */
  async procesarAhora(): Promise<void> {
    while (this.pasada != null) {
      await this.pasada;
    }
    await this.arrancarPasada();
  }

  private arrancarPasada(): Promise<void> {
    const pasada = this.unaPasada().finally(() => {
      this.pasada = null;
    });
    this.pasada = pasada;
    return pasada;
  }

  /** Una pasada completa. No lanza: un fallo se loguea y queda para la proxima. */
  private async unaPasada(): Promise<void> {
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

      const ids = eventos.map((e) => e.id_comentario);
      const filas = await this.leerComentarios(ids);
      const hashesPrevios = await this.leerHashes(ids);

      const sinResena: EventoPendiente[] = [];
      const porRevisar: PorRevisar[] = [];
      for (const evento of eventos) {
        const fila = filas.get(evento.id_comentario);
        if (fila == null) {
          sinResena.push(evento);
          continue;
        }
        const texto = fila.comentario;
        const hash = md5(texto);
        const vectorizable = this.esVectorizable(fila, texto);
        porRevisar.push({
          evento,
          texto,
          hash,
          vectorizable,
          recalcular:
            vectorizable && hashesPrevios.get(evento.id_comentario) !== hash,
        });
      }

      const vectores = await this.calcularVectores(porRevisar);
      const hechos: EventoPendiente[] = [];
      const fallidos: { evento: EventoPendiente; motivo: string }[] = [];
      let quitados = 0;

      for (const evento of sinResena) {
        await this.guardar(evento, hechos, fallidos, async () => {
          quitados += await this.quitarVector(evento.id_comentario);
        });
      }
      for (const p of porRevisar) {
        if (!p.vectorizable) {
          // Antes pudo tener vector (el texto era mas largo): se quita.
          await this.guardar(p.evento, hechos, fallidos, async () => {
            quitados += await this.quitarVector(p.evento.id_comentario);
          });
        } else if (!p.recalcular) {
          // El texto no cambio: el vector que tiene sigue valiendo.
          hechos.push(p.evento);
        } else {
          const vector = vectores.get(p.evento.id_comentario);
          if (vector == null) {
            // Ollama no dio el vector: sin el no se guarda nada, se reintenta.
            this.logger.warn(
              `worker de comentarios: sin vector para el comentario ${p.evento.id_comentario}, se reintenta en la proxima corrida`,
            );
            continue;
          }
          await this.guardar(p.evento, hechos, fallidos, () =>
            this.guardarVector(p.evento.id_comentario, vector, p.hash),
          );
        }
      }

      await this.marcarProcesados(hechos);
      await this.marcarFallidos(fallidos);

      this.logger.log(
        `worker de comentarios: ${eventos.length} evento(s), ${hechos.length} al dia, ${vectores.size} vector(es) calculados, ${quitados} sin vector, ${fallidos.length} con error`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de comentarios: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
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
   * Los comentarios que existen y cuelgan de una resena. Sube por
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
       SELECT c.id_comentario, c.id_comentario_padre, c.comentario
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

  /** El `texto_hash` del vector que ya tienen. Uno sin vector no sale. */
  private async leerHashes(ids: string[]): Promise<Map<string, string>> {
    const { rows } = await pool.query<{
      id_comentario: string;
      texto_hash: string;
    }>(
      `SELECT id_comentario, texto_hash
         FROM vector_comentario
        WHERE id_comentario = ANY($1::bigint[])`,
      [ids],
    );
    return new Map(rows.map((fila) => [fila.id_comentario, fila.texto_hash]));
  }

  /** Pide a Ollama los vectores de los textos que cambiaron, por lotes. Los
   * lotes que fallan quedan fuera del mapa y esos eventos se reintentan. */
  private async calcularVectores(
    porRevisar: PorRevisar[],
  ): Promise<Map<string, number[]>> {
    const vectores = new Map<string, number[]>();
    const pendientes = porRevisar.filter((p) => p.recalcular);
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

  /** Corre la escritura de un evento y lo anota como hecho o como fallido. Un
   * fallo de conexion no es culpa del comentario: corta la corrida sin sumarle
   * intentos. */
  private async guardar(
    evento: EventoPendiente,
    hechos: EventoPendiente[],
    fallidos: { evento: EventoPendiente; motivo: string }[],
    escribir: () => Promise<void>,
  ): Promise<void> {
    try {
      await escribir();
      hechos.push(evento);
    } catch (error) {
      if (esFalloDeConexion(error)) {
        throw error;
      }
      fallidos.push({ evento, motivo: mensajeCorto(error) });
    }
  }

  /** El vector nuevo, sin valoracion: el texto cambio y la que tenia ya no vale.
   * `ValoracionComentariosService` la vuelve a calcular. */
  private async guardarVector(
    idComentario: string,
    vector: number[],
    hash: string,
  ): Promise<void> {
    await pool.query(
      `INSERT INTO vector_comentario (id_comentario, vector, texto_hash, modelo)
       VALUES ($1, $2::vector, $3, $4)
       ON CONFLICT (id_comentario) DO UPDATE SET
         vector = EXCLUDED.vector,
         texto_hash = EXCLUDED.texto_hash,
         modelo = EXCLUDED.modelo,
         fecha_calculo = now(),
         valoracion_texto = NULL,
         prob_mala = NULL,
         valoracion_modelo = NULL`,
      [idComentario, aVectorPg(vector), hash, OLLAMA_MODELO],
    );
  }

  /** Devuelve 1 si el comentario tenia vector y se le quito, 0 si no tenia. */
  private async quitarVector(idComentario: string): Promise<number> {
    const { rowCount } = await pool.query(
      'DELETE FROM vector_comentario WHERE id_comentario = $1',
      [idComentario],
    );
    return rowCount ?? 0;
  }

  /** Solo si `fecha` sigue siendo la que se leyo: si el comentario cambio
   * mientras se calculaba, la fila queda pendiente y se vuelve a hacer. */
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
