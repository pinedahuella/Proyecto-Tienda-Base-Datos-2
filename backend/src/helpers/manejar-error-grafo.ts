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

/**
 * Para los workers que llevan PostgreSQL al grafo (`GrafoSyncService`,
 * `GrafoComprasSyncService`): `true` si el error es un problema de CONEXION
 * (Neo4j o PostgreSQL caídos, la tabla de la cola desapareció) y no culpa del
 * evento. En ese caso el worker corta la corrida sin gastar un intento y
 * reintenta entera después.
 *
 * Un `Neo.ClientError.Statement.*` SÍ es culpa del evento (Cypher o
 * parámetro inválido → dato torcido en la base): eso sí gasta intento.
 */
export function esFalloDeConexionGrafo(error: unknown): boolean {
  if (error instanceof AggregateError) {
    return true; // el driver de pg probó varias IPs y todas fallaron
  }
  const codigo = (error as { code?: string } | undefined)?.code;
  if (typeof codigo !== 'string') {
    return false;
  }
  if (codigo.startsWith('Neo.ClientError.Statement')) {
    return false;
  }
  if (codigo.startsWith('Neo.') || codigo === 'ServiceUnavailable') {
    return true; // ServiceUnavailable, SessionExpired, Neo.TransientError.*
  }
  return (
    codigo.startsWith('08') || // clase de error de conexion de Postgres
    codigo.startsWith('53') || // recursos insuficientes
    codigo === '57P01' || // admin shutdown
    codigo === '57P02' || // crash shutdown
    codigo === '57P03' || // cannot connect now
    codigo === '42P01' || // la tabla de la cola ya no existe
    codigo === 'ECONNREFUSED' ||
    codigo === 'ECONNRESET' ||
    codigo === 'ETIMEDOUT' ||
    codigo === 'ENOTFOUND' ||
    codigo === 'EPIPE'
  );
}
