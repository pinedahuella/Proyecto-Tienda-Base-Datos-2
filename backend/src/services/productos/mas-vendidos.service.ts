import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { mongoDb } from '../../database/mongo';
import { manejarErrorRedis } from '../../helpers/manejar-error-redis';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import { ESTADO_PRODUCTO_VISIBLE } from '../../models/estado-producto';
import { Producto } from '../../models/producto';
import { MasVendidosSyncService } from './mas-vendidos-sync.service';

/**
 * Lee el ranking de "productos mas vendidos" (el ZSET de Redis que
 * mantiene `MasVendidosSyncService`) y trae el detalle real de esos
 * productos desde MongoDB -- igual que el resto del catalogo publico
 * (`ProductosService.listar`): Redis solo guarda el id y el orden, nunca
 * nombre/precio/imagen, para no tener otra copia que desincronizar.
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

  /**
   * El ranking completo: primero los ids en orden desde Redis, luego el
   * detalle de esos productos desde Mongo, reordenado para que coincida
   * con ese ranking (Mongo con `$in` no respeta el orden de la lista de
   * ids que se le manda). Un id del ranking sin producto visible en Mongo
   * (se desactivo, se borro, o esta en revision) simplemente se salta, en
   * vez de romper toda la respuesta.
   */
  async obtener(): Promise<Producto[]> {
    const idsOrdenados = await this.leerRankingRedis();
    if (idsOrdenados.length === 0) {
      return [];
    }

    const productos = await this.leerProductosMongo(idsOrdenados);
    const productoPorId = new Map(productos.map((p) => [p._id, p]));

    return idsOrdenados
      .map((id) => productoPorId.get(id))
      .filter((producto): producto is Producto => producto != null);
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
   * Solo productos `activo` -- mismo criterio de visibilidad que
   * `GET /productos` y `GET /productos/:id`: un producto que se desactivo
   * despues de venderse mucho no debe seguir apareciendo aqui.
   */
  private async leerProductosMongo(ids: number[]): Promise<Producto[]> {
    try {
      return await mongoDb
        .collection<Producto>('productos')
        .find({ _id: { $in: ids }, estado: ESTADO_PRODUCTO_VISIBLE })
        .toArray();
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
  }
}
