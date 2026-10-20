import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import {
  esRedisInalcanzable,
  manejarErrorRedis,
} from '../../helpers/manejar-error-redis';
import {
  OfertaRegistroRedis,
  RegistroOfertasRedisService,
} from '../vendedores/registro-ofertas-redis.service';

/** Una fila de `mesh:ofertas:descuento`/`mesh:ofertas:venta_relampago`, con su `id_oferta` (el campo del HASH) ya puesto dentro. */
export interface OfertaDestacada extends OfertaRegistroRedis {
  id_oferta: number;
}

/**
 * Lee los dos HASH de Redis que mantiene `RegistroOfertasRedisService`:
 * ofertas con descuento activo, y ofertas en venta relampago. Solo lectura
 * -- quien los escribe/mantiene es ese otro servicio (los 4 escritos
 * reactivos, `revisarVencidas()` y el worker de reconciliacion); con Redis
 * arriba este servicio no toca Postgres ni Mongo, mismo espiritu que
 * `MasVendidosService` con el ranking de mas vendidos.
 *
 * Sin orden particular: Redis no promete ningun orden estable en un
 * `HGETALL`, y no se pidio ninguno (a diferencia del ranking de mas
 * vendidos, que si tiene un criterio de orden -- el ZSET por unidades
 * vendidas).
 *
 * **Sin Redis (2026-10-20).** Las ofertas viven en PostgreSQL y los HASH son
 * una copia ya armada: si Redis no responde, se arman en el momento desde
 * PostgreSQL (`RegistroOfertasRedisService.desdePostgres`), con las mismas
 * filas, en vez de dar 503 y dejar la portada sin las dos vitrinas.
 */
@Injectable()
export class OfertasDestacadasService {
  private readonly logger = new Logger(OfertasDestacadasService.name);

  constructor(private readonly registro: RegistroOfertasRedisService) {}

  async obtenerConDescuento(): Promise<OfertaDestacada[]> {
    return this.leer(RegistroOfertasRedisService.CLAVE_DESCUENTO, false);
  }

  async obtenerVentaRelampago(): Promise<OfertaDestacada[]> {
    return this.leer(RegistroOfertasRedisService.CLAVE_VENTA_RELAMPAGO, true);
  }

  private async leer(
    clave: string,
    ventaRelampago: boolean,
  ): Promise<OfertaDestacada[]> {
    if (esRedisInalcanzable()) {
      return this.desdePostgres(ventaRelampago);
    }
    try {
      return await this.leerHash(clave);
    } catch (error) {
      if (esRedisInalcanzable(error)) {
        return this.desdePostgres(ventaRelampago);
      }
      throw error;
    }
  }

  private async desdePostgres(
    ventaRelampago: boolean,
  ): Promise<OfertaDestacada[]> {
    try {
      return await this.registro.desdePostgres(ventaRelampago);
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * `HGETALL` y `JSON.parse` de cada campo. Un valor corrupto (no deberia
   * pasar, lo escribe siempre `JSON.stringify` del lado de
   * `RegistroOfertasRedisService`) se descarta en silencio -- mismo
   * criterio que ya usan `MasVendidosService` y el carrito con una linea de
   * Redis rota, para que una fila mala no tumbe toda la respuesta.
   */
  private async leerHash(clave: string): Promise<OfertaDestacada[]> {
    try {
      const filas = await redis.hgetall(clave);
      const ofertas: OfertaDestacada[] = [];
      for (const [idOferta, valor] of Object.entries(filas)) {
        try {
          ofertas.push({
            id_oferta: Number(idOferta),
            ...(JSON.parse(valor) as OfertaRegistroRedis),
          });
        } catch {
          // Campo corrupto -- se ignora.
        }
      }
      return ofertas;
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }
}
