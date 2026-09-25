import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { clickhouse } from '../../database/clickhouse';
import { ID_ROL_VENDEDOR } from '../../models/rol-usuario';
import { OfertasVendedorService } from '../vendedores/ofertas.service';
import { VentasLimitadasService } from '../vendedores/ventas-limitadas.service';

interface ReglaActivaSinDisparar {
  id_oferta: string;
  id_usuario: string;
  id_regla_descuento_automatico: string;
  umbral_unidades: number;
  ventana_minutos: number;
  es_venta_relampago: boolean;
  duracion_segundos: number;
  /** numeric(5,2) de Postgres: string, igual que en el resto del proyecto. */
  porcentaje_descuento: string;
}

interface FilaVentasClickHouse {
  total: string;
}

/**
 * El disparador de `regla_descuento_automatico`: revisa cada regla activa
 * cuya oferta todavia NO tiene un descuento puesto, consulta ClickHouse
 * (`compra_producto`) por las unidades vendidas de esa oferta en los
 * ultimos `ventana_minutos`, y si llegan a `umbral_unidades` activa el
 * descuento (y la venta relampago, si `es_venta_relampago`) con
 * `duracion_segundos` como TTL.
 *
 * **Por que ya se puede construir (el bloqueo de "cuando se activo" ya no
 * aplica):** el problema original era que este disparo es de una sola vez
 * con duracion fija, a diferencia de `regla_descuento_periodo` (una
 * condicion de estado reevaluable sola). Pero `duracion_segundos` en
 * `regla_descuento_automatico` nunca puede ser 0 (ver
 * `validarDuracionSegundos` en `helpers/validaciones-regla-descuento.ts`,
 * "aca la regla siempre tiene que vencer sola") -- asi que toda activacion
 * de este worker usa EXACTAMENTE el mismo mecanismo de TTL de Redis que ya
 * usan `POST .../descuento` y `POST .../venta-limitada` con
 * `duracion_segundos`, y `VentasLimitadasService.revisarVencidas()` (el
 * worker que ya existe, sin cambios) es quien la apaga sola cuando vence.
 * No hace falta guardar en Postgres "cuando se activo": la cuenta regresiva
 * vive en Redis, no aca.
 *
 * Por el mismo motivo, este disparador **nunca desactiva nada** -- a
 * diferencia de `DisparadorReglasPeriodoService`, que si tiene un
 * `quitarEfecto()` porque su condicion (la fecha de hoy) puede dejar de
 * cumplirse sin que nada la fuerce a apagarse sola.
 *
 * Solo trae reglas activas cuya oferta tiene `porcentaje_descuento IS NULL`:
 * mientras esa columna este llena, la exclusion mutua
 * (`exigirSinOtroMecanismoActivo()`) garantiza que esta MISMA regla es su
 * unica duena (una oferta no puede tener dos mecanismos a la vez, y
 * `regla_descuento_automatico` tiene `UNIQUE(id_oferta)`), asi que no hace
 * falta gastar una consulta a ClickHouse por ella en cada corrida: ya esta
 * activa, esperando a que su propio TTL venza.
 *
 * Reusa las rutas existentes (`OfertasVendedorService.aplicarDescuento()`/
 * `VentasLimitadasService.abrir()`) en vez de escribir SQL propio -- de
 * gratis vienen la validacion, el recalculo de Mongo, la sincronizacion de
 * Redis y el trigger de `precio_historial`, mismo motivo que
 * `DisparadorReglasPeriodoService`. Como esas rutas piden un actor humano,
 * el disparador pasa el `id_usuario` DUENO de la oferta con rol vendedor --
 * nunca admin -- para operar como si el vendedor lo hubiera hecho el mismo,
 * identificandose con `mecanismo: 'regla_automatica'` para que la exclusion
 * mutua no se rechace a si misma.
 */
@Injectable()
export class DisparadorReglasAutomaticoService {
  private readonly logger = new Logger(DisparadorReglasAutomaticoService.name);

  /** Cada cuanto se revisan las reglas automaticas activas. */
  private static readonly INTERVALO_MS = 60 * 1000;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private revisando = false;

  constructor(
    private readonly ofertasVendedorService: OfertasVendedorService,
    private readonly ventasLimitadasService: VentasLimitadasService,
  ) {}

