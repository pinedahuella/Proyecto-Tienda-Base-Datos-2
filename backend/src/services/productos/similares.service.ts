import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../../database/elastic';
import { mongoDb } from '../../database/mongo';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { Producto } from '../../models/producto';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';
const LIMITE = 6;
/** Cuantos vecinos se piden antes de quedarse con uno por grupo. Igual que el
 * `LIMIT 200` de `productos_similares()` (migracion 027). */
const CANDIDATOS = 200;

interface DocumentoVector {
  vector?: number[];
  vector_grupo?: string;
}

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
 * Solo une dos piezas: la busqueda kNN sobre el campo `vector` de
 * `mesh_productos` (Elasticsearch) dice CUALES ids son parecidos, y esta clase
 * le pide a MongoDB el detalle para pintar la tarjeta -- mismo patron de
 * enriquecido que `TambienVieronSyncService.consultarProductosPorId`. Sin
 * cache: el kNN sobre el indice es rapido.
 *
 * Mismas reglas que tenia `productos_similares()` en PostgreSQL (migracion
 * 027): solo productos activos, nunca el mismo producto, nunca uno del mismo
 * `grupo` que el base (las copias del generador que solo cambian el nombre),
 * y uno solo por grupo, el mas cercano.
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
      const productos = await mongoDb
        .collection<Producto>('productos')
        .find({ _id: { $in: ids } })
        .toArray();
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

  /** Vacio si el producto no existe en el indice o todavia no tiene vector. */
  private async buscarSimilares(idProducto: number): Promise<Similar[]> {
    try {
      const base = await elasticClient.get<DocumentoVector>(
        {
          index: INDICE,
          id: String(idProducto),
          _source_includes: ['vector', 'vector_grupo'],
        },
        { ignore: [404] },
      );
      const vector = base.found ? base._source?.vector : undefined;
      if (!vector) {
        return [];
      }
      const grupoBase = base._source?.vector_grupo;

      const respuesta = await elasticClient.search<DocumentoVector>({
        index: INDICE,
        size: CANDIDATOS,
        _source: ['vector_grupo'],
        knn: {
          field: 'vector',
          query_vector: vector,
          k: CANDIDATOS,
          num_candidates: CANDIDATOS * 2,
          filter: {
            bool: {
              filter: [{ term: { estado: 'activo' } }],
              must_not: [
                { ids: { values: [String(idProducto)] } },
                ...(grupoBase ? [{ term: { vector_grupo: grupoBase } }] : []),
              ],
            },
          },
        },
      });

      // Los resultados llegan del mas cercano al mas lejano: el primero de
      // cada grupo es el que se queda.
      const vistos = new Set<string>();
      const similares: Similar[] = [];
      for (const hit of respuesta.hits.hits) {
        const clave = hit._source?.vector_grupo ?? `id:${hit._id}`;
        if (vistos.has(clave)) {
          continue;
        }
        vistos.add(clave);
        similares.push({
          id_producto: Number(hit._id),
          // En coseno, Elasticsearch puntua (1 + coseno) / 2: se devuelve al
          // coseno (1 - distancia), la misma escala que daba pgvector.
          similitud: 2 * (hit._score ?? 0) - 1,
        });
        if (similares.length === LIMITE) {
          break;
        }
      }
      return similares;
    } catch (error) {
      manejarErrorConexionElastic(this.logger, error);
    }
  }
}
