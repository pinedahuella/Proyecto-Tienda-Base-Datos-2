import { Logger } from '@nestjs/common';
import { ErrorConexion } from './errores';

/**
 * Traduce cualquier error de una operacion de Redis a `ErrorConexion` (que
 * el controlador convierte en 503). A diferencia de PostgreSQL, un comando
 * de Redis no tiene "violaciones de restriccion" ni codigos de negocio:
 * casi todo fallo es de conexion (socket caido, timeout). El detalle
 * tecnico va al log del servidor, nunca a la respuesta.
 */
export function manejarErrorRedis(logger: Logger, error: unknown): never {
  logger.error(error instanceof Error ? error.message : String(error));
  throw new ErrorConexion('No se pudo conectar con Redis');
}
