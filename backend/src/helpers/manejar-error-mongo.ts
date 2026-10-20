import { Logger } from '@nestjs/common';
import {
  MongoNetworkError,
  MongoNotConnectedError,
  MongoServerSelectionError,
  MongoTopologyClosedError,
} from 'mongodb';
import { ErrorConexion } from './errores';

/**
 * Si un error de una consulta a Mongo quiere decir "Mongo no responde".
 *
 * Ademas de los dos de siempre (no encontro el servidor, se corto la red),
 * los dos de un cliente cerrado: el driver se conecta solo con la primera
 * consulta, y si en ese momento Mongo no responde (el backend arranco con Mongo
 * caido) cierra el cliente, y desde ahi cada consulta da "Topology is closed"
 * hasta que alguien llame a `mongoClient.connect()` (ver
 * `conRespaldoDeMongo` en catalogo-respaldo.ts). Antes eso salia como 500.
 */
export function esCaidaDeMongo(error: unknown): boolean {
  return (
    error instanceof MongoServerSelectionError ||
    error instanceof MongoNetworkError ||
    error instanceof MongoTopologyClosedError ||
    error instanceof MongoNotConnectedError
  );
}

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

  if (esCaidaDeMongo(error)) {
    throw new ErrorConexion('No se pudo conectar con MongoDB');
  }

  throw error;
}
