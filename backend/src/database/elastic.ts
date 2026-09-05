import { Logger } from '@nestjs/common';
import { Client } from '@elastic/elasticsearch';

const logger = new Logger('Elasticsearch');

/**
 * La conexion a Elasticsearch (el buscador de la Entrega 3). El equivalente
 * de src/database/mongo.ts, redis.ts y neo4j.ts, pero para el motor de
 * busqueda.
 *
 * Elasticsearch es una PROYECCION, igual que el grafo de Neo4j: la carga
 * `etl/cargar_busqueda.sh` desde el catalogo de MongoDB, y el backend solo la
 * CONSULTA. No guarda nada que no este ya en las otras bases.
 *
 * Sin autenticacion, a proposito: `docker-compose.yml` trae
 * `xpack.security.enabled: false` porque esta base no guarda nada que no
 * este ya en PostgreSQL/Mongo y solo escucha en localhost. Por eso, a
 * diferencia de mongo.ts/redis.ts/neo4j.ts, aca no hace falta `obligatoria()`
 * para ningun usuario ni contrasena.
 *
 * El cliente no abre ninguna conexion al construirse (es HTTP, no un socket
 * persistente): cada llamada abre su propia peticion.
 */
const host = process.env.ELASTIC_HOST ?? 'localhost';
const port = Number(process.env.ELASTIC_PORT ?? 9200);

export const elasticClient = new Client({
  node: `http://${host}:${port}`,
  // Sin esto, una caida de Elasticsearch reintenta varias veces antes de
  // fallar y la peticion HTTP se queda colgada mucho mas de lo razonable.
  requestTimeout: 8000,
  maxRetries: 1,
});

logger.log(`Cliente de Elasticsearch listo para http://${host}:${port}`);
