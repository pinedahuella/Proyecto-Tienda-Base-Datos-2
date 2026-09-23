import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';
import {
  LineaPorEstadoPago,
  LineaPorEstadoPedido,
  LineaPorMetodoPago,
  Reservacion,
  ReporteReservaciones,
  ReporteVentas,
} from '../../models/reporte';

/**
 * Los dos reportes del panel de admin (Entrega 2). Solo lectura sobre
 * PostgreSQL: `pedido`, `pedido_producto`, `pago` y sus catalogos.
 *
 *   reservaciones()  los pedidos en estado `pendiente` (abiertos, sin pagar).
 *   ventas()         el resumen: pedidos por estado, pagos por estado y por
 *                    metodo, e ingresos / reembolsos / ticket promedio.
 *
 * El total de un pedido NO se guarda en ninguna tabla (`pedido` no lleva
 * total, a proposito): se suma del precio FINAL (con descuento aplicado si
 * lo tenia, ver `helpers/precio-descuento.ts`) de `precio_historial` de
 * cada linea -- el precio congelado de cada una, que es tambien el que se
 * cobra. `pago.monto` si es una columna, y NO siempre coincide con esa suma
 * (un reembolso deja la suma igual y el monto no), por eso los ingresos se
 * leen de `pago.monto` y no de las lineas -- ese monto ya sale correcto sin
 * tocar nada aqui, porque lo escribe `comprar_pedido()` aplicando la misma
 * formula.
 *
 * Todos los montos se devuelven como texto con dos decimales
 * (`::numeric(12,2)::text`): son `numeric` de Postgres y no deben pasar por
 * el float de JavaScript.
 */
@Injectable()
export class AdminReportesService {
  private readonly logger = new Logger(AdminReportesService.name);

