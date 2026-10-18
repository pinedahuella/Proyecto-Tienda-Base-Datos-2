import { Logger } from '@nestjs/common';
import { redis } from '../database/redis';
import { ErrorConexionRedis } from './errores';

/**
 * Traduce cualquier error de una operacion de Redis a `ErrorConexionRedis`
 * (un `ErrorConexion`, que el controlador convierte en 503). A diferencia de
 * PostgreSQL, un comando de Redis no tiene "violaciones de restriccion" ni
 * codigos de negocio: casi todo fallo es de conexion (socket caido,
 * timeout). El detalle tecnico va al log del servidor, nunca a la respuesta.
 */
export function manejarErrorRedis(logger: Logger, error: unknown): never {
  logger.error(error instanceof Error ? error.message : String(error));
  throw new ErrorConexionRedis('No se pudo conectar con Redis', error);
}

/** Los mensajes con que ioredis avisa que no llego a Redis. */
const MENSAJES_SIN_CONEXION =
  /connection is closed|econnrefused|etimedout|econnreset|enotfound|command timed out|max retries|reached the max retries|stream isn't writeable|connect etimedout|ehostunreach/i;

/**
 * `true` si Redis no esta para atender: el cliente no esta `ready`, o el
 * error es de conexion (no una respuesta de Redis, como el error de un
 * script). Es lo que decide si el carrito sigue por PostgreSQL, que es la
 * verdad, en vez de responder 503.
 *
 * Se mira primero el estado del cliente: con Redis caido, ioredis tarda sus
 * reintentos en fallar cada comando, y preguntar antes ahorra esa espera.
 */
export function esRedisInalcanzable(error?: unknown): boolean {
  if (error === undefined) {
    return redis.status !== 'ready';
  }
  const causa =
    error instanceof ErrorConexionRedis && error.causa !== undefined
      ? error.causa
      : error;
  if (causa instanceof Error) {
    return (
      causa.name === 'MaxRetriesPerRequestError' ||
      MENSAJES_SIN_CONEXION.test(causa.message) ||
      redis.status !== 'ready'
    );
  }
  return redis.status !== 'ready';
}
