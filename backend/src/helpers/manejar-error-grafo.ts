import { Logger } from '@nestjs/common';
import { ErrorConexion } from './errores';

/**
 * Traduce un error de una consulta a Neo4j (el grafo). Mismo criterio que
 * `manejar-error-db.ts` y `manejar-error-redis.ts`:
 *
 *   - Un `Neo.ClientError.Statement.*` (sintaxis, parametro invalido) es un
 *     bug del backend, no una caida de la base: se relanza tal cual para que
 *     termine en un 500.
 *   - Cualquier otro fallo (Bolt caido, sesion expirada, timeout) es de
 *     conexion -> `ErrorConexion`, que el controlador convierte en 503.
 *
 * El detalle tecnico va al log del servidor, nunca a la respuesta.
 */
export function manejarErrorGrafo(logger: Logger, error: unknown): never {
  logger.error(error instanceof Error ? error.message : String(error));

  const codigo = (error as { code?: string } | undefined)?.code;
  if (
    typeof codigo === 'string' &&
    codigo.startsWith('Neo.ClientError.Statement')
  ) {
    throw error;
  }

  throw new ErrorConexion('No se pudo conectar con Neo4j');
}
