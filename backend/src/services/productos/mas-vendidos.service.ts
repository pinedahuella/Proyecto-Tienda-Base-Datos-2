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
  MasVendidosSyncService,
  ProductoTarjetaMasVendido,
} from './mas-vendidos-sync.service';

/**
 * Lee el ranking de "productos mas vendidos" y su detalle, las dos
 * estructuras de Redis que mantiene `MasVendidosSyncService` -- desde el
 * 2026-09-23, esta ruta ya no toca MongoDB: el worker trae la version
 * acotada (`ProductoTarjetaMasVendido`, no el documento completo -- ver
 * `mas-vendidos-sync.service.ts`) de cada producto UNA vez por corrida
 * (cada 10 min) y la deja cacheada en un HASH. El detalle puede estar hasta
 * 10 minutos desactualizado (nombre, precio, imagen, o incluso que ya no
 * este `activo`); es el mismo trato que ya tiene el propio ranking, ahora
 * extendido al detalle.
 *
 * **Sin Redis (2026-10-20).** Redis es solo la copia ya calculada; el ranking
 * sale de ClickHouse. Si Redis no responde, se hace en el momento la misma
 * consulta que hace el worker (`MasVendidosSyncService.calcular()`), en vez de
 * dar 503 y dejar la portada sin la vitrina. Lo calculado se guarda un minuto
 * en memoria (`Memoria`): la portada la pide todo el que entra. Si tambien
 * ClickHouse esta caido, 503 como antes.
 */
@Injectable()
export class MasVendidosService {
  private readonly logger = new Logger(MasVendidosService.name);

  /**
   * Cuantos productos se devuelven -- menos que `TOPE_ALMACENADO` del
   * worker a proposito (ver ese archivo): el ZSET guarda hasta 20, esta
   * ruta solo enseña los primeros 8.
   */
  private static readonly LIMITE_MOSTRADO = 8;

  private readonly sinRedis = new Memoria<ProductoTarjetaMasVendido[]>(60_000);

  constructor(private readonly sync: MasVendidosSyncService) {}

  /**
   * El ranking completo: primero los ids en orden desde el ZSET, luego el
   * detalle de esos productos desde el HASH de Redis, ya en el orden
   * correcto (a diferencia del `$in` de Mongo que se usaba antes, `HMGET`
   * respeta el orden de los ids que se le piden). Un id del ranking sin
   * detalle cacheado (no gano en la ultima corrida del worker, o no era
   * `activo` entonces) simplemente se salta, en vez de romper toda la
   * respuesta.
   */
  async obtener(): Promise<ProductoTarjetaMasVendido[]> {
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
  private async desdeClickHouse(): Promise<ProductoTarjetaMasVendido[]> {
    try {
      return await this.sinRedis.obtener(async () => {
        const calculado = await this.sync.calcular();
        return (calculado?.tarjetas ?? []).slice(
          0,
          MasVendidosService.LIMITE_MOSTRADO,
        );
      });
    } catch (error) {
      // Un ErrorConexion ya viene clasificado (las tarjetas con Mongo y la
      // copia de PostgreSQL caidos); lo demas es de la consulta a ClickHouse.
      if (error instanceof ErrorConexion) {
        throw error;
      }
      manejarErrorClickHouse(this.logger, error);
    }
  }

  /**
   * `ZREVRANGE` sin scores: los miembros del ZSET son el `id_producto` como
   * texto (asi los guarda `MasVendidosSyncService.reemplazarRanking`), ya
   * en orden de mas a menos vendido.
   */
  private async leerRankingRedis(): Promise<number[]> {
    try {
      const miembros = await redis.zrevrange(
        MasVendidosSyncService.CLAVE_RANKING,
        0,
        MasVendidosService.LIMITE_MOSTRADO - 1,
      );
      return miembros.map(Number);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * `HMGET` de un id por cada miembro del ranking (en vez de `HGETALL` +
   * filtrar): as[i] es el detalle del producto ids[i], o `null` si ese
   * campo no existe en el HASH. Un valor corrupto (no deberia pasar, lo
   * escribe siempre `JSON.stringify` del lado del worker) se descarta en
   * silencio, mismo criterio que el carrito con una linea de Redis rota.
   */
  private async leerDetalleRedis(
    ids: number[],
  ): Promise<ProductoTarjetaMasVendido[]> {
    try {
      const valores = await redis.hmget(
        MasVendidosSyncService.CLAVE_DETALLE,
        ...ids.map(String),
      );

      const productos: ProductoTarjetaMasVendido[] = [];
      for (const valor of valores) {
        if (valor == null) {
          continue;
        }
        try {
          productos.push(JSON.parse(valor) as ProductoTarjetaMasVendido);
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
