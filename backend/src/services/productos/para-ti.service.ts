import { Injectable, Logger } from '@nestjs/common';
import neo4j from 'neo4j-driver';
import {
  consultarGrafo,
  LIMITE_CONSULTA_PAGINA_MS,
} from '../../database/neo4j';
import { ErrorConexion, ErrorValidacion } from '../../helpers/errores';
import { manejarErrorGrafo } from '../../helpers/manejar-error-grafo';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { aNumero, soloActivos } from '../../helpers/recomendaciones-grafo';
import {
  conRespaldoDeNeo4j,
  paraTiDesdePostgres,
} from '../../helpers/recomendaciones-respaldo';
import { Producto } from '../../models/producto';

/** Cuantas recomendaciones devuelve la ruta. */
const LIMITE = 10;

/** Cuantos candidatos se piden al grafo antes de quedarse con los activos. */
const CANDIDATOS = 50;

/** Cuantos productos tuyos se devuelven como motivo de cada recomendacion. */
const MAX_PORQUE = 5;

/** De cuantos productos comprados se parte, si no se pide otra cosa, y el tope. */
const MAX_PRODUCTOS_DEFECTO = 10;
const MAX_PRODUCTOS_TOPE = 50;

/** Una recomendacion de "para ti". */
export interface ProductoParaTi {
  id_producto: number;
  /** Cuantas cuentas que compraron algo que tu compraste tambien compraron este. */
  compradores: number;
  /** Los productos que compraste y que esas cuentas tambien compraron. */
  porque_compraste: number[];
  producto: Producto;
}

/**
 * "Para ti" (`GET /productos/para-ti`): lo que compraron las cuentas que
 * compraron lo mismo que tu, y tu todavia no. Sale del grafo de Neo4j, de los
 * nodos `:Compra` que mantiene `GrafoComprasSyncService`:
 *
 *   tu -[:HIZO]-> compra -[:DE]-> un producto <-[:DE]- compra <-[:HIZO]- otra cuenta
 *   otra cuenta -[:HIZO]-> compra -[:DE]-> otro producto
 *
 * Se parte de tus `max_productos` productos comprados MAS RECIENTES (por la
 * fecha de tu ultima compra de cada uno): lo que compraste hace un ano dice
 * menos de lo que buscas hoy. Pero nunca se recomienda nada que ya compraste,
 * reciente o no. Ordenado por cuantas cuentas distintas llevan a cada
 * producto. Es la pregunta para la que esta hecho un grafo: un recorrido corto
 * desde una cuenta, en vivo, sin worker ni cache. Hasta el 2026-10-16 era R3 de
 * ClickHouse (las vistas de las sesiones, recalculadas cada 15 min en Redis).
 *
 * Solo productos `activo`: el detalle se pide a MongoDB con ese filtro, como
 * las demas rutas publicas. Una cuenta sin compras, o cuyas compras no
 * comparte nadie, recibe `[]`; caer a otra lista ("mas vistos") lo decide
 * quien llama.
 */
@Injectable()
export class ParaTiService {
  private readonly logger = new Logger(ParaTiService.name);

  async obtener(
    idUsuario: number,
    maxProductos?: string,
  ): Promise<ProductoParaTi[]> {
    const semillas = this.aMaxProductos(maxProductos);
    const candidatos = await this.candidatos(idUsuario, semillas);
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
        porque_compraste: c.porque,
        producto: activos.get(c.id)!,
      }));
  }

  /** `max_productos` es opcional: entero de 1 a `MAX_PRODUCTOS_TOPE`. */
  private aMaxProductos(valor: string | undefined): number {
    if (valor == null || valor === '') {
      return MAX_PRODUCTOS_DEFECTO;
    }
    const numero = Number(valor);
    if (
      !Number.isInteger(numero) ||
      numero < 1 ||
      numero > MAX_PRODUCTOS_TOPE
    ) {
      throw new ErrorValidacion(
        `max_productos debe ser un numero entero de 1 a ${MAX_PRODUCTOS_TOPE}`,
      );
    }
    return numero;
  }

  /** Los productos recomendados por el grafo, del mas al menos compartido. */
  private async candidatos(
    idUsuario: number,
    maxProductos: number,
  ): Promise<{ id: number; compradores: number; porque: number[] }[]> {
    try {
      // Sin Neo4j, la misma pregunta sobre los pedidos en PostgreSQL
      // (recomendaciones-respaldo.ts, 2026-10-20).
      return await conRespaldoDeNeo4j(
        async () => {
          const filas = await consultarGrafo<{
            id: unknown;
            compradores: unknown;
            porque: unknown[];
          }>(
            CYPHER_PARA_TI,
            {
              id: neo4j.int(idUsuario),
              maxProductos: neo4j.int(maxProductos),
              candidatos: neo4j.int(CANDIDATOS),
              maxPorque: neo4j.int(MAX_PORQUE),
            },
            LIMITE_CONSULTA_PAGINA_MS,
          );
          return filas.map((fila) => ({
            id: aNumero(fila.id),
            compradores: aNumero(fila.compradores),
            porque: fila.porque.map(aNumero),
          }));
        },
        () =>
          paraTiDesdePostgres(idUsuario, maxProductos, CANDIDATOS, MAX_PORQUE),
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
 * 1. Tus `$maxProductos` productos comprados mas recientes (los "comunes").
 * 2. Las OTRAS cuentas que compraron alguno de ellos, y lo que compraron.
 * 3. Sin nada que ya compraste (de cualquier fecha).
 * Cada recomendacion trae cuantas cuentas distintas llevan a ella y cuales de
 * tus productos las conectan. Empate: el id mas bajo, para que la respuesta
 * sea estable.
 */
const CYPHER_PARA_TI = `
MATCH (yo:Usuario {id: $id})-[:HIZO]->(k:Compra)-[:DE]->(comun:Producto)
WITH yo, comun, max(k.fecha) AS ultima
ORDER BY ultima DESC, comun.id
LIMIT $maxProductos
MATCH (comun)<-[:DE]-(:Compra)<-[:HIZO]-(otro:Usuario)
WHERE otro <> yo
MATCH (otro)-[:HIZO]->(:Compra)-[:DE]->(rec:Producto)
WHERE NOT (yo)-[:HIZO]->(:Compra)-[:DE]->(rec)
WITH rec, count(DISTINCT otro) AS compradores, collect(DISTINCT comun.id) AS porque
RETURN rec.id AS id, compradores, porque[0..$maxPorque] AS porque
ORDER BY compradores DESC, id
LIMIT $candidatos
`;