  @Interval(
    'disparador-reglas-automatico',
    DisparadorReglasAutomaticoService.INTERVALO_MS,
  )
  async revisar(): Promise<void> {
    if (this.revisando) {
      return;
    }
    this.revisando = true;
    try {
      await this.revisarReglasSinDisparar();
    } finally {
      this.revisando = false;
    }
  }

  private async revisarReglasSinDisparar(): Promise<void> {
    let filas: ReglaActivaSinDisparar[];
    try {
      const resultado = await pool.query<ReglaActivaSinDisparar>(
        `SELECT o.id_oferta, o.id_usuario,
                r.id_regla_descuento_automatico, r.umbral_unidades, r.ventana_minutos,
                r.es_venta_relampago, r.duracion_segundos, r.porcentaje_descuento
           FROM regla_descuento_automatico r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE r.activa = true AND o.porcentaje_descuento IS NULL`,
      );
      filas = resultado.rows;
    } catch (error) {
      this.logger.warn(
        `disparador de reglas automaticas: no se pudo leer Postgres (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    let activadas = 0;
    for (const regla of filas) {
      let ventas: number;
      try {
        ventas = await this.unidadesVendidas(
          Number(regla.id_oferta),
          regla.ventana_minutos,
        );
      } catch (error) {
        this.logger.warn(
          `disparador de reglas automaticas: no se pudo consultar ClickHouse para la oferta ${regla.id_oferta} (${(error as Error)?.message ?? error})`,
        );
        continue;
      }

      if (ventas < regla.umbral_unidades) {
        continue;
      }

      const seActivo = await this.activar(regla);
      if (seActivo) {
        activadas++;
      }
    }

    if (activadas > 0) {
      this.logger.log(
        `disparador de reglas automaticas: ${activadas} oferta(s) activada(s) por umbral de ventas`,
      );
    }
  }

  /**
   * Unidades vendidas (`compra_producto`, `lote = 'real'`) de una oferta en
   * los ultimos `ventanaMinutos`. Mismo patron de consulta que
   * `MasVendidosSyncService.consultarVentana()`: parametros con nombre, sin
   * interpolar nada del cliente en el texto del query.
   *
   * `sum()` sin `GROUP BY` sobre cero filas devuelve `0` en ClickHouse (no
   * `NULL` ni un resultado vacio), confirmado en vivo contra el servidor
   * real -- pero igual se protege con `?? 0` por si el resultado llegara
   * vacio por otro motivo (un timeout parcial, por ejemplo).
   */
  private async unidadesVendidas(
    idOferta: number,
    ventanaMinutos: number,
  ): Promise<number> {
    const resultado = await clickhouse.query({
      query: `SELECT sum(cantidad) AS total
                FROM compra_producto
               WHERE id_oferta = {idOferta:UInt64}
                 AND fecha >= now() - INTERVAL {ventana:UInt32} MINUTE
                 AND lote = 'real'`,
      query_params: { idOferta, ventana: ventanaMinutos },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<FilaVentasClickHouse>();
    return Number(filas[0]?.total ?? 0);
  }

  private async activar(regla: ReglaActivaSinDisparar): Promise<boolean> {
    const idOfertaTexto = regla.id_oferta;
    try {
      await this.ofertasVendedorService.aplicarDescuento(
        regla.id_usuario,
        ID_ROL_VENDEDOR,
        idOfertaTexto,
        {
          porcentaje_descuento: Number(regla.porcentaje_descuento),
          duracion_segundos: regla.duracion_segundos,
        },
        'regla_automatica',
      );
      if (regla.es_venta_relampago) {
        await this.ventasLimitadasService.abrir(
          idOfertaTexto,
          regla.id_usuario,
          ID_ROL_VENDEDOR,
          { duracion_segundos: regla.duracion_segundos },
          'regla_automatica',
        );
      }
      return true;
    } catch (error) {
      this.logger.warn(
        `disparador de reglas automaticas: no se pudo activar la regla ${regla.id_regla_descuento_automatico} sobre la oferta ${idOfertaTexto} (${(error as Error)?.message ?? error})`,
      );
      return false;
    }
  }
}
