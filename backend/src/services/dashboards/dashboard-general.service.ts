import { Injectable, Logger } from '@nestjs/common';
import { clickhouse } from '../../database/clickhouse';
import { pool } from '../../database/postgres';
import {
  BusquedasDashboard,
  CancelacionesDashboard,
  CeldaMapaCalor,
  CifrasDashboard,
  DashboardCompleto,
  EmbudoDashboard,
  FilaCategoria,
  FilaDepartamento,
  FilaPagoMensual,
  FilaPedidoDashboard,
  FilaProducto,
  FilaVendedor,
  PedidosDashboard,
  PeriodoDashboard,
  ResumenDashboard,
  SeccionDashboard,
  VentasDashboard,
} from '../../dto/dashboards/dashboard-general';
import { ErrorValidacion } from '../../helpers/errores';
import { manejarErrorClickHouse } from '../../helpers/manejar-error-clickhouse';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';
import { leerPeriodo, ZONA_TIENDA } from './dashboard-periodo';

/**
 * El dashboard general del admin: como va la tienda en un periodo, con las
 * mismas cuentas que Reportes (`AdminReportesService`) pero repartidas en el
 * tiempo, por categoria, por vendedor, por departamento y por hora.
 *
 * Que es una venta: un pedido `comprado`, `enviado` o `entregado`. Los
 * `pendiente` son carritos (desde la 045) y los `cancelado` se cuentan aparte.
 * Lo cobrado sale de `pago` en estado `pagado`, igual que el Cobrado de
 * Reportes; lo de cada linea (por categoria, vendedor, producto) sale del
 * precio congelado de la linea con su descuento (`expresionPrecioFinal`).
 *
 * Todo sale de PostgreSQL menos el embudo (las dos primeras etapas) y las
 * busquedas, que salen de ClickHouse: los eventos de la tienda solo viven
 * ahi. Solo cuentan los eventos con `lote = 'real'`, como en Tendencias.
 */

/** Lo que es una venta. */
const VENDIDO = `('comprado', 'enviado', 'entregado')`;

/** El dia de un instante en hora de la tienda. */
const diaDe = (columna: string) =>
  `(${columna} AT TIME ZONE '${ZONA_TIENDA}')::date`;

/** Del periodo: $1 desde, $2 hasta, los dos incluidos. */
const enPeriodo = (columna: string) =>
  `${diaDe(columna)} BETWEEN $1::date AND $2::date`;

/** Las lineas vendidas del periodo, con su importe ya con descuento. */
const LINEAS_VENDIDAS = `
  lineas AS (
    SELECT p.id_pedido, p.id_usuario, p.fecha_creacion, p.id_direccion_historial,
           pp.id_producto_mongo, pp.nombre_producto, pp.cantidad, ph.id_oferta,
           ${expresionPrecioFinal('ph')} * pp.cantidad AS importe
      FROM pedido p
      JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
      JOIN pedido_producto pp ON pp.id_pedido = p.id_pedido
      JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
     WHERE ep.estado_pedido_nombre IN ${VENDIDO}
       AND ${enPeriodo('p.fecha_creacion')}
  )`;

const LIMITE_RANKING = 10;

@Injectable()
export class DashboardGeneralService {
  private readonly logger = new Logger(DashboardGeneralService.name);

  periodo(desde?: string, hasta?: string): PeriodoDashboard {
    return leerPeriodo(desde, hasta);
  }

