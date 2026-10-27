import { Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import neo4j from 'neo4j-driver';
import { pool } from '../../database/postgres';
import { consultarGrafo, ejecutarGrafo } from '../../database/neo4j';

/**
 * La categoria de cada `:Producto` del grafo, al dia con la copia del catalogo
 * en PostgreSQL (`producto_catalogo.id_categoria` y el nombre de `categorias`).
 *
 * La necesita "quienes lo compraron tambien llevaron"
 * (`TambienCompraronService`), que ordena por grupos: primero los productos de
 * la misma categoria que el de la ficha. Con la categoria en el nodo, Neo4j
 * resuelve el orden en la misma consulta.
 *
 * Quien la escribe:
 * - Al proyectar una compra (`GrafoComprasSyncService`) o una resena
 *   (`GrafoSyncService`), y en el ETL (`etl/extraer_grafo.sql`): el nodo nace
 *   o se toca ya con su categoria.
 * - Este worker, cada minuto y al arrancar: compara la categoria de TODOS los
 *   `:Producto` contra PostgreSQL y corrige solo los que no coinciden. Asi se
 *   rellenan los nodos que ya existian antes de este cambio y se recoge un
 *   producto al que el admin le cambio la categoria, que no pasa por ninguna
 *   cola del grafo.
 *
 * Solo lee PostgreSQL y solo toca `:Producto` que ya existen: nunca crea un
 * nodo (un producto entra al grafo cuando alguien lo compra o lo resena). Con
 * Neo4j o PostgreSQL caidos la corrida se salta y la siguiente lo vuelve a
 * intentar.
 */
@Injectable()
export class GrafoCategoriasSyncService implements OnApplicationBootstrap {
  private readonly logger = new Logger(GrafoCategoriasSyncService.name);

  private static readonly INTERVALO_MS = 60000;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  /** Para avisar una vez cuando se cae y una vez cuando vuelve. */
  private fallando = false;

  onApplicationBootstrap(): void {
    // Sin await: el arranque del backend no espera al grafo.
    void this.sincronizar();
  }

  @Interval('grafo-categorias', GrafoCategoriasSyncService.INTERVALO_MS)
  async sincronizar(): Promise<number> {
    if (this.procesando) {
      return 0;
    }
    this.procesando = true;
    try {
      const { rows } = await pool.query<FilaCategoria>(SQL_CATEGORIAS);
      const enPostgres = new Map(rows.map((f) => [Number(f.id), f]));

      const nodos = await consultarGrafo<{
        id: unknown;
        id_categoria: unknown;
        categoria: unknown;
      }>(CYPHER_LEER);

      const cambios: Record<string, unknown>[] = [];
      for (const nodo of nodos) {
        const id = aNumero(nodo.id);
        const fila = enPostgres.get(id);
        const idCategoria = fila?.id_categoria ?? null;
        const categoria = fila?.categoria ?? null;
        const actualId =
          nodo.id_categoria == null ? null : String(aNumero(nodo.id_categoria));
        const actualNombre =
          typeof nodo.categoria === 'string' ? nodo.categoria : null;
        if (actualId !== idCategoria || actualNombre !== categoria) {
          cambios.push({
            id: neo4j.int(id),
            id_categoria: idCategoriaParaGrafo(idCategoria),
            categoria,
          });
        }
      }

      if (cambios.length > 0) {
        await ejecutarGrafo(CYPHER_ESCRIBIR, { cambios });
        this.logger.log(
          `worker de categorias del grafo: ${cambios.length} :Producto al dia`,
        );
      }
      if (this.fallando) {
        this.logger.log('worker de categorias del grafo: otra vez en marcha');
        this.fallando = false;
      }
      return cambios.length;
    } catch (error) {
      if (!this.fallando) {
        this.logger.warn(
          `worker de categorias del grafo: corrida interrumpida -- ${mensajeCorto(error)}`,
        );
        this.fallando = true;
      }
      return 0;
    } finally {
      this.procesando = false;
    }
  }
}

/**
 * El id de categoria como lo guarda el grafo: `Integer` de Neo4j, o null si el
 * producto no tiene categoria conocida. Un number crudo se guardaria como
 * `Float` y la comparacion `rec.id_categoria = base.id_categoria` seguiria
 * funcionando, pero el mismo dato quedaria con dos tipos segun quien lo
 * escribio.
 */
export function idCategoriaParaGrafo(
  idCategoria: string | null,
): ReturnType<typeof neo4j.int> | null {
  return idCategoria == null ? null : neo4j.int(idCategoria);
}

function aNumero(valor: unknown): number {
  return neo4j.isInt(valor)
    ? (valor as { toNumber(): number }).toNumber()
    : Number(valor);
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}

interface FilaCategoria {
  id: string;
  id_categoria: string | null;
  categoria: string | null;
}

/** La categoria de cada producto de la copia del catalogo. */
const SQL_CATEGORIAS = `
  SELECT pc.id_producto_mongo::text AS id,
         pc.id_categoria::text      AS id_categoria,
         c.nombre                   AS categoria
    FROM producto_catalogo pc
    LEFT JOIN categorias c ON c.id_categoria = pc.id_categoria
`;

const CYPHER_LEER = `
MATCH (p:Producto)
RETURN p.id AS id, p.id_categoria AS id_categoria, p.categoria AS categoria
`;

/** `MATCH` y no `MERGE`: este worker nunca crea un `:Producto`. */
const CYPHER_ESCRIBIR = `
UNWIND $cambios AS c
MATCH (p:Producto {id: c.id})
SET p.id_categoria = c.id_categoria, p.categoria = c.categoria
`;
