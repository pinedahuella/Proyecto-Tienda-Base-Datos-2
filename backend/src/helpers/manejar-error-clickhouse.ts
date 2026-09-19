import { Logger } from '@nestjs/common';
import { ClickHouseError } from '@clickhouse/client';
import { ErrorConexion } from './errores';

/**
 * El equivalente de manejar-error-elastic.ts / manejar-error-grafo.ts pero
 * para ClickHouse: clasifica un error que vino de una consulta.
 *
 *   - `ClickHouseError` es lo que el SERVIDOR de ClickHouse devolvio (un
 *     query rechazado -- sintaxis, tipo invalido): es un bug del backend,
 *     no una caida de la base, se relanza tal cual para que termine en 500.
 *   - Cualquier otro error (conexion rechazada, timeout) nunca llego a
 *     hablar con el servidor -> `ErrorConexion`, que el controlador
 *     convierte en 503.
 */
export function manejarErrorClickHouse(logger: Logger, error: unknown): never {
  logger.error(error instanceof Error ? error.message : String(error));

  if (error instanceof ClickHouseError) {
    throw error;
  }

  throw new ErrorConexion('No se pudo conectar con ClickHouse');
}
