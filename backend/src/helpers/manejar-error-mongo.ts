import { Logger } from '@nestjs/common';
import { MongoNetworkError, MongoServerSelectionError } from 'mongodb';
import { ErrorConexion } from './errores';

/**
 * El equivalente de manejar-error-db.ts (que es para Postgres) pero para
 * MongoDB: clasifica un error que vino de una consulta a Mongo y decide si
 * es un problema de conexion (ErrorConexion, que el controlador convierte
 * en 503) o algo inesperado (se relanza tal cual, para que termine en 500).
 */
export function manejarErrorConexionMongo(
  logger: Logger,
  error: unknown,
): never {
  logger.error(error instanceof Error ? error.message : String(error));

  if (
    error instanceof MongoServerSelectionError ||
    error instanceof MongoNetworkError
  ) {
    throw new ErrorConexion('No se pudo conectar con MongoDB');
  }

  throw error;
}
