import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { ID_ROL_VENDEDOR } from '../../models/rol-usuario';
import {
  RangoPeriodo,
  reglasDePeriodoSeSolapan,
} from '../../helpers/solape-regla-descuento-periodo';
import { OfertasVendedorService } from '../vendedores/ofertas.service';
import { VentasLimitadasService } from '../vendedores/ventas-limitadas.service';

interface ReglaOferta extends RangoPeriodo {
  id_regla_descuento_periodo: string;
  activa: boolean;
  porcentaje_descuento: string;
  es_venta_relampago: boolean;
}

interface EstadoOferta {
  id_usuario: string;
  porcentaje_descuento: string | null;
  es_inventario_limitado: boolean;
  reglas: ReglaOferta[];
}

/**
 * El disparador de `regla_descuento_periodo`: revisa la fecha de hoy
 * contra las reglas activas y prende/apaga el descuento (y la venta
 * relampago, si corresponde) de la oferta asociada. A diferencia de
 * `regla_descuento_automatico` (un disparo de una sola vez que dura
 * `duracion_segundos` fijos, todavia sin construir por el pendiente de
 * "cuando se activo"), esta es una condicion de estado -- "¿hoy cae en el
 * rango?" -- que se puede reevaluar sola en cada corrida sin necesitar
 * memoria de nada.
 *
 * Puede construirse ya porque las dos piezas de diseno que le faltaban
 * quedaron resueltas antes: la exclusion mutua entre los cuatro mecanismos
 * (`exigirSinOtroMecanismoActivo()`) garantiza que, mientras una regla de
 * periodo este activa, sea la UNICA duena del `porcentaje_descuento`/
 * `es_inventario_limitado` de esa oferta; y el solape entre reglas de
 * periodo de la misma oferta (`exigirSinSolapeConOtrasActivas()`) garantiza
 * que a lo sumo UNA regla activa de una oferta puede aplicar en un dia
 * dado -- nunca hay que decidir entre dos que compitan.
 *
 * Reusa las rutas ya existentes (`OfertasVendedorService.aplicarDescuento()`/
 * `quitarDescuento()`, `VentasLimitadasService.abrir()`/`cerrar()`) en vez
 * de escribir SQL propio -- de gratis vienen la validacion, el recalculo de
 * Mongo, la sincronizacion de Redis y el trigger de `precio_historial`.
 * Como estas rutas piden un actor humano, el disparador pasa el
 * `id_usuario` DUENO de la oferta con rol vendedor -- nunca admin -- asi
 * que opera exactamente como si el vendedor lo hubiera hecho el mismo.
 * `duracion_segundos: 0` en las dos siempre: el disparador mismo decide
 * cuando apagar, por calendario, no por un TTL de Redis.
 */
@Injectable()
export class DisparadorReglasPeriodoService {
  private readonly logger = new Logger(DisparadorReglasPeriodoService.name);

  /** Cada cuanto se revisan las reglas de periodo activas. */
  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private revisando = false;

  constructor(
    private readonly ofertasVendedorService: OfertasVendedorService,
    private readonly ventasLimitadasService: VentasLimitadasService,
  ) {}

  @Interval(
    'disparador-reglas-periodo',
    DisparadorReglasPeriodoService.INTERVALO_MS,
  )
  async revisar(): Promise<void> {
    if (this.revisando) {
      return;
    }
    this.revisando = true;
    try {
      await this.revisarReglasActivas();
    } finally {
      this.revisando = false;
    }
  }

