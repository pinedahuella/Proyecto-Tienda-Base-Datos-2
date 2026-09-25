import { Injectable, Logger } from '@nestjs/common';
import { clickhouse } from '../../database/clickhouse';
import { mongoDb } from '../../database/mongo';
import { manejarErrorClickHouse } from '../../helpers/manejar-error-clickhouse';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import {
  validarDiasEvento,
  validarDiasBase,
  validarDiasVentana,
  validarLimiteEvento,
} from '../../helpers/validaciones-eventos';
import type { ConsultarTendenciaAscensoQuery } from '../../dto/consultar-tendencia-ascenso';
import type { ConsultarTendenciaVentanaQuery } from '../../dto/consultar-tendencia-ventana';
import type {
  TendenciaEnAscenso,
  TendenciaEmbudo,
  TendenciaBusquedaSinRespuesta,
} from '../../models/tendencia-avanzada';
import { Producto } from '../../models/producto';

/**
 * Umbrales de las tres consultas -- fijos, no configurables por query param
 * (decision explicita: exponerlos complicaria la ruta con parametros que
 * nadie pidio ajustar). Mismos valores ya probados por el companero en
 * `clickhouse/consultas/parametros.txt`.
 */
const T1_MIN_VISTAS = 20;
const T1_MIN_CRECIMIENTO = 1.5;
const T2_MIN_SESIONES_EMBUDO = 20;
const T2_MAX_CONVERSION = 0.02;
const T2_MIN_TASA_DEVOLUCION = 0.3;
const T3_MIN_SESIONES_BUSQUEDA = 3;

interface FilaEnAscenso {
  id_producto: string;
  por_dia_ahora: string;
  por_dia_antes: string;
  veces: string;
  vistas_por_persona: string;
}

interface FilaEmbudo {
  id_producto: string;
  sesiones: string;
  en_carrito: string;
  pedidos: string;
  unidades: string;
  devueltas: string;
  conversion: string;
  tasa_devolucion: string;
  diagnostico: 'mucho_interes_poca_compra' | 'devolucion_alta';
}

interface FilaBusquedaSinRespuesta {
  termino: string;
  busquedas: string;
  sesiones: string;
  mas_resultados: string;
  clics: string;
  diagnostico: 'no_tenemos' | 'no_convence';
}

/**
 * `GET /admin/eventos/tendencias|embudo|busquedas-sin-respuesta` -- las tres
 * consultas de "Tendencias" que propuso el companero en
 * `docs/fraude-entrega3/03-consultas-clickhouse.md` (T1, T2, T3), que el
 * ranking generico de `AdminTendenciasService` no puede contestar: ese
 * agrega UNA tabla a la vez por conteo/suma; estas cruzan varias tablas o
 * comparan dos ventanas de tiempo entre si.
 *
 * Controller y servicio SEPARADOS de `AdminTendenciasController`/`Service`
 * (pedido explicito del usuario) -- mismo prefijo de ruta (`/admin/eventos`)
 * porque conceptualmente es el mismo dominio, pero clases distintas.
 *
 * `GET /admin/eventos/tendencias` es, ademas, la ruta exacta que el
 * profesor pidio el 2026-09-06 y que nunca se habia construido (se
 * reemplazo por el explorador generico en su momento) -- ver memoria
 * `estado-backend-tienda`.
 */
@Injectable()
export class AdminTendenciasAvanzadasService {
  private readonly logger = new Logger(AdminTendenciasAvanzadasService.name);

