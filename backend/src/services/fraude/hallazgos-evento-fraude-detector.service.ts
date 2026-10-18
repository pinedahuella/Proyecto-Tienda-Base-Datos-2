import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { clickhouse } from '../../database/clickhouse';
import { registrarHallazgoEventoFraude } from '../../helpers/registrar-hallazgo-evento-fraude';
import {} from '../../models/hallazgo-evento-fraude';

// Los .sql de referencia (clickhouse/consultas/F1, F2, F3 y F5, obra del
// companero) y sus umbrales (clickhouse/consultas/parametros.txt) -- las
// consultas de aqui abajo son copia textual de esos archivos, sin tocar una
// coma (mismo criterio que el resto de detectores de ClickHouse: el propio
// documento dice "el backend puede copiar el texto de cada .sql sin
// tocarlo").
const LOTE = 'real';
const DIAS_VENTANA = 30;
const MIN_VISTAS_POR_SESION = 20;
const MINUTOS_RAFAGA = 15;
const MIN_PEDIDOS_RAFAGA = 5;
const MIN_CUENTAS_POR_IP = 4;
const IPS_DE_CONFIANZA = ['::1', '::ffff:127.0.0.1'];
const MIN_DEVOLUCIONES = 3;
const MIN_TASA_DEVOLUCION_CUENTA = 0.5;
const LIMITE = 10;
// Cuantos ids de pedido guarda F2/F3/F5 por senal (los mas recientes). Las
// tres consultas agregan `ids_pedidos` al texto del .sql del companero para
// llenar `senal_fraude_pedido` (etapa 5 del refactor de fraude); esa es la
// unica diferencia con sus F2, F3 y F5 de clickhouse/consultas/.
const MAX_PEDIDOS_POR_SENAL = 50;

interface FilaF1 {
  id_producto: string;
  vistas: string;
  sesiones: string;
  vistas_por_sesion: string;
  ips: string;
  sesiones_que_mas_miran: string[];
}

interface FilaF2 {
  id_usuario: string;
  pedidos_en_la_peor_rafaga: string;
  empezo: string;
  pedidos_en_el_periodo: string;
  ids_pedidos: string[];
}

interface FilaF3 {
  ip: string;
  cuentas_distintas: string;
  cuentas: string[];
  pedidos: string;
  ids_pedidos: string[];
  primera: string;
  ultima: string;
}

interface FilaF5 {
  id_usuario: string;
  pedidos: string;
  compradas: string;
  devueltas: string;
  tasa_devolucion: string;
  ids_pedidos: string[];
}

/**
 * Worker de F1, F2, F3 y F5 (`docs/fraude-entrega3/03-consultas-clickhouse.md`):
 * hallazgos de fraude sobre eventos de ClickHouse (vistas, compras,
 * devoluciones) que el grafo de Neo4j y el fraude de login no pueden ver.
 * F4 (carrito acaparador) se quito: con la venta relampago reservando en
 * PostgreSQL por 15 min, apartar sin comprar ya no deja unidades secuestradas
 * por 24 h. F6 (granja de registros) se mudo a Elasticsearch
 * (`FraudeLoginRetrospectivoService`): los registros ya no llegan a
 * ClickHouse. Persiste cada hallazgo con
 * `registrarHallazgoEventoFraude()` -- ver
 * `elementos Generales/plan pendiente/hallazgos-evento-fraude.md` para el
 * diseno de esa tabla.
 *
 * Corre una vez al dia, no cada 15 min como los demas workers de fraude:
 * F2 hace un self-join sobre `dias_ventana` (30) dias completos de
 * datos para calcular una ventana movil -- una consulta bastante mas
 * pesada que un simple `GROUP BY`, y `dias_ventana` es un corte diario, no
 * de minutos, asi que correr esto cada 15 min no encontraria nada nuevo la
 * gran mayoria de las veces.
 *
 * `ventana_inicio` es el inicio del dia UTC en que corre el worker (no la
 * hora exacta): dos corridas del mismo dia (una manual, otra el
 * `@Interval`) caen en la misma ventana y el `UPSERT` de
 * `registrarHallazgoEventoFraude` suma `contador` en vez de duplicar; al
 * dia siguiente nace una fila nueva a proposito (es una deteccion nueva).
 *
 * Cada consulta corre independiente, con su propio try/catch: un fallo en
 * una (ClickHouse parcialmente caido, un timeout) se loguea y no impide que
 * las otras se procesen.
 */
@Injectable()
export class HallazgosEventoFraudeDetectorService {
  private readonly logger = new Logger(
    HallazgosEventoFraudeDetectorService.name,
  );