  /**
   * Trae toda oferta que tenga AL MENOS UNA regla de periodo (activa o no)
   * y que ademas cumpla `r.activa = true` (para saber que aplicar) O
   * `o.porcentaje_descuento IS NOT NULL` (para poder reconciliar un
   * descuento que quedo pegado porque su regla se pauso -- `editar()` de
   * `ReglasDescuentoPeriodoService` solo apaga `activa`, nunca toca la
   * oferta). No filtrar por `r.activa = true` a secas dejaria invisible
   * ese caso: la unica fila que explicaria el descuento activo de la
   * oferta jamas apareceria en el resultado.
   */
  private async revisarReglasActivas(): Promise<void> {
    let filas: {
      id_oferta: string;
      id_usuario: string;
      porcentaje_descuento: string | null;
      es_inventario_limitado: boolean;
      id_regla_descuento_periodo: string;
      activa: boolean;
      dia_inicio: number;
      dia_fin: number;
      mes_inicio: number | null;
      mes_fin: number | null;
      anio: number | null;
      regla_porcentaje_descuento: string;
      es_venta_relampago: boolean;
    }[];
    try {
      const resultado = await pool.query<(typeof filas)[number]>(
        `SELECT o.id_oferta, o.id_usuario, o.porcentaje_descuento, o.es_inventario_limitado,
                r.id_regla_descuento_periodo, r.activa, r.dia_inicio, r.dia_fin, r.mes_inicio, r.mes_fin, r.anio,
                r.porcentaje_descuento AS regla_porcentaje_descuento, r.es_venta_relampago
           FROM regla_descuento_periodo r
           JOIN oferta o ON o.id_oferta = r.id_oferta
          WHERE r.activa = true OR o.porcentaje_descuento IS NOT NULL`,
      );
      filas = resultado.rows;
    } catch (error) {
      this.logger.warn(
        `disparador de reglas de periodo: no se pudo leer Postgres (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    const porOferta = new Map<string, EstadoOferta>();
    for (const fila of filas) {
      let estado = porOferta.get(fila.id_oferta);
      if (estado == null) {
        estado = {
          id_usuario: fila.id_usuario,
          porcentaje_descuento: fila.porcentaje_descuento,
          es_inventario_limitado: fila.es_inventario_limitado,
          reglas: [],
        };
        porOferta.set(fila.id_oferta, estado);
      }
      estado.reglas.push({
        id_regla_descuento_periodo: fila.id_regla_descuento_periodo,
        activa: fila.activa,
        dia_inicio: fila.dia_inicio,
        dia_fin: fila.dia_fin,
        mes_inicio: fila.mes_inicio,
        mes_fin: fila.mes_fin,
        anio: fila.anio,
        porcentaje_descuento: fila.regla_porcentaje_descuento,
        es_venta_relampago: fila.es_venta_relampago,
      });
    }

    const hoy = this.rangoDeHoy();
    let aplicadas = 0;
    let quitadas = 0;
    for (const [idOferta, estado] of porOferta) {
      const reglaHoy = estado.reglas.find(
        (regla) => regla.activa && reglasDePeriodoSeSolapan(regla, hoy),
      );
      const estadoVacio = estado.porcentaje_descuento == null;
      const coincideConReglaHoy =
        reglaHoy != null &&
        !estadoVacio &&
        estado.porcentaje_descuento === reglaHoy.porcentaje_descuento &&
        estado.es_inventario_limitado === reglaHoy.es_venta_relampago;

      if (coincideConReglaHoy) {
        continue;
      }

      if (!estadoVacio) {
        const seJustificaPorAlgunaRegla = estado.reglas.some(
          (regla) =>
            estado.porcentaje_descuento === regla.porcentaje_descuento &&
            estado.es_inventario_limitado === regla.es_venta_relampago,
        );
        if (!seJustificaPorAlgunaRegla) {
          this.logger.warn(
            `disparador de reglas de periodo: la oferta ${idOferta} tiene un descuento/venta relampago activo que no coincide con ninguna de sus reglas de periodo -- no se toca`,
          );
          continue;
        }
        const seQuito = await this.quitarEfecto(idOferta, estado);
        if (seQuito) {
          quitadas++;
        }
      }

      if (reglaHoy != null) {
        const seAplico = await this.aplicarEfecto(idOferta, estado, reglaHoy);
        if (seAplico) {
          aplicadas++;
        }
      }
    }

    if (aplicadas > 0 || quitadas > 0) {
      this.logger.log(
        `disparador de reglas de periodo: ${aplicadas} oferta(s) con descuento aplicado, ${quitadas} con descuento quitado`,
      );
    }
  }

  private rangoDeHoy(): RangoPeriodo {
    const ahora = new Date();
    const dia = ahora.getDate();
    return {
      dia_inicio: dia,
      dia_fin: dia,
      mes_inicio: ahora.getMonth() + 1,
      mes_fin: ahora.getMonth() + 1,
      anio: ahora.getFullYear(),
    };
  }

  private async aplicarEfecto(
    idOferta: string,
    estado: EstadoOferta,
    regla: ReglaOferta,
  ): Promise<boolean> {
    try {
      await this.ofertasVendedorService.aplicarDescuento(
        estado.id_usuario,
        ID_ROL_VENDEDOR,
        idOferta,
        {
          porcentaje_descuento: Number(regla.porcentaje_descuento),
          duracion_segundos: 0,
        },
        'regla_periodo',
      );
      if (regla.es_venta_relampago) {
        await this.ventasLimitadasService.abrir(
          idOferta,
          estado.id_usuario,
          ID_ROL_VENDEDOR,
          { duracion_segundos: 0 },
          'regla_periodo',
        );
      }
      return true;
    } catch (error) {
      this.logger.warn(
        `disparador de reglas de periodo: no se pudo aplicar la regla ${regla.id_regla_descuento_periodo} sobre la oferta ${idOferta} (${(error as Error)?.message ?? error})`,
      );
      return false;
    }
  }

  private async quitarEfecto(
    idOferta: string,
    estado: EstadoOferta,
  ): Promise<boolean> {
    try {
      if (estado.es_inventario_limitado) {
        await this.ventasLimitadasService.cerrar(
          idOferta,
          estado.id_usuario,
          ID_ROL_VENDEDOR,
        );
      }
      await this.ofertasVendedorService.quitarDescuento(
        estado.id_usuario,
        ID_ROL_VENDEDOR,
        idOferta,
      );
      return true;
    } catch (error) {
      this.logger.warn(
        `disparador de reglas de periodo: no se pudo quitar el descuento de la oferta ${idOferta} (${(error as Error)?.message ?? error})`,
      );
      return false;
    }
  }
}
