import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { clickhouse } from '../../database/clickhouse';
import { redis } from '../../database/redis';
import { mongoDb } from '../../database/mongo';
import { Producto } from '../../models/producto';

/** Umbrales de R2 -- fijos, mismos valores probados en `clickhouse/consultas/parametros.txt`. */
const DIAS_HISTORIAL = 30;
const MIN_SESIONES_EN_COMUN = 2;
const LIMITE = 10;

/**
 * TTL de cada clave -- mucho mas largo que `INTERVALO_MS` (15 min, para que
 * un ciclo perdido por un error transitorio no la expire de mas) y mucho
 * mas corto que `DIAS_HISTORIAL` (30 dias, para que una clave huerfana no
 * se quede semanas mostrando un dato viejo). Cada ciclo la reescribe con un
 * TTL nuevo mientras el producto siga activo, asi que en la practica nunca
 * expira estando vivo; el dia que el producto deje de calificar (menos de
 * `MIN_SESIONES_EN_COMUN` sesiones en los ultimos 30 dias), el worker deja
 * de tocar su clave y Redis la borra sola dentro de este plazo.
 */
const TTL_SEGUNDOS = 24 * 60 * 60;

interface FilaTambienVieron {
  id_producto: string;
  sesiones_en_comun: string;
  sesiones_del_producto: string;
  afinidad: string;
}

/** El calculo crudo de un candidato, antes de resolver su detalle en Mongo. */
interface CandidatoTambienVieron {
  id_producto: number;
  sesiones_en_comun: number;
  afinidad: number;
}

/**
 * Lo que queda guardado en Redis por producto, listo para `JSON.parse` y
 * para la respuesta HTTP tal cual -- `producto` ya resuelto, la ruta que
 * lee esto (`TambienVieronService`) nunca toca MongoDB.
 */
export interface TambienVieronCacheado {
  id_producto: number;
  sesiones_en_comun: number;
  afinidad: number;
  producto: Producto | null;
}

/**
 * Worker de R2 ("quienes vieron esto tambien vieron",
 * `docs/fraude-entrega3/03-consultas-clickhouse.md`): cada
 * `INTERVALO_MS`, calcula la afinidad de cada producto con vistas
 * recientes y la deja lista en Redis -- ninguna peticion en vivo corre
 * nunca la consulta pesada, siempre lee un resultado ya calculado. Mismo
 * criterio que `MasVendidosSyncService` (desde el 2026-09-23): el propio
 * worker resuelve el detalle de Mongo una vez por ciclo, no la ruta que
 * lee esto despues.
 *
 * **Filtro de descubrimiento (corregido 2026-09-25):** solo procesa
 * productos con AL MENOS `MIN_SESIONES_EN_COMUN` sesiones distintas
 * viendolos -- no "alguna vista" a secas. R2 exige que un candidato
 * comparta ese minimo de sesiones con el producto base; si el producto
 * base en si fue visto por MENOS sesiones que ese minimo, ningun candidato
 * puede alcanzarlo nunca (el maximo posible de sesiones en comun esta
 * acotado por cuantas sesiones vieron al producto base). Verificado en
 * vivo: con el filtro viejo ("alguna vista"), los 6 productos reales que
 * calificaban tenian 1 sola sesion cada uno y las 6 claves quedaban
 * siempre vacias -- ciclos completos gastados en productos que
 * matematicamente no podian dar resultado.
 *
 * Mismo patron que `BuscadorSyncService`: bandera `procesando` para que un
 * ciclo lento no se pise con el siguiente, y nunca lanza -- un fallo de
 * ClickHouse, Redis o Mongo en un producto se loguea y se reintenta en el
 * proximo ciclo, sin tumbar el resto.
 *
 * Clave `mesh:producto:<id>:tambien-vieron`, se SOBRESCRIBE cada ciclo con
 * TTL de `TTL_SEGUNDOS` (24h): mientras el producto siga calificando, el
 * propio worker la mantiene viva renovando el TTL en cada ciclo; el dia que
 * deje de calificar, la clave se limpia sola en vez de quedar huerfana
 * mostrando un dato viejo para siempre (ver el comentario de `TTL_SEGUNDOS`).
 */
@Injectable()
export class TambienVieronSyncService {
  private readonly logger = new Logger(TambienVieronSyncService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** `true` mientras un ciclo esta en curso: el siguiente se salta. */
  private procesando = false;

  @Interval('tambien-vieron-sync', TambienVieronSyncService.INTERVALO_MS)
  async recalcular(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      await this.recalcularTodos();
    } finally {
      this.procesando = false;
    }
  }

