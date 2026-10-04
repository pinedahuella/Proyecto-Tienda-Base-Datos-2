import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { registrarAnilloFraude } from '../../helpers/registrar-anillo-fraude';

/** Una resena cuyo autor cancelo (y se le reembolso) esa misma compra poco despues. */
interface FilaCancelada {
  id_resena: string;
  id_usuario: string;
  id_usuario_vendedor: string;
  id_producto_mongo: string;
  calificacion: number;
  id_pedido: string;
  /** Minutos entre la resena y la cancelacion. */
  minutos: number;
}

/** A que se le limita la consulta: un pedido (chequeo inmediato), un comprador o un vendedor. */
interface Filtro {
  idPedido?: number;
  idUsuario?: string;
  idVendedor?: string;
}

/**
 * Detecta el fraude de reseñar y cancelar la compra: el comprador paga, reseña
 * y cancela el pedido (se le reembolsa) antes de que salga. La compra que
 * justificaba la reseña ya no existe, y la reseña se queda. Dos variantes, dos
 * senales de la familia `patron_resenas`, fuente `postgres`:
 *
 * - `resena_positiva_cancelada` (4 o 5 estrellas): infla las reseñas de un
 *   vendedor sin comprar nada. Nadie cancela lo que acaba de elogiar, asi que
 *   **una sola vez ya es una senal fuerte** (`TIPOS_FUERTES`). Una senal por
 *   cuenta (`clave` = su id); entra a los casos de fraude (20 puntos).
 * - `resenas_negativas_canceladas_vendedor` (1 o 2 estrellas): perjudica a un
 *   vendedor. Una reseña negativa con cancelacion tambien la deja un comprador
 *   honesto y molesto, asi que una sola no prueba nada: la senal es del
 *   VENDEDOR y exige `MIN_NEGATIVAS` o mas. No se enfoca en una oferta ni en un
 *   producto, sino en la cuenta del vendedor. Solo alerta para el admin: no forma
 *   casos ni suma puntos (`TIPOS_SOLO_ALERTA`). El vendedor entra a la senal como
 *   `victima` y quienes reseñaron y cancelaron como `autor`.
 *
 * Las 3 estrellas no cuentan nunca. Tampoco una reseña cuyo autor tiene OTRA
 * compra vigente (pagada y sin cancelar) de ese producto a ese vendedor: esa
 * compra si la justifica.
 *
 * Todo sale de PostgreSQL, sin campos nuevos: una "devolucion" en este sistema
 * es `cancelar_pedido()` sobre un pedido `comprado`, que deja un
 * `stock_movimiento` de motivo `devolucion` (con su fecha) y reembolsa el pago.
 * Un pedido `enviado` o `entregado` ya no se puede cancelar. Se cruza ese
 * movimiento con la reseña del mismo comprador al mismo vendedor por el mismo
 * producto, y se exige que la cancelacion sea DESPUES de la reseña y dentro de
 * `HORAS_ENTRE_RESENA_Y_CANCELACION`.
 *
 * Dos disparadores:
 * - **Inmediato** (`detectarInmediato`): lo llama `PedidosService.cancelarPedido`
 *   justo despues de cancelar un pedido `comprado`. Es la cancelacion, y no
 *   escribir la reseña, lo que completa el patron: al escribirla todavia no
 *   ocurrio. Sin `await`, como el chequeo acotado de los anillos.
 * - **Periodico** (`detectar`): cada `INTERVALO_MS`, sobre toda la ventana. Es la
 *   red de seguridad y el que cuenta las negativas por vendedor desde cero.
 *
 * Mismo molde que los demas detectores: `@Interval`, bandera `procesando`, y un
 * error de conexion se loguea y no tumba el proceso.
 */
