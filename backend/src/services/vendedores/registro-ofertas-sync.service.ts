import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { redis } from '../../database/redis';
import { RegistroOfertasRedisService } from './registro-ofertas-redis.service';

/**
 * Worker de reconciliacion de los dos HASH de `RegistroOfertasRedisService`
 * (`mesh:ofertas:descuento` / `mesh:ofertas:venta_relampago`): los 4
 * escritos que los mantienen (aplicar/quitar descuento, abrir/cerrar venta
 * relampago) ya los actualizan al momento (`sincronizar()`, reactivo), asi
 * que esto es una red de seguridad, no la fuente principal -- corrige el
 * caso de un escrito reactivo que fallo (Redis caido un instante, por
 * ejemplo) o una llave que se perdio a mano.
 *
 * Compara cada HASH contra la fuente de verdad en PostgreSQL
 * (`oferta.porcentaje_descuento`/`oferta.es_inventario_limitado`) y corrige
 * la diferencia: lo que sobra en Redis (un id que ya no deberia estar ahi)
 * se borra directo con `HDEL`; lo que falta (un id que deberia estar y no
 * esta) se repara llamando a `sincronizar()` uno por uno, que arma su
 * detalle representativo desde cero.
 *
 * Mismo patron `@Interval` + bandera que el resto de los workers del
 * proyecto (`MasVendidosSyncService`, el que apaga solas las ventas
 * relampago vencidas): nunca lanza, un fallo se loguea y se reintenta en la
 * proxima corrida.
 */
@Injectable()
export class RegistroOfertasSyncService {
  private readonly logger = new Logger(RegistroOfertasSyncService.name);

  private static readonly INTERVALO_MS = 10 * 60 * 1000; // 10 minutos

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  constructor(private readonly registro: RegistroOfertasRedisService) {}

  /**
   * Las dos consultas de mas abajo tienen que coincidir EXACTAMENTE con lo
   * que `RegistroOfertasRedisService.sincronizar()` decide para cada oferta
   * -- si no, un id que esta condicion cuenta como "falta" pero que
   * `sincronizar()` termina descartando (por ejemplo, `es_inventario_limitado`
   * sin `porcentaje_descuento`: una venta relampago vieja, de antes de que
   * existiera la regla de descuento obligatorio) queda contado como
   * "agregada" en el log sin haberse agregado nunca -- se detecto asi en las
   * pruebas del 2026-09-23, con la oferta 6 (venta relampago heredada, sin
   * descuento).
   */
  @Interval('registro-ofertas-sync', RegistroOfertasSyncService.INTERVALO_MS)
  async reconciliar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      await this.reconciliarClave(
        RegistroOfertasRedisService.CLAVE_DESCUENTO,
        `SELECT id_oferta FROM oferta
          WHERE porcentaje_descuento IS NOT NULL AND NOT es_inventario_limitado`,
      );
      await this.reconciliarClave(
        RegistroOfertasRedisService.CLAVE_VENTA_RELAMPAGO,
        `SELECT id_oferta FROM oferta
          WHERE es_inventario_limitado AND porcentaje_descuento IS NOT NULL`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de registro de ofertas: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /**
   * Reconcilia UNA de las dos llaves contra el resultado de `consultaIds`
   * (siempre `SELECT id_oferta FROM oferta WHERE ...`, sin parametros del
   * cliente -- las dos consultas son literales fijos en `reconciliar()`).
   */
  private async reconciliarClave(
    clave: string,
    consultaIds: string,
  ): Promise<void> {
    const resultado = await pool.query<{ id_oferta: string }>(consultaIds);
    const idsCorrectos = new Set(
      resultado.rows.map((fila) => Number(fila.id_oferta)),
    );

    const idsEnRedis = (await redis.hkeys(clave)).map(Number);
    const idsEnRedisSet = new Set(idsEnRedis);

    const sobran = idsEnRedis.filter((id) => !idsCorrectos.has(id));
    const faltan = [...idsCorrectos].filter((id) => !idsEnRedisSet.has(id));

    if (sobran.length > 0) {
      await redis.hdel(clave, ...sobran.map(String));
    }
    for (const id of faltan) {
      await this.registro.sincronizar(id);
    }

    if (sobran.length > 0 || faltan.length > 0) {
      this.logger.log(
        `worker de registro de ofertas (${clave}): ${sobran.length} de mas eliminada(s), ${faltan.length} faltante(s) agregada(s)`,
      );
    }
  }
}

/** Un mensaje de error corto para el log -- mismo patron que los demas workers. */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
