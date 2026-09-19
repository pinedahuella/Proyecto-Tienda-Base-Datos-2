import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { clickhouse } from '../../database/clickhouse';
import { redis } from '../../database/redis';

/**
 * Worker que recalcula el ranking de "productos mas vendidos" a partir de
 * `compra_producto` (ClickHouse) y lo deja listo en un ZSET de Redis para
 * lectura rapida -- sin este worker, cada consulta tendria que agregar el
 * evento en vivo contra ClickHouse en vez de leer un resultado ya calculado.
 *
 * Ventana: ultimas 24 horas. Si no hubo NINGUNA compra en ese lapso (un
 * bache normal de trafico, no un error), cae a los ultimos 7 dias para no
 * dejar el ranking en blanco por algo tan corto. Si tampoco hay nada en 7
 * dias, el ZSET de Redis NO se toca -- se deja el ultimo calculo valido
 * (aunque ya este viejo) en vez de vaciarlo; mostrar algo desactualizado es
 * mejor que no mostrar nada.
 *
 * Guarda mas productos de los que el catalogo va a mostrar
 * (`TOPE_ALMACENADO`): si mañana cambia cuantos se pintan en la pagina, no
 * hace falta tocar este worker ni la consulta a ClickHouse, solo el
 * `ZREVRANGE` que lo lee.
 *
 * El reemplazo del ZSET es atomico: se arma en una llave temporal y se
 * publica con `RENAME` (atomico en Redis), para que nadie lea el ranking a
 * medio reconstruir.
 *
 * Mismo patron que `BuscadorSyncService`/`GrafoSyncService`: `@Interval`
 * con una bandera para que una corrida lenta no se pise con la siguiente,
 * y nunca lanza -- un fallo de ClickHouse o Redis se loguea y se reintenta
 * en la proxima corrida, sin tumbar nada mas.
 */
@Injectable()
export class MasVendidosSyncService {
  private readonly logger = new Logger(MasVendidosSyncService.name);

  static readonly CLAVE_RANKING = 'mesh:productos:mas_vendidos';
  private static readonly CLAVE_TEMPORAL = `${MasVendidosSyncService.CLAVE_RANKING}:tmp`;

  private static readonly INTERVALO_MS = 10 * 60 * 1000; // 10 minutos

  /** Cuantos productos guarda el ZSET -- mas de los que se van a mostrar. */
  private static readonly TOPE_ALMACENADO = 20;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  @Interval('mas-vendidos-sync', MasVendidosSyncService.INTERVALO_MS)
  async recalcular(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      let filas = await this.consultarVentana(24, 'HOUR');
      let ventana = 'ultimas 24h';

      if (filas.length === 0) {
        filas = await this.consultarVentana(7, 'DAY');
        ventana = 'ultimos 7 dias (sin compras en 24h)';
      }

      if (filas.length === 0) {
        this.logger.log(
          'worker de mas vendidos: sin compras en 24h ni en 7 dias -- se deja el ranking anterior tal cual',
        );
        return;
      }

      await this.reemplazarRanking(filas);
      this.logger.log(
        `worker de mas vendidos: ranking recalculado con ${filas.length} producto(s) (${ventana})`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de mas vendidos: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /**
   * Agrega `compra_producto` de los ultimos `cantidad` `unidad` hacia atras.
   * `unidad` nunca sale del cliente -- son las dos constantes literales que
   * llama `recalcular()` -- asi que interpolarla en el `INTERVAL` es segura,
   * mismo criterio que `orden` en `AdminEventosService.consultarTabla`.
   */
  private async consultarVentana(
    cantidad: number,
    unidad: 'HOUR' | 'DAY',
  ): Promise<FilaRankingClickHouse[]> {
    const resultado = await clickhouse.query({
      query: `SELECT id_producto, sum(cantidad) AS total
                FROM compra_producto
               WHERE fecha >= now() - INTERVAL {cantidad:UInt32} ${unidad}
               GROUP BY id_producto
               ORDER BY total DESC
               LIMIT {tope:UInt32}`,
      query_params: { cantidad, tope: MasVendidosSyncService.TOPE_ALMACENADO },
      format: 'JSONEachRow',
    });
    return resultado.json<FilaRankingClickHouse>();
  }

  /**
   * `total` es un `UInt64` (ClickHouse promueve `sum(UInt32)` a 64 bits) y
   * por eso llega como STRING -- mismo motivo que `id_producto`/`id_oferta`
   * en `models/evento-clickhouse.ts`. Se convierte a `number` recien aqui,
   * al armar el score para Redis.
   */
  private async reemplazarRanking(
    filas: FilaRankingClickHouse[],
  ): Promise<void> {
    const paresScoreMiembro: (string | number)[] = [];
    for (const fila of filas) {
      paresScoreMiembro.push(Number(fila.total), fila.id_producto);
    }

    await redis.del(MasVendidosSyncService.CLAVE_TEMPORAL);
    await redis.zadd(
      MasVendidosSyncService.CLAVE_TEMPORAL,
      ...paresScoreMiembro,
    );
    await redis.rename(
      MasVendidosSyncService.CLAVE_TEMPORAL,
      MasVendidosSyncService.CLAVE_RANKING,
    );
  }
}

interface FilaRankingClickHouse {
  id_producto: string;
  total: string;
}

/** Un mensaje de error corto para el log. */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
