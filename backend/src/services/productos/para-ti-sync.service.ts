import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { clickhouse } from '../../database/clickhouse';
import { redis } from '../../database/redis';
import { mongoDb } from '../../database/mongo';
import { Producto } from '../../models/producto';

/** Umbrales de R3 -- fijos, mismos valores probados en `clickhouse/consultas/parametros.txt`. */
const DIAS_HISTORIAL = 30;
const SEMILLAS = 5;
const VIDA_MEDIA_HORAS = 72;
const LIMITE = 10;

/**
 * TTL de cada clave -- mismo criterio y mismo valor que
 * `TambienVieronSyncService.TTL_SEGUNDOS` (R2): mucho mas largo que
 * `INTERVALO_MS` (15 min) para que un ciclo perdido no la expire de mas, y
 * mucho mas corto que `DIAS_HISTORIAL` (30 dias) para que una cuenta sin
 * vistas recientes no se quede semanas con una recomendacion vieja
 * cacheada. Se renueva en cada ciclo mientras la cuenta siga teniendo
 * vistas recientes; el dia que deje de tenerlas, el worker deja de tocar su
 * clave y Redis la borra sola dentro de este plazo.
 */
const TTL_SEGUNDOS = 24 * 60 * 60;

interface FilaParaTi {
  id_producto: string;
  puntaje: string;
  sesiones: string;
  porque_viste: string[];
}

/** El calculo crudo de un candidato, antes de resolver su detalle en Mongo. */
interface CandidatoParaTi {
  id_producto: number;
  puntaje: number;
  porque_viste: number[];
}

/**
 * Lo que queda guardado en Redis por cuenta, listo para `JSON.parse` y
 * para la respuesta HTTP tal cual -- `producto` ya resuelto, mismo
 * criterio que `TambienVieronCacheado` (R2).
 */
export interface ParaTiCacheado {
  id_producto: number;
  puntaje: number;
  porque_viste: number[];
  producto: Producto | null;
}

/**
 * Worker de R3 ("para ti", `docs/fraude-entrega3/03-consultas-clickhouse.md`):
 * cada `INTERVALO_MS`, calcula las recomendaciones personalizadas de cada
 * CUENTA con vistas recientes y las deja listas en Redis -- mismo
 * principio que `TambienVieronSyncService` (R2): ninguna peticion en vivo
 * corre nunca la consulta, y el propio worker resuelve el detalle de Mongo
 * una vez por ciclo (no la ruta que lee esto despues).
 *
 * Solo procesa cuentas (`id_usuario`, nunca sesiones anonimas -- R3 pide
 * historial de una cuenta real) con AL MENOS una vista en `DIAS_HISTORIAL`
 * dias -- no todas las cuentas registradas. Una cuenta sin ninguna vista
 * reciente no tiene semillas de las que partir, R3 le devolveria vacio
 * igual, asi que ni se intenta. A diferencia de R2, aca no hay un minimo
 * de sesiones que se pueda exigir de antemano: si va a salir vacio (porque
 * ninguna sesion ajena vio lo mismo que la cuenta) solo se sabe corriendo
 * la consulta completa, no hay atajo posible.
 *
 * Si R3 no encuentra nada para una cuenta (tiene vistas, pero ninguna
 * sesion ajena vio lo mismo), se guarda un arreglo vacio -- la decision de
 * caer a T1 ("en ascenso") en ese caso es de quien lea esta cache despues,
 * no de este worker.
 *
 * Clave `mesh:cuenta:<id>:para-ti`, se SOBRESCRIBE cada ciclo con TTL de
 * `TTL_SEGUNDOS` (24h) -- mismo criterio que R2 (ver ese comentario): se
 * renueva sola mientras la cuenta siga activa, y se limpia sola cuando deje
 * de estarlo.
 */
@Injectable()
export class ParaTiSyncService {
  private readonly logger = new Logger(ParaTiSyncService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** `true` mientras un ciclo esta en curso: el siguiente se salta. */
  private procesando = false;

  @Interval('para-ti-sync', ParaTiSyncService.INTERVALO_MS)
  async recalcular(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      await this.recalcularTodas();
    } finally {
      this.procesando = false;
    }
  }

