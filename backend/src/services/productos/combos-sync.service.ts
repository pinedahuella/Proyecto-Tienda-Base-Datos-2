import { Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { clickhouse } from '../../database/clickhouse';
import { redis } from '../../database/redis';
import {
  TarjetaProducto,
  tarjetasDeProductos,
} from '../../helpers/tarjetas-producto';

/** Un combo listo para mostrar: los productos que se compran juntos. */
export interface Combo {
  /** En cuantos pedidos distintos aparecen todos juntos. */
  pedidos: number;
  /** Dos o tres productos, en orden de id. */
  productos: TarjetaProducto[];
}

interface FilaComboClickHouse {
  /** `Array(UInt64)`: los ids llegan como texto. */
  productos: string[];
  pedidos: string;
}

/**
 * Worker de los COMBOS: los grupos de 2 y 3 productos que mas se compran en
 * el MISMO pedido, en toda la tienda. Es un conteo sobre todas las compras
 * (`compra_producto` de ClickHouse), sin un punto de partida: lo que
 * ClickHouse hace bien. La version "con este producto suelen llevar" no va
 * aqui: esa parte de un producto y es un recorrido del grafo
 * (`TambienCompraronService`).
 *
 * Por cada pedido de la ventana se arman todos sus pares y sus trios, y se
 * cuenta en cuantos pedidos aparece cada grupo. Reglas:
 *
 * - Solo pedidos de los ultimos `VENTANA_DIAS`, sin los cancelados (los que
 *   tienen fila en `devolucion_producto`) y solo `lote = 'real'`, igual que
 *   los demas rankings: nunca mezcla datos sembrados.
 * - Un grupo cuenta como combo si aparece en `MIN_PEDIDOS` pedidos o mas.
 * - Hasta trios: con 4 o mas, las combinaciones de un pedido grande se
 *   disparan y casi nunca se repiten en otro. Por lo mismo, un pedido de mas
 *   de `MAX_PRODUCTOS_POR_PEDIDO` productos distintos no entra (seria una
 *   compra al por mayor, no un combo).
 * - Un par que esta dentro de un trio igual de frecuente no se muestra: el
 *   trio ya lo dice.
 * - Solo combos cuyos productos sigan TODOS `activo`.
 *
 * Mismo patron que `MasVendidosSyncService`: el worker consulta ClickHouse y
 * Mongo una vez por corrida y deja en Redis el JSON ya listo (con la tarjeta
 * de cada producto); `GET /productos/combos` solo lee Redis. Un combo puede
 * estar hasta `INTERVALO_MS` desactualizado. Corre tambien al arrancar.
 * Nunca lanza: un fallo se loguea y se reintenta en la proxima corrida.
 */
@Injectable()
export class CombosSyncService implements OnApplicationBootstrap {
  private readonly logger = new Logger(CombosSyncService.name);

  /** STRING con el arreglo de `Combo` en JSON. */
  static readonly CLAVE = 'mesh:productos:combos';

  /** Cada 30 minutos: lo que se compra junto cambia despacio. */
  private static readonly INTERVALO_MS = 30 * 60 * 1000;

  private static readonly VENTANA_DIAS = 180;
  private static readonly MIN_PEDIDOS = 2;
  private static readonly MAX_PRODUCTOS_POR_PEDIDO = 30;

  /** Cuantos combos se piden a ClickHouse y cuantos se guardan. */
  private static readonly CANDIDATOS = 100;
  private static readonly TOPE_ALMACENADO = 20;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  @Interval('combos-sync', CombosSyncService.INTERVALO_MS)
  async recalcular(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      const { combos, grupos } = await this.calcular();
      // Una sola clave: SET la reemplaza de una vez, nadie lee una a medias.
      await redis.set(CombosSyncService.CLAVE, JSON.stringify(combos));
      this.logger.log(
        `worker de combos: ${combos.length} combo(s) guardados (${grupos} grupo(s) en ${CombosSyncService.MIN_PEDIDOS}+ pedidos de los ultimos ${CombosSyncService.VENTANA_DIAS} dias)`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de combos: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /** Ver el comentario de la clase -- corre una vez, al arrancar. */
  async onApplicationBootstrap(): Promise<void> {
    await this.recalcular();
  }

  /**
   * El calculo de una corrida, sin tocar Redis: los grupos de ClickHouse y la
   * tarjeta de cada producto. Un combo con algun producto que ya no esta
   * `activo` no sale entero. `grupos` es cuantos grupos dio ClickHouse, para
   * el log. Lo usa el worker para llenar Redis y `CombosService` cuando Redis
   * no esta (2026-10-20).
   */
  async calcular(): Promise<{ combos: Combo[]; grupos: number }> {
    const grupos = quitarParesDentroDeTrios(await this.consultarCombos());
    const tarjetas = await tarjetasDeProductos([
      ...new Set(grupos.flatMap((g) => g.productos)),
    ]);
    const combos: Combo[] = [];
    for (const grupo of grupos) {
      const productos = grupo.productos
        .map((id) => tarjetas.get(id))
        .filter((p): p is TarjetaProducto => p != null);
      // Si alguno ya no esta activo, el combo entero no se muestra.
      if (productos.length === grupo.productos.length) {
        combos.push({ pedidos: grupo.pedidos, productos });
      }
      if (combos.length === CombosSyncService.TOPE_ALMACENADO) {
        break;
      }
    }
    return { combos, grupos: grupos.length };
  }

  /**
   * Los grupos de 2 y 3 productos de cada pedido, contados. `ps` son los
   * productos distintos del pedido en orden; `range(i + 1, ...)` arma cada
   * grupo una sola vez y siempre en orden de id. Se arman como TUPLAS y se
   * pasan a arreglo al final: `arrayFlatten` aplana todos los niveles, y con
   * arreglos de arreglos desharia los propios grupos. Mas frecuentes primero;
   * a igual frecuencia, el grupo mas grande.
   */
  private async consultarCombos(): Promise<
    { productos: number[]; pedidos: number }[]
  > {
    const resultado = await clickhouse.query({
      query: `
        WITH canastas AS (
          SELECT id_pedido, arraySort(groupUniqArray(id_producto)) AS ps
            FROM compra_producto FINAL
           WHERE lote = 'real'
             AND fecha >= now() - INTERVAL {dias:UInt32} DAY
             AND id_pedido NOT IN (SELECT id_pedido FROM devolucion_producto)
           GROUP BY id_pedido
          HAVING length(ps) BETWEEN 2 AND {maxPorPedido:UInt32}
        )
        SELECT grupo AS productos, count() AS pedidos
          FROM (
            SELECT [par.1, par.2] AS grupo
              FROM canastas
             ARRAY JOIN arrayFlatten(arrayMap(i -> arrayMap(j -> (ps[i], ps[j]),
               range(i + 1, length(ps) + 1)), range(1, length(ps) + 1))) AS par
            UNION ALL
            SELECT [trio.1, trio.2, trio.3] AS grupo
              FROM canastas
             ARRAY JOIN arrayFlatten(arrayMap(i -> arrayFlatten(arrayMap(j -> arrayMap(k -> (ps[i], ps[j], ps[k]),
               range(j + 1, length(ps) + 1)), range(i + 1, length(ps) + 1))), range(1, length(ps) + 1))) AS trio
          )
         GROUP BY grupo
        HAVING pedidos >= {minPedidos:UInt32}
         ORDER BY pedidos DESC, length(grupo) DESC, grupo
         LIMIT {candidatos:UInt32}`,
      query_params: {
        dias: CombosSyncService.VENTANA_DIAS,
        maxPorPedido: CombosSyncService.MAX_PRODUCTOS_POR_PEDIDO,
        minPedidos: CombosSyncService.MIN_PEDIDOS,
        candidatos: CombosSyncService.CANDIDATOS,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaComboClickHouse>();
    return filas.map((fila) => ({
      productos: fila.productos.map(Number),
      pedidos: Number(fila.pedidos),
    }));
  }
}

/**
 * Quita los pares que estan dentro de un trio con los MISMOS pedidos o mas:
 * si 7+24+25 se compran juntos en 2 pedidos, el par 7+24 en esos mismos 2 no
 * dice nada nuevo. Un par que aparece en MAS pedidos que su trio si se queda:
 * se compra junto tambien sin el tercero.
 */
export function quitarParesDentroDeTrios(
  grupos: { productos: number[]; pedidos: number }[],
): { productos: number[]; pedidos: number }[] {
  const trios = grupos.filter((g) => g.productos.length === 3);
  return grupos.filter(
    (g) =>
      g.productos.length !== 2 ||
      !trios.some(
        (t) =>
          t.pedidos >= g.pedidos &&
          g.productos.every((id) => t.productos.includes(id)),
      ),
  );
}

/** Un mensaje de error corto para el log. */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
