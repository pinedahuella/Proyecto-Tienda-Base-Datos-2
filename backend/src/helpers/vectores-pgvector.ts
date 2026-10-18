import { QueryResultRow } from 'pg';
import { pool } from '../database/postgres';
import { ParParecido } from './similitud-vectores';

/**
 * Lo comun a todo lo que lee o escribe vectores en PostgreSQL (pgvector):
 * `vector_producto` y `vector_comentario`. Ver
 * `elementos Generales/plan pendiente/vectores-pgvector.md`.
 *
 * Todas las cuentas son con distancia coseno (`<=>`, de 0 a 2), la que usa el
 * modelo de Ollama y la de los indices HNSW. El parecido que se devuelve y se
 * compara con los umbrales es el coseno: `1 - distancia`, de -1 a 1.
 */

/** Un vector como lo recibe pgvector en un parametro (`$1::vector`). */
export function aVectorPg(vector: number[]): string {
  return `[${vector.join(',')}]`;
}

/** Un vector como lo devuelve pgvector (`vector::text`, `[0.1,0.2,...]`). */
export function deVectorPg(texto: string): number[] {
  return JSON.parse(texto) as number[];
}

/**
 * Corre una busqueda de vecinos (`ORDER BY vector <=> $1 LIMIT k`) dejando que
 * el indice HNSW devuelva los `k` que se piden. Con los valores por defecto de
 * pgvector, una consulta que usa el indice revisa solo 40 candidatos
 * (`hnsw.ef_search`) y lo que el filtro descarte se pierde: un `LIMIT 200`
 * puede volver con 39 filas. Por eso, solo dentro de esta transaccion:
 *
 * - `hnsw.ef_search` = `candidatos`: cuantos vecinos mira el indice, lo mismo
 *   que era `num_candidates` en la busqueda kNN de Elasticsearch.
 * - `hnsw.iterative_scan` = `strict_order`: si el filtro (activo, raiz, una
 *   calificacion) descarta candidatos, el indice sigue buscando en vez de
 *   cortar, y los entrega en orden de distancia.
 *
 * Con tablas chicas PostgreSQL prefiere recorrerlas enteras y ordenar (el
 * resultado exacto); esto cuenta cuando crecen y el plan pasa al indice.
 */
export async function buscarCercanos<T extends QueryResultRow>(
  sql: string,
  parametros: unknown[],
  candidatos: number,
): Promise<T[]> {
  const cliente = await pool.connect();
  try {
    await cliente.query('BEGIN');
    await cliente.query(
      `SELECT set_config('hnsw.ef_search', $1, true),
              set_config('hnsw.iterative_scan', 'strict_order', true)`,
      [String(candidatos)],
    );
    const { rows } = await cliente.query<T>(sql, parametros);
    await cliente.query('COMMIT');
    return rows;
  } catch (error) {
    await cliente.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    cliente.release();
  }
}

/**
 * Los pares de comentarios, de entre `idsComentario`, cuyo coseno llega a
 * `umbral`. Cada par va por la POSICION de sus dos comentarios en
 * `idsComentario`, con el coseno como `valor`: es lo que esperan
 * `marcarConGemela` y `agruparPorParecido`.
 *
 * La comparacion de todos contra todos la hace PostgreSQL: los vectores no
 * salen de la base. Un comentario sin vector no aparece en ningun par.
 */
export async function paresParecidos(
  idsComentario: number[],
  umbral: number,
): Promise<ParParecido[]> {
  if (idsComentario.length < 2) {
    return [];
  }
  const { rows } = await pool.query<{ a: string; b: string; coseno: number }>(
    `SELECT a.id_comentario AS a, b.id_comentario AS b,
            1 - (a.vector <=> b.vector) AS coseno
       FROM vector_comentario a
       JOIN vector_comentario b ON b.id_comentario > a.id_comentario
      WHERE a.id_comentario = ANY($1::bigint[])
        AND b.id_comentario = ANY($1::bigint[])
        AND 1 - (a.vector <=> b.vector) >= $2`,
    [idsComentario, umbral],
  );
  const posicion = new Map(idsComentario.map((id, i) => [id, i]));
  return rows.map((fila) => ({
    a: posicion.get(Number(fila.a))!,
    b: posicion.get(Number(fila.b))!,
    valor: fila.coseno,
  }));
}
