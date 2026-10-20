import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { clickhouse } from '../../database/clickhouse';
import { redis } from '../../database/redis';
import {
  TarjetaProducto,
  tarjetasDeProductos,
} from '../../helpers/tarjetas-producto';
import {
  ordenarComoRedis,
  type FilaRankingClickHouse,
  type RankingCalculado,
} from './mas-vendidos-sync.service';

/**
 * Version acotada de un producto, igual criterio que
 * `ProductoTarjetaMasVendido` en `mas-vendidos-sync.service.ts`: solo los
 * campos que pinta una tarjeta de "mas vistos".
 */
export type ProductoTarjetaMasVisto = TarjetaProducto;

/**
 * Worker que recalcula el ranking de "productos mas vistos" a partir de
 * `vista_producto` (ClickHouse) y lo deja listo en Redis -- mismo patron
 * que `MasVendidosSyncService`, cambiando la tabla/metrica: aqui se cuentan
 * sesiones distintas (`count(DISTINCT sesion)`), no unidades vendidas,
 * mismo criterio que usa `AdminTendenciasService.rankingVistas` para no
 * inflar el ranking con una sola persona recargando la misma ficha.
 *
 * Ventana: ultimas 24 horas, con caida a 7 dias si no hubo vistas en ese
 * lapso; si tampoco hay nada en 7 dias, Redis no se toca (se deja el ultimo
 * calculo valido). Solo cuenta `lote = 'real'`.
 *
 * Esta ruta existe para poder usarse como plan B publico cuando "para ti"
 * viene vacio (la ruta de admin equivalente, `/admin/eventos/vista`, no la
 * puede pedir un cliente normal).
 */
@Injectable()
export class MasVistosSyncService {
  private readonly logger = new Logger(MasVistosSyncService.name);

  static readonly CLAVE_RANKING = 'mesh:productos:mas_vistos';
  private static readonly CLAVE_TEMPORAL = `${MasVistosSyncService.CLAVE_RANKING}:tmp`;

  /** HASH `{ id_producto: <ProductoTarjetaMasVisto en JSON> }`. */
  static readonly CLAVE_DETALLE = 'mesh:productos:mas_vistos:detalle';
  private static readonly CLAVE_DETALLE_TEMPORAL = `${MasVistosSyncService.CLAVE_DETALLE}:tmp`;

  private static readonly INTERVALO_MS = 10 * 60 * 1000; // 10 minutos

  /** Cuantos productos guarda el ZSET -- mas de los que se van a mostrar. */
  private static readonly TOPE_ALMACENADO = 20;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  @Interval('mas-vistos-sync', MasVistosSyncService.INTERVALO_MS)
  async recalcular(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      const calculado = await this.calcular();
      if (calculado == null) {
        this.logger.log(
          'worker de mas vistos: sin vistas en 24h ni en 7 dias -- se deja el ranking anterior tal cual',
        );
        return;
      }

      await this.reemplazarRanking(calculado.filas);
      await this.reemplazarDetalle(calculado.tarjetas);
      this.logger.log(
        `worker de mas vistos: ranking recalculado con ${calculado.filas.length} producto(s) (${calculado.ventana}), ${calculado.tarjetas.length} con detalle cacheado`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de mas vistos: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /**
   * El calculo de una corrida, sin tocar Redis: el ranking de ClickHouse (24 h,
   * o 7 dias si en 24 h no hubo vistas) y las tarjetas. `null` si no hubo
   * ninguna vista en 7 dias. Lo usa el worker para llenar Redis y
   * `MasVistosService` cuando Redis no esta (2026-10-20). Mismo molde que
   * `MasVendidosSyncService.calcular()`.
   */
  async calcular(): Promise<RankingCalculado | null> {
    let filas = await this.consultarVentana(24, 'HOUR');
    let ventana = 'ultimas 24h';

    if (filas.length === 0) {
      filas = await this.consultarVentana(7, 'DAY');
      ventana = 'ultimos 7 dias (sin vistas en 24h)';
    }

    if (filas.length === 0) {
      return null;
    }

    filas = ordenarComoRedis(filas);
    const ids = filas.map((fila) => Number(fila.id_producto));
    const porId = await tarjetasDeProductos(ids);
    const tarjetas = ids
      .map((id) => porId.get(id))
      .filter((t): t is TarjetaProducto => t != null);
    return { filas, ventana, tarjetas };
  }

  /**
   * Agrega `vista_producto` de los ultimos `cantidad` `unidad` hacia atras,
   * contando sesiones distintas por producto -- mismo motivo que
   * `AdminTendenciasService.rankingVistas`: ver una ficha es una accion de
   * bajo esfuerzo que la misma persona puede repetir varias veces.
   */
  private async consultarVentana(
    cantidad: number,
    unidad: 'HOUR' | 'DAY',
  ): Promise<FilaRankingClickHouse[]> {
    const resultado = await clickhouse.query({
      query: `SELECT id_producto, count(DISTINCT sesion) AS total
                FROM vista_producto
               WHERE fecha >= now() - INTERVAL {cantidad:UInt32} ${unidad}
                 AND lote = 'real'
               GROUP BY id_producto
               ORDER BY total DESC
               LIMIT {tope:UInt32}`,
      query_params: { cantidad, tope: MasVistosSyncService.TOPE_ALMACENADO },
      format: 'JSONEachRow',
    });
    return resultado.json<FilaRankingClickHouse>();
  }

  private async reemplazarRanking(
    filas: FilaRankingClickHouse[],
  ): Promise<void> {
    const paresScoreMiembro: (string | number)[] = [];
    for (const fila of filas) {
      paresScoreMiembro.push(Number(fila.total), fila.id_producto);
    }

    await redis.del(MasVistosSyncService.CLAVE_TEMPORAL);
    await redis.zadd(MasVistosSyncService.CLAVE_TEMPORAL, ...paresScoreMiembro);
    await redis.rename(
      MasVistosSyncService.CLAVE_TEMPORAL,
      MasVistosSyncService.CLAVE_RANKING,
    );
  }

  private async reemplazarDetalle(productos: TarjetaProducto[]): Promise<void> {
    if (productos.length === 0) {
      await redis.del(MasVistosSyncService.CLAVE_DETALLE);
      return;
    }

    const camposValores: string[] = [];
    for (const producto of productos) {
      camposValores.push(String(producto._id), JSON.stringify(producto));
    }

    await redis.del(MasVistosSyncService.CLAVE_DETALLE_TEMPORAL);
    await redis.hset(
      MasVistosSyncService.CLAVE_DETALLE_TEMPORAL,
      ...camposValores,
    );
    await redis.rename(
      MasVistosSyncService.CLAVE_DETALLE_TEMPORAL,
      MasVistosSyncService.CLAVE_DETALLE,
    );
  }
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
