import { Logger } from '@nestjs/common';
import neo4j, { Driver } from 'neo4j-driver';
import { obligatoria } from '../helpers/entorno';

const logger = new Logger('Neo4j');

/**
 * La conexion a Neo4j (el grafo, para la deteccion de fraude en resenas de
 * la Entrega 2). El equivalente de src/database/postgres.ts y
 * src/database/mongo.ts, pero para la base de grafos.
 *
 * El grafo es una PROYECCION de PostgreSQL: se carga con el ETL
 * (`etl/cargar_grafo.sh`) y el backend solo lo CONSULTA, nunca le escribe.
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
): Promise<T[]> {
  const sesion = neo4jDriver.session({
    defaultAccessMode: neo4j.session.READ,
  });
  try {
    const resultado = await sesion.run(cypher, parametros);
    return resultado.records.map((registro) => registro.toObject() as T);
  } finally {
    await sesion.close();
  }
}

logger.log(`Driver de Neo4j listo para bolt://${host}:${port}`);