  /**
   * T1 -- productos cuyas vistas diarias de los ultimos `dias_recientes`
   * dias superan a las de los `dias_base` dias anteriores. Lee el resumen
   * `vistas_por_producto_dia` (la vista materializada que ya existe, no la
   * tabla cruda), con `countMergeIf`/`uniqMergeIf` porque guarda estados
   * parciales, no numeros. Compara PROMEDIOS diarios (no totales) y suaviza
   * con +1 arriba y abajo -- ver `T1_en_ascenso.sql` para el porque exacto
   * de las dos correcciones.
   */
  async enAscenso(
    query: ConsultarTendenciaAscensoQuery,
  ): Promise<TendenciaEnAscenso[]> {
    const diasRecientes = validarDiasEvento(query.dias_recientes);
    const diasBase = validarDiasBase(query.dias_base);
    const limite = validarLimiteEvento(query.limite);

    let filas: FilaEnAscenso[];
    try {
      const resultado = await clickhouse.query({
        query: `SELECT
                    id_producto,
                    countMergeIf(vistas, dia > today() - {diasRecientes:UInt32})   AS vistas_recientes,
                    countMergeIf(vistas, dia <= today() - {diasRecientes:UInt32})  AS vistas_base,
                    uniqMergeIf(sesiones, dia > today() - {diasRecientes:UInt32})  AS personas_recientes,
                    round(vistas_recientes / {diasRecientes:UInt32}, 1)            AS por_dia_ahora,
                    round(vistas_base / {diasBase:UInt32}, 1)                      AS por_dia_antes,
                    round((vistas_recientes / {diasRecientes:UInt32} + 1)
                        / (vistas_base / {diasBase:UInt32} + 1), 2)                AS veces,
                    round(vistas_recientes / greatest(personas_recientes, 1), 1)   AS vistas_por_persona
                  FROM vistas_por_producto_dia
                 WHERE lote = 'real'
                   AND dia > today() - ({diasRecientes:UInt32} + {diasBase:UInt32})
                 GROUP BY id_producto
                HAVING vistas_recientes >= {minVistas:UInt32}
                   AND veces >= {minCrecimiento:Float64}
                 ORDER BY veces DESC
                 LIMIT {limite:UInt32}`,
        query_params: {
          diasRecientes,
          diasBase,
          minVistas: T1_MIN_VISTAS,
          minCrecimiento: T1_MIN_CRECIMIENTO,
          limite,
        },
        format: 'JSONEachRow',
      });
      filas = await resultado.json<FilaEnAscenso>();
    } catch (error) {
      manejarErrorClickHouse(this.logger, error);
    }

    const productoPorId = await this.consultarProductosPorId(
      filas.map((fila) => Number(fila.id_producto)),
    );
    return filas.map((fila) => ({
      por_dia_ahora: Number(fila.por_dia_ahora),
      por_dia_antes: Number(fila.por_dia_antes),
      veces: Number(fila.veces),
      vistas_por_persona: Number(fila.vistas_por_persona),
      producto: productoPorId.get(Number(fila.id_producto)) ?? null,
    }));
  }

  /**
   * T2 -- por producto, cuantas sesiones lo vieron, cuantas cuentas lo
   * agregaron al carrito, cuantos pedidos/unidades salieron y cuantas
   * volvieron -- solo los que tienen un problema (`mucho_interes_poca_compra`
   * o `devolucion_alta`). `FINAL` en `compra_producto`/`devolucion_producto`
   * (`ReplacingMergeTree`): sin el, una fila que el ETL cargo dos veces
   * cuenta dos veces hasta que ClickHouse fusione las partes.
   */
  async embudo(
    query: ConsultarTendenciaVentanaQuery,
  ): Promise<TendenciaEmbudo[]> {
    const diasVentana = validarDiasVentana(query.dias_ventana);
    const limite = validarLimiteEvento(query.limite);

    let filas: FilaEmbudo[];
    try {
      const resultado = await clickhouse.query({
        query: `WITH
                    v AS (SELECT id_producto, uniqExact(sesion) AS sesiones FROM vista_producto
                           WHERE lote = 'real' AND fecha >= now() - INTERVAL {diasVentana:UInt32} DAY
                           GROUP BY id_producto),
                    c AS (SELECT id_producto, uniqExact(id_usuario) AS en_carrito FROM carrito_producto
                           WHERE lote = 'real' AND fecha >= now() - INTERVAL {diasVentana:UInt32} DAY
                           GROUP BY id_producto),
                    k AS (SELECT id_producto, uniqExact(id_pedido) AS pedidos, sum(cantidad) AS unidades
                            FROM compra_producto FINAL
                           WHERE lote = 'real' AND fecha >= now() - INTERVAL {diasVentana:UInt32} DAY
                           GROUP BY id_producto),
                    d AS (SELECT id_producto, sum(cantidad) AS devueltas FROM devolucion_producto FINAL
                           WHERE lote = 'real' AND fecha >= now() - INTERVAL {diasVentana:UInt32} DAY
                           GROUP BY id_producto),
                    ids AS (SELECT id_producto FROM v UNION DISTINCT SELECT id_producto FROM k)
                  SELECT
                    ids.id_producto                                     AS id_producto,
                    v.sesiones                                          AS sesiones,
                    c.en_carrito                                        AS en_carrito,
                    k.pedidos                                           AS pedidos,
                    k.unidades                                          AS unidades,
                    d.devueltas                                         AS devueltas,
                    if(sesiones = 0, 0, round(pedidos / sesiones, 3))    AS conversion,
                    if(unidades = 0, 0, round(devueltas / unidades, 2))  AS tasa_devolucion,
                    multiIf(sesiones >= {minSesionesEmbudo:UInt32}
                              AND conversion <= {maxConversion:Float64}, 'mucho_interes_poca_compra',
                            unidades > 0
                              AND tasa_devolucion >= {minTasaDevolucion:Float64}, 'devolucion_alta',
                            'normal')                                   AS diagnostico
                  FROM ids
                  LEFT JOIN v ON v.id_producto = ids.id_producto
                  LEFT JOIN c ON c.id_producto = ids.id_producto
                  LEFT JOIN k ON k.id_producto = ids.id_producto
                  LEFT JOIN d ON d.id_producto = ids.id_producto
                 WHERE diagnostico != 'normal'
                 ORDER BY diagnostico, sesiones DESC
                 LIMIT {limite:UInt32}`,
        query_params: {
          diasVentana,
          minSesionesEmbudo: T2_MIN_SESIONES_EMBUDO,
          maxConversion: T2_MAX_CONVERSION,
          minTasaDevolucion: T2_MIN_TASA_DEVOLUCION,
          limite,
        },
        format: 'JSONEachRow',
      });
      filas = await resultado.json<FilaEmbudo>();
    } catch (error) {
      manejarErrorClickHouse(this.logger, error);
    }

    const productoPorId = await this.consultarProductosPorId(
      filas.map((fila) => Number(fila.id_producto)),
    );
    return filas.map((fila) => ({
      sesiones: Number(fila.sesiones),
      en_carrito: Number(fila.en_carrito),
      pedidos: Number(fila.pedidos),
      unidades: Number(fila.unidades),
      devueltas: Number(fila.devueltas),
      conversion: Number(fila.conversion),
      tasa_devolucion: Number(fila.tasa_devolucion),
      diagnostico: fila.diagnostico,
      producto: productoPorId.get(Number(fila.id_producto)) ?? null,
    }));
  }