  private async recalcularTodas(): Promise<void> {
    let idsUsuario: number[];
    try {
      const resultado = await clickhouse.query({
        query: `SELECT DISTINCT id_usuario
                  FROM vista_producto
                 WHERE lote = 'real'
                   AND id_usuario IS NOT NULL
                   AND fecha >= now() - INTERVAL {diasHistorial:UInt32} DAY`,
        query_params: { diasHistorial: DIAS_HISTORIAL },
        format: 'JSONEachRow',
      });
      const filas = await resultado.json<{ id_usuario: string }>();
      idsUsuario = filas.map((fila) => Number(fila.id_usuario));
    } catch (error) {
      this.logger.warn(
        `worker de para-ti: no se pudo leer ClickHouse (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    // Primera pasada: el calculo crudo de cada cuenta, sin Mongo todavia.
    const candidatosPorCuenta = new Map<number, CandidatoParaTi[]>();
    for (const idUsuario of idsUsuario) {
      try {
        candidatosPorCuenta.set(
          idUsuario,
          await this.calcularRecomendaciones(idUsuario),
        );
      } catch (error) {
        this.logger.warn(
          `worker de para-ti: no se pudo calcular la cuenta ${idUsuario} (${(error as Error)?.message ?? error})`,
        );
      }
    }

    // Una sola consulta a Mongo por TODOS los candidatos de TODAS las
    // cuentas de este ciclo, nunca una por cuenta.
    const idsCandidatos = [
      ...new Set(
        [...candidatosPorCuenta.values()].flatMap((fila) =>
          fila.map((candidato) => candidato.id_producto),
        ),
      ),
    ];
    const productoPorId = await this.consultarProductosPorId(idsCandidatos);

    let calculadas = 0;
    for (const [idUsuario, candidatos] of candidatosPorCuenta) {
      const cacheado: ParaTiCacheado[] = candidatos.map((candidato) => ({
        ...candidato,
        producto: productoPorId.get(candidato.id_producto) ?? null,
      }));
      try {
        await redis.set(
          ParaTiSyncService.clave(idUsuario),
          JSON.stringify(cacheado),
          'EX',
          TTL_SEGUNDOS,
        );
        calculadas++;
      } catch (error) {
        this.logger.warn(
          `worker de para-ti: no se pudo guardar en Redis la cuenta ${idUsuario} (${(error as Error)?.message ?? error})`,
        );
      }
    }

    if (calculadas > 0) {
      this.logger.log(
        `worker de para-ti: ${calculadas}/${idsUsuario.length} cuenta(s) recalculadas`,
      );
    }
  }

  private async calcularRecomendaciones(
    idUsuario: number,
  ): Promise<CandidatoParaTi[]> {
    const resultado = await clickhouse.query({
      query: `WITH
                  semillas AS (
                      SELECT id_producto,
                             exp2(-dateDiff('second', max(fecha), now()) / 3600
                                  / {vidaMediaHoras:Float64}) AS peso
                        FROM vista_producto
                       WHERE lote = 'real'
                         AND id_usuario = {idUsuario:UInt64}
                         AND fecha >= now() - INTERVAL {diasHistorial:UInt32} DAY
                       GROUP BY id_producto
                       ORDER BY max(fecha) DESC
                       LIMIT {semillas:UInt32}
                  ),
                  ajenos AS (
                      SELECT DISTINCT sesion, id_producto
                        FROM vista_producto
                       WHERE lote = 'real'
                         AND fecha >= now() - INTERVAL {diasHistorial:UInt32} DAY
                         AND (id_usuario IS NULL OR id_usuario != {idUsuario:UInt64})
                  ),
                  puentes AS (
                      SELECT a.sesion AS sesion, s.id_producto AS semilla, s.peso AS peso
                        FROM ajenos AS a
                       INNER JOIN semillas AS s ON s.id_producto = a.id_producto
                  ),
                  alcance AS (
                      SELECT id_producto, count() AS sesiones FROM ajenos GROUP BY id_producto
                  )
                SELECT
                  c.id_producto                                   AS id_producto,
                  round(sum(p.peso) / sqrt(any(a.sesiones)), 3)   AS puntaje,
                  uniqExact(c.sesion)                             AS sesiones,
                  arraySort(groupUniqArray(p.semilla))            AS porque_viste
                FROM ajenos AS c
                INNER JOIN puentes AS p ON p.sesion = c.sesion
                INNER JOIN alcance AS a ON a.id_producto = c.id_producto
               WHERE c.id_producto NOT IN (SELECT id_producto FROM semillas)
                 AND c.id_producto NOT IN (
                       SELECT id_producto FROM compra_producto
                        WHERE lote = 'real' AND id_usuario = {idUsuario:UInt64})
               GROUP BY c.id_producto
               ORDER BY puntaje DESC, sesiones DESC, id_producto
               LIMIT {limite:UInt32}`,
      query_params: {
        idUsuario,
        diasHistorial: DIAS_HISTORIAL,
        semillas: SEMILLAS,
        vidaMediaHoras: VIDA_MEDIA_HORAS,
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaParaTi>();
    return filas.map((fila) => ({
      id_producto: Number(fila.id_producto),
      puntaje: Number(fila.puntaje),
      porque_viste: fila.porque_viste.map(Number),
    }));
  }

  /**
   * El detalle real de un conjunto de productos, pedido a MongoDB una sola
   * vez -- mismo patron que `TambienVieronSyncService`.
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
        `worker de para-ti: no se pudo leer Mongo (${(error as Error)?.message ?? error})`,
      );
      return new Map();
    }
  }

  /** Publica y estatica para que `ParaTiService` arme la misma clave al leer. */
  static clave(idUsuario: number): string {
    return `mesh:cuenta:${idUsuario}:para-ti`;
  }
}
