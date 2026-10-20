import { Logger } from '@nestjs/common';
import {
  cortacircuitosRedis,
  esFalloDeConexionRedis,
  redis,
} from '../database/redis';
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

/**
 * `true` si Redis no esta para atender: el cliente no esta `ready`, el
 * cortacircuitos esta en pausa, o el error es de conexion (no una respuesta de
 * Redis, como el error de un script). Es lo que decide si el carrito sigue por
 * PostgreSQL, que es la verdad, en vez de responder 503, y si los rankings
 * salen de ClickHouse.
 *
 * Se mira primero el estado del cliente: con Redis caido, ioredis tarda sus
 * reintentos en fallar cada comando, y preguntar antes ahorra esa espera.
 */
export function esRedisInalcanzable(error?: unknown): boolean {
  const noAtiende = redis.status !== 'ready' || cortacircuitosRedis.enPausa();
  if (error === undefined) {
    return noAtiende;
  }
  const causa =
    error instanceof ErrorConexionRedis && error.causa !== undefined
      ? error.causa
      : error;
  return esFalloDeConexionRedis(causa) || noAtiende;
}