@Injectable()
export class ResenasCanceladasDetectorService {
  private readonly logger = new Logger(ResenasCanceladasDetectorService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** Solo cuentan las cancelaciones de los ultimos dias. */
  private static readonly VENTANA_DIAS = 60;

  /** Cuanto despues de reseñar se puede cancelar para que cuente. */
  private static readonly HORAS_ENTRE_RESENA_Y_CANCELACION = 72;

  /** Reseñas negativas con cancelacion que hacen falta para señalar a un vendedor. */
  private static readonly MIN_NEGATIVAS = 5;

  /** Tope de reseñas que se guardan como evidencia de una senal. */
  private static readonly MAX_EVIDENCIA = 100;

  private procesando = false;

  @Interval(
    'resenas-canceladas-detector',
    ResenasCanceladasDetectorService.INTERVALO_MS,
  )
  async detectar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      const filas = await this.consultar({});
      const positivas = await this.registrarPositivas(filas);
      const negativas = await this.registrarNegativas(filas);
      this.logger.log(
        `worker de reseñas canceladas: ${filas.length} reseña(s) con compra cancelada, ${positivas} positiva(s) y ${negativas} vendedor(es) señalados`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de reseñas canceladas interrumpido: ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /**
   * El chequeo de un pedido recien cancelado. Sin `await` en quien lo llama:
   * no debe retrasar la respuesta de la cancelacion, y un error aqui solo se
   * loguea. Vuelve a mirar al comprador (y al vendedor) completo, no solo este
   * pedido, para que la senal quede con todas sus reseñas y su conteo real.
   */
  async detectarInmediato(idPedido: number): Promise<void> {
    try {
      const deEstePedido = await this.consultar({ idPedido });
      if (deEstePedido.length === 0) {
        return;
      }

      const compradores = new Set(
        deEstePedido
          .filter((f) => f.calificacion >= 4)
          .map((f) => f.id_usuario),
      );
      for (const idUsuario of compradores) {
        await this.registrarPositivas(await this.consultar({ idUsuario }));
      }

      const vendedores = new Set(
        deEstePedido
          .filter((f) => f.calificacion <= 2)
          .map((f) => f.id_usuario_vendedor),
      );
      for (const idVendedor of vendedores) {
        await this.registrarNegativas(await this.consultar({ idVendedor }));
      }
    } catch (error) {
      this.logger.warn(
        `chequeo de reseñas canceladas interrumpido (pedido ${idPedido}): ${mensajeCorto(error)}`,
      );
    }
  }

  /**
   * Las reseñas cuya compra se cancelo despues de escribirlas. Una fila por
   * reseña (la cancelacion mas cercana si el pedido tiene varias lineas).
   */
  private async consultar(filtro: Filtro): Promise<FilaCancelada[]> {
    const { rows } = await pool.query<FilaCancelada>(
      `SELECT DISTINCT ON (r.id_resena)
              r.id_resena, r.id_usuario, r.id_usuario_vendedor,
              r.id_producto_mongo, r.calificacion, sm.id_pedido,
              round(extract(epoch FROM (sm.fecha_movimiento - c.fecha_publicacion)) / 60)::int AS minutos
         FROM stock_movimiento sm
         JOIN motivo_movimiento mm
           ON mm.id_motivo_movimiento = sm.id_motivo_movimiento
          AND mm.motivo_nombre = 'devolucion'
         JOIN pedido pe ON pe.id_pedido = sm.id_pedido
         JOIN oferta o ON o.id_oferta = sm.id_oferta
         JOIN precio_historial ph ON ph.id_oferta = sm.id_oferta
         JOIN pedido_producto pp
           ON pp.id_pedido = sm.id_pedido
          AND pp.id_precio_historial = ph.id_precio_historial
         JOIN resena r
           ON r.id_usuario = pe.id_usuario
          AND r.id_usuario_vendedor = o.id_usuario
          AND r.id_producto_mongo = pp.id_producto_mongo
         JOIN comentario c ON c.id_comentario = r.id_comentario
        WHERE sm.fecha_movimiento >= c.fecha_publicacion
          AND sm.fecha_movimiento <= c.fecha_publicacion + make_interval(hours => $1)
          AND sm.fecha_movimiento >= now() - make_interval(days => $2)
          AND ($3::bigint IS NULL OR sm.id_pedido = $3)
          AND ($4::bigint IS NULL OR r.id_usuario = $4)
          AND ($5::bigint IS NULL OR r.id_usuario_vendedor = $5)
          AND NOT EXISTS (
                SELECT 1
                  FROM pedido pe2
                  JOIN estado_pedido ep2
                    ON ep2.id_estado_pedido = pe2.id_estado_pedido
                   AND ep2.estado_pedido_nombre <> 'cancelado'
                  JOIN pago pg2 ON pg2.id_pedido = pe2.id_pedido
                  JOIN estado_pago eg2
                    ON eg2.id_estado_pago = pg2.id_estado_pago
                   AND eg2.estado_pago_nombre = 'pagado'
                  JOIN pedido_producto pp2 ON pp2.id_pedido = pe2.id_pedido
                   AND pp2.id_producto_mongo = r.id_producto_mongo
                  JOIN precio_historial ph2
                    ON ph2.id_precio_historial = pp2.id_precio_historial
                  JOIN oferta o2
                    ON o2.id_oferta = ph2.id_oferta
                   AND o2.id_usuario = r.id_usuario_vendedor
                 WHERE pe2.id_usuario = r.id_usuario
                   AND pe2.id_pedido <> sm.id_pedido)
        ORDER BY r.id_resena, sm.fecha_movimiento`,
      [
        ResenasCanceladasDetectorService.HORAS_ENTRE_RESENA_Y_CANCELACION,
        ResenasCanceladasDetectorService.VENTANA_DIAS,
        filtro.idPedido ?? null,
        filtro.idUsuario ?? null,
        filtro.idVendedor ?? null,
      ],
    );
    return rows;
  }

  /** Una senal por comprador con al menos una reseña de 4-5 estrellas cancelada. */
  private async registrarPositivas(filas: FilaCancelada[]): Promise<number> {
    const porComprador = new Map<string, FilaCancelada[]>();
    for (const fila of filas) {
      if (fila.calificacion < 4) {
        continue;
      }
      const lista = porComprador.get(fila.id_usuario) ?? [];
      lista.push(fila);
      porComprador.set(fila.id_usuario, lista);
    }

    let senales = 0;
    for (const [idUsuario, lista] of porComprador) {
      try {
        await registrarAnilloFraude({
          tipo: 'resena_positiva_cancelada',
          clave: idUsuario,
          resenas: this.idsDeResenas(lista),
          detalle: {
            resenas: lista.length,
            vendedores: new Set(lista.map((f) => f.id_usuario_vendedor)).size,
            minutos_minimo: Math.min(...lista.map((f) => f.minutos)),
            horas_maximas:
              ResenasCanceladasDetectorService.HORAS_ENTRE_RESENA_Y_CANCELACION,
            ventana_dias: ResenasCanceladasDetectorService.VENTANA_DIAS,
          },
        });
        senales++;
      } catch (error) {
        this.logger.warn(
          `no se pudo persistir resena_positiva_cancelada de la cuenta ${idUsuario}: ${mensajeCorto(error)}`,
        );
      }
    }
    return senales;
  }

  /** Una senal por vendedor con `MIN_NEGATIVAS` o mas reseñas de 1-2 estrellas canceladas. */
  private async registrarNegativas(filas: FilaCancelada[]): Promise<number> {
    const porVendedor = new Map<string, FilaCancelada[]>();
    for (const fila of filas) {
      if (fila.calificacion > 2) {
        continue;
      }
      const lista = porVendedor.get(fila.id_usuario_vendedor) ?? [];
      lista.push(fila);
      porVendedor.set(fila.id_usuario_vendedor, lista);
    }

    let senales = 0;
    for (const [idVendedor, lista] of porVendedor) {
      if (lista.length < ResenasCanceladasDetectorService.MIN_NEGATIVAS) {
        continue;
      }
      const compradores = [...new Set(lista.map((f) => f.id_usuario))];
      try {
        await registrarAnilloFraude({
          tipo: 'resenas_negativas_canceladas_vendedor',
          clave: idVendedor,
          resenas: this.idsDeResenas(lista),
          cuentas: [
            { idUsuario: Number(idVendedor), rol: 'victima' },
            ...compradores.map((id) => ({
              idUsuario: Number(id),
              rol: 'autor' as const,
            })),
          ],
          detalle: {
            resenas_negativas_canceladas: lista.length,
            compradores: compradores.length,
            productos: new Set(lista.map((f) => f.id_producto_mongo)).size,
            minutos_minimo: Math.min(...lista.map((f) => f.minutos)),
            min_negativas: ResenasCanceladasDetectorService.MIN_NEGATIVAS,
            horas_maximas:
              ResenasCanceladasDetectorService.HORAS_ENTRE_RESENA_Y_CANCELACION,
            ventana_dias: ResenasCanceladasDetectorService.VENTANA_DIAS,
          },
        });
        senales++;
      } catch (error) {
        this.logger.warn(
          `no se pudo persistir resenas_negativas_canceladas_vendedor del vendedor ${idVendedor}: ${mensajeCorto(error)}`,
        );
      }
    }
    return senales;
  }

  /** Las mas recientes primero hasta el tope, devueltas en orden numerico. */
  private idsDeResenas(filas: FilaCancelada[]): number[] {
    return filas
      .map((f) => Number(f.id_resena))
      .sort((a, b) => b - a)
      .slice(0, ResenasCanceladasDetectorService.MAX_EVIDENCIA)
      .sort((a, b) => a - b);
  }
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
