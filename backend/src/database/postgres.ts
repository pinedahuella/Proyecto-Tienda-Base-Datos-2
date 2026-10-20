import { Logger } from '@nestjs/common';
import { Pool, PoolClient, QueryResult, QueryResultRow } from 'pg';
import { Cortacircuitos, conLimite } from '../helpers/cortacircuitos';
import { obligatoria } from '../helpers/entorno';
import { esFalloDeConexion } from '../helpers/manejar-error-db';

const logger = new Logger('Postgres');

/**
 * La conexion a PostgreSQL. Todo el backend consulta la base por aqui.
 *
 * Es un "pool": un grupo de conexiones ya abiertas que se reutilizan. Abrir una
 * conexion nueva en cada consulta seria lento, asi que el pool las mantiene
 * listas y las va prestando.
 *
 * Las credenciales salen de backend/.env, que no se sube al repositorio.
 */
export const pool = new Pool({
  host: process.env.DB_HOST ?? 'localhost',
  port: Number(process.env.DB_PORT ?? 5432),
  user: obligatoria('DB_USER'),
  password: obligatoria('DB_PASSWORD'),
  database: obligatoria('DB_NAME'),
  // Los limites que no tenia (2026-10-20). Sin el primero, con la red cortada
  // cada conexion nueva esperaba lo que tarda Windows en rendirse, unos 21 s
  // (medido el 19-10 con la PC de Jose David); vale tambien para esperar turno
  // con el pool lleno. Sin el segundo, una conexion ya abierta a una base
  // congelada esperaba para siempre; es solo una red, generosa a proposito: con
  // 30 s cortaba transacciones de fraude que se esperan entre si por la misma
  // fila (medido el 20-10 con la bateria de pruebas). 20 conexiones y no las 10
  // de fabrica, para que esa espera de turno sea rara.
  max: 20,
  connectionTimeoutMillis: 10_000,
  query_timeout: 120_000,
});

/**
 * Si un error quiere decir que PostgreSQL no responde, para el cortacircuitos.
 * Es `esFalloDeConexion` menos dos casos que tambien dan 503 a quien los sufre
 * pero NO son la base caida: esperar turno con el pool lleno ("timeout exceeded
 * when trying to connect", pg-pool) y una consulta que paso el `query_timeout`.
 * Los dos pasan con la base sana y ocupada; si abrieran el cortacircuitos, una
 * rafaga de carga dejaria la tienda 15 s sin PostgreSQL (paso el 20-10 en la
 * bateria de pruebas, antes de separarlos).
 */
export function esCaidaDePostgres(error: unknown): boolean {
  return (
    esFalloDeConexion(error) &&
    !(
      error instanceof Error &&
      /timeout exceeded when trying to connect|query read timeout/i.test(
        error.message,
      )
    )
  );
}

/**
 * El cortacircuitos de PostgreSQL (helpers/cortacircuitos.ts): despues de una
 * caida, 15 s sin pedir conexiones. Es la base que manda, asi que lo que
 * depende de ella falla al instante con 503 (comprar, entrar) y lo que tiene
 * otro camino lo toma sin esperar: la sesion ya abierta se cree al token
 * (sesion.guard.ts), el carrito se ve desde Redis y el catalogo desde Mongo.
 */
export const cortacircuitosPostgres = new Cortacircuitos('PostgreSQL');

/** El error de lo que no se intento porque PostgreSQL esta en pausa. 08006 = connection_failure. */
function errorEnPausa(): Error {
  return Object.assign(new Error('PostgreSQL en pausa despues de una caida'), {
    code: '08006',
  });
}

/**
 * `pool.query` y `pool.connect` pasan por el cortacircuitos. La forma con
 * callback pasa directo: es la que usa el propio pool por dentro (su `query`
 * llama a `connect(callback)`), y contarla dos veces no hace falta.
 */
const consultar = pool.query.bind(pool) as (...args: unknown[]) => unknown;
pool.query = ((...args: unknown[]) => {
  if (typeof args[args.length - 1] === 'function') {
    return consultar(...args);
  }
  return cortacircuitosPostgres.correr(
    () => consultar(...args) as Promise<unknown>,
    esCaidaDePostgres,
    errorEnPausa,
  );
}) as typeof pool.query;

/**
 * Una consulta de las que tardan milesimas (una fila por su llave) con un limite
 * propio y corto. Es para el camino de cada peticion: la revision de la sesion
 * (`SesionGuard`) y el perfil de `/usuario/yo`. Con PostgreSQL congelado, una
 * conexion ya abierta del pool no contesta y la consulta esperaba el
 * `query_timeout` entero (medido el 2026-10-20: la primera peticion con sesion
 * tardo 30.3 s). Con esto se rinde a los `ms` y el que llama sigue por su
 * camino sin PostgreSQL.
 *
 * Avisa al cortacircuitos solo si el pool no tenia a nadie esperando turno: con
 * el pool lleno, tardar es estar ocupada, no caida.
 *
 * El error lleva `ETIMEDOUT`, asi que `esFalloDeConexion` lo reconoce y quien
 * llama lo trata como una caida.
 */
export async function consultaCorta<T extends QueryResultRow>(
  texto: string,
  valores: unknown[],
  ms = 3000,
): Promise<QueryResult<T>> {
  return conLimite(pool.query<T>(texto, valores), ms, () => {
    const error = Object.assign(
      new Error(`PostgreSQL no respondio en ${ms / 1000} s`),
      { code: 'ETIMEDOUT' },
    );
    if (pool.waitingCount === 0) {
      cortacircuitosPostgres.registrarCaida(error);
    }
    return error;
  });
}

const conectar = pool.connect.bind(pool) as (...args: unknown[]) => unknown;
pool.connect = ((...args: unknown[]) => {
  if (typeof args[0] === 'function') {
    return conectar(...args);
  }
  return cortacircuitosPostgres.correr(
    () => conectar() as Promise<PoolClient>,
    esCaidaDePostgres,
    errorEnPausa,
  );
}) as typeof pool.connect;

/**
 * Cuando una conexion que estaba en reposo se cae (por ejemplo, se apago
 * PostgreSQL), el pool avisa con un evento "error".
 *
 * Este listener es obligatorio: en Node, un evento "error" que nadie escucha
 * mata el proceso. Sin estas lineas, apagar la base tumba el backend completo
 * en vez de que solo falle la consulta.
 */
pool.on('error', (error) => {
  logger.warn(`Se perdio una conexion en reposo: ${error.message}`);
});

/**
 * Lo mismo para las conexiones que estan en uso. El "pool.on('error')" de arriba
 * solo cubre las que estan en reposo dentro del pool; una sacada con
 * pool.connect() (transacciones de ofertas, pedidos, fraude, grafo-sync...) no
 * tiene listener mientras esta afuera, y si la red se corta justo ahi, pg emite
 * "error" en el Client y Node mata el proceso.
 *
 * "connect" se dispara una vez por conexion fisica nueva, asi que el listener
 * queda puesto toda su vida, dentro y fuera del pool. La consulta que estaba en
 * curso sigue fallando (y su transaccion se pierde); lo que cambia es que el
 * backend sigue vivo.
 */
pool.on('connect', (cliente) => {
  cliente.on('error', (error) => {
    logger.warn(`Se perdio una conexion en uso: ${error.message}`);
  });
});
