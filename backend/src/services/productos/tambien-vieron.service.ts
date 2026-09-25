import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { manejarErrorRedis } from '../../helpers/manejar-error-redis';
import {
  TambienVieronCacheado,
  TambienVieronSyncService,
} from './tambien-vieron-sync.service';

/**
 * Lee `mesh:producto:<id>:tambien-vieron`, la caché que mantiene
 * `TambienVieronSyncService` (R2) -- mismo criterio que `MasVendidosService`:
 * esta ruta nunca toca ClickHouse ni MongoDB, el worker ya resolvió todo.
 */
@Injectable()
export class TambienVieronService {
  private readonly logger = new Logger(TambienVieronService.name);

  async obtener(idProducto: number): Promise<TambienVieronCacheado[]> {
    let valor: string | null;
    try {
      valor = await redis.get(TambienVieronSyncService.clave(idProducto));
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
    if (valor == null) {
      return [];
    }
    try {
      return JSON.parse(valor) as TambienVieronCacheado[];
    } catch {
      // Valor corrupto -- no deberia pasar, lo escribe siempre
      // JSON.stringify del lado del worker. Mismo criterio que
      // MasVendidosService con un campo del HASH roto: se ignora.
      return [];
    }
  }
}
