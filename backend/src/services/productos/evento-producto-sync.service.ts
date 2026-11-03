import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { mongoClient } from '../../database/mongo';
import { pool } from '../../database/postgres';
import { esCaidaDeMongo } from '../../helpers/manejar-error-mongo';
import { ProductosService } from './productos.service';

/** Una fila pendiente de `evento_producto`. `fecha` va como texto para no perder microsegundos. */
interface EventoPendiente {
  id_evento: string;
  id_producto_mongo: string;
  fecha: string;
}

/**
 * El worker que recalcula en Mongo los campos calculados de un producto
 * (precio, stock, ofertas, descuento, nota de resenas) cuando algo cambio:
 * vacia la cola `evento_producto`, que llenan los triggers de `oferta` y
 * `resena` en la misma transaccion del cambio. Ver
 * `elementos Generales/plan pendiente/evento-producto.md`.
 *
 * Por eso el checkout ya no le habla a Mongo despues de cobrar. A cambio, la
 * tarjeta del catalogo tarda hasta INTERVALO_MS en ponerse al dia; la ficha y
 * el cobro siguen en vivo contra PostgreSQL.
 *
 * Mismo patron que `BuscadorSyncService`: `@Interval` con una bandera para
 * que una corrida lenta no se pise con la siguiente.
 */
@Injectable()
export class EventoProductoSyncService {
  private readonly logger = new Logger(EventoProductoSyncService.name);

  private static readonly INTERVALO_MS = 5000;

  /** Tope por corrida: si hay mas pendientes, siguen en la proxima. */
  private static readonly MAX_POR_CORRIDA = 200;

  /**
   * Fallos (que no sean de conexion) tras los cuales un producto se aparta:
   * deja de reintentarse hasta que un cambio nuevo lo reactive (el trigger
   * pone `intentos` en 0), para que no frene a los demas.
   */
  private static readonly MAX_INTENTOS = 5;

  private procesando = false;

  /**
   * La corrida anterior se corto porque Mongo no respondia. Si el driver dejo
   * el cliente cerrado ("Topology is closed"), ninguna consulta vuelve a
   * funcionar hasta que alguien llame a `connect()`, y este worker no puede
   * esperar a que lo haga el respaldo del catalogo.
   */
  private mongoCaido = false;

  constructor(private readonly productosService: ProductosService) {}

  @Interval('evento-producto', EventoProductoSyncService.INTERVALO_MS)
  async sincronizar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      const { rows } = await pool.query<EventoPendiente>(
        `SELECT id_evento, id_producto_mongo, fecha::text AS fecha
           FROM evento_producto
          WHERE procesado_en IS NULL AND intentos < $1
          ORDER BY id_evento
          LIMIT $2`,
        [
          EventoProductoSyncService.MAX_INTENTOS,
          EventoProductoSyncService.MAX_POR_CORRIDA,
        ],
      );

      if (rows.length === 0) {
        return;
      }
      if (this.mongoCaido) {
        try {
          await mongoClient.connect();
        } catch (error) {
          if (esCaidaDeMongo(error)) {
            return;
          }
          throw error;
        }
        this.mongoCaido = false;
        this.logger.log('worker de productos: Mongo volvio');
      }

      let recalculados = 0;
      for (const evento of rows) {
        try {
          await this.productosService.recalcularProductoEstricto(
            Number(evento.id_producto_mongo),
          );
          // Solo se marca si `fecha` sigue siendo la que se leyo: si el
          // producto cambio mientras se recalculaba, la fila queda pendiente
          // y se vuelve a hacer en la proxima corrida.
          await pool.query(
            `UPDATE evento_producto SET procesado_en = now()
              WHERE id_evento = $1 AND fecha = $2::timestamptz
                AND procesado_en IS NULL`,
            [evento.id_evento, evento.fecha],
          );
          recalculados++;
        } catch (error) {
          if (esCaidaDeMongo(error)) {
            // Con Mongo caido todos los demas fallarian igual (3 s cada uno):
            // se corta la corrida y no se cuenta como intento fallido. Antes
            // este worker tenia su propia lista de errores, sin los dos de un
            // cliente cerrado, y con Mongo apagado apartaba productos con el
            // stock viejo como si fueran fallos de verdad.
            this.mongoCaido = true;
            this.logger.warn(
              'worker de productos: Mongo no responde, se reintenta en la proxima corrida',
            );
            break;
          }
          await pool.query(
            `UPDATE evento_producto
                SET intentos = intentos + 1, ultimo_error = $2
              WHERE id_evento = $1`,
            [evento.id_evento, mensajeCorto(error)],
          );
          this.logger.warn(
            `worker de productos: fallo el producto ${evento.id_producto_mongo}: ${mensajeCorto(error)}`,
          );
        }
      }

      if (recalculados > 0) {
        this.logger.log(
          `worker de productos: ${recalculados} producto(s) recalculados`,
        );
      }
    } catch (error) {
      this.logger.warn(
        `worker de productos: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
