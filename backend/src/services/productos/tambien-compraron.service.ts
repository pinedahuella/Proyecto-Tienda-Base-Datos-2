import { Injectable, Logger } from '@nestjs/common';
import neo4j from 'neo4j-driver';
import {
  consultarGrafo,
  LIMITE_CONSULTA_PAGINA_MS,
} from '../../database/neo4j';
import { manejarErrorGrafo } from '../../helpers/manejar-error-grafo';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { ErrorConexion } from '../../helpers/errores';
import { aNumero, soloActivos } from '../../helpers/recomendaciones-grafo';
import {
  conRespaldoDeNeo4j,
  tambienCompraronDesdePostgres,
} from '../../helpers/recomendaciones-respaldo';
import { Producto } from '../../models/producto';

/** Cuantas recomendaciones devuelve la ruta. */
const LIMITE = 6;

/** Cuantos candidatos se piden al grafo antes de quedarse con los activos. */
const CANDIDATOS = 30;

/** Una recomendacion de "tambien compraron". */
export interface ProductoTambienComprado {
  id_producto: number;
  /** Cuantas cuentas que compraron el producto pedido tambien compraron este. */
  compradores: number;
  /** Si es de la misma categoria que el producto pedido: esos van siempre primero. */
  misma_categoria: boolean;
  producto: Producto;
}

/**
 * "Quienes compraron esto tambien compraron"
 * (`GET /productos/:id/tambien-compraron`), pensada para cuando se agrega un
 * producto al carrito: sugerir que mas llevar. Sale del grafo de Neo4j, de los
 * nodos `:Compra` que mantiene `GrafoComprasSyncService`:
 *
 *   el producto <-[:DE]- compra <-[:HIZO]- cuenta -[:HIZO]-> compra -[:DE]-> otro producto
 *
 * Ordenado por grupos: primero SIEMPRE los de la misma categoria que el
 * producto pedido, despues el resto, y dentro de cada grupo por cuantas
 * cuentas distintas compraron los dos. Uno de la misma categoria con un solo
 * comprador va antes que otro de otra categoria con veinte. La categoria vive
 * en el propio `:Producto` (`id_categoria`, ver `GrafoCategoriasSyncService`),
 * asi que el orden lo resuelve Neo4j en la misma consulta. Es la hermana de
 * "para ti" (`ParaTiService`), pero parte de un producto y no de una cuenta, asi
 * que es publica: no hace falta sesion. Solo productos `activo`, y nunca el
 * mismo producto. Un producto que nadie compro, o que nadie compro junto con
 * otro, recibe `[]`.
 *
 * Es la version por compras de "tambien vieron" (`TambienVieronService`, que
 * sale de las vistas en ClickHouse).
 */
@Injectable()
export class TambienCompraronService {
  private readonly logger = new Logger(TambienCompraronService.name);

  async obtener(idProducto: number): Promise<ProductoTambienComprado[]> {
    const candidatos = await this.candidatos(idProducto);
    if (candidatos.length === 0) {
      return [];
    }

    let activos: Map<number, Producto>;
    try {
      activos = await soloActivos(
        candidatos.map((c) => c.id),
        LIMITE,
      );
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }

    return candidatos
      .filter((c) => activos.has(c.id))
      .map((c) => ({
        id_producto: c.id,
        compradores: c.compradores,
        misma_categoria: c.misma_categoria,
        producto: activos.get(c.id)!,
      }));
  }

  private async candidatos(
    idProducto: number,
  ): Promise<{ id: number; compradores: number; misma_categoria: boolean }[]> {
    try {
      // Sin Neo4j, la misma pregunta sobre los pedidos en PostgreSQL
      // (recomendaciones-respaldo.ts, 2026-10-20).
      return await conRespaldoDeNeo4j(
        async () => {
          const filas = await consultarGrafo<{
            id: unknown;
            compradores: unknown;
            misma_categoria: unknown;
          }>(
            CYPHER_TAMBIEN_COMPRARON,
            {
              id: neo4j.int(idProducto),
              candidatos: neo4j.int(CANDIDATOS),
            },
            LIMITE_CONSULTA_PAGINA_MS,
          );
          return filas.map((fila) => ({
            id: aNumero(fila.id),
            compradores: aNumero(fila.compradores),
            misma_categoria: fila.misma_categoria === true,
          }));
        },
        () => tambienCompraronDesdePostgres(idProducto, CANDIDATOS),
      );
    } catch (error) {
      if (error instanceof ErrorConexion) {
        throw error;
      }
      manejarErrorGrafo(this.logger, error);
    }
  }
}

/**
 * Las cuentas que compraron el producto, y lo demas que compraron. El orden va
 * por grupos: `grupo` 0 es la misma categoria que el producto pedido y 1 todo
 * lo demas (tambien cuando alguno de los dos no tiene categoria en el grafo).
 * Dentro del grupo, mas compradores primero; empate, el id mas bajo, para que
 * la respuesta sea estable. El `LIMIT` corta despues de ordenar, asi que los
 * candidatos ya llegan con su grupo delante.
 */
const CYPHER_TAMBIEN_COMPRARON = `
MATCH (base:Producto {id: $id})<-[:DE]-(:Compra)<-[:HIZO]-(cuenta:Usuario)
MATCH (cuenta)-[:HIZO]->(:Compra)-[:DE]->(rec:Producto)
WHERE rec <> base
WITH base, rec, count(DISTINCT cuenta) AS compradores
WITH rec, compradores,
     CASE WHEN base.id_categoria IS NOT NULL
               AND rec.id_categoria = base.id_categoria
          THEN 0 ELSE 1 END AS grupo
RETURN rec.id AS id, compradores, grupo = 0 AS misma_categoria
ORDER BY grupo, compradores DESC, id
LIMIT $candidatos
`;
