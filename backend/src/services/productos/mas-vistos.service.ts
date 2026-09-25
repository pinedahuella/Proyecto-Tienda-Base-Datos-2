import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { manejarErrorRedis } from '../../helpers/manejar-error-redis';
import {
  MasVistosSyncService,
  ProductoTarjetaMasVisto,
} from './mas-vistos-sync.service';

/**
 * Lee el ranking de "productos mas vistos" y su detalle desde Redis --
 * mismo patron que `MasVendidosService`: nunca toca ClickHouse ni Mongo en
 * el momento, solo lee lo que ya dejo cacheado `MasVistosSyncService`.
 */
@Injectable()
export class MasVistosService {
  private readonly logger = new Logger(MasVistosService.name);

  private static readonly LIMITE_MOSTRADO = 8;

  async obtener(): Promise<ProductoTarjetaMasVisto[]> {
    const idsOrdenados = await this.leerRankingRedis();
    if (idsOrdenados.length === 0) {
      return [];
    }

    return this.leerDetalleRedis(idsOrdenados);
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
