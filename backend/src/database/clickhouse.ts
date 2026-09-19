import { Logger } from '@nestjs/common';
import { createClient } from '@clickhouse/client';
import { obligatoria } from '../helpers/entorno';

const logger = new Logger('ClickHouse');

/**
 * La conexion a ClickHouse (eventos de producto y buscador, ver
 * `elementos Generales/plan pendiente/eventos-clickhouse.md`). El
 * equivalente de src/database/postgres.ts, mongo.ts, redis.ts, neo4j.ts y
 * elastic.ts, pero para la base columnar.
 *
 * Se conecta por el protocolo HTTP (puerto 8123), no el nativo (9010 hacia
 * afuera): es el que soporta el cliente oficial de Node y, al igual que
 * elastic.ts, no abre un socket persistente -- cada consulta es su propia
 * peticion HTTP.
 *
 * `CLICKHOUSE_DB` es la base que ya crea `docker-compose.yml` (raiz) en el
 * primer arranque del contenedor -- las credenciales tienen que coincidir
 * con las de ahi.
 */
const host = process.env.CLICKHOUSE_HOST ?? 'localhost';
const port = Number(process.env.CLICKHOUSE_PORT ?? 8123);
const database = obligatoria('CLICKHOUSE_DB');
const usuario = obligatoria('CLICKHOUSE_USER');
const contrasena = obligatoria('CLICKHOUSE_PASSWORD');

export const clickhouse = createClient({
  url: `http://${host}:${port}`,
  username: usuario,
  password: contrasena,
  database,
  // Sin esto, una caida de ClickHouse deja la peticion HTTP colgada mucho
  // mas de lo razonable -- mismo motivo que el commandTimeout de redis.ts.
  request_timeout: 8000,
});

logger.log(`Cliente de ClickHouse listo para http://${host}:${port}/${database}`);
