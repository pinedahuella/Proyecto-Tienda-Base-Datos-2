import { Logger } from '@nestjs/common';
import { esCaidaDeElastic } from '../database/elastic';
import { ErrorConexion } from './errores';

/**
 * El equivalente de manejar-error-mongo.ts / manejar-error-redis.ts /
 * manejar-error-grafo.ts pero para Elasticsearch (el buscador): clasifica un
 * error que vino de una consulta y decide si es un problema de conexion
 * (ErrorConexion, que el controlador convierte en 503) o algo inesperado (se
 * relanza tal cual, para que termine en 500).
 */
export function manejarErrorConexionElastic(
  logger: Logger,
  error: unknown,
): never {
  logger.error(error instanceof Error ? error.message : String(error));

  if (esCaidaDeElastic(error)) {
    throw new ErrorConexion('No se pudo conectar con Elasticsearch');
  }

  throw error;
}