  /**
   * T3 -- terminos buscados con un problema (`no_tenemos`: siempre 0
   * resultados; `no_convence`: hay resultados y nadie hace clic). El
   * termino se compara en minusculas y sin espacios en las puntas -- el
   * backend lo guarda tal como se escribio, y "Dron"/"dron " son la misma
   * demanda. Sin segunda consulta a Mongo: el termino ya es todo el dato.
   */
  async busquedasSinRespuesta(
    query: ConsultarTendenciaVentanaQuery,
  ): Promise<TendenciaBusquedaSinRespuesta[]> {
    const diasVentana = validarDiasVentana(query.dias_ventana);
    const limite = validarLimiteEvento(query.limite);

    try {
      const resultado = await clickhouse.query({
        query: `WITH
                    b AS (SELECT lower(trim(BOTH ' ' FROM termino)) AS t,
                                 count() AS busquedas, uniqExact(sesion) AS sesiones,
                                 countIf(resultados = 0) AS sin_resultados,
                                 max(resultados) AS mas_resultados
                            FROM busqueda_realizada
                           WHERE lote = 'real' AND fecha >= now() - INTERVAL {diasVentana:UInt32} DAY
                           GROUP BY t),
                    k AS (SELECT lower(trim(BOTH ' ' FROM termino)) AS t, count() AS clics
                            FROM busqueda_clic
                           WHERE lote = 'real' AND fecha >= now() - INTERVAL {diasVentana:UInt32} DAY
                           GROUP BY t)
                  SELECT
                    b.t              AS termino,
                    b.busquedas      AS busquedas,
                    b.sesiones       AS sesiones,
                    b.mas_resultados AS mas_resultados,
                    k.clics          AS clics,
                    multiIf(b.sin_resultados = b.busquedas, 'no_tenemos',
                            k.clics = 0,                    'no_convence',
                            'normal') AS diagnostico
                  FROM b LEFT JOIN k ON k.t = b.t
                 WHERE b.sesiones >= {minSesionesBusqueda:UInt32}
                   AND diagnostico != 'normal'
                 ORDER BY diagnostico, sesiones DESC
                 LIMIT {limite:UInt32}`,
        query_params: {
          diasVentana,
          minSesionesBusqueda: T3_MIN_SESIONES_BUSQUEDA,
          limite,
        },
        format: 'JSONEachRow',
      });
      const filas = await resultado.json<FilaBusquedaSinRespuesta>();
      return filas.map((fila) => ({
        termino: fila.termino,
        busquedas: Number(fila.busquedas),
        sesiones: Number(fila.sesiones),
        mas_resultados: Number(fila.mas_resultados),
        clics: Number(fila.clics),
        diagnostico: fila.diagnostico,
      }));
    } catch (error) {
      manejarErrorClickHouse(this.logger, error);
    }
  }

  /**
   * El detalle real de un conjunto de productos, pedido a MongoDB con los
   * ids que devolvio ClickHouse -- mismo patron que
   * `AdminTendenciasService.rankingPorProducto()`: SIN filtrar por estado
   * (un admin necesita ver tambien un producto inactivo o ya borrado), y
   * sin descartar un id sin documento (la fila de ClickHouse sigue siendo
   * un dato valido aunque el producto ya no exista -- sale con
   * `producto: null`).
   */
  private async consultarProductosPorId(
    idsProducto: number[],
  ): Promise<Map<number, Producto>> {
    if (idsProducto.length === 0) {
      return new Map();
    }
    let productos: Producto[];
    try {
      productos = await mongoDb
        .collection<Producto>('productos')
        .find({ _id: { $in: idsProducto } })
        .toArray();
    } catch (error) {
      manejarErrorConexionMongo(this.logger, error);
    }
    return new Map(productos.map((p) => [p._id, p]));
  }
}
