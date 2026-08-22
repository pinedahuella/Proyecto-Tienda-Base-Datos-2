import { Logger } from '@nestjs/common';
import { ErrorConexion } from './errores';

/**
 * Clasifica un error que vino de un pool.query y decide si es un problema
 * de conexion (ErrorConexion, que el controlador convierte en 503) o algo
 * inesperado (se relanza tal cual, para que termine en un 500). Loguea el
 * detalle tecnico en los dos casos: eso nunca sale en la respuesta.
 *
 * No cubre violaciones de restriccion unica (23505): eso solo pasa en un
 * INSERT o UPDATE, es especifico de cada tabla, y cada servicio decide que
 * conflicto de negocio representa antes de llegar aqui.
 */
export function manejarErrorConexion(logger: Logger, error: unknown): never {
  logger.error(describirError(error));

  if (esFalloDeConexion(error)) {
    throw new ErrorConexion('No se pudo conectar con PostgreSQL');
  }

  throw error;
}

/**
 * 08*: clase de error de conexion de Postgres. 28P01: contrasena
 * incorrecta. 3D000: la base no existe. Los demas (ECONNREFUSED,
 * ETIMEDOUT, ENOTFOUND) los tira el driver, no Postgres, cuando ni
 * siquiera logra abrir el socket. AggregateError aparece cuando el driver
 * intenta varias direcciones y todas fallan.
 */
function esFalloDeConexion(error: unknown): boolean {
  if (error instanceof AggregateError) {
    return true;
  }

  const codigo = (error as NodeJS.ErrnoException | undefined)?.code;
  if (!codigo) {
    return false;
  }

  return (
    codigo.startsWith('08') ||
    codigo === '28P01' ||
    codigo === '3D000' ||
    codigo === 'ECONNREFUSED' ||
    codigo === 'ETIMEDOUT' ||
    codigo === 'ENOTFOUND'
  );
}

function describirError(error: unknown): string {
  if (error instanceof AggregateError) {
    const causas = error.errors.map(describirError).filter(Boolean);
    return causas.join(' | ') || 'Error de conexion desconocido';
  }

  if (error instanceof Error) {
    const codigo = (error as NodeJS.ErrnoException).code;
    return codigo ? `${codigo}: ${error.message}` : error.message;
  }
  return String(error);
}
