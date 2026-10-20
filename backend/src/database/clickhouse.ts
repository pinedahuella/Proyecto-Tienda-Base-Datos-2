import { Logger } from '@nestjs/common';
import {
  ClickHouseClient,
  ClickHouseError,
  createClient,
} from '@clickhouse/client';
import { Cortacircuitos } from '../helpers/cortacircuitos';
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

const cliente = createClient({
  url: `http://${host}:${port}`,
  username: usuario,
  password: contrasena,
  database,
  // Sin esto, una caida de ClickHouse deja la peticion HTTP colgada mucho
  // mas de lo razonable -- mismo motivo que el commandTimeout de redis.ts.
  request_timeout: 8000,
});

/**
 * El cortacircuitos de ClickHouse (helpers/cortacircuitos.ts): despues de una
 * caida, 15 s sin preguntarle, asi que cada seccion que lo usa no espera sus
 * 8 s. Una respuesta del servidor con error (`ClickHouseError`: sintaxis, un
 * tipo invalido) no es una caida; cualquier otro fallo es que no se llego.
 */
export const cortacircuitosClickHouse = new Cortacircuitos('ClickHouse');

/**
 * Para una consulta que la tienda pinta mientras el comprador espera (viste
 * hace poco): 3 s y no los 8 s de `request_timeout`, como OPCIONES_BUSQUEDA de
 * elastic.ts. Con ClickHouse congelado la primera tardaba 8 s (medido el
 * 20-10). Las consultas de los paneles y los workers siguen con 8 s. Una
 * funcion porque cada consulta necesita su propia senal.
 */
export const limiteDeTienda = () => AbortSignal.timeout(3000);

const CON_CORTACIRCUITOS = new Set<PropertyKey>([
  'query',
  'insert',
  'command',
  'exec',
]);

/**
 * El cliente de siempre, con `query`, `insert`, `command` y `exec` pasando por
 * el cortacircuitos. Mismo tipo y mismos metodos: nada del resto del backend
 * cambia.
 */
export const clickhouse: ClickHouseClient = new Proxy(cliente, {
  get(objetivo, propiedad, receptor) {
    const valor: unknown = Reflect.get(objetivo, propiedad, receptor);
    if (typeof valor !== 'function') {
      return valor;
    }
    const metodo = valor as (...args: unknown[]) => Promise<unknown>;
    if (!CON_CORTACIRCUITOS.has(propiedad)) {
      return metodo.bind(objetivo);
    }
    return (...args: unknown[]) =>
      cortacircuitosClickHouse.correr(
        () => metodo.apply(objetivo, args),
        (error) => !(error instanceof ClickHouseError),
        () => new Error('ClickHouse en pausa despues de una caida'),
      );
  },
});

logger.log(
  `Cliente de ClickHouse listo para http://${host}:${port}/${database}`,
);
