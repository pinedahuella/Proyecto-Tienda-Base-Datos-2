import { Injectable, Logger } from '@nestjs/common';
import neo4j from 'neo4j-driver';
import { consultarGrafo } from '../../database/neo4j';
import { manejarErrorGrafo } from '../../helpers/manejar-error-grafo';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { aNumero, soloActivos } from '../../helpers/recomendaciones-grafo';
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
 * Ordenado por cuantas cuentas distintas compraron los dos. Es la hermana de
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
        producto: activos.get(c.id)!,
      }));
  }

  private async candidatos(
    idProducto: number,
  ): Promise<{ id: number; compradores: number }[]> {
    try {
      const filas = await consultarGrafo<{ id: unknown; compradores: unknown }>(
        CYPHER_TAMBIEN_COMPRARON,
        {
          id: neo4j.int(idProducto),
          candidatos: neo4j.int(CANDIDATOS),
        },
      );
      return filas.map((fila) => ({
        id: aNumero(fila.id),
        compradores: aNumero(fila.compradores),
      }));
    } catch (error) {
      manejarErrorGrafo(this.logger, error);
    }
  }
}

/**
 * Las cuentas que compraron el producto, y lo demas que compraron. Empate: el
 * id mas bajo, para que la respuesta sea estable.
 */
const CYPHER_TAMBIEN_COMPRARON = `
MATCH (base:Producto {id: $id})<-[:DE]-(:Compra)<-[:HIZO]-(cuenta:Usuario)
MATCH (cuenta)-[:HIZO]->(:Compra)-[:DE]->(rec:Producto)
WHERE rec <> base
WITH rec, count(DISTINCT cuenta) AS compradores
RETURN rec.id AS id, compradores
ORDER BY compradores DESC, id
LIMIT $candidatos
`;
