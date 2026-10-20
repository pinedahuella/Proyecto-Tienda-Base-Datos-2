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
  TambienVieronCacheado,
  TambienVieronSyncService,
} from './tambien-vieron-sync.service';

/**
 * Lee `mesh:producto:<id>:tambien-vieron`, la caché que mantiene
 * `TambienVieronSyncService` (R2) -- mismo criterio que `MasVendidosService`:
 * esta ruta nunca toca ClickHouse ni MongoDB, el worker ya resolvió todo.
 *
 * Sin Redis (2026-10-20): la afinidad de ese producto se calcula en el momento
 * con la misma consulta del worker (`calcularUno`) y se guarda un minuto por
 * producto.
 */
@Injectable()
export class TambienVieronService {
  private readonly logger = new Logger(TambienVieronService.name);

  private readonly sinRedis = new Map<
    number,
    Memoria<TambienVieronCacheado[]>
  >();

  constructor(private readonly sync: TambienVieronSyncService) {}

  async obtener(idProducto: number): Promise<TambienVieronCacheado[]> {
    if (esRedisInalcanzable()) {
      return this.desdeClickHouse(idProducto);
    }
    let valor: string | null;
    try {
      valor = await redis.get(TambienVieronSyncService.clave(idProducto));
    } catch (error) {
      if (esRedisInalcanzable(error)) {
        return this.desdeClickHouse(idProducto);
      }
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

  /** La afinidad de un producto calculada en el momento, sin Redis. */
  private async desdeClickHouse(
    idProducto: number,
  ): Promise<TambienVieronCacheado[]> {
    let memoria = this.sinRedis.get(idProducto);
    if (memoria == null) {
      memoria = new Memoria<TambienVieronCacheado[]>(60_000);
      this.sinRedis.set(idProducto, memoria);
    }
    try {
      return await memoria.obtener(() => this.sync.calcularUno(idProducto));
    } catch (error) {
      if (error instanceof ErrorConexion) {
        throw error;
      }
      manejarErrorClickHouse(this.logger, error);
    }
  }
}
