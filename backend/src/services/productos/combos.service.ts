import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { ErrorConexion } from '../../helpers/errores';
import { manejarErrorClickHouse } from '../../helpers/manejar-error-clickhouse';
import {
  esRedisInalcanzable,
  manejarErrorRedis,
} from '../../helpers/manejar-error-redis';
import { Memoria } from '../../helpers/tarjetas-producto';
import { Combo, CombosSyncService } from './combos-sync.service';

/**
 * Lee los combos que deja en Redis `CombosSyncService`: los grupos de 2 y 3
 * productos que mas se compran en el mismo pedido. Esta ruta no toca
 * ClickHouse ni MongoDB; el detalle de cada producto ya viene en el JSON. Sin
 * clave (el worker todavia no corrio) o con un valor roto, devuelve `[]`.
 *
 * Sin Redis (2026-10-20), como `MasVendidosService`: la misma consulta del
 * worker en el momento (`CombosSyncService.calcular()`), guardada un minuto.
 */
@Injectable()
export class CombosService {
  private readonly logger = new Logger(CombosService.name);

  /** Cuantos combos se muestran: menos de los que guarda el worker. */
  private static readonly LIMITE_MOSTRADO = 10;

  private readonly sinRedis = new Memoria<Combo[]>(60_000);

  constructor(private readonly sync: CombosSyncService) {}

  async obtener(): Promise<Combo[]> {
    if (esRedisInalcanzable()) {
      return this.desdeClickHouse();
    }
    let valor: string | null;
    try {
      valor = await redis.get(CombosSyncService.CLAVE);
    } catch (error) {
      if (esRedisInalcanzable(error)) {
        return this.desdeClickHouse();
      }
      manejarErrorRedis(this.logger, error);
    }
    if (valor == null) {
      return [];
    }
    try {
      return (JSON.parse(valor) as Combo[]).slice(
        0,
        CombosService.LIMITE_MOSTRADO,
      );
    } catch {
      return [];
    }
  }

  /** Los combos calculados en el momento, sin Redis. */
  private async desdeClickHouse(): Promise<Combo[]> {
    try {
      return await this.sinRedis.obtener(async () => {
        const { combos } = await this.sync.calcular();
        return combos.slice(0, CombosService.LIMITE_MOSTRADO);
      });
    } catch (error) {
      if (error instanceof ErrorConexion) {
        throw error;
      }
      manejarErrorClickHouse(this.logger, error);
    }
  }
}
