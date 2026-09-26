import { Logger } from '@nestjs/common';

const logger = new Logger('Ollama');

/**
 * La conexion a Ollama (recomendacion semantica, Entrega final). El
 * equivalente de elastic.ts para el servicio de embeddings: HTTP puro, sin
 * cliente oficial -- cada llamada abre su propia peticion con `fetch`.
 *
 * `etl/cargar_vectores.ps1` ya resuelve CUAL Ollama usar (el de la PC o el
 * contenedor `mesh-ollama` del compose) y lo deja arriba antes de que el
 * backend arranque. Aca no se repite esa logica: `OLLAMA_URL` apunta fijo al
 * que haya quedado disponible, igual que `ELASTIC_HOST`/`ELASTIC_PORT` para
 * Elasticsearch.
 */
export const OLLAMA_URL = process.env.OLLAMA_URL ?? 'http://localhost:11434';
export const OLLAMA_MODELO =
  process.env.OLLAMA_MODELO_VECTORES ?? 'paraphrase-multilingual';

logger.log(
  `Cliente de Ollama listo para ${OLLAMA_URL} (modelo ${OLLAMA_MODELO})`,
);
