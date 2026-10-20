import { Injectable, Logger } from '@nestjs/common';
import { productosPorIds } from '../../helpers/catalogo-respaldo';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { buscarCercanos } from '../../helpers/vectores-pgvector';
import { Producto } from '../../models/producto';

const LIMITE = 6;
/** Cuantos vecinos se piden antes de quedarse con uno por grupo. Igual que el
 * `LIMIT 200` que tenia `productos_similares()` (migracion 027). */
const CANDIDATOS = 200;

interface Similar {
  id_producto: number;
  similitud: number;
}

export interface ProductoSimilar {
  id_producto: number;
  similitud: number;
  producto: Producto | null;
}

/**
 * Recomendacion semantica de la Entrega final (`GET /productos/:id/similares`).
 * Solo une dos piezas: la busqueda de vecinos sobre `vector_producto`
 * (PostgreSQL, pgvector) dice CUALES ids son parecidos, y esta clase le pide a
 * MongoDB el detalle para pintar la tarjeta -- mismo patron de enriquecido que
 * `TambienVieronSyncService.consultarProductosPorId`. Sin cache: la busqueda
 * sobre el indice HNSW es rapida.
 *
 * Mismas reglas que tenia `productos_similares()` (migracion 027): solo
 * productos activos, nunca el mismo producto, nunca uno del mismo `grupo` que
 * el base (las copias del generador que solo cambian el nombre), y uno solo
 * por grupo, el mas cercano.
 */
@Injectable()
export class SimilaresService {
  private readonly logger = new Logger(SimilaresService.name);

  async obtener(idProducto: number): Promise<ProductoSimilar[]> {
    const filas = await this.buscarSimilares(idProducto);

    if (filas.length === 0) {
      return [];
    }

    const ids = filas.map((fila) => fila.id_producto);
    let productoPorId: Map<number, Producto>;
    try {
      // Sin Mongo, de la copia del catalogo en PostgreSQL.
      const productos = await productosPorIds(ids, { soloVisibles: false });
      productoPorId = new Map(productos.map((p) => [p._id, p]));
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }

    return filas.map((fila) => ({
      id_producto: fila.id_producto,
      similitud: fila.similitud,
      producto: productoPorId.get(fila.id_producto) ?? null,
    }));
  }

  /** Vacio si el producto no existe o todavia no tiene vector. */
  private async buscarSimilares(idProducto: number): Promise<Similar[]> {
    try {
      const { rows: base } = await pool.query<{
        vector: string;
        grupo: string;
      }>(
        `SELECT vector::text AS vector, grupo
           FROM vector_producto
          WHERE id_producto_mongo = $1`,
        [idProducto],
      );
      if (base.length === 0) {
        return [];
      }

      // El vector va como parametro (no como subconsulta): asi el ORDER BY
      // puede usar el indice HNSW.
      const cercanos = await buscarCercanos<{
        id_producto_mongo: string;
        grupo: string;
        similitud: number;
      }>(
        `SELECT id_producto_mongo, grupo, 1 - (vector <=> $1::vector) AS similitud
           FROM vector_producto
          WHERE activo
            AND id_producto_mongo <> $2
            AND grupo <> $3
          ORDER BY vector <=> $1::vector
          LIMIT $4`,
        [base[0].vector, idProducto, base[0].grupo, CANDIDATOS],
        CANDIDATOS * 2,
      );

      // Llegan del mas cercano al mas lejano: el primero de cada grupo es el
      // que se queda.
      const vistos = new Set<string>();
      const similares: Similar[] = [];
      for (const fila of cercanos) {
        if (vistos.has(fila.grupo)) {
          continue;
        }
        vistos.add(fila.grupo);
        similares.push({
          id_producto: Number(fila.id_producto_mongo),
          similitud: fila.similitud,
        });
        if (similares.length === LIMITE) {
          break;
        }
      }
      return similares;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}
