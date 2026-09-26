import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { clickhouse } from '../../database/clickhouse';
import { registrarHallazgoEventoFraude } from '../../helpers/registrar-hallazgo-evento-fraude';
import {
  ID_TIPO_HALLAZGO_EVENTO_CARRITO_ACAPARADOR,
  ID_TIPO_HALLAZGO_EVENTO_COMPRAS_EN_RAFAGA,
  ID_TIPO_HALLAZGO_EVENTO_DEVOLUCIONES_SERIALES,
  ID_TIPO_HALLAZGO_EVENTO_GRANJA_DE_REGISTROS,
  ID_TIPO_HALLAZGO_EVENTO_IP_MULTICUENTA_COMPRAS,
  ID_TIPO_HALLAZGO_EVENTO_VISTAS_INFLADAS,
} from '../../models/hallazgo-evento-fraude';

// Los seis .sql de referencia (clickhouse/consultas/F1..F6, obra del
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
const MIN_UNIDADES_ACAPARADAS = 20;
const MAX_TASA_COMPRA_ACAPARADOR = 0.2;
const MIN_DEVOLUCIONES = 3;
const MIN_TASA_DEVOLUCION_CUENTA = 0.5;
const MINUTOS_REGISTRO = 60;
const MIN_REGISTROS_POR_IP = 5;
const LIMITE = 10;

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
}

interface FilaF3 {
  ip: string;
  cuentas_distintas: string;
  cuentas: string[];
  pedidos: string;
  primera: string;
  ultima: string;
}

interface FilaF4 {
  id_usuario: string;
  id_producto: string;
  agregadas: string;
  veces: string;
  compradas: string | null;
  tasa_compra: string | null;
}

interface FilaF5 {
  id_usuario: string;
  pedidos: string;
  compradas: string;
  devueltas: string;
  tasa_devolucion: string;
}

interface FilaF6 {
  ip: string;
  cuentas_en_la_peor_ventana: string;
  empezo: string;
  cuentas: string[];
}

