import { Logger } from '@nestjs/common';
import Redis from 'ioredis';
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
 *   commandTimeout        un comando que no termina en 10 s falla, en vez de
 *                         quedar encolado indefinidamente esperando que Redis
 *                         vuelva -- eso es lo que convierte "Redis caido" en
 *                         un 503 rapido y no en una peticion colgada
 *   maxRetriesPerRequest  3 reintentos por comando durante una reconexion
 *                         corta; despues falla
 */
const host = process.env.REDIS_HOST ?? 'localhost';
const port = Number(process.env.REDIS_PORT ?? 6379);
const contrasena = obligatoria('REDIS_PASSWORD');

export const redis = new Redis({
  host,
  port,
  password: contrasena,
  connectTimeout: 10000,
  commandTimeout: 10000,
  maxRetriesPerRequest: 3,
});

/**
 * Obligatorio: en Node, un evento "error" que nadie escucha mata el
 * proceso. Sin esto, apagar Redis tumba el backend entero en vez de que
 * solo falle la operacion que lo necesitaba (mismo motivo que el
 * `pool.on('error')` de postgres.ts).
 */
redis.on('error', (error: Error) => {
  logger.warn(`Fallo hablando con Redis: ${error.message}`);
});

redis.on('ready', () => {
  logger.log(`Conectado a Redis en ${host}:${port}`);
});