  private static readonly INTERVALO_MS = 24 * 60 * 60 * 1000; // 1 dia

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  @Interval(
    'hallazgos-evento-fraude-detector',
    HallazgosEventoFraudeDetectorService.INTERVALO_MS,
  )
  async detectar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    const ventanaInicio = this.inicioDeHoy();
    try {
      await this.correr('F1 (vistas infladas)', () =>
        this.detectarVistasInfladas(ventanaInicio),
      );
      await this.correr('F2 (compras en rafaga)', () =>
        this.detectarComprasEnRafaga(ventanaInicio),
      );
      await this.correr('F3 (IP multicuenta compras)', () =>
        this.detectarIpMulticuentaCompras(ventanaInicio),
      );
      await this.correr('F5 (devoluciones seriales)', () =>
        this.detectarDevolucionesSeriales(ventanaInicio),
      );
    } finally {
      this.procesando = false;
    }
  }

  private async correr(
    nombre: string,
    detector: () => Promise<number>,
  ): Promise<void> {
    try {
      const hallazgos = await detector();
      if (hallazgos > 0) {
        this.logger.log(
          `worker de hallazgos de evento: ${nombre} -- ${hallazgos} hallazgo(s)`,
        );
      }
    } catch (error) {
      this.logger.warn(
        `worker de hallazgos de evento: ${nombre} fallo -- ${(error as Error)?.message ?? error}`,
      );
    }
  }

  private inicioDeHoy(): Date {
    const ahora = new Date();
    return new Date(
      Date.UTC(ahora.getUTCFullYear(), ahora.getUTCMonth(), ahora.getUTCDate()),
    );
  }

  /** F1_vistas_infladas.sql, sin tocar. */
  private async detectarVistasInfladas(ventanaInicio: Date): Promise<number> {
    const resultado = await clickhouse.query({
      query: `SELECT
                  id_producto,
                  count()                                  AS vistas,
                  uniqExact(sesion)                        AS sesiones,
                  round(vistas / sesiones, 1)              AS vistas_por_sesion,
                  uniqExact(ip)                             AS ips,
                  topK(3)(sesion)                          AS sesiones_que_mas_miran
                FROM vista_producto
               WHERE lote = {lote:String}
                 AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
               GROUP BY id_producto
              HAVING vistas_por_sesion >= {min_vistas_por_sesion:UInt32}
               ORDER BY vistas_por_sesion DESC
               LIMIT {limite:UInt32}`,
      query_params: {
        lote: LOTE,
        dias_ventana: DIAS_VENTANA,
        min_vistas_por_sesion: MIN_VISTAS_POR_SESION,
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaF1>();

    for (const fila of filas) {
      await registrarHallazgoEventoFraude({
        tipo: 'vistas_infladas',
        clave: fila.id_producto,
        cuentas: [],
        idProductoMongo: Number(fila.id_producto),
        detalle: {
          vistas: Number(fila.vistas),
          sesiones: Number(fila.sesiones),
          vistas_por_sesion: Number(fila.vistas_por_sesion),
          ips: Number(fila.ips),
        },
        ventanaInicio,
      });
    }
    return filas.length;
  }

  /** F2_compras_en_rafaga.sql, sin tocar. */
  private async detectarComprasEnRafaga(ventanaInicio: Date): Promise<number> {
    const resultado = await clickhouse.query({
      query: `WITH pedidos AS (
                    SELECT id_usuario, id_pedido, min(fecha) AS momento, any(ip) AS ip
                      FROM compra_producto FINAL
                     WHERE lote = {lote:String}
                       AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                     GROUP BY id_usuario, id_pedido
                )
                SELECT
                    id_usuario,
                    max(en_ventana)                 AS pedidos_en_la_peor_rafaga,
                    argMax(desde, en_ventana)       AS empezo,
                    any(total)                      AS pedidos_en_el_periodo,
                    arraySlice(arrayReverseSort(argMax(ids_en_ventana, en_ventana)), 1, {max_pedidos:UInt32}) AS ids_pedidos
                FROM (
                    SELECT p.id_usuario AS id_usuario, p.momento AS desde,
                           countIf(q.momento >= p.momento
                                   AND q.momento < p.momento + toIntervalMinute({minutos_rafaga:UInt32})) AS en_ventana,
                           groupArrayIf(q.id_pedido, q.momento >= p.momento
                                   AND q.momento < p.momento + toIntervalMinute({minutos_rafaga:UInt32})) AS ids_en_ventana
                      FROM pedidos AS p
                     INNER JOIN pedidos AS q ON q.id_usuario = p.id_usuario
                     GROUP BY p.id_usuario, p.id_pedido, p.momento
                ) AS r
                INNER JOIN (SELECT id_usuario, count() AS total FROM pedidos GROUP BY id_usuario) AS t USING (id_usuario)
                GROUP BY id_usuario
               HAVING pedidos_en_la_peor_rafaga >= {min_pedidos_rafaga:UInt32}
                ORDER BY pedidos_en_la_peor_rafaga DESC
                LIMIT {limite:UInt32}`,
      query_params: {
        lote: LOTE,
        dias_ventana: DIAS_VENTANA,
        minutos_rafaga: MINUTOS_RAFAGA,
        min_pedidos_rafaga: MIN_PEDIDOS_RAFAGA,
        max_pedidos: MAX_PEDIDOS_POR_SENAL,
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaF2>();

    for (const fila of filas) {
      await registrarHallazgoEventoFraude({
        tipo: 'compras_en_rafaga',
        clave: fila.id_usuario,
        cuentas: [fila.id_usuario],
        pedidos: fila.ids_pedidos,
        idProductoMongo: null,
        detalle: {
          pedidos_en_la_peor_rafaga: Number(fila.pedidos_en_la_peor_rafaga),
          pedidos_en_el_periodo: Number(fila.pedidos_en_el_periodo),
          empezo: fila.empezo,
        },
        ventanaInicio,
      });
    }
    return filas.length;
  }

  /** F3_ip_multicuenta_compras.sql, sin tocar. */
  private async detectarIpMulticuentaCompras(
    ventanaInicio: Date,
  ): Promise<number> {
    const resultado = await clickhouse.query({
      query: `SELECT
                  toString(ip)                           AS ip,
                  uniqExact(id_usuario)                  AS cuentas_distintas,
                  arraySort(groupUniqArray(id_usuario))  AS cuentas,
                  uniqExact(id_pedido)                   AS pedidos,
                  arraySlice(arrayReverseSort(groupUniqArray(id_pedido)), 1, {max_pedidos:UInt32}) AS ids_pedidos,
                  min(fecha)                             AS primera,
                  max(fecha)                             AS ultima
                FROM compra_producto FINAL
               WHERE lote = {lote:String}
                 AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                 AND NOT has({ips_de_confianza:Array(String)}, toString(ip))
                 AND toString(ip) != '::'
               GROUP BY ip
              HAVING cuentas_distintas >= {min_cuentas_por_ip:UInt32}
               ORDER BY cuentas_distintas DESC
               LIMIT {limite:UInt32}`,
      query_params: {
        lote: LOTE,
        dias_ventana: DIAS_VENTANA,
        min_cuentas_por_ip: MIN_CUENTAS_POR_IP,
        ips_de_confianza: IPS_DE_CONFIANZA,
        max_pedidos: MAX_PEDIDOS_POR_SENAL,
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaF3>();

    for (const fila of filas) {
      await registrarHallazgoEventoFraude({
        tipo: 'ip_multicuenta_compras',
        clave: fila.ip,
        cuentas: fila.cuentas,
        pedidos: fila.ids_pedidos,
        idProductoMongo: null,
        detalle: {
          cuentas_distintas: Number(fila.cuentas_distintas),
          pedidos: Number(fila.pedidos),
          primera: fila.primera,
          ultima: fila.ultima,
        },
        ventanaInicio,
      });
    }
    return filas.length;
  }

  /** F5_devoluciones_seriales.sql, sin tocar. */
  private async detectarDevolucionesSeriales(
    ventanaInicio: Date,
  ): Promise<number> {
    const resultado = await clickhouse.query({
      query: `WITH
                  k AS (SELECT id_usuario, sum(cantidad) AS compradas, uniqExact(id_pedido) AS pedidos
                          FROM compra_producto FINAL
                         WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                         GROUP BY id_usuario),
                  d AS (SELECT id_usuario, sum(cantidad) AS devueltas,
                               groupUniqArray(id_pedido) AS pedidos_devueltos
                          FROM devolucion_producto FINAL
                         WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                         GROUP BY id_usuario)
                SELECT
                  d.id_usuario                          AS id_usuario,
                  k.pedidos                             AS pedidos,
                  k.compradas                           AS compradas,
                  d.devueltas                           AS devueltas,
                  round(d.devueltas / greatest(k.compradas, 1), 2) AS tasa_devolucion,
                  arraySlice(arrayReverseSort(d.pedidos_devueltos), 1, {max_pedidos:UInt32}) AS ids_pedidos
                FROM d LEFT JOIN k ON k.id_usuario = d.id_usuario
               WHERE d.devueltas >= {min_devoluciones:UInt32}
                 AND tasa_devolucion >= {min_tasa_devolucion_cuenta:Float64}
               ORDER BY tasa_devolucion DESC, devueltas DESC
               LIMIT {limite:UInt32}`,
      query_params: {
        lote: LOTE,
        dias_ventana: DIAS_VENTANA,
        min_devoluciones: MIN_DEVOLUCIONES,
        min_tasa_devolucion_cuenta: MIN_TASA_DEVOLUCION_CUENTA,
        max_pedidos: MAX_PEDIDOS_POR_SENAL,
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaF5>();

    for (const fila of filas) {
      await registrarHallazgoEventoFraude({
        tipo: 'devoluciones_seriales',
        clave: fila.id_usuario,
        cuentas: [fila.id_usuario],
        pedidos: fila.ids_pedidos,
        idProductoMongo: null,
        detalle: {
          pedidos: Number(fila.pedidos),
          compradas: Number(fila.compradas),
          devueltas: Number(fila.devueltas),
          tasa_devolucion: Number(fila.tasa_devolucion),
        },
        ventanaInicio,
      });
    }
    return filas.length;
  }
}