  private async recalcularTodos(): Promise<void> {
    let idsProducto: number[];
    try {
      const resultado = await clickhouse.query({
        query: `SELECT id_producto
                  FROM vista_producto
                 WHERE lote = 'real'
                   AND fecha >= now() - INTERVAL {diasHistorial:UInt32} DAY
                 GROUP BY id_producto
                HAVING uniqExact(sesion) >= {minSesionesEnComun:UInt32}`,
        query_params: {
          diasHistorial: DIAS_HISTORIAL,
          minSesionesEnComun: MIN_SESIONES_EN_COMUN,
        },
        format: 'JSONEachRow',
      });
      const filas = await resultado.json<{ id_producto: string }>();
      idsProducto = filas.map((fila) => Number(fila.id_producto));
    } catch (error) {
      this.logger.warn(
        `worker de tambien-vieron: no se pudo leer ClickHouse (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    // Primera pasada: el calculo crudo de cada producto, sin Mongo todavia.
    const candidatosPorProducto = new Map<number, CandidatoTambienVieron[]>();
    for (const idProducto of idsProducto) {
      try {
        candidatosPorProducto.set(
          idProducto,
          await this.calcularAfinidad(idProducto),
        );
      } catch (error) {
        this.logger.warn(
          `worker de tambien-vieron: no se pudo calcular el producto ${idProducto} (${(error as Error)?.message ?? error})`,
        );
      }
    }

    // Una sola consulta a Mongo por TODOS los candidatos de TODOS los
    // productos de este ciclo, nunca una por producto.
    const idsCandidatos = [
      ...new Set(
        [...candidatosPorProducto.values()].flatMap((fila) =>
          fila.map((candidato) => candidato.id_producto),
        ),
      ),
    ];
    const productoPorId = await this.consultarProductosPorId(idsCandidatos);

    let calculados = 0;
    for (const [idProducto, candidatos] of candidatosPorProducto) {
      const cacheado: TambienVieronCacheado[] = candidatos.map((candidato) => ({
        ...candidato,
        producto: productoPorId.get(candidato.id_producto) ?? null,
      }));
      try {
        await redis.set(
          TambienVieronSyncService.clave(idProducto),
          JSON.stringify(cacheado),
          'EX',
          TTL_SEGUNDOS,
        );
        calculados++;
      } catch (error) {
        this.logger.warn(
          `worker de tambien-vieron: no se pudo guardar en Redis el producto ${idProducto} (${(error as Error)?.message ?? error})`,
        );
      }
    }

    if (calculados > 0) {
      this.logger.log(
        `worker de tambien-vieron: ${calculados}/${idsProducto.length} producto(s) recalculados`,
      );
    }
  }

  private async calcularAfinidad(
    idProducto: number,
  ): Promise<CandidatoTambienVieron[]> {
    const resultado = await clickhouse.query({
      query: `WITH
                  pares AS (
                      SELECT DISTINCT sesion, id_producto
                        FROM vista_producto
                       WHERE lote = 'real'
                         AND fecha >= now() - INTERVAL {diasHistorial:UInt32} DAY
                  ),
                  alcance AS (
                      SELECT id_producto, count() AS sesiones FROM pares GROUP BY id_producto
                  )
                SELECT
                  q.id_producto                                        AS id_producto,
                  count()                                               AS sesiones_en_comun,
                  any(a.sesiones)                                       AS sesiones_del_producto,
                  round(count() / sqrt(
                      (SELECT sesiones FROM alcance WHERE id_producto = {idProducto:UInt64})
                      * any(a.sesiones)), 3)                            AS afinidad
                FROM pares AS q
                INNER JOIN alcance AS a ON a.id_producto = q.id_producto
               WHERE q.sesion IN (SELECT sesion FROM pares WHERE id_producto = {idProducto:UInt64})
                 AND q.id_producto != {idProducto:UInt64}
               GROUP BY q.id_producto
              HAVING sesiones_en_comun >= {minSesionesEnComun:UInt32}
               ORDER BY afinidad DESC, sesiones_en_comun DESC
               LIMIT {limite:UInt32}`,
      query_params: {
        idProducto,
        diasHistorial: DIAS_HISTORIAL,
        minSesionesEnComun: MIN_SESIONES_EN_COMUN,
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaTambienVieron>();
    return filas.map((fila) => ({
      id_producto: Number(fila.id_producto),
      sesiones_en_comun: Number(fila.sesiones_en_comun),
      afinidad: Number(fila.afinidad),
    }));
  }

  /**
   * El detalle real de un conjunto de productos, pedido a MongoDB una sola
   * vez -- mismo patron que `AdminTendenciasAvanzadasService`: SIN filtrar
   * por estado, un id sin documento sale con `producto: null`.
   */
  private async consultarProductosPorId(
    idsProducto: number[],
  ): Promise<Map<number, Producto>> {
    if (idsProducto.length === 0) {
      return new Map();
    }
    try {
      const productos = await mongoDb
        .collection<Producto>('productos')
        .find({ _id: { $in: idsProducto } })
        .toArray();
      return new Map(productos.map((p) => [p._id, p]));
    } catch (error) {
      this.logger.warn(
        `worker de tambien-vieron: no se pudo leer Mongo (${(error as Error)?.message ?? error})`,
      );
      return new Map();
    }
  }

  /** Publica y estatica para que `TambienVieronService` arme la misma clave al leer. */
  static clave(idProducto: number): string {
    return `mesh:producto:${idProducto}:tambien-vieron`;
  }
}
