import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { ErrorConexion } from '../../helpers/errores';
import { manejarErrorClickHouse } from '../../helpers/manejar-error-clickhouse';
import {
  esRedisInalcanzable,
  manejarErrorRedis,
} from '../../helpers/manejar-error-redis';
import { Memoria } from '../../helpers/tarjetas-producto';
import {
  MasVistosSyncService,
  ProductoTarjetaMasVisto,
} from './mas-vistos-sync.service';

/**
 * Lee el ranking de "productos mas vistos" y su detalle desde Redis --
 * mismo patron que `MasVendidosService`: nunca toca ClickHouse ni Mongo en
 * el momento, solo lee lo que ya dejo cacheado `MasVistosSyncService`.
 *
 * Sin Redis (2026-10-20), igual que `MasVendidosService`: la misma consulta
 * del worker en el momento, guardada un minuto.
 */
@Injectable()
export class MasVistosService {
  private readonly logger = new Logger(MasVistosService.name);

  private static readonly LIMITE_MOSTRADO = 8;

  private readonly sinRedis = new Memoria<ProductoTarjetaMasVisto[]>(60_000);

  constructor(private readonly sync: MasVistosSyncService) {}

  async obtener(): Promise<ProductoTarjetaMasVisto[]> {
    if (esRedisInalcanzable()) {
      return this.desdeClickHouse();
    }
    try {
      const idsOrdenados = await this.leerRankingRedis();
      if (idsOrdenados.length === 0) {
        return [];
      }

      return await this.leerDetalleRedis(idsOrdenados);
    } catch (error) {
      if (esRedisInalcanzable(error)) {
        return this.desdeClickHouse();
      }
      throw error;
    }
  }

  /** El ranking calculado en el momento, sin Redis. */
  private async desdeClickHouse(): Promise<ProductoTarjetaMasVisto[]> {
    try {
      return await this.sinRedis.obtener(async () => {
        const calculado = await this.sync.calcular();
        return (calculado?.tarjetas ?? []).slice(
          0,
          MasVistosService.LIMITE_MOSTRADO,
        );
      });
    } catch (error) {
      if (error instanceof ErrorConexion) {
        throw error;
      }
      manejarErrorClickHouse(this.logger, error);
    }
  }

  private async leerRankingRedis(): Promise<number[]> {
    try {
      const miembros = await redis.zrevrange(
        MasVistosSyncService.CLAVE_RANKING,
        0,
        MasVistosService.LIMITE_MOSTRADO - 1,
      );
      return miembros.map(Number);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  private async leerDetalleRedis(
    ids: number[],
  ): Promise<ProductoTarjetaMasVisto[]> {
    try {
      const valores = await redis.hmget(
        MasVistosSyncService.CLAVE_DETALLE,
        ...ids.map(String),
      );

      const productos: ProductoTarjetaMasVisto[] = [];
      for (const valor of valores) {
        if (valor == null) {
          continue;
        }
        try {
          productos.push(JSON.parse(valor) as ProductoTarjetaMasVisto);
        } catch {
          // Campo corrupto -- se ignora, no tumba el resto del ranking.
        }
      }
      return productos;
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }
}
