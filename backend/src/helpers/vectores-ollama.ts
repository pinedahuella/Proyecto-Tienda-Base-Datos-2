import { createHash } from 'crypto';
import { OLLAMA_URL, OLLAMA_MODELO } from '../database/ollama';
import { conLimiteDeTiempo } from './limite-tiempo';

/** Cuantos textos van en una sola llamada a Ollama. Igual que `$lote` en
 * `etl/cargar_vectores.ps1`: Ollama procesa el lote en un solo request, mas
 * barato que uno por texto. */
export const LOTE_VECTORES = 32;

/** Dimensiones que devuelve `paraphrase-multilingual` y que espera el campo
 * `dense_vector` de Elasticsearch. */
export const DIMENSIONES_VECTOR = 768;

const LIMITE_MS_OLLAMA_DEFECTO = 30000;

interface RespuestaEmbed {
  embeddings: number[][];
}

/**
 * Pide a Ollama el vector de cada texto (`/api/embed`). Lo comparten los
 * workers que mantienen vectores en Elasticsearch: `VectoresSyncService`
 * (productos) y `EventoComentarioSyncService` (reseñas y sus respuestas).
 * Lanza si Ollama no responde o contesta con error. `limiteMs` es cuanto se
 * espera: los workers dejan los 30 s de siempre, una peticion de una persona
 * (la busqueda por intencion) pide menos.
 */
export async function pedirVectores(
  textos: string[],
  limiteMs: number = LIMITE_MS_OLLAMA_DEFECTO,
): Promise<number[][]> {
  const respuesta = await conLimiteDeTiempo(
    fetch(`${OLLAMA_URL}/api/embed`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: OLLAMA_MODELO, input: textos }),
    }),
    limiteMs,
    'Ollama',
  );
  if (!respuesta.ok) {
    throw new Error(`Ollama respondio ${respuesta.status}`);
  }
  const cuerpo = (await respuesta.json()) as RespuestaEmbed;
  return cuerpo.embeddings;
}

/** md5 del texto: sirve para saber si cambio desde el ultimo vector. */
export function md5(texto: string): string {
  return createHash('md5').update(texto, 'utf8').digest('hex');
}
