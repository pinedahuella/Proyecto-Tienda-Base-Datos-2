import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { manejarErrorRedis } from '../../helpers/manejar-error-redis';
import { ParaTiCacheado, ParaTiSyncService } from './para-ti-sync.service';

/**
 * Lee `mesh:cuenta:<id>:para-ti`, la caché que mantiene `ParaTiSyncService`
 * (R3) -- mismo criterio que `TambienVieronService`: esta ruta nunca toca
 * ClickHouse ni MongoDB.
 *
 * Un arreglo vacío (cuenta sin recomendaciones calculables, o cuenta que
 * el worker todavía no proceso porque no tenía vistas en el último ciclo)
 * y "la cuenta nunca tuvo caché" se ven exactamente igual desde acá --
 * decisión pendiente, no resuelta en esta ronda: si el llamador quiere
 * caer a T1 ("en ascenso") cuando esto viene vacío, lo decide él, no este
 * servicio.
 */
@Injectable()
export class ParaTiService {
  private readonly logger = new Logger(ParaTiService.name);

  async obtener(idUsuario: number): Promise<ParaTiCacheado[]> {
    let valor: string | null;
    try {
      valor = await redis.get(ParaTiSyncService.clave(idUsuario));
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
    if (valor == null) {
      return [];
    }
    try {
      return JSON.parse(valor) as ParaTiCacheado[];
    } catch {
      return [];
    }
  }
}
