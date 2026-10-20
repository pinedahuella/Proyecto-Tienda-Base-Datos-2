import neo4j from 'neo4j-driver';
import { productosPorIds } from './catalogo-respaldo';
import { Producto } from '../models/producto';

/**
 * Lo comun a las recomendaciones que salen del grafo de compras (`:Compra`,
 * `GrafoComprasSyncService`): "para ti" (`ParaTiService`) y "tambien
 * compraron" (`TambienCompraronService`).
 */

/** Los enteros de Neo4j llegan como su `Integer` de 64 bits. */
export function aNumero(valor: unknown): number {
  return neo4j.isInt(valor)
    ? (valor as { toNumber(): number }).toNumber()
    : Number(valor);
}

/**
 * Los productos de `ids` que siguen `activo` en MongoDB, en el MISMO orden en
 * que vienen y hasta `limite`. El grafo no sabe del estado del catalogo; lo
 * publico nunca muestra un producto que no este activo. Sin Mongo salen de la
 * copia del catalogo en PostgreSQL (`productosPorIds`); si tampoco hay
 * PostgreSQL lanza, y cada servicio lo traduce con `manejarErrorConexionMongo`.
 */
export async function soloActivos(
  ids: number[],
  limite: number,
): Promise<Map<number, Producto>> {
  const productos = await productosPorIds(ids, { soloVisibles: true });
  const porId = new Map(productos.map((p) => [p._id, p]));
  const activos = new Map<number, Producto>();
  for (const id of ids) {
    const producto = porId.get(id);
    if (producto != null) {
      activos.set(id, producto);
      if (activos.size === limite) {
        break;
      }
    }
  }
  return activos;
}