  /** Las cifras de arriba, contra el periodo anterior del mismo largo. */
  async resumen(desde?: string, hasta?: string): Promise<ResumenDashboard> {
    const periodo = leerPeriodo(desde, hasta);
    try {
      const [actual, anterior, hoy] = await Promise.all([
        this.cifras(periodo.desde, periodo.hasta),
        this.cifras(periodo.anterior_desde, periodo.anterior_hasta),
        pool.query<ResumenDashboard['hoy']>(`
          SELECT (SELECT count(*) FROM producto_catalogo WHERE estado = 'activo')::int AS productos_activos,
                 (SELECT count(DISTINCT o.id_usuario)
                    FROM oferta o JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
                   WHERE eo.estado_oferta_nombre = 'activa')::int AS vendedores_activos,
                 (SELECT count(*) FROM usuarios)::int AS cuentas,
                 (SELECT count(DISTINCT p.id_pedido)
                    FROM pedido p
                    JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
                    JOIN pedido_producto pp ON pp.id_pedido = p.id_pedido
                   WHERE ep.estado_pedido_nombre = 'pendiente')::int AS carritos_abiertos`),
      ]);
      return { periodo, actual, anterior, hoy: hoy.rows[0] };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async cifras(desde: string, hasta: string): Promise<CifrasDashboard> {
    const { rows } = await pool.query<
      Omit<CifrasDashboard, 'tasa_cancelacion'>
    >(
      `WITH ${LINEAS_VENDIDAS},
            cobrado AS (
              SELECT pg.monto, epa.estado_pago_nombre AS estado
                FROM pago pg
                JOIN estado_pago epa ON epa.id_estado_pago = pg.id_estado_pago
                JOIN pedido p ON p.id_pedido = pg.id_pedido
               WHERE ${enPeriodo('p.fecha_creacion')}
            )
       SELECT COALESCE((SELECT sum(monto) FROM cobrado WHERE estado = 'pagado'), 0)::numeric(14,2)::text AS ingresos,
              (SELECT count(DISTINCT id_pedido) FROM lineas)::int AS pedidos,
              COALESCE((SELECT (sum(monto) / NULLIF(count(*), 0)) FROM cobrado WHERE estado = 'pagado'), 0)::numeric(14,2)::text AS ticket_promedio,
              COALESCE((SELECT sum(cantidad) FROM lineas), 0)::int AS unidades,
              (SELECT count(DISTINCT id_usuario) FROM lineas)::int AS compradores,
              (SELECT count(*) FROM usuarios u WHERE ${enPeriodo('u.fecha_creacion')})::int AS clientes_nuevos,
              (SELECT count(*) FROM pedido p JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
                WHERE ep.estado_pedido_nombre = 'cancelado' AND ${enPeriodo('p.fecha_creacion')})::int AS cancelados,
              COALESCE((SELECT sum(monto) FROM cobrado WHERE estado = 'reembolsado'), 0)::numeric(14,2)::text AS reembolsado,
              (SELECT count(DISTINCT o.id_usuario) FROM lineas l JOIN oferta o ON o.id_oferta = l.id_oferta)::int AS vendedores_con_ventas`,
      [desde, hasta],
    );
    const fila = rows[0];
    const llegaronAPagarse = fila.pedidos + fila.cancelados;
    return {
      ...fila,
      tasa_cancelacion:
        llegaronAPagarse === 0 ? 0 : fila.cancelados / llegaronAPagarse,
    };
  }

  /** Lo cobrado, los pedidos y las unidades, por dia, semana o mes, sin huecos. */
  async ventas(desde?: string, hasta?: string): Promise<VentasDashboard> {
    const periodo = leerPeriodo(desde, hasta);
    const g =
      periodo.agrupado === 'dia'
        ? 'day'
        : periodo.agrupado === 'semana'
          ? 'week'
          : 'month';
    try {
      const { rows } = await pool.query<{
        periodo: string;
        ingresos: string;
        pedidos: number;
        unidades: number;
      }>(
        `WITH ${LINEAS_VENDIDAS},
              por_pedido AS (
                SELECT date_trunc('${g}', ${diaDe('fecha_creacion')})::date AS periodo,
                       id_pedido, sum(importe) AS importe, sum(cantidad) AS unidades
                  FROM lineas GROUP BY 1, 2
              ),
              huecos AS (
                SELECT generate_series(date_trunc('${g}', $1::date), date_trunc('${g}', $2::date), interval '1 ${g}')::date AS periodo
              )
         SELECT to_char(h.periodo, 'YYYY-MM-DD') AS periodo,
                COALESCE(sum(pp.importe), 0)::numeric(14,2)::text AS ingresos,
                count(pp.id_pedido)::int AS pedidos,
                COALESCE(sum(pp.unidades), 0)::int AS unidades
           FROM huecos h
           LEFT JOIN por_pedido pp ON pp.periodo = h.periodo
          GROUP BY h.periodo
          ORDER BY h.periodo`,
        [periodo.desde, periodo.hasta],
      );
      return { periodo, serie: rows };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * De mirar a comprar: personas distintas que vieron un producto (sesiones,
   * ClickHouse), cuentas que agregaron algo al carrito (ClickHouse), cuentas
   * que compraron y pedidos cancelados (PostgreSQL). Sin ClickHouse salen las
   * dos de PostgreSQL y `sin_eventos`.
   */
  async embudo(desde?: string, hasta?: string): Promise<EmbudoDashboard> {
    const periodo = leerPeriodo(desde, hasta);
    let compras: { compraron: number; cancelaron: number };
    try {
      const { rows } = await pool.query<{
        compraron: number;
        cancelaron: number;
      }>(
        `WITH ${LINEAS_VENDIDAS}
         SELECT (SELECT count(DISTINCT id_usuario) FROM lineas)::int AS compraron,
                (SELECT count(*) FROM pedido p JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
                  WHERE ep.estado_pedido_nombre = 'cancelado' AND ${enPeriodo('p.fecha_creacion')})::int AS cancelaron`,
        [periodo.desde, periodo.hasta],
      );
      compras = rows[0];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    try {
      const resultado = await clickhouse.query({
        query: `SELECT
                  (SELECT uniqExact(sesion) FROM vista_producto
                    WHERE lote = 'real' AND toDate(fecha, '${ZONA_TIENDA}') BETWEEN {desde:Date} AND {hasta:Date}) AS vieron,
                  (SELECT uniqExact(id_usuario) FROM carrito_producto
                    WHERE lote = 'real' AND toDate(fecha, '${ZONA_TIENDA}') BETWEEN {desde:Date} AND {hasta:Date}) AS agregaron,
                  (SELECT if(count() = 0, '', toString(toDate(min(fecha), '${ZONA_TIENDA}'))) FROM vista_producto
                    WHERE lote = 'real') AS eventos_desde`,
        query_params: { desde: periodo.desde, hasta: periodo.hasta },
        format: 'JSONEachRow',
      });
      const [fila] = await resultado.json<{
        vieron: string;
        agregaron: string;
        eventos_desde: string;
      }>();
      return {
        periodo,
        vieron: Number(fila.vieron),
        agregaron: Number(fila.agregaron),
        ...compras,
        sin_eventos: false,
        eventos_desde: fila.eventos_desde || null,
      };
    } catch (error) {
      this.logger.warn(
        `Embudo sin ClickHouse: ${error instanceof Error ? error.message : String(error)}`,
      );
      return {
        periodo,
        vieron: null,
        agregaron: null,
        ...compras,
        sin_eventos: true,
        eventos_desde: null,
      };
    }
  }

  /** Lo vendido por categoria (la de primer nivel si tiene padre). */
  async categorias(desde?: string, hasta?: string): Promise<FilaCategoria[]> {
    const periodo = leerPeriodo(desde, hasta);
    return this.consulta<FilaCategoria>(
      `WITH ${LINEAS_VENDIDAS}
       SELECT COALESCE(padre.id_categoria, c.id_categoria)::int AS id_categoria,
              COALESCE(padre.nombre, c.nombre, 'Sin categoria') AS categoria,
              sum(l.importe)::numeric(14,2)::text AS ingresos,
              sum(l.cantidad)::int AS unidades,
              count(DISTINCT l.id_pedido)::int AS pedidos
         FROM lineas l
         LEFT JOIN producto_catalogo pc ON pc.id_producto_mongo = l.id_producto_mongo
         LEFT JOIN categorias c ON c.id_categoria = pc.id_categoria
         LEFT JOIN categorias padre ON padre.id_categoria = c.id_categoria_padre
        GROUP BY 1, 2
        ORDER BY sum(l.importe) DESC`,
      periodo,
    );
  }

  /** Lo cobrado por mes y por metodo de pago. */
  async pagos(desde?: string, hasta?: string): Promise<FilaPagoMensual[]> {
    const periodo = leerPeriodo(desde, hasta);
    return this.consulta<FilaPagoMensual>(
      `SELECT to_char(date_trunc('month', ${diaDe('p.fecha_creacion')}), 'YYYY-MM') AS mes,
              mp.metodo_nombre AS metodo,
              sum(pg.monto)::numeric(14,2)::text AS ingresos,
              count(DISTINCT p.id_pedido)::int AS pedidos
         FROM pago pg
         JOIN estado_pago epa ON epa.id_estado_pago = pg.id_estado_pago
         JOIN metodo_pago mp ON mp.id_metodo_pago = pg.id_metodo_pago
         JOIN pedido p ON p.id_pedido = pg.id_pedido
        WHERE epa.estado_pago_nombre = 'pagado'
          AND ${enPeriodo('p.fecha_creacion')}
        GROUP BY 1, 2
        ORDER BY 1, 2`,
      periodo,
    );
  }

  /** Cuando compra la gente: dia de la semana por hora, en hora de Guatemala. */
  async mapa(desde?: string, hasta?: string): Promise<CeldaMapaCalor[]> {
    const periodo = leerPeriodo(desde, hasta);
    return this.consulta<CeldaMapaCalor>(
      `WITH ${LINEAS_VENDIDAS}
       SELECT extract(isodow FROM fecha_creacion AT TIME ZONE '${ZONA_TIENDA}')::int AS dia_semana,
              extract(hour FROM fecha_creacion AT TIME ZONE '${ZONA_TIENDA}')::int AS hora,
              count(DISTINCT id_pedido)::int AS pedidos,
              sum(importe)::numeric(14,2)::text AS ingresos
         FROM lineas
        GROUP BY 1, 2
        ORDER BY 1, 2`,
      periodo,
    );
  }

  /** Los vendedores que mas vendieron, con la nota que les dan. */
  async vendedores(desde?: string, hasta?: string): Promise<FilaVendedor[]> {
    const periodo = leerPeriodo(desde, hasta);
    return this.consulta<FilaVendedor>(
      `WITH ${LINEAS_VENDIDAS}
       SELECT u.id_usuario::int AS id_usuario,
              COALESCE(NULLIF(trim(concat_ws(' ', u.nombre, u.apellido)), ''), u.usuario) AS vendedor,
              sum(l.importe)::numeric(14,2)::text AS ingresos,
              sum(l.cantidad)::int AS unidades,
              count(DISTINCT l.id_pedido)::int AS pedidos,
              (SELECT round(avg(r.calificacion), 2)::float FROM resena r WHERE r.id_usuario_vendedor = u.id_usuario AND r.id_estado_resena = 1) AS nota_promedio
         FROM lineas l
         JOIN oferta o ON o.id_oferta = l.id_oferta
         JOIN usuarios u ON u.id_usuario = o.id_usuario
        GROUP BY u.id_usuario
        ORDER BY sum(l.importe) DESC
        LIMIT ${LIMITE_RANKING}`,
      periodo,
    );
  }

  /** Los productos que mas dejaron. */
  async productos(desde?: string, hasta?: string): Promise<FilaProducto[]> {
    const periodo = leerPeriodo(desde, hasta);
    return this.consulta<FilaProducto>(
      `WITH ${LINEAS_VENDIDAS}
       SELECT l.id_producto_mongo::int AS id_producto,
              COALESCE(pc.nombre, min(l.nombre_producto)) AS nombre,
              sum(l.importe)::numeric(14,2)::text AS ingresos,
              sum(l.cantidad)::int AS unidades,
              count(DISTINCT l.id_pedido)::int AS pedidos
         FROM lineas l
         LEFT JOIN producto_catalogo pc ON pc.id_producto_mongo = l.id_producto_mongo
        GROUP BY l.id_producto_mongo, pc.nombre
        ORDER BY sum(l.importe) DESC
        LIMIT ${LIMITE_RANKING}`,
      periodo,
    );
  }

  /** A donde se manda: el departamento de la direccion del pedido. */
  async departamentos(
    desde?: string,
    hasta?: string,
  ): Promise<FilaDepartamento[]> {
    const periodo = leerPeriodo(desde, hasta);
    return this.consulta<FilaDepartamento>(
      `WITH ${LINEAS_VENDIDAS}
       SELECT COALESCE(NULLIF(trim(dh.departamento), ''), 'Sin direccion') AS departamento,
              count(DISTINCT l.id_pedido)::int AS pedidos,
              sum(l.importe)::numeric(14,2)::text AS ingresos
         FROM lineas l
         LEFT JOIN direccion_historial dh ON dh.id_direccion_historial = l.id_direccion_historial
        GROUP BY 1
        ORDER BY sum(l.importe) DESC`,
      periodo,
    );
  }

  /** Lo que se busca, por dia, y lo que se busca y no se encuentra (ClickHouse). */
  async busquedas(desde?: string, hasta?: string): Promise<BusquedasDashboard> {
    const periodo = leerPeriodo(desde, hasta);
    const g =
      periodo.agrupado === 'dia'
        ? 'toDate'
        : periodo.agrupado === 'semana'
          ? 'toMonday'
          : 'toStartOfMonth';
    const filtro = `lote = 'real' AND toDate(fecha, '${ZONA_TIENDA}') BETWEEN {desde:Date} AND {hasta:Date}`;
    const params = {
      desde: periodo.desde,
      hasta: periodo.hasta,
      limite: LIMITE_RANKING,
    };
    try {
      const [porDia, mas, sin] = await Promise.all([
        clickhouse.query({
          query: `SELECT toString(${g}(toDate(fecha, '${ZONA_TIENDA}'))) AS periodo,
                         uniqExact(sesion) AS busquedas,
                         uniqExactIf(sesion, resultados = 0) AS sin_resultados
                    FROM busqueda_realizada WHERE ${filtro}
                   GROUP BY periodo ORDER BY periodo`,
          query_params: params,
          format: 'JSONEachRow',
        }),
        clickhouse.query({
          query: `SELECT termino, uniqExact(sesion) AS personas FROM busqueda_realizada
                   WHERE ${filtro} GROUP BY termino ORDER BY personas DESC, termino LIMIT {limite:UInt32}`,
          query_params: params,
          format: 'JSONEachRow',
        }),
        clickhouse.query({
          query: `SELECT termino, uniqExact(sesion) AS personas FROM busqueda_realizada
                   WHERE ${filtro} AND resultados = 0 GROUP BY termino ORDER BY personas DESC, termino LIMIT {limite:UInt32}`,
          query_params: params,
          format: 'JSONEachRow',
        }),
      ]);
      const numeros = <T extends Record<string, unknown>>(
        filas: T[],
        campos: string[],
      ) =>
        filas.map((f) =>
          Object.fromEntries(
            Object.entries(f).map(([k, v]) => [
              k,
              campos.includes(k) ? Number(v) : v,
            ]),
          ),
        );
      return {
        periodo,
        por_dia: numeros(await porDia.json<Record<string, unknown>>(), [
          'busquedas',
          'sin_resultados',
        ]) as BusquedasDashboard['por_dia'],
        mas_buscadas: numeros(await mas.json<Record<string, unknown>>(), [
          'personas',
        ]) as BusquedasDashboard['mas_buscadas'],
        sin_resultado: numeros(await sin.json<Record<string, unknown>>(), [
          'personas',
        ]) as BusquedasDashboard['sin_resultado'],
      };
    } catch (error) {
      manejarErrorClickHouse(this.logger, error);
    }
  }

  /**
   * Los pedidos cancelados del periodo: cuanto paso entre comprar y cancelar
   * (la fecha de cancelacion del pago), de que categoria eran y con que se
   * habian pagado.
   */
  async cancelaciones(
    desde?: string,
    hasta?: string,
  ): Promise<CancelacionesDashboard> {
    const periodo = leerPeriodo(desde, hasta);
    const cancelados = `
      cancelados AS (
        SELECT p.id_pedido, p.fecha_creacion, pg.fecha_cancelacion, pg.monto, mp.metodo_nombre
          FROM pedido p
          JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
          LEFT JOIN pago pg ON pg.id_pedido = p.id_pedido
          LEFT JOIN metodo_pago mp ON mp.id_metodo_pago = pg.id_metodo_pago
         WHERE ep.estado_pedido_nombre = 'cancelado' AND ${enPeriodo('p.fecha_creacion')}
      )`;
    try {
      const [tiempo, categoria, metodo] = await Promise.all([
        pool.query<{ tramo: string; pedidos: number }>(
          `WITH ${cancelados},
                tramos(orden, tramo) AS (VALUES (1, 'En la primera hora'), (2, 'El mismo dia'), (3, 'En la semana'), (4, 'Despues de una semana'), (5, 'Sin fecha'))
           SELECT t.tramo, count(c.id_pedido)::int AS pedidos
             FROM tramos t
             LEFT JOIN cancelados c ON t.orden = CASE
                  WHEN c.fecha_cancelacion IS NULL THEN 5
                  WHEN c.fecha_cancelacion - c.fecha_creacion < interval '1 hour' THEN 1
                  WHEN c.fecha_cancelacion - c.fecha_creacion < interval '1 day' THEN 2
                  WHEN c.fecha_cancelacion - c.fecha_creacion < interval '7 days' THEN 3
                  ELSE 4 END
            GROUP BY t.orden, t.tramo
            ORDER BY t.orden`,
          [periodo.desde, periodo.hasta],
        ),
        pool.query<{ categoria: string; pedidos: number; unidades: number }>(
          `WITH ${cancelados}
           SELECT COALESCE(padre.nombre, c.nombre, 'Sin categoria') AS categoria,
                  count(DISTINCT x.id_pedido)::int AS pedidos,
                  sum(pp.cantidad)::int AS unidades
             FROM cancelados x
             JOIN pedido_producto pp ON pp.id_pedido = x.id_pedido
             LEFT JOIN producto_catalogo pc ON pc.id_producto_mongo = pp.id_producto_mongo
             LEFT JOIN categorias c ON c.id_categoria = pc.id_categoria
             LEFT JOIN categorias padre ON padre.id_categoria = c.id_categoria_padre
            GROUP BY 1
            ORDER BY 2 DESC`,
          [periodo.desde, periodo.hasta],
        ),
        pool.query<{ metodo: string; pedidos: number; monto: string }>(
          `WITH ${cancelados}
           SELECT COALESCE(metodo_nombre, 'Sin pago') AS metodo,
                  count(DISTINCT id_pedido)::int AS pedidos,
                  COALESCE(sum(monto), 0)::numeric(14,2)::text AS monto
             FROM cancelados
            GROUP BY 1
            ORDER BY 2 DESC`,
          [periodo.desde, periodo.hasta],
        ),
      ]);
      return {
        periodo,
        por_tiempo: tiempo.rows,
        por_categoria: categoria.rows,
        por_metodo: metodo.rows,
      };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * El registro de pedidos del periodo, el mas nuevo primero, con filtros por
   * estado, metodo de pago y texto (cliente, correo o numero de pedido). Los
   * carritos (`pendiente`) no salen.
   */
  async pedidos(opciones: {
    desde?: string;
    hasta?: string;
    estado?: string;
    metodo?: string;
    texto?: string;
    pagina?: string;
    limite?: string;
  }): Promise<PedidosDashboard> {
    const periodo = leerPeriodo(opciones.desde, opciones.hasta);
    const pagina = Math.max(
      1,
      Number.parseInt(opciones.pagina ?? '1', 10) || 1,
    );
    const limite = Math.min(
      5000,
      Math.max(1, Number.parseInt(opciones.limite ?? '25', 10) || 25),
    );
    const estado = opciones.estado?.trim() ?? '';
    if (
      estado !== '' &&
      !['comprado', 'enviado', 'entregado', 'cancelado'].includes(estado)
    ) {
      throw new ErrorValidacion(
        'estado tiene que ser comprado, enviado, entregado o cancelado',
      );
    }
    const metodo = opciones.metodo?.trim() ?? '';
    const texto = (opciones.texto ?? '').trim().slice(0, 100);
    try {
      const { rows } = await pool.query<
        FilaPedidoDashboard & { total_filas: number }
      >(
        `WITH base AS (
           SELECT p.id_pedido, p.fecha_creacion, ep.estado_pedido_nombre AS estado,
                  COALESCE(NULLIF(trim(concat_ws(' ', u.nombre, u.apellido)), ''), u.usuario) AS cliente,
                  u.correo_electronico AS correo, dh.departamento,
                  mp.metodo_nombre AS metodo, epa.estado_pago_nombre AS estado_pago,
                  ult.por_la_tienda, ult.motivo
             FROM pedido p
             JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
             JOIN usuarios u ON u.id_usuario = p.id_usuario
             LEFT JOIN direccion_historial dh ON dh.id_direccion_historial = p.id_direccion_historial
             LEFT JOIN pago pg ON pg.id_pedido = p.id_pedido
             LEFT JOIN metodo_pago mp ON mp.id_metodo_pago = pg.id_metodo_pago
             LEFT JOIN estado_pago epa ON epa.id_estado_pago = pg.id_estado_pago
             -- El ultimo cambio de estado (migracion 051): si lo cancelo o lo
             -- envio la tienda, y por que. NULL en los pedidos de antes.
             LEFT JOIN LATERAL (
                  SELECT pce.por_la_tienda, pce.motivo
                    FROM pedido_cambio_estado pce
                   WHERE pce.id_pedido = p.id_pedido
                   ORDER BY pce.fecha DESC, pce.id_pedido_cambio_estado DESC
                   LIMIT 1) ult ON true
            WHERE ep.estado_pedido_nombre <> 'pendiente'
              AND ${enPeriodo('p.fecha_creacion')}
              AND ($3 = '' OR ep.estado_pedido_nombre = $3)
              AND ($4 = '' OR mp.metodo_nombre = $4)
              AND ($5 = '' OR u.correo_electronico ILIKE '%' || $5 || '%'
                   OR concat_ws(' ', u.nombre, u.apellido, u.usuario) ILIKE '%' || $5 || '%'
                   OR p.id_pedido::text = $5)
         )
         SELECT b.id_pedido::int AS id_pedido,
                to_char(b.fecha_creacion AT TIME ZONE '${ZONA_TIENDA}', 'YYYY-MM-DD HH24:MI') AS fecha,
                b.cliente, b.correo, b.estado, b.metodo, b.estado_pago, b.departamento,
                b.por_la_tienda, b.motivo,
                COALESCE(sum(${expresionPrecioFinal('ph')} * pp.cantidad), 0)::numeric(14,2)::text AS total,
                COALESCE(sum(pp.cantidad), 0)::int AS unidades,
                count(*) OVER ()::int AS total_filas
           FROM base b
           LEFT JOIN pedido_producto pp ON pp.id_pedido = b.id_pedido
           LEFT JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
          GROUP BY b.id_pedido, b.fecha_creacion, b.cliente, b.correo, b.estado, b.metodo, b.estado_pago, b.departamento,
                   b.por_la_tienda, b.motivo
          ORDER BY b.fecha_creacion DESC, b.id_pedido DESC
          LIMIT $6 OFFSET $7`,
        [
          periodo.desde,
          periodo.hasta,
          estado,
          metodo,
          texto,
          limite,
          (pagina - 1) * limite,
        ],
      );
      const total = rows[0]?.total_filas ?? 0;
      return {
        pedidos: rows.map((fila) => {
          const sinTotal: Partial<typeof fila> = { ...fila };
          delete sinTotal.total_filas;
          return sinTotal as FilaPedidoDashboard;
        }),
        total,
        pagina,
        total_paginas: Math.ceil(total / limite),
      };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Todo junto, para exportar. Cada seccion se pide aparte y la que falla
   * queda en null (un ClickHouse caido no deja sin PDF al resto).
   */
  async completo(
    desde: string | undefined,
    hasta: string | undefined,
    secciones: SeccionDashboard[],
  ): Promise<DashboardCompleto> {
    const periodo = leerPeriodo(desde, hasta);
    const quiere = (s: SeccionDashboard) => secciones.includes(s);
    const seguro = async <T>(
      s: SeccionDashboard,
      fn: () => Promise<T>,
    ): Promise<T | null> => {
      if (!quiere(s)) return null;
      try {
        return await fn();
      } catch (error) {
        this.logger.warn(
          `Exportar sin ${s}: ${error instanceof Error ? error.message : String(error)}`,
        );
        return null;
      }
    };
    const d = periodo.desde;
    const h = periodo.hasta;
    const [
      resumen,
      ventas,
      embudo,
      categorias,
      pagos,
      mapa,
      vendedores,
      productos,
      departamentos,
      busquedas,
      cancelaciones,
      pedidos,
    ] = await Promise.all([
      seguro('resumen', () => this.resumen(d, h)),
      seguro('ventas', () => this.ventas(d, h)),
      seguro('embudo', () => this.embudo(d, h)),
      seguro('categorias', () => this.categorias(d, h)),
      seguro('pagos', () => this.pagos(d, h)),
      seguro('mapa', () => this.mapa(d, h)),
      seguro('vendedores', () => this.vendedores(d, h)),
      seguro('productos', () => this.productos(d, h)),
      seguro('departamentos', () => this.departamentos(d, h)),
      seguro('busquedas', () => this.busquedas(d, h)),
      seguro('cancelaciones', () => this.cancelaciones(d, h)),
      seguro(
        'pedidos',
        async () =>
          (await this.pedidos({ desde: d, hasta: h, limite: '5000' })).pedidos,
      ),
    ]);
    return {
      periodo,
      resumen,
      ventas,
      embudo,
      categorias,
      pagos,
      mapa,
      vendedores,
      productos,
      departamentos,
      busquedas,
      cancelaciones,
      pedidos,
    };
  }

  private async consulta<T>(
    sql: string,
    periodo: PeriodoDashboard,
  ): Promise<T[]> {
    try {
      const { rows } = await pool.query(sql, [periodo.desde, periodo.hasta]);
      return rows as T[];
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}
