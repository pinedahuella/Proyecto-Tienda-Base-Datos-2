import { Logger } from '@nestjs/common';
import { cortacircuitosNeo4j, esCaidaDeNeo4j } from '../database/neo4j';
import { pool } from '../database/postgres';
import { ESTADOS_DE_COMPRA } from '../services/grafo/grafo-compras-sync.service';
import { ErrorConexion } from './errores';
import { esFalloDeConexion } from './manejar-error-db';

/**
 * El respaldo de las recomendaciones del grafo: cuando Neo4j no responde, "para
 * ti" y "quienes lo compraron tambien llevaron" salen de los pedidos en
 * PostgreSQL (2026-10-20), en vez de dar 503.
 *
 * Se puede porque el grafo de compras es una copia: cada nodo `:Compra` es una
 * linea de `pedido_producto` de un pedido comprado, enviado o entregado
 * (`GrafoComprasSyncService`, migracion 041). Las dos consultas de abajo son
 * las de Cypher (`para-ti.service.ts` y `tambien-compraron.service.ts`)
 * escritas en SQL sobre esas mismas lineas, con los mismos criterios, el mismo
 * orden y los mismos desempates. Si la cola `evento_grafo_compra` esta al dia,
 * dan lo mismo; si no, el respaldo esta MAS al dia que el grafo.
 *
 * Neo4j sigue siendo donde estas preguntas se hacen bien (varios saltos, y en el
 * mismo grafo los anillos de fraude); esto es solo para que la pagina no pierda
 * las recomendaciones mientras no esta.
 */

const logger = new Logger('RecomendacionesRespaldo');

/** Si la ultima vez se uso el respaldo: para avisar solo al entrar y al salir. */
let enRespaldo = false;

/**
 * Corre `deGrafo`, y si Neo4j no responde (o su cortacircuitos esta en pausa),
 * `dePostgres`. Cualquier otro error del grafo sale tal cual. Un fallo de
 * PostgreSQL en el respaldo sale como `ErrorConexion` (503).
 */
export async function conRespaldoDeNeo4j<T>(
  deGrafo: () => Promise<T>,
  dePostgres: () => Promise<T>,
): Promise<T> {
  if (!cortacircuitosNeo4j.enPausa()) {
    try {
      const resultado = await deGrafo();
      if (enRespaldo) {
        enRespaldo = false;
        logger.log(
          'Neo4j volvio: las recomendaciones salen otra vez del grafo',
        );
      }
      return resultado;
    } catch (error) {
      if (!esCaidaDeNeo4j(error)) {
        throw error;
      }
      if (!enRespaldo) {
        enRespaldo = true;
        logger.warn(
          `Neo4j no responde (${error instanceof Error ? error.message : String(error)}): para ti y tambien compraron salen de los pedidos en PostgreSQL`,
        );
      }
    }
  }

  try {
    return await dePostgres();
  } catch (error) {
    if (esFalloDeConexion(error)) {
      logger.error(
        `El respaldo de las recomendaciones tampoco pudo leer PostgreSQL: ${error instanceof Error ? error.message : String(error)}`,
      );
      throw new ErrorConexion('No se pudo conectar con PostgreSQL');
    }
    throw error;
  }
}

/** Las compras como las ve el grafo: quien, que producto y cuando. */
const CTE_COMPRAS = `compras AS (
    SELECT pe.id_usuario AS u, pp.id_producto_mongo AS p, pe.fecha_creacion AS f
      FROM pedido pe
      JOIN estado_pedido e ON e.id_estado_pedido = pe.id_estado_pedido
      JOIN pedido_producto pp ON pp.id_pedido = pe.id_pedido
     WHERE e.estado_pedido_nombre = ANY($1::text[])
  )`;

