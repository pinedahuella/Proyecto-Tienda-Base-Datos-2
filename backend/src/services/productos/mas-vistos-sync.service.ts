import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { Decimal128 } from 'mongodb';
import { clickhouse } from '../../database/clickhouse';
import { redis } from '../../database/redis';
import { mongoDb } from '../../database/mongo';
import { ESTADO_PRODUCTO_VISIBLE } from '../../models/estado-producto';
import { Producto } from '../../models/producto';

/**
 * Version acotada de un producto, igual criterio que
 * `ProductoTarjetaMasVendido` en `mas-vendidos-sync.service.ts`: solo los
 * campos que pinta una tarjeta de "mas vistos".
 */
export interface ProductoTarjetaMasVisto {
  _id: number;
  nombre: string;
  imagen: string | null;
  precio_tienda: Decimal128 | null;
  precio_desde: Decimal128 | null;
  hay_descuento: boolean;
  resenas_promedio: number;
  resenas_total: number;
  stock_total: number;
}

interface FilaProductoProyectado {
  _id: number;
  nombre: string;
  precio_tienda: Decimal128 | null;
  precio_desde: Decimal128 | null;
  hay_descuento: boolean;
  resenas_promedio: number;
  resenas_total: number;
  stock_total: number;
  variantes: { imagenes: string[] }[];
}

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
      let filas = await this.consultarVentana(24, 'HOUR');
      let ventana = 'ultimas 24h';

      if (filas.length === 0) {
        filas = await this.consultarVentana(7, 'DAY');
        ventana = 'ultimos 7 dias (sin vistas en 24h)';
      }

      if (filas.length === 0) {
        this.logger.log(
          'worker de mas vistos: sin vistas en 24h ni en 7 dias -- se deja el ranking anterior tal cual',
        );
        return;
      }

      const ids = filas.map((fila) => Number(fila.id_producto));
      const productos = await this.consultarProductosMongo(ids);

      await this.reemplazarRanking(filas);
      await this.reemplazarDetalle(productos);
      this.logger.log(
        `worker de mas vistos: ranking recalculado con ${filas.length} producto(s) (${ventana}), ${productos.length} con detalle cacheado`,
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

  /**
   * Proyeccion acotada de cada producto ganador -- mismo criterio y misma
   * forma que `MasVendidosSyncService.consultarProductosMongo`, solo
   * `activo` para no cachear un producto que ya no se puede mostrar.
   */
  private async consultarProductosMongo(
    ids: number[],
  ): Promise<ProductoTarjetaMasVisto[]> {
    const filas = await mongoDb
      .collection<Producto>('productos')
      .find<FilaProductoProyectado>(
        { _id: { $in: ids }, estado: ESTADO_PRODUCTO_VISIBLE },
        {
          projection: {
            _id: 1,
            nombre: 1,
            precio_tienda: 1,
            precio_desde: 1,
            hay_descuento: 1,
            resenas_promedio: 1,
            resenas_total: 1,
            stock_total: 1,
            'variantes.imagenes': 1,
          },
        },
      )
      .toArray();

    return filas.map((fila) => ({
      _id: fila._id,
      nombre: fila.nombre,
      imagen: fila.variantes[0]?.imagenes[0] ?? null,
      precio_tienda: fila.precio_tienda,
      precio_desde: fila.precio_desde,
      hay_descuento: fila.hay_descuento,
      resenas_promedio: fila.resenas_promedio,
      resenas_total: fila.resenas_total,
      stock_total: fila.stock_total,
    }));
  }

  private async reemplazarDetalle(
    productos: ProductoTarjetaMasVisto[],
  ): Promise<void> {
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

interface FilaRankingClickHouse {
  id_producto: string;
  total: string;
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
