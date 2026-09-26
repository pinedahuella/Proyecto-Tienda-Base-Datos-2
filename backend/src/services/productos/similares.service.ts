import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { mongoDb } from '../../database/mongo';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { Producto } from '../../models/producto';

const LIMITE = 6;

interface FilaSimilar {
  id_producto: string;
  similitud: number;
}

export interface ProductoSimilar {
  id_producto: number;
  similitud: number;
  producto: Producto | null;
}

/**
 * Recomendacion semantica de la Entrega final (`GET /productos/:id/similares`).
 * Solo une dos piezas ya construidas: `productos_similares()` en PostgreSQL
 * (migracion 024, pgvector) dice CUALES ids son parecidos, y esta clase le
 * pide a MongoDB el detalle para pintar la tarjeta -- mismo patron de
 * enriquecido que `TambienVieronSyncService.consultarProductosPorId`. Sin
 * cache: la funcion ya es rapida por el indice HNSW.
 */
@Injectable()
export class SimilaresService {
  private readonly logger = new Logger(SimilaresService.name);

  async obtener(idProducto: number): Promise<ProductoSimilar[]> {
    let filas: FilaSimilar[];
    try {
      const resultado = await pool.query<FilaSimilar>(
        'SELECT id_producto, similitud FROM productos_similares($1, $2)',
        [idProducto, LIMITE],
      );
      filas = resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (filas.length === 0) {
      return [];
    }

    const ids = filas.map((fila) => Number(fila.id_producto));
    let productoPorId: Map<number, Producto>;
    try {
      const productos = await mongoDb
        .collection<Producto>('productos')
        .find({ _id: { $in: ids } })
        .toArray();
      productoPorId = new Map(productos.map((p) => [p._id, p]));
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }

    return filas.map((fila) => ({
      id_producto: Number(fila.id_producto),
      similitud: Number(fila.similitud),
      producto: productoPorId.get(Number(fila.id_producto)) ?? null,
    }));
  }
}
