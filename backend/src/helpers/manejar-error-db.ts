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
 * ETIMEDOUT, ENOTFOUND, ECONNRESET) los tira el driver, no Postgres,
 * cuando ni siquiera logra abrir el socket o este se corta a la mitad.
 * AggregateError aparece cuando el driver intenta varias direcciones y
 * todas fallan.
 *
 * Hay un caso mas que NO trae `.code`: cuando Postgres se cae con
 * conexiones del pool ya abiertas (`docker stop` con el server corriendo,
 * el caso mas comun al probar esto a mano), `pg` lanza un Error a secas
 * con el mensaje `"Connection terminated unexpectedly"` -- verificado en
 * vivo el 2026-09-04, este caso se colaba como 500 en vez de 503 porque
 * no tenia codigo que revisar.
 *
 * Exportada para los workers que necesitan distinguir "se cayo la base" de
 * "fallo esta fila" sin lanzar el 503 (`EventoComentarioSyncService`).
 */
export function esFalloDeConexion(error: unknown): boolean {
  if (error instanceof AggregateError) {
    return true;
  }

  const codigo = (error as NodeJS.ErrnoException | undefined)?.code;
  if (
    codigo != null &&
    (codigo.startsWith('08') ||
      codigo === '28P01' ||
      codigo === '3D000' ||
      codigo === 'ECONNREFUSED' ||
      codigo === 'ETIMEDOUT' ||
      codigo === 'ENOTFOUND' ||
      codigo === 'ECONNRESET')
  ) {
    return true;
  }

  // Los dos limites de database/postgres.ts (2026-10-20): no se consiguio
  // conexion a tiempo, o una consulta se quedo sin respuesta (base congelada).
  return (
    error instanceof Error &&
    /connection terminated|timeout exceeded when trying to connect|query read timeout/i.test(
      error.message,
    )
  );
}

/** El error en una linea, para el log. Un `AggregateError` (el driver probo
 * varias direcciones y todas fallaron) no trae `message`: se arma con sus
 * causas. */
export function describirError(error: unknown): string {
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
