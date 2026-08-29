/**
 * Corre una promesa con un limite de tiempo: si no resuelve en `ms`
 * milisegundos, lanza un Error en vez de esperar para siempre.
 *
 * Se usa en las comprobaciones de conexion (`GET /clave-valor`,
 * `GET /grafo`): aunque los clientes de Redis y Neo4j ya tienen sus propios
 * timeouts, esto garantiza que la ruta HTTP responda rapido pase lo que
 * pase, y traduce un cuelgue en un 503 limpio.
 */
export async function conLimiteDeTiempo<T>(
  promesa: Promise<T>,
  ms: number,
  queEs: string,
): Promise<T> {
  let temporizador: NodeJS.Timeout;
  const limite = new Promise<never>((_, rechazar) => {
    temporizador = setTimeout(
      () => rechazar(new Error(`${queEs} no respondio en ${ms} ms`)),
      ms,
    );
  });
  try {
    return await Promise.race([promesa, limite]);
  } finally {
    clearTimeout(temporizador!);
  }
}