/**
 * "Para ti" desde PostgreSQL. La misma pregunta que `CYPHER_PARA_TI`: los
 * `maxProductos` productos que la cuenta compro mas recientemente; las otras
 * cuentas que compraron alguno; lo que esas cuentas compraron y la cuenta no;
 * por cuantas cuentas distintas, de mas a menos, y por que (cuales de los suyos
 * los unen, hasta `maxPorque`).
 */
export async function paraTiDesdePostgres(
  idUsuario: number,
  maxProductos: number,
  candidatos: number,
  maxPorque: number,
): Promise<{ id: number; compradores: number; porque: number[] }[]> {
  const { rows } = await pool.query<{
    id: string;
    compradores: number;
    porque: string[];
  }>(
    `WITH ${CTE_COMPRAS},
       mios AS (
         SELECT p, max(f) AS ultima,
                row_number() OVER (ORDER BY max(f) DESC, p) AS orden
           FROM compras WHERE u = $2
          GROUP BY p
          ORDER BY ultima DESC, p
          LIMIT $3
       ),
       otros AS (
         SELECT DISTINCT c.u AS otro, m.p AS comun, m.orden
           FROM compras c JOIN mios m ON m.p = c.p
          WHERE c.u <> $2
       ),
       recs AS (
         SELECT c.p AS rec, o.otro, o.comun, o.orden
           FROM otros o JOIN compras c ON c.u = o.otro
          WHERE c.p NOT IN (SELECT p FROM compras WHERE u = $2)
       )
     -- El porque en el orden en que Cypher los junta: de lo que la cuenta
     -- compro mas reciente a lo mas viejo.
     SELECT rec AS id, count(DISTINCT otro)::int AS compradores,
            (SELECT array_agg(x.comun ORDER BY x.orden)
               FROM (SELECT DISTINCT r2.comun, r2.orden FROM recs r2
                      WHERE r2.rec = recs.rec) x)[1:$5] AS porque
       FROM recs
      GROUP BY rec
      ORDER BY compradores DESC, rec
      LIMIT $4`,
    [ESTADOS_DE_COMPRA, idUsuario, maxProductos, candidatos, maxPorque],
  );
  return rows.map((fila) => ({
    id: Number(fila.id),
    compradores: fila.compradores,
    porque: fila.porque.map(Number),
  }));
}

/**
 * "Quienes lo compraron tambien llevaron" desde PostgreSQL. La misma pregunta
 * y el mismo orden que `CYPHER_TAMBIEN_COMPRARON`: las cuentas que compraron
 * `idProducto`, lo demas que compraron, primero el grupo de la misma categoria
 * que `idProducto` y despues el resto, y dentro de cada grupo por cuantas
 * cuentas distintas. La categoria sale de la copia del catalogo
 * (`producto_catalogo.id_categoria`), la misma que lleva el grafo.
 */
export async function tambienCompraronDesdePostgres(
  idProducto: number,
  candidatos: number,
): Promise<{ id: number; compradores: number; misma_categoria: boolean }[]> {
  const { rows } = await pool.query<{
    id: string;
    compradores: number;
    misma_categoria: boolean;
  }>(
    `WITH ${CTE_COMPRAS},
     origen AS (
       SELECT id_categoria FROM producto_catalogo WHERE id_producto_mongo = $2
     )
     SELECT otra.p AS id, count(DISTINCT base.u)::int AS compradores,
            COALESCE(pc.id_categoria = (SELECT id_categoria FROM origen), false)
              AS misma_categoria
       FROM compras base
       JOIN compras otra ON otra.u = base.u
       LEFT JOIN producto_catalogo pc ON pc.id_producto_mongo = otra.p
      WHERE base.p = $2 AND otra.p <> $2
      GROUP BY otra.p, pc.id_categoria
      ORDER BY misma_categoria DESC, compradores DESC, otra.p
      LIMIT $3`,
    [ESTADOS_DE_COMPRA, idProducto, candidatos],
  );
  return rows.map((fila) => ({
    id: Number(fila.id),
    compradores: fila.compradores,
    misma_categoria: fila.misma_categoria,
  }));
}
