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

/**
 * Cuanto pesa cada parte del puntaje que ordena Parecidos a este (2026-11-08).
 * Manda el parecido general, el del texto con nombre, categoria y descripcion.
 * Suma el de las caracteristicas (migracion 055) y un poco la nota de las
 * resenas. Suman 1, asi que el puntaje va de 0 a 1 igual que el parecido.
 */
export const PESO_GENERAL = 0.7;
export const PESO_CARACTERISTICAS = 0.2;
export const PESO_NOTA = 0.1;
/** La nota es un promedio bayesiano: se le suman RESENAS_PREVIAS resenas
 * imaginarias de NOTA_PREVIA estrellas. Asi una sola resena de 5 no le gana a
 * veinte buenas, y un producto sin resenas cuenta como de 3 estrellas. */
export const RESENAS_PREVIAS = 2;
export const NOTA_PREVIA = 3;

interface Similar {
  id_producto: number;
  similitud: number;
  misma_categoria: boolean;
  puntaje: number;
  parecido_caracteristicas: number | null;
  nota_resenas: number | null;
}

/** Una fila de vecinos de `vector_producto`, del mas cercano al mas lejano. */
interface FilaCercana {
  id_producto_mongo: string;
  grupo: string;
  similitud: number;
}

/** Un candidato ya puntuado. */
interface Puntuado extends FilaCercana {
  puntaje: number;
  parecido_caracteristicas: number | null;
  nota_resenas: number | null;
}

export interface ProductoSimilar {
  id_producto: number;
  /** El parecido general, `1 - distancia` del vector de nombre, categoria y
   * descripcion. */
  similitud: number;
  /** Si es de la misma categoria que el producto pedido: esos van siempre primero. */
  misma_categoria: boolean;
  /** Lo que ordena cada bloque: 0,7 del parecido general, 0,2 del de
   * caracteristicas y 0,1 de la nota. */
  puntaje: number;
  /** `1 - distancia` de los vectores de caracteristicas, o null si a alguno de
   * los dos le falta. Entonces en el puntaje vale lo mismo que el general. */
  parecido_caracteristicas: number | null;
  /** El promedio de estrellas de sus resenas publicadas, o null si no tiene. */
  nota_resenas: number | null;
  producto: Producto | null;
}

/**
 * El puntaje de un candidato. Si a alguno de los dos productos le faltan las
 * caracteristicas, esa parte vale lo mismo que el parecido general, asi no
 * gana ni pierde por eso.
 */
