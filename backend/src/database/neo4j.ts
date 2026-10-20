import { Logger } from '@nestjs/common';
import neo4j, { Driver, Session, SessionMode } from 'neo4j-driver';
import { Cortacircuitos, conLimite } from '../helpers/cortacircuitos';
import { obligatoria } from '../helpers/entorno';

const logger = new Logger('Neo4j');

/**
 * La conexion a Neo4j (el grafo, para la deteccion de fraude en resenas de
 * la Entrega 2). El equivalente de src/database/postgres.ts y
 * src/database/mongo.ts, pero para la base de grafos.
 *
 * El grafo es una PROYECCION de PostgreSQL: se carga con el ETL
 * (`etl/cargar_grafo.sh`). El backend lo CONSULTA (`consultarGrafo`, modo
 * READ) para el panel de fraude, y desde el worker del outbox
 * (`GrafoSyncService`) tambien lo ESCRIBE (`ejecutarGrafo`, modo WRITE):
 * ese worker es el unico escritor en vivo, y todas sus escrituras son
 * idempotentes (`MERGE` / `DETACH DELETE`), asi que reaplicar un evento no
 * duplica nada.
 *
 * Las credenciales salen de backend/.env. El usuario es siempre "neo4j" en
 * la edicion community. Se conecta por Bolt (puerto 7687), no por el HTTP
 * del 7474.
 *
 * `neo4j.driver()` no abre ninguna conexion todavia: el driver es un pool
 * perezoso, igual que el de postgres. La primera consulta abre la sesion.
 */
const host = process.env.NEO4J_HOST ?? 'localhost';
const port = Number(process.env.NEO4J_PORT ?? 7687);
const usuario = process.env.NEO4J_USER ?? 'neo4j';
const contrasena = obligatoria('NEO4J_PASSWORD');

export const neo4jDriver: Driver = neo4j.driver(
  `bolt://${host}:${port}`,
  neo4j.auth.basic(usuario, contrasena),
  {
    // Que una caida de Neo4j se convierta en un 503 rapido y no en una
    // peticion colgada: cuanto espera abrir el socket, y cuanto espera
    // conseguir una conexion del pool antes de rendirse.
    connectionTimeout: 8000,
    connectionAcquisitionTimeout: 10000,
  },
);

/**
 * El cortacircuitos de Neo4j (helpers/cortacircuitos.ts): despues de una caida,
 * 15 s sin preguntarle. Lo usan las dos funciones de abajo, que son las unicas
 * puertas del backend al grafo.
 */
export const cortacircuitosNeo4j = new Cortacircuitos('Neo4j');

/**
 * Cuanto puede tardar una consulta antes de dar al grafo por congelado. El
 * driver tiene limite para abrir una conexion (8 s) y para conseguirla del pool
 * (10 s), pero no para una conexion ya abierta que deja de contestar: con la
 * red cortada a mitad de una consulta, `run()` esperaba para siempre. Las
 * consultas mas pesadas del backend (los detectores de anillos) tardan menos de
 * 2 s con los datos de la tienda.
 */
const LIMITE_CONSULTA_MS = 20_000;

/** El error de una consulta que no se hizo porque Neo4j esta en pausa o congelado. */
function errorNeo4jNoResponde(mensaje: string): Error {
  return Object.assign(new Error(mensaje), { code: 'ServiceUnavailable' });
}

/**
 * Corre `trabajo` en una sesion nueva con el cortacircuitos y el limite de
 * tiempo. La sesion se cierra sin esperar si el grafo no contesto: cerrarla
 * tambien le habla al servidor y se quedaria colgada igual.
 */
async function enSesion<T>(
  modo: SessionMode,
  trabajo: (sesion: Session) => Promise<T>,
  limiteMs = LIMITE_CONSULTA_MS,
): Promise<T> {
  return cortacircuitosNeo4j.correr(
    async () => {
      const sesion = neo4jDriver.session({ defaultAccessMode: modo });
      let respondio = false;
      try {
        const resultado = await conLimite(trabajo(sesion), limiteMs, () =>
          errorNeo4jNoResponde(`Neo4j no respondio en ${limiteMs / 1000} s`),
        );
        respondio = true;
        return resultado;
      } finally {
        if (respondio) {
          await sesion.close();
        } else {
          void sesion.close().catch(() => undefined);
        }
      }
    },
    esCaidaDeNeo4j,
    () => errorNeo4jNoResponde('Neo4j en pausa despues de una caida'),
  );
}

/**
 * Si un error quiere decir "Neo4j no responde": el driver no llego
 * (`ServiceUnavailable`, `SessionExpired`), un error pasajero del servidor, o
 * el limite de tiempo de arriba. Un error de la consulta
 * (`Neo.ClientError.*`) no es una caida.
 */
export function esCaidaDeNeo4j(error: unknown): boolean {
  const codigo = (error as { code?: string } | undefined)?.code;
  if (typeof codigo !== 'string') {
    return false;
  }
  return (
    codigo === 'ServiceUnavailable' ||
    codigo === 'SessionExpired' ||
    codigo.startsWith('Neo.TransientError')
  );
}

/**
 * Corre una consulta de solo lectura contra el grafo y devuelve las filas
 * ya como objetos planos. Abre una sesion, la usa y la cierra: es el patron
 * recomendado del driver (una sesion es barata, no se comparte entre
 * peticiones).
 *
 * `defaultAccessMode: READ` deja claro que el backend nunca escribe aca y,
 * en un cluster, enruta la consulta a una replica de lectura.
 */
export async function consultarGrafo<T = Record<string, unknown>>(
  cypher: string,
  parametros: Record<string, unknown> = {},
  limiteMs = LIMITE_CONSULTA_MS,
): Promise<T[]> {
  return enSesion(
    neo4j.session.READ,
    async (sesion) => {
      const resultado = await sesion.run(cypher, parametros);
      return resultado.records.map((registro) => registro.toObject() as T);
    },
    limiteMs,
  );
}

/**
 * El limite de las consultas que pide una persona desde la pagina (para ti,
 * tambien compraron): tardan decimas. Con Neo4j congelado, la primera esperaba
 * los 20 s de los detectores de fraude antes de pasar a PostgreSQL.
 */
export const LIMITE_CONSULTA_PAGINA_MS = 3000;

/**
 * Corre una consulta que ESCRIBE en el grafo. Hasta el worker del outbox
 * (`GrafoSyncService`) nada del backend escribia aca -- el grafo se cargaba
 * solo con el ETL. El worker es el primer y unico escritor en vivo.
 *
 * Los ids de nodo (`:Usuario.id`, `:Resena.id`, `:Producto.id`) son
 * `Integer` de Neo4j: los parametros de id **tienen que** pasarse con
 * `neo4j.int(...)`, no como number de JS -- un number crudo se guarda como
 * `Float` y `MERGE` crea un nodo duplicado que ninguna consulta encuentra.
 */
export async function ejecutarGrafo(
  cypher: string,
  parametros: Record<string, unknown> = {},
): Promise<void> {
  await enSesion(neo4j.session.WRITE, async (sesion) => {
    await sesion.run(cypher, parametros);
  });
}

logger.log(`Driver de Neo4j listo para bolt://${host}:${port}`);