  /**
   * Los pedidos en estado `pendiente`: se abrieron y no se pagaron. Un
   * pedido pendiente NO aparta stock (nunca descuenta ni reserva unidades),
   * pero el precio de cada linea ya quedo congelado al agregarla, asi que
   * `total` es firme.
   */
  async reservaciones(): Promise<ReporteReservaciones> {
    try {
      const resultado = await pool.query<FilaReservacion>(
        `SELECT p.id_pedido, p.fecha_creacion,
                u.id_usuario, u.usuario, u.correo_electronico,
                u.nombre || COALESCE(' ' || u.apellido, '') AS cliente_nombre,
                dh.ciudad, dh.departamento,
                COUNT(pp.id_pedido_producto)::int AS cantidad_lineas,
                COALESCE(SUM(pp.cantidad), 0)::int AS unidades,
                COALESCE(SUM(${expresionPrecioFinal('ph')} * pp.cantidad), 0)::numeric(12,2)::text AS total
           FROM pedido p
           JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
           JOIN usuarios u ON u.id_usuario = p.id_usuario
           JOIN direccion_historial dh
             ON dh.id_direccion_historial = p.id_direccion_historial
           LEFT JOIN pedido_producto pp ON pp.id_pedido = p.id_pedido
           LEFT JOIN precio_historial ph
             ON ph.id_precio_historial = pp.id_precio_historial
          WHERE ep.estado_pedido_nombre = 'pendiente'
          GROUP BY p.id_pedido, p.fecha_creacion, u.id_usuario, u.usuario,
                   u.correo_electronico, u.nombre, u.apellido,
                   dh.ciudad, dh.departamento
          ORDER BY p.fecha_creacion DESC`,
      );

      const reservaciones: Reservacion[] = resultado.rows.map((fila) => ({
        id_pedido: Number(fila.id_pedido),
        fecha_creacion: fila.fecha_creacion,
        cliente: {
          id_usuario: Number(fila.id_usuario),
          usuario: fila.usuario,
          correo_electronico: fila.correo_electronico,
          nombre: fila.cliente_nombre,
        },
        cantidad_lineas: fila.cantidad_lineas,
        unidades: fila.unidades,
        total: fila.total,
        ciudad: fila.ciudad,
        departamento: fila.departamento,
      }));

      return {
        generado: new Date().toISOString(),
        resumen: {
          cantidad: reservaciones.length,
          unidades: reservaciones.reduce((suma, r) => suma + r.unidades, 0),
          total: sumarMontos(reservaciones.map((r) => r.total)),
        },
        reservaciones,
      };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * El resumen de ventas. Cuatro consultas en paralelo:
   *   1. pedidos por estado (las 5 filas del catalogo, aunque valgan 0)
   *   2. pagos por estado (las 4 filas)
   *   3. pagos por metodo (las 3 filas)
   *   4. los totales (una fila con subconsultas escalares)
   */
  async ventas(): Promise<ReporteVentas> {
    try {
      const [pedidosPorEstado, pagosPorEstado, pagosPorMetodo, totales] =
        await Promise.all([
          pool.query<FilaEstadoPedido>(CONSULTA_PEDIDOS_POR_ESTADO),
          pool.query<FilaEstadoPago>(CONSULTA_PAGOS_POR_ESTADO),
          pool.query<FilaMetodoPago>(CONSULTA_PAGOS_POR_METODO),
          pool.query<FilaTotales>(CONSULTA_TOTALES),
        ]);

      const fila = totales.rows[0];

      return {
        generado: new Date().toISOString(),
        pedidos_por_estado: pedidosPorEstado.rows.map(
          (f): LineaPorEstadoPedido => ({
            estado: f.estado,
            cantidad: f.cantidad,
            monto: f.monto,
          }),
        ),
        pagos_por_estado: pagosPorEstado.rows.map((f): LineaPorEstadoPago => ({
          estado: f.estado,
          cantidad: f.cantidad,
          monto: f.monto,
        })),
        pagos_por_metodo: pagosPorMetodo.rows.map((f): LineaPorMetodoPago => ({
          metodo: f.metodo,
          cantidad: f.cantidad,
          monto: f.monto,
        })),
        totales: {
          pedidos: fila.pedidos,
          unidades_vendidas: fila.unidades_vendidas,
          ingresos: fila.ingresos,
          reembolsado: fila.reembolsado,
          ticket_promedio: fila.ticket_promedio,
        },
      };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}

// =====================================================================
// Filas crudas
// =====================================================================

interface FilaReservacion {
  id_pedido: string;
  fecha_creacion: Date;
  id_usuario: string;
  usuario: string;
  correo_electronico: string;
  cliente_nombre: string;
  ciudad: string;
  departamento: string;
  cantidad_lineas: number;
  unidades: number;
  total: string;
}

interface FilaEstadoPedido {
  estado: string;
  cantidad: number;
  monto: string;
}

interface FilaEstadoPago {
  estado: string;
  cantidad: number;
  monto: string;
}

interface FilaMetodoPago {
  metodo: string;
  cantidad: number;
  monto: string;
}

interface FilaTotales {
  pedidos: number;
  unidades_vendidas: number;
  ingresos: string;
  reembolsado: string;
  ticket_promedio: string;
}

// =====================================================================
// Utilidades
// =====================================================================

/**
 * Suma una lista de montos en texto sin pasar por el float de JavaScript:
 * trabaja en centavos (enteros) y vuelve a texto con dos decimales.
 */
function sumarMontos(montos: string[]): string {
  const centavos = montos.reduce((suma, monto) => {
    const limpio = monto.replace(/[^0-9.-]/g, '');
    return suma + Math.round(Number(limpio) * 100);
  }, 0);
  const signo = centavos < 0 ? '-' : '';
  const abs = Math.abs(centavos);
  return `${signo}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}

// =====================================================================
// Las consultas del reporte de ventas
// =====================================================================

/**
 * Pedidos por estado. `FROM estado_pedido LEFT JOIN` para que salgan los
 * cinco estados aunque alguno no tenga ni un pedido. `monto` es la suma de
 * las lineas de esos pedidos (el total no vive en `pedido`).
 */
const CONSULTA_PEDIDOS_POR_ESTADO = `
SELECT ep.estado_pedido_nombre AS estado,
       COUNT(DISTINCT p.id_pedido)::int AS cantidad,
       COALESCE(SUM(${expresionPrecioFinal('ph')} * pp.cantidad), 0)::numeric(12,2)::text AS monto
  FROM estado_pedido ep
  LEFT JOIN pedido p ON p.id_estado_pedido = ep.id_estado_pedido
  LEFT JOIN pedido_producto pp ON pp.id_pedido = p.id_pedido
  LEFT JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
 GROUP BY ep.id_estado_pedido, ep.estado_pedido_nombre
 ORDER BY ep.id_estado_pedido
`;

/** Pagos por estado. Los cuatro estados del catalogo, aunque valgan 0. */
const CONSULTA_PAGOS_POR_ESTADO = `
SELECT epa.estado_pago_nombre AS estado,
       COUNT(pg.id_pago)::int AS cantidad,
       COALESCE(SUM(pg.monto), 0)::numeric(12,2)::text AS monto
  FROM estado_pago epa
  LEFT JOIN pago pg ON pg.id_estado_pago = epa.id_estado_pago
 GROUP BY epa.id_estado_pago, epa.estado_pago_nombre
 ORDER BY epa.id_estado_pago
`;

/** Pagos por metodo. Los tres metodos del catalogo. */
const CONSULTA_PAGOS_POR_METODO = `
SELECT mp.metodo_nombre AS metodo,
       COUNT(pg.id_pago)::int AS cantidad,
       COALESCE(SUM(pg.monto), 0)::numeric(12,2)::text AS monto
  FROM metodo_pago mp
  LEFT JOIN pago pg ON pg.id_metodo_pago = mp.id_metodo_pago
 GROUP BY mp.id_metodo_pago, mp.metodo_nombre
 ORDER BY mp.id_metodo_pago
`;

/**
 * Los totales, en una fila. Subconsultas escalares en vez de un JOIN para
 * que cada numero se lea solo y no dependa del grano de los demas.
 */
const CONSULTA_TOTALES = `
SELECT
  (SELECT COUNT(*) FROM pedido)::int AS pedidos,
  COALESCE((
    SELECT SUM(pp.cantidad)
      FROM pedido p
      JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
      JOIN pedido_producto pp ON pp.id_pedido = p.id_pedido
     WHERE ep.estado_pedido_nombre IN ('comprado', 'enviado', 'entregado')
  ), 0)::int AS unidades_vendidas,
  COALESCE((
    SELECT SUM(pg.monto)
      FROM pago pg
      JOIN estado_pago epa ON epa.id_estado_pago = pg.id_estado_pago
     WHERE epa.estado_pago_nombre = 'pagado'
  ), 0)::numeric(12,2)::text AS ingresos,
  COALESCE((
    SELECT SUM(pg.monto)
      FROM pago pg
      JOIN estado_pago epa ON epa.id_estado_pago = pg.id_estado_pago
     WHERE epa.estado_pago_nombre = 'reembolsado'
  ), 0)::numeric(12,2)::text AS reembolsado,
  (
    SELECT CASE WHEN COUNT(*) > 0
                THEN (SUM(pg.monto) / COUNT(*))::numeric(12,2)::text
                ELSE '0.00' END
      FROM pago pg
      JOIN estado_pago epa ON epa.id_estado_pago = pg.id_estado_pago
     WHERE epa.estado_pago_nombre = 'pagado'
  ) AS ticket_promedio
`;