export function puntajeDe(
  general: number,
  caracteristicas: number | null,
  promedio: number | null,
  totalResenas: number,
): number {
  const suma = (promedio ?? 0) * totalResenas;
  const nota =
    (suma + RESENAS_PREVIAS * NOTA_PREVIA) / (totalResenas + RESENAS_PREVIAS);
  return (
    PESO_GENERAL * general +
    PESO_CARACTERISTICAS * (caracteristicas ?? general) +
    PESO_NOTA * (nota / 5)
  );
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
 *
 * Desde el 2026-11-08, por mas campos (migracion 055). Dentro de cada bloque
 * no ordena solo el parecido general: cada candidato lleva un puntaje, 0,7 del
 * parecido general (nombre, categoria y descripcion), 0,2 del parecido de sus
 * caracteristicas y 0,1 de la nota de sus resenas (`puntajeDe`). Los
 * candidatos son los mismos de antes, todos los de su categoria y los 200 mas
 * cercanos por el indice HNSW, y despues se puntuan (`puntuar`).
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
      puntaje: fila.puntaje,
      parecido_caracteristicas: fila.parecido_caracteristicas,
      nota_resenas: fila.nota_resenas,
      producto: productoPorId.get(fila.id_producto) ?? null,
    }));
  }

  /** Vacio si el producto no existe o todavia no tiene vector. */
  private async buscarSimilares(idProducto: number): Promise<Similar[]> {
    try {
      const { rows: base } = await pool.query<{
        vector: string;
        vector_caracteristicas: string | null;
        grupo: string;
        id_categoria: string | null;
      }>(
        `SELECT v.vector::text AS vector,
                v.vector_caracteristicas::text AS vector_caracteristicas,
                v.grupo, pc.id_categoria
           FROM vector_producto v
           LEFT JOIN producto_catalogo pc USING (id_producto_mongo)
          WHERE v.id_producto_mongo = $1`,
        [idProducto],
      );
      if (base.length === 0) {
        return [];
      }
      const {
        vector,
        vector_caracteristicas: vectorCarac,
        grupo,
        id_categoria: categoria,
      } = base[0];

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

      // Los candidatos de los dos bloques se puntuan juntos: parecido general,
      // parecido de caracteristicas y nota. Cada bloque queda del puntaje mas
      // alto al mas bajo; en un empate, el id mas bajo, para que sea estable.
      const puntuados = await this.puntuar(
        [...deSuCategoria, ...cercanos],
        vectorCarac,
      );
      const enOrden = (filas: FilaCercana[]) =>
        filas
          .map((fila) => puntuados.get(fila.id_producto_mongo)!)
          .sort(
            (a, b) =>
              b.puntaje - a.puntaje ||
              Number(a.id_producto_mongo) - Number(b.id_producto_mongo),
          );

      // El primero de cada grupo es el que se queda, el de mejor puntaje.
      // Primero se llena con su categoria y lo que falte, con el resto. Los de
      // su categoria ya entraron todos en el bloque 1.
      const vistos = new Set<string>();
      const similares: Similar[] = [];
      const agregar = (filas: Puntuado[], mismaCategoria: boolean) => {
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
            puntaje: fila.puntaje,
            parecido_caracteristicas: fila.parecido_caracteristicas,
            nota_resenas: fila.nota_resenas,
          });
        }
      };
      agregar(enOrden(deSuCategoria), true);
      agregar(enOrden(cercanos), false);
      return similares;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * El puntaje de cada candidato. Solo mira los candidatos, por su id, asi la
   * consulta de los vecinos sigue usando el indice HNSW y esta compara unos
   * cientos de filas. El parecido de caracteristicas sale de PostgreSQL, sin
   * traer los vectores, y la nota de las resenas publicadas de `resena`.
   */
  private async puntuar(
    filas: FilaCercana[],
    vectorCarac: string | null,
  ): Promise<Map<string, Puntuado>> {
    const ids = [...new Set(filas.map((fila) => fila.id_producto_mongo))];
    if (ids.length === 0) {
      return new Map();
    }
    const { rows } = await pool.query<{
      id_producto_mongo: string;
      parecido_caracteristicas: number | null;
      promedio: number | null;
      total: number;
    }>(
      `SELECT v.id_producto_mongo,
              CASE WHEN v.vector_caracteristicas IS NULL OR $2::vector IS NULL
                   THEN NULL
                   ELSE 1 - (v.vector_caracteristicas <=> $2::vector)
              END AS parecido_caracteristicas,
              r.promedio,
              coalesce(r.total, 0)::int AS total
         FROM vector_producto v
         LEFT JOIN (
               SELECT id_producto_mongo,
                      avg(calificacion)::float8 AS promedio,
                      count(*) AS total
                 FROM resena
                WHERE id_estado_resena = 1
                  AND id_producto_mongo = ANY($1::bigint[])
                GROUP BY id_producto_mongo
              ) r USING (id_producto_mongo)
        WHERE v.id_producto_mongo = ANY($1::bigint[])`,
      [ids, vectorCarac],
    );
    const extra = new Map(rows.map((fila) => [fila.id_producto_mongo, fila]));
    const puntuados = new Map<string, Puntuado>();
    for (const fila of filas) {
      const e = extra.get(fila.id_producto_mongo);
      const caracteristicas = e?.parecido_caracteristicas ?? null;
      const promedio = e?.promedio ?? null;
      const total = e?.total ?? 0;
      puntuados.set(fila.id_producto_mongo, {
        ...fila,
        puntaje: puntajeDe(fila.similitud, caracteristicas, promedio, total),
        parecido_caracteristicas: caracteristicas,
        nota_resenas: promedio,
      });
    }
    return puntuados;
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
