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
  misma_categoria: boolean;
}

/** Una fila de vecinos de `vector_producto`, del mas cercano al mas lejano. */
interface FilaCercana {
  id_producto_mongo: string;
  grupo: string;
  similitud: number;
}

export interface ProductoSimilar {
  id_producto: number;
  similitud: number;
  /** Si es de la misma categoria que el producto pedido: esos van siempre primero. */
  misma_categoria: boolean;
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
 *
 * Ordenado por bloques, igual que "quienes lo compraron tambien llevaron"
 * (`TambienCompraronService`, ADR-25): primero SIEMPRE los de la misma
 * categoria que el producto pedido, del mas parecido al menos, y despues el
 * resto del catalogo, tambien por parecido. Uno de la misma categoria con 0,40
 * va antes que otro de otra categoria con 0,80. La categoria es la de
 * `producto_catalogo.id_categoria`, la misma que lleva el grafo. Se pidio el
 * 2026-11-05 para la presentacion final.
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
      misma_categoria: fila.misma_categoria,
      producto: productoPorId.get(fila.id_producto) ?? null,
    }));
  }

  /** Vacio si el producto no existe o todavia no tiene vector. */
  private async buscarSimilares(idProducto: number): Promise<Similar[]> {
    try {
      const { rows: base } = await pool.query<{
        vector: string;
        grupo: string;
        id_categoria: string | null;
      }>(
        `SELECT v.vector::text AS vector, v.grupo, pc.id_categoria
           FROM vector_producto v
           LEFT JOIN producto_catalogo pc USING (id_producto_mongo)
          WHERE v.id_producto_mongo = $1`,
        [idProducto],
      );
      if (base.length === 0) {
        return [];
      }
      const { vector, grupo, id_categoria: categoria } = base[0];

      // Bloque 1, los de su misma categoria. Una categoria tiene decenas de
      // productos, asi que PostgreSQL los filtra primero por categoria y los
      // ordena por coseno contra todos ellos.
      const deSuCategoria =
        categoria === null
          ? []
          : await buscarCercanos<FilaCercana>(
              `SELECT v.id_producto_mongo, v.grupo,
                      1 - (v.vector <=> $1::vector) AS similitud
                 FROM vector_producto v
                 JOIN producto_catalogo pc USING (id_producto_mongo)
                WHERE v.activo
                  AND v.id_producto_mongo <> $2
                  AND v.grupo <> $3
                  AND pc.id_categoria = $4
                ORDER BY v.vector <=> $1::vector
                LIMIT $5`,
              [vector, idProducto, grupo, categoria, CANDIDATOS],
              CANDIDATOS * 2,
            );

      // Bloque 2, todo el catalogo. El vector va como parametro (no como
      // subconsulta) y sin JOIN: asi el ORDER BY puede usar el indice HNSW.
      const cercanos = await buscarCercanos<FilaCercana>(
        `SELECT id_producto_mongo, grupo, 1 - (vector <=> $1::vector) AS similitud
           FROM vector_producto
          WHERE activo
            AND id_producto_mongo <> $2
            AND grupo <> $3
          ORDER BY vector <=> $1::vector
          LIMIT $4`,
        [vector, idProducto, grupo, CANDIDATOS],
        CANDIDATOS * 2,
      );
      const categoriaDe = await this.categorias(
        cercanos.map((fila) => fila.id_producto_mongo),
      );

      // Llegan del mas cercano al mas lejano: el primero de cada grupo es el
      // que se queda. Primero se llena con su categoria y lo que falte, con
      // el resto. Los de su categoria ya entraron todos en el bloque 1.
      const vistos = new Set<string>();
      const similares: Similar[] = [];
      const agregar = (filas: FilaCercana[], mismaCategoria: boolean) => {
        for (const fila of filas) {
          if (similares.length === LIMITE) {
            return;
          }
          if (vistos.has(fila.grupo)) {
            continue;
          }
          if (
            !mismaCategoria &&
            categoria !== null &&
            categoriaDe.get(fila.id_producto_mongo) === categoria
          ) {
            continue;
          }
          vistos.add(fila.grupo);
          similares.push({
            id_producto: Number(fila.id_producto_mongo),
            similitud: fila.similitud,
            misma_categoria: mismaCategoria,
          });
        }
      };
      agregar(deSuCategoria, true);
      agregar(cercanos, false);
      return similares;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** La categoria de cada producto, de `producto_catalogo`. */
  private async categorias(ids: string[]): Promise<Map<string, string | null>> {
    if (ids.length === 0) {
      return new Map();
    }
    const { rows } = await pool.query<{
      id_producto_mongo: string;
      id_categoria: string | null;
    }>(
      `SELECT id_producto_mongo, id_categoria
         FROM producto_catalogo
        WHERE id_producto_mongo = ANY($1::bigint[])`,
      [ids],
    );
    return new Map(
      rows.map((fila) => [fila.id_producto_mongo, fila.id_categoria]),
    );
  }
}
