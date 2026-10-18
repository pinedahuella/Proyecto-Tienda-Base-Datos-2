import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { redis } from '../../database/redis';
import {
  CarritoPostgresService,
  VIDA_CARRITO_SEGUNDOS,
} from './carrito-postgres.service';

/**
 * Borra los carritos (pedidos `pendiente`) con mas de 24 h sin actividad que
 * nadie volvio a leer. El vencimiento normal es pasivo -- al leer un carrito
 * vencido se borra en el acto (`CarritoPostgresService.leer`) --, pero el
 * carrito de alguien que no vuelve nunca se quedaria para siempre en
 * PostgreSQL. Ver `plan pendiente/carrito-postgres-verdad.md`.
 *
 * Cada carrito se borra en su propia transaccion, con el pedido bloqueado
 * (`FOR UPDATE SKIP LOCKED`: si alguien lo esta usando justo ahora, se salta y
 * se mira en la proxima pasada) y volviendo a comprobar que sigue vencido. Su
 * clave de Redis se borra despues, si Redis esta.
 *
 * Mismo patron que los demas workers: `@Interval` con una bandera, un tope por
 * pasada, y nunca lanza.
 */
@Injectable()
export class CarritoBarridoService {
  private readonly logger = new Logger(CarritoBarridoService.name);

  private static readonly INTERVALO_MS = 10 * 60 * 1000;

  private static readonly MAX_POR_PASADA = 200;

  private procesando = false;

  constructor(private readonly carritoPostgres: CarritoPostgresService) {}

  @Interval('carrito-barrido', CarritoBarridoService.INTERVALO_MS)
  async barrer(): Promise<number> {
    if (this.procesando) {
      return 0;
    }
    this.procesando = true;
    let borrados = 0;
    try {
      const { rows } = await pool.query<{
        id_pedido: string;
        id_usuario: string;
      }>(
        `SELECT p.id_pedido, p.id_usuario
           FROM pedido p
           JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
          WHERE ep.estado_pedido_nombre = 'pendiente'
            AND p.fecha_ultima_actividad <= now() - make_interval(secs => $1)
          ORDER BY p.fecha_ultima_actividad
          LIMIT $2`,
        [VIDA_CARRITO_SEGUNDOS, CarritoBarridoService.MAX_POR_PASADA],
      );
      for (const fila of rows) {
        if (await this.borrarUno(fila.id_pedido)) {
          borrados++;
          await redis
            .del(`mesh:carrito:${fila.id_usuario}`)
            .catch(() => undefined);
        }
      }
      if (borrados > 0) {
        this.logger.log(
          `barrido de carritos: ${borrados} carrito(s) vencido(s) borrado(s)`,
        );
      }
    } catch (error) {
      this.logger.warn(
        `barrido de carritos interrumpido: ${error instanceof Error ? error.message : String(error)}`,
      );
    } finally {
      this.procesando = false;
    }
    return borrados;
  }

  private async borrarUno(idPedido: string): Promise<boolean> {
    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');
      const { rows } = await cliente.query(
        `SELECT 1 FROM pedido p
           JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
          WHERE p.id_pedido = $1
            AND ep.estado_pedido_nombre = 'pendiente'
            AND p.fecha_ultima_actividad <= now() - make_interval(secs => $2)
            FOR UPDATE OF p SKIP LOCKED`,
        [idPedido, VIDA_CARRITO_SEGUNDOS],
      );
      if (rows.length === 0) {
        await cliente.query('ROLLBACK');
        return false;
      }
      await this.carritoPostgres.vencer(cliente, idPedido);
      await cliente.query('COMMIT');
      return true;
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      this.logger.warn(
        `no se pudo borrar el carrito vencido ${idPedido}: ${error instanceof Error ? error.message : String(error)}`,
      );
      return false;
    } finally {
      cliente.release();
    }
  }
}
