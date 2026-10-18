import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { redis } from '../../database/redis';
import { InventarioLimitadoService } from './inventario-limitado.service';

/**
 * Mantiene a Redis cuadrado con PostgreSQL para las ventas relampago. Redis es
 * la puerta rapida (su script atomico decide primero), pero la verdad de las
 * reservas esta en `reserva_venta_relampago`. Ver
 * `elementos Generales/plan pendiente/carrito-postgres-verdad.md`.
 *
 * Cada pasada:
 *
 *   1. Las reservas activas que ya vencieron pasan a `vencida` (es historial:
 *      las consultas ya no las cuentan desde que pasa `fecha_vence`).
 *   2. Reconstruye Redis (`InventarioLimitadoService.restaurar`) para las
 *      ventas vigentes que lo necesitan:
 *        - todas, la primera vez y cada vez que Redis vuelve despues de caerse
 *          (pudo perder la venta, o hubo reservas que no vio);
 *        - las que Redis no tiene (se reinicio, un FLUSHALL);
 *        - las que tienen reservas hechas solo en PostgreSQL (`ticket` NULL);
 *        - las que otro servicio marco (una reserva que PostgreSQL rechazo,
 *          una compra con Redis caido, un cierre que no borro sus claves).
 *
 * Mismo patron que los demas workers: `@Interval` con una bandera para que una
 * pasada lenta no se pise con la siguiente. No lanza: es mantenimiento.
 */
@Injectable()
export class ReservasVentaRelampagoSyncService {
  private readonly logger = new Logger(ReservasVentaRelampagoSyncService.name);

  private static readonly INTERVALO_MS = 10000;

  private procesando = false;

  /** Al arrancar no se sabe que tiene Redis: se reconstruye todo una vez. */
  private restaurarTodas = true;

  /** `true` desde que Redis se cae hasta que vuelve. */
  private redisCaido = false;

  constructor(private readonly inventarioLimitado: InventarioLimitadoService) {
    redis.on('close', () => {
      this.redisCaido = true;
    });
    redis.on('ready', () => {
      if (this.redisCaido) {
        this.redisCaido = false;
        this.restaurarTodas = true;
        this.logger.log(
          'Redis volvio: las ventas relampago se reconstruyen desde PostgreSQL',
        );
      }
    });
  }

  @Interval(
    'reservas-venta-relampago',
    ReservasVentaRelampagoSyncService.INTERVALO_MS,
  )
  async sincronizar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      await this.vencerReservas();
      if (redis.status === 'ready') {
        await this.reconciliar();
      }
    } catch (error) {
      this.logger.warn(
        `reconciliacion de ventas relampago interrumpida: ${error instanceof Error ? error.message : String(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  private async vencerReservas(): Promise<void> {
    const { rowCount } = await pool.query(
      `UPDATE reserva_venta_relampago
          SET id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                    WHERE estado_reserva_nombre = 'vencida'),
              fecha_cierre = fecha_vence
        WHERE id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                    WHERE estado_reserva_nombre = 'activa')
          AND fecha_vence <= now()`,
    );
    if ((rowCount ?? 0) > 0) {
      this.logger.log(`${rowCount} reserva(s) de venta relampago vencida(s)`);
    }
  }

  private async reconciliar(): Promise<void> {
    const todas = this.restaurarTodas;
    this.restaurarTodas = false;

    const { rows } = await pool.query<{
      id_oferta: string;
      sin_ticket: boolean;
    }>(
      `SELECT o.id_oferta,
              EXISTS (SELECT 1 FROM reserva_venta_relampago r
                       WHERE r.id_oferta = o.id_oferta
                         AND r.ticket IS NULL
                         AND r.fecha_vence > now()
                         AND r.id_estado_reserva = (SELECT id_estado_reserva
                                                      FROM estado_reserva_venta_relampago
                                                     WHERE estado_reserva_nombre = 'activa')
                     ) AS sin_ticket
         FROM oferta o
        WHERE o.es_inventario_limitado
          AND (o.fecha_vencimiento_venta_limitada IS NULL
               OR o.fecha_vencimiento_venta_limitada > now())`,
    );

    const porRestaurar = new Set<number>(
      this.inventarioLimitado.tomarPorRestaurar(),
    );
    for (const fila of rows) {
      const idOferta = Number(fila.id_oferta);
      if (todas || fila.sin_ticket) {
        porRestaurar.add(idOferta);
      } else if (
        (await redis
          .hexists(`mesh:oferta:${idOferta}`, 'stock')
          .catch(() => 1)) === 0
      ) {
        // Redis perdio la venta (o quedo un hash sin `stock`) y PostgreSQL
        // dice que sigue abierta.
        porRestaurar.add(idOferta);
      }
    }

    for (const idOferta of porRestaurar) {
      // Una marcada sin venta vigente tambien se pasa: restaurar le borra las
      // claves que hubieran quedado en Redis.
      await this.inventarioLimitado.restaurar(idOferta);
    }
  }
}
