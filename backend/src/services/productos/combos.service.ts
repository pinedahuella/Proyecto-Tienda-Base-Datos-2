import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { manejarErrorRedis } from '../../helpers/manejar-error-redis';
import { Combo, CombosSyncService } from './combos-sync.service';

/**
 * Lee los combos que deja en Redis `CombosSyncService`: los grupos de 2 y 3
 * productos que mas se compran en el mismo pedido. Esta ruta no toca
 * ClickHouse ni MongoDB; el detalle de cada producto ya viene en el JSON. Sin
 * clave (el worker todavia no corrio) o con un valor roto, devuelve `[]`.
 */
@Injectable()
export class CombosService {
  private readonly logger = new Logger(CombosService.name);

  /** Cuantos combos se muestran: menos de los que guarda el worker. */
  private static readonly LIMITE_MOSTRADO = 10;

  async obtener(): Promise<Combo[]> {
    let valor: string | null;
    try {
      valor = await redis.get(CombosSyncService.CLAVE);
    } catch (error) {
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
}
