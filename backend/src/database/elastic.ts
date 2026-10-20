import { Logger } from '@nestjs/common';
import { Client, errors } from '@elastic/elasticsearch';
import { Cortacircuitos } from '../helpers/cortacircuitos';

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

const cliente = new Client({
  node: `http://${host}:${port}`,
  // Sin esto, una caida de Elasticsearch reintenta varias veces antes de
  // fallar y la peticion HTTP se queda colgada mucho mas de lo razonable.
  requestTimeout: 8000,
  // Sin reintento: con la red cortada cada intento espera los 10 s de abrir
  // la conexion, y con uno de mas la busqueda tardaba 22 s en avisar (medido el
  // 19-10). Un fallo de un momento lo cubre el cortacircuitos, que vuelve a
  // probar a los 15 s, y mientras tanto el buscador sale de la copia del
  // catalogo en PostgreSQL.
  maxRetries: 0,
});

/**
 * El cortacircuitos de Elasticsearch (helpers/cortacircuitos.ts): despues de
 * una caida, 15 s sin preguntarle. Solo cuentan como caida los tres errores de
 * no llegar; una respuesta con error (indice que no existe, consulta mal
 * armada) no.
 */
export const cortacircuitosElastic = new Cortacircuitos('Elasticsearch');

export function esCaidaDeElastic(error: unknown): boolean {
  return (
    error instanceof errors.ConnectionError ||
    error instanceof errors.TimeoutError ||
    error instanceof errors.NoLivingConnectionsError
  );
}

/** Los metodos del cliente que usa el backend, todos con cortacircuitos. */
const CON_CORTACIRCUITOS = new Set<PropertyKey>([
  'search',
  'mget',
  'count',
  'index',
  'delete',
  'update',
  'bulk',
  'info',
]);

/**
 * El cliente de siempre, con sus metodos de arriba pasando por el
 * cortacircuitos. Mismo tipo: nada del resto del backend cambia. Los de un
 * espacio (`indices.*`, `cluster.*`) los usan solo las comprobaciones de
 * conexion, que tienen su propio limite.
 */
export const elasticClient: Client = new Proxy(cliente, {
  get(objetivo, propiedad, receptor) {
    const valor: unknown = Reflect.get(objetivo, propiedad, receptor);
    if (typeof valor !== 'function' || !CON_CORTACIRCUITOS.has(propiedad)) {
      return valor;
    }
    const metodo = valor as (...args: unknown[]) => Promise<unknown>;
    return (...args: unknown[]) =>
      cortacircuitosElastic.correr(
        () => metodo.apply(objetivo, args),
        esCaidaDeElastic,
        () =>
          new errors.ConnectionError(
            'Elasticsearch en pausa despues de una caida',
          ),
      );
  },
});

logger.log(`Cliente de Elasticsearch listo para http://${host}:${port}`);