/**
 * Worker de F1-F6 (`docs/fraude-entrega3/03-consultas-clickhouse.md`):
 * hallazgos de fraude sobre eventos de ClickHouse (vistas, carritos,
 * compras, devoluciones, registros) que el grafo de Neo4j y el fraude de
 * login no pueden ver. Persiste cada hallazgo con
 * `registrarHallazgoEventoFraude()` -- ver
 * `elementos Generales/plan pendiente/hallazgos-evento-fraude.md` para el
 * diseno de esa tabla.
 *
 * Corre una vez al dia, no cada 15 min como los demas workers de fraude:
 * F2 y F6 hacen un self-join sobre `dias_ventana` (30) dias completos de
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
 * Cada una de las seis consultas corre independiente, con su propio
 * try/catch: un fallo en una (ClickHouse parcialmente caido, un timeout)
 * se loguea y no impide que las otras cinco se procesen.
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
      await this.correr('F4 (carrito acaparador)', () =>
        this.detectarCarritoAcaparador(ventanaInicio),
      );
      await this.correr('F5 (devoluciones seriales)', () =>
        this.detectarDevolucionesSeriales(ventanaInicio),
      );
      await this.correr('F6 (granja de registros)', () =>
        this.detectarGranjaDeRegistros(ventanaInicio),
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
        idTipoHallazgo: ID_TIPO_HALLAZGO_EVENTO_VISTAS_INFLADAS,
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
                    any(total)                      AS pedidos_en_el_periodo
                FROM (
                    SELECT p.id_usuario AS id_usuario, p.momento AS desde,
                           countIf(q.momento >= p.momento
                                   AND q.momento < p.momento + toIntervalMinute({minutos_rafaga:UInt32})) AS en_ventana
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
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaF2>();

    for (const fila of filas) {
      await registrarHallazgoEventoFraude({
        idTipoHallazgo: ID_TIPO_HALLAZGO_EVENTO_COMPRAS_EN_RAFAGA,
        clave: fila.id_usuario,
        cuentas: [fila.id_usuario],
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
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaF3>();

    for (const fila of filas) {
      await registrarHallazgoEventoFraude({
        idTipoHallazgo: ID_TIPO_HALLAZGO_EVENTO_IP_MULTICUENTA_COMPRAS,
        clave: fila.ip,
        cuentas: fila.cuentas,
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

  /** F4_carrito_acaparador.sql, sin tocar. */
  private async detectarCarritoAcaparador(
    ventanaInicio: Date,
  ): Promise<number> {
    const resultado = await clickhouse.query({
      query: `WITH
                  carrito AS (SELECT id_usuario, id_producto, sum(cantidad) AS agregadas, count() AS veces
                                FROM carrito_producto
                               WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                               GROUP BY id_usuario, id_producto),
                  compra  AS (SELECT id_usuario, id_producto, sum(cantidad) AS compradas
                                FROM compra_producto FINAL
                               WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                               GROUP BY id_usuario, id_producto)
                SELECT
                  c.id_usuario                              AS id_usuario,
                  c.id_producto                             AS id_producto,
                  c.agregadas                               AS agregadas,
                  c.veces                                   AS veces,
                  k.compradas                               AS compradas,
                  round(k.compradas / c.agregadas, 2)       AS tasa_compra
                FROM carrito AS c
                LEFT JOIN compra AS k ON k.id_usuario = c.id_usuario AND k.id_producto = c.id_producto
               WHERE c.agregadas >= {min_unidades_acaparadas:UInt32}
                 AND tasa_compra <= {max_tasa_compra_acaparador:Float64}
               ORDER BY c.agregadas DESC
               LIMIT {limite:UInt32}`,
      query_params: {
        lote: LOTE,
        dias_ventana: DIAS_VENTANA,
        min_unidades_acaparadas: MIN_UNIDADES_ACAPARADAS,
        max_tasa_compra_acaparador: MAX_TASA_COMPRA_ACAPARADOR,
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaF4>();

    for (const fila of filas) {
      await registrarHallazgoEventoFraude({
        idTipoHallazgo: ID_TIPO_HALLAZGO_EVENTO_CARRITO_ACAPARADOR,
        clave: `${fila.id_usuario}-${fila.id_producto}`,
        cuentas: [fila.id_usuario],
        idProductoMongo: Number(fila.id_producto),
        detalle: {
          agregadas: Number(fila.agregadas),
          veces: Number(fila.veces),
          compradas: fila.compradas != null ? Number(fila.compradas) : 0,
          tasa_compra: fila.tasa_compra != null ? Number(fila.tasa_compra) : 0,
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
                  d AS (SELECT id_usuario, sum(cantidad) AS devueltas
                          FROM devolucion_producto FINAL
                         WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                         GROUP BY id_usuario)
                SELECT
                  d.id_usuario                          AS id_usuario,
                  k.pedidos                             AS pedidos,
                  k.compradas                           AS compradas,
                  d.devueltas                           AS devueltas,
                  round(d.devueltas / greatest(k.compradas, 1), 2) AS tasa_devolucion
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
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaF5>();

    for (const fila of filas) {
      await registrarHallazgoEventoFraude({
        idTipoHallazgo: ID_TIPO_HALLAZGO_EVENTO_DEVOLUCIONES_SERIALES,
        clave: fila.id_usuario,
        cuentas: [fila.id_usuario],
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

  /** F6_granja_de_registros.sql, sin tocar. */
  private async detectarGranjaDeRegistros(
    ventanaInicio: Date,
  ): Promise<number> {
    const resultado = await clickhouse.query({
      query: `WITH r AS (
                    SELECT ip, id_usuario, fecha
                      FROM evento_registro FINAL
                     WHERE lote = {lote:String}
                       AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                       AND NOT has({ips_de_confianza:Array(String)}, toString(ip))
                       AND ip != toIPv6('::')
                )
                SELECT
                    toString(ip)                                  AS ip,
                    max(cuantas)                                  AS cuentas_en_la_peor_ventana,
                    argMax(desde, cuantas)                        AS empezo,
                    arraySort(argMax(cuentas_de_la_ventana, cuantas)) AS cuentas
                FROM (
                    SELECT a.ip AS ip, a.fecha AS desde,
                           countIf(b.fecha >= a.fecha
                                   AND b.fecha < a.fecha + toIntervalMinute({minutos_registro:UInt32})) AS cuantas,
                           groupArrayIf(b.id_usuario, b.fecha >= a.fecha
                                   AND b.fecha < a.fecha + toIntervalMinute({minutos_registro:UInt32})) AS cuentas_de_la_ventana
                      FROM r AS a INNER JOIN r AS b ON b.ip = a.ip
                     GROUP BY a.ip, a.id_usuario, a.fecha
                )
                GROUP BY ip
               HAVING cuentas_en_la_peor_ventana >= {min_registros_por_ip:UInt32}
                ORDER BY cuentas_en_la_peor_ventana DESC
                LIMIT {limite:UInt32}`,
      query_params: {
        lote: LOTE,
        dias_ventana: DIAS_VENTANA,
        minutos_registro: MINUTOS_REGISTRO,
        min_registros_por_ip: MIN_REGISTROS_POR_IP,
        ips_de_confianza: IPS_DE_CONFIANZA,
        limite: LIMITE,
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaF6>();

    for (const fila of filas) {
      await registrarHallazgoEventoFraude({
        idTipoHallazgo: ID_TIPO_HALLAZGO_EVENTO_GRANJA_DE_REGISTROS,
        clave: fila.ip,
        cuentas: fila.cuentas,
        idProductoMongo: null,
        detalle: {
          cuentas_en_la_peor_ventana: Number(fila.cuentas_en_la_peor_ventana),
          empezo: fila.empezo,
        },
        ventanaInicio,
      });
    }
    return filas.length;
  }
}
