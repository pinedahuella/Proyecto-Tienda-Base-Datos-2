import { Logger } from '@nestjs/common';
import Redis from 'ioredis';
import { Cortacircuitos } from '../helpers/cortacircuitos';
import { obligatoria } from '../helpers/entorno';

const logger = new Logger('Redis');

/**
 * La conexion a Redis (el almacen clave-valor, para el carrito con
 * expiracion por inactividad y la oferta de inventario limitado de la
 * Entrega 2). El equivalente de src/database/postgres.ts y
 * src/database/mongo.ts, pero para Redis.
 *
 * Las credenciales salen de backend/.env, que no se sube al repositorio.
 * Redis no pide usuario, solo contrasena (`requirepass` en
 * docker-compose.yml).
 *
 * ioredis abre la conexion al construir el cliente y la reintenta sola si se
 * cae. Los limites estan puestos para que una caida de Redis NO cuelgue una
 * peticion HTTP para siempre:
 *
 *   connectTimeout        cuanto espera abrir el socket antes de rendirse
 *   commandTimeout        un comando que no termina en 3 s falla, en vez de
 *                         quedar encolado indefinidamente esperando que Redis
 *                         vuelva -- eso es lo que convierte "Redis caido" en
 *                         un 503 rapido y no en una peticion colgada. Los
 *                         comandos de la tienda tardan milesimas; hasta el
 *                         2026-10-20 eran 10 s, y con Redis congelado cada
 *                         seccion de la portada esperaba eso
 *   maxRetriesPerRequest  3 reintentos por comando durante una reconexion
 *                         corta; despues falla
 */
const host = process.env.REDIS_HOST ?? 'localhost';
const port = Number(process.env.REDIS_PORT ?? 6379);
const contrasena = obligatoria('REDIS_PASSWORD');
/**
 * El usuario de ACL. `backend` desde el 2026-10-23: solo las claves `mesh:*`
 * (ver el bloque de Redis en docker-compose.yml). Sin REDIS_USER entra como
 * `default`, que es lo que habia antes y lo que tiene una PC que todavia no
 * corrio arrancar.ps1 con esta version.
 */
const usuario = process.env.REDIS_USER || undefined;

export const redis = new Redis({
  host,
  port,
  username: usuario,
  password: contrasena,
  connectTimeout: 10000,
  commandTimeout: 3000,
  maxRetriesPerRequest: 3,
});

/** Los mensajes con que ioredis avisa que no llego a Redis. */
const MENSAJES_SIN_CONEXION =
  /connection is closed|econnrefused|etimedout|econnreset|enotfound|command timed out|max retries|reached the max retries|stream isn't writeable|connect etimedout|ehostunreach/i;

/**
 * Si un error de un comando quiere decir "Redis no responde" y no una
 * respuesta de Redis (el error de un script, un tipo equivocado).
 */
export function esFalloDeConexionRedis(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.name === 'MaxRetriesPerRequestError' ||
      MENSAJES_SIN_CONEXION.test(error.message))
  );
}

/**
 * El cortacircuitos de Redis (helpers/cortacircuitos.ts): despues de una caida,
 * 15 s sin mandarle comandos. `esRedisInalcanzable()` lo mira, asi que el
 * carrito se va a PostgreSQL y los rankings a ClickHouse sin esperar.
 */
export const cortacircuitosRedis = new Cortacircuitos('Redis');

/**
 * Los comandos con que ioredis abre y revisa la conexion. Pasan siempre: si el
 * cortacircuitos los frenara, el cliente no podria volver a conectarse.
 */
const COMANDOS_DE_CONEXION = new Set([
  'auth',
  'hello',
  'info',
  'select',
  'client',
  'ping',
  'readonly',
  'quit',
]);

/**
 * Todo comando de ioredis pasa por `sendCommand` (tambien los de un `multi` y
 * los de un script), asi que el cortacircuitos va aqui y no en cada llamada.
 *
 * Si un comando se queda sin respuesta (Redis congelado: la conexion sigue
 * abierta pero nadie contesta), se fuerza una reconexion. Mientras reconecta,
 * el cliente no esta `ready` y `esRedisInalcanzable()` lo ve en el acto; sin
 * esto el cliente seguia `ready` sobre una conexion muerta y cada comando
 * esperaba su limite entero.
 */
type ComandoRedis = Parameters<Redis['sendCommand']>[0];
type StreamRedis = Parameters<Redis['sendCommand']>[1];
const enviar = redis.sendCommand.bind(redis) as (
  comando: ComandoRedis,
  stream?: StreamRedis,
) => Promise<unknown>;
redis.sendCommand = ((comando: ComandoRedis, stream?: StreamRedis) => {
  if (stream != null || COMANDOS_DE_CONEXION.has(comando.name)) {
    return enviar(comando, stream);
  }
  if (cortacircuitosRedis.enPausa()) {
    comando.reject(
      new Error('Connection is closed: Redis en pausa despues de una caida'),
    );
    return comando.promise;
  }
  const promesa = enviar(comando, stream);
  promesa.then(
    () => cortacircuitosRedis.registrarRespuesta(),
    (error: unknown) => {
      if (!esFalloDeConexionRedis(error)) {
        return;
      }
      cortacircuitosRedis.registrarCaida(error);
      // Solo desde `ready`: con muchos comandos vencidos a la vez, uno basta.
      if (
        /command timed out/i.test((error as Error).message) &&
        redis.status === 'ready'
      ) {
        redis.disconnect(true);
      }
    },
  );
  return promesa;
}) as typeof redis.sendCommand;

/**
 * Obligatorio: en Node, un evento "error" que nadie escucha mata el
 * proceso. Sin esto, apagar Redis tumba el backend entero en vez de que
 * solo falle la operacion que lo necesitaba (mismo motivo que el
 * `pool.on('error')` de postgres.ts).
 */
redis.on('error', (error: Error) => {
  logger.warn(`Fallo hablando con Redis: ${error.message}`);
  // La conexion misma fallo (Redis apagado, la red cortada). Se marca la caida
  // aqui y no solo cuando falla un comando: con Redis apagado el cliente no
  // esta `ready`, quien llama ve `esRedisInalcanzable()` y se va a su respaldo
  // sin mandar nada, y el cortacircuitos nunca se enteraba. Asi lo de
  // GET /db/cortacircuitos dice la verdad aunque nadie le hable a Redis.
  if (esFalloDeConexionRedis(error)) {
    cortacircuitosRedis.registrarCaida(error);
  }
});

redis.on('ready', () => {
  logger.log(`Conectado a Redis en ${host}:${port}`);
  cortacircuitosRedis.registrarRespuesta();
});
