import { Injectable, Logger } from '@nestjs/common';
import { readFileSync } from 'fs';
import { join } from 'path';
import { redis } from '../../database/redis';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorRedis } from '../../helpers/manejar-error-redis';
import { RegistroOfertasRedisService } from '../vendedores/registro-ofertas-redis.service';

/**
 * El script vive en redis/inventario_limitado.lua, en la RAIZ del repo (lo
 * escribio y probo el companero -- ver redis/README.md). No se toca ni se
 * copia aca: se lee tal cual al importar este archivo.
 *
 * __dirname apunta a esta carpeta (src/services/inventario-limitado, o su
 * espejo en dist/ una vez compilado -- misma profundidad en los dos
 * casos), asi que subir 4 niveles llega a la raiz del repo sin importar
 * desde donde se haya arrancado el proceso.
 */
const RUTA_SCRIPT = join(
  __dirname,
  '../../../../redis/inventario_limitado.lua',
);

/**
 * `defineCommand` es la forma que da ioredis de manejar `SCRIPT LOAD` /
 * `EVALSHA` / el reintento en `NOSCRIPT` sin escribirlo a mano (que es lo
 * que pide el punto 5 del plan): manda `EVALSHA` primero, y si Redis
 * contesta `NOSCRIPT` (puede pasar tras un reinicio de Redis o un
 * `SCRIPT FLUSH`), reenvia el script completo una vez y lo vuelve a
 * cachear solo. Corre una sola vez, al importar este modulo.
 *
 * ioredis no trae tipos para un comando definido a mano, asi que la
 * llamada de mas abajo usa un cast puntual en vez de declarar un modulo
 * completo para esto solo.
 */
redis.defineCommand('inventarioLimitado', {
  numberOfKeys: 2,
  lua: readFileSync(RUTA_SCRIPT, 'utf8'),
});

/*
 * `redimensionar` ya es una rama de `redis/inventario_limitado.lua` (el
 * companero la sumo alla). Hasta el 2026-10-17 el backend cargaba todavia la
 * copia provisional de `plan pendiente/redimensionar-reserva.lua`, que no
 * comprobaba que la venta existiera (`campo('stock') or 0`): si Redis perdia
 * la venta contestaba AGOTADO en vez de SIN_OFERTA y dejaba un hash con solo
 * `rechazos`. Ahora se usa la rama del original, que si lo comprueba.
 */

/**
 * `restaurar-venta-relampago.lua`, mismo caso que el de arriba: provisional,
 * en `plan pendiente/`, sobre las mismas dos claves. Reconstruye el estado de
 * Redis desde PostgreSQL (ver `restaurar()` de abajo).
 */
const RUTA_SCRIPT_RESTAURAR = join(
  __dirname,
  '../../../elementos Generales/plan pendiente/restaurar-venta-relampago.lua',
);

redis.defineCommand('restaurarVentaRelampago', {
  numberOfKeys: 2,
  lua: readFileSync(RUTA_SCRIPT_RESTAURAR, 'utf8'),
});

type ComandoInventarioLimitado = (
  clave: string,
  claveReservas: string,
  ...argv: (string | number)[]
) => Promise<unknown[]>;

/** Fila minima de `oferta` para decidir si se puede abrir/cerrar la venta. */
interface FilaOfertaLimitada {
  stock: number;
  estado_oferta_nombre: string;
  es_inventario_limitado: boolean;
}

/** La primera palabra que devuelven `reservar` / `redimensionar` de Redis. */
export type ResultadoReservar = 'VENDIDO' | 'AGOTADO' | 'SIN_OFERTA';
export type ResultadoRedimensionar =
  'REDIMENSIONADO' | 'AGOTADO' | 'TICKET_AJENO' | 'SIN_OFERTA';
export type ResultadoConfirmar = 'CONFIRMADO' | 'SIN_TICKET' | 'TICKET_AJENO';
export type ResultadoDevolver = 'DEVUELTO' | 'SIN_TICKET' | 'TICKET_AJENO';

export interface RespuestaReservar {
  resultado: ResultadoReservar;
  /** Solo tiene valor cuando `resultado` es `VENDIDO`. */
  ticket: number | null;
  /** El stock restante (si VENDIDO) o el disponible (si AGOTADO). */
  numero: number;
}

export interface RespuestaRedimensionar {
  resultado: ResultadoRedimensionar;
  /** Solo tiene valor cuando `resultado` es `REDIMENSIONADO`. */
  ticket: number | null;
  /** El stock restante (si REDIMENSIONADO) o el efectivo (si AGOTADO). */
  numero: number;
}

export interface RespuestaConfirmar {
  resultado: ResultadoConfirmar;
  cantidad: number;
}

export interface RespuestaDevolver {
  resultado: ResultadoDevolver;
  cantidad: number;
  restante: number;
}

/**
 * Lo que devuelve la operacion `estado` de `redis/inventario_limitado.lua`:
 * los cinco contadores del hash `mesh:oferta:<id>` mas cuantas reservas
 * vivas hay (`pendientes`, el `ZCARD` del ZSET) y el TTL de la clave. Es
 * SOLO LECTURA -- `estado` no cosecha reservas vencidas a proposito, para
 * que una pantalla que se refresca sola no mueva el stock de nadie.
 */
export interface EstadoVentaLimitada {
  /** Unidades que todavia se pueden tomar AHORA. */
  stock: number;
  /** Unidades tomadas y sin confirmar todavia. */
  reservado: number;
  /** Unidades confirmadas (el pago paso en PostgreSQL). */
  vendidas: number;
  /** Intentos que se fueron sin unidad (llegaron tarde). */
  rechazos: number;
  /** Ultimo numero de ticket entregado. */
  ticket: number;
  /** Reservas vivas en el ZSET -- comprobacion independiente de `reservado`. */
  pendientes: number;
  /** TTL de la clave en segundos: -1 si no vence, -2 si ya no existe. */
  ttl_segundos: number;
}

/**
 * Paso 2 de `elementos Generales/plan pendiente/inventario-limitado.md`:
 * prender y apagar el modo de venta relampago de UNA oferta puntual.
 *
 * `activar` pone `oferta.es_inventario_limitado = true` y siembra el
 * contador de Redis con el stock que tenga esa oferta en ESTE instante
 * (operacion `sembrar` de `redis/inventario_limitado.lua`). `revertir`
 * hace lo contrario: apaga la columna y borra las dos llaves de Redis de
 * esa oferta -- no toca el stock de Postgres, porque lo que haya quedado
 * vendido de verdad en Redis solo se sabe llamando `confirmar` por cada
 * ticket, y eso es el paso 4 del plan, todavia sin construir. Por ahora
 * `revertir` sirve para deshacer una prueba, no para cerrar con calma una
 * venta real que ya tiene reservas en curso.
 *
 * Todavia NO tiene controlador ni ruta HTTP -- no hay decidido quien
 * puede llamarla ni con que autorizacion (ver el plan). Se dispara a
 * mano mientras se decide el resto del flujo.
 *
 * El worker que revisa las ventas relampago que vencieron solas por su
 * propio TTL de Redis (sin pasar por `revertir()`) vive en
 * `VentasLimitadasService.revisarVencidas()`, no aca -- necesita tambien
 * `ProductosService` para recalcular Mongo al quitar el descuento, y
 * `ProductosService` ya inyecta esta clase (para `estado()`), asi que
 * ponerlo aca habria sido una dependencia circular.
 */
@Injectable()
export class InventarioLimitadoService {
  private readonly logger = new Logger(InventarioLimitadoService.name);

  /**
   * Ofertas cuyo estado de Redis hay que reconstruir desde PostgreSQL en la
   * proxima pasada de `ReservasVentaRelampagoSyncService`: una reserva que
   * PostgreSQL rechazo, una compra hecha con Redis caido, un cierre que no
   * pudo borrar sus claves.
   */
  private readonly porRestaurar = new Set<number>();

  /** Las que estan restaurandose ahora: dos restauraciones de la misma oferta no se pisan. */
  private readonly restaurando = new Map<number, Promise<unknown>>();

  constructor(
    private readonly registroOfertasRedis: RegistroOfertasRedisService,
  ) {}

  private clave(idOferta: number): string {
    return `mesh:oferta:${idOferta}`;
  }

  private claveReservas(idOferta: number): string {
    return `mesh:oferta:${idOferta}:reservas`;
  }

  /**
   * Prende el modo de venta relampago, sembrando el contador de Redis con
   * el stock que la oferta tiene AHORA en Postgres.
   *
   * Rechaza si la oferta no esta `activa` (no tiene sentido abrir una
   * venta relampago de algo pausado/retirado) o si ya esta en modo
   * limitado -- `sembrar` es DESTRUCTIVO a proposito (ver el `.lua`):
   * volver a sembrar borraria cualquier reserva que ya estuviera viva.
   *
   * `ttlSegundos` es cuando CIERRA la venta entera (0 = sin vencimiento).
   * No es el tiempo de una reserva individual -- ese es otro parametro,
   * de la operacion `reservar` (paso 3, todavia sin construir).
   *
   * Ademas del TTL de Redis, guarda `oferta.fecha_vencimiento_venta_limitada`
   * (`now() + ttlSegundos`, o `NULL` si `ttlSegundos` es `0`) -- es lo que
   * lee `VentasLimitadasService.revisarVentasLimitadasVencidas()` para
   * decidir si ya vencio (desde 2026-09-27 ya NO le pregunta a Redis: ver
   * `plan pendiente/vencimiento-automatico-oferta.md`, el porque).
   */
  async activar(
    idOferta: number,
    ttlSegundos = 0,
  ): Promise<{ stock_sembrado: number }> {
    if (!Number.isInteger(idOferta) || idOferta <= 0) {
      throw new ErrorValidacion('El id de la oferta no es valido');
    }

    const fila = await this.obtenerFila(idOferta);

    if (fila.estado_oferta_nombre !== 'activa') {
      throw new ErrorConflicto(
        `La oferta ${idOferta} no esta activa (esta ${fila.estado_oferta_nombre}), no se puede abrir una venta limitada`,
      );
    }
    if (fila.es_inventario_limitado) {
      throw new ErrorConflicto(
        `La oferta ${idOferta} ya esta en modo venta limitada -- sembrar de nuevo borraria sus reservas vivas`,
      );
    }

    try {
      await pool.query(
        `UPDATE oferta
            SET es_inventario_limitado = true,
                fecha_vencimiento_venta_limitada = CASE WHEN $2 > 0
                  THEN now() + make_interval(secs => $2) ELSE NULL END
          WHERE id_oferta = $1`,
        [idOferta, ttlSegundos],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    try {
      // Antes era `sembrar` (del script original), que reinicia el contador
      // de tickets en 0: un carrito con el ticket 3 de una venta anterior
      // chocaba con el ticket 3 de otra persona en la nueva. `restaurar`
      // siembra desde PostgreSQL (la verdad) y sigue numerando desde el
      // ticket mas alto que esta oferta haya repartido.
      const { stock_libre } = await this.restaurarAhora(idOferta);
      return { stock_sembrado: stock_libre };
    } catch (error) {
      // El UPDATE de arriba ya se comprometio. Si Redis falla aca, hay
      // que deshacerlo -- si no, la oferta queda marcada como limitada en
      // Postgres sin nada sembrado en Redis.
      try {
        await pool.query(
          `UPDATE oferta
              SET es_inventario_limitado = false, fecha_vencimiento_venta_limitada = NULL
            WHERE id_oferta = $1`,
          [idOferta],
        );
      } catch {
        // Si tampoco se puede deshacer, el error de Redis de abajo es el
        // que hay que ver primero -- Postgres ya estaba fallando antes.
      }
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * Apaga el modo de venta limitada: `es_inventario_limitado = false` (y
   * `fecha_vencimiento_venta_limitada = NULL`) en Postgres, y `DEL` de las
   * dos llaves de esa oferta en Redis.
   */
  async revertir(idOferta: number): Promise<void> {
    if (!Number.isInteger(idOferta) || idOferta <= 0) {
      throw new ErrorValidacion('El id de la oferta no es valido');
    }

    // En UNA transaccion: apagar la oferta y devolver sus reservas activas.
    // El UPDATE de `oferta` toma la fila primero (mismo orden que el checkout:
    // oferta -> reserva), asi que un checkout que estaba confirmando una de
    // estas reservas termina antes, y una reserva ya confirmada no se toca.
    let cliente: PoolClient;
    let usuarios: string[] = [];
    try {
      cliente = await pool.connect();
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    try {
      await cliente.query('BEGIN');
      const resultado = await cliente.query(
        `UPDATE oferta
            SET es_inventario_limitado = false, fecha_vencimiento_venta_limitada = NULL
          WHERE id_oferta = $1
          RETURNING id_oferta`,
        [idOferta],
      );
      if (resultado.rowCount === 0) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }
      usuarios = await devolverReservasDeOferta(cliente, idOferta);
      await cliente.query('COMMIT');
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }

    // PostgreSQL ya cerro la venta, que es lo que vale. Si Redis no responde,
    // sus claves se borran en la proxima reconciliacion (restaurar una oferta
    // sin venta vigente las borra) en vez de devolver un 503 que diria que no
    // se cerro.
    await this.soltarTicketsDeCarritos(idOferta, usuarios);
    try {
      await redis.del(this.clave(idOferta), this.claveReservas(idOferta));
    } catch (error) {
      this.logger.warn(
        `La venta relampago de la oferta ${idOferta} se cerro en PostgreSQL pero no se pudieron borrar sus claves de Redis (se reintenta sola): ${error instanceof Error ? error.message : String(error)}`,
      );
      this.marcarParaRestaurar(idOferta);
    }
  }

  /**
   * La venta cerro: el ticket de esta oferta se quita del carrito de Redis de
   * quienes tenian reserva, para que su linea se vea como una normal y no como
   * una reserva vencida. La linea se queda. No lanza: si Redis no esta, el
   * ticket queda huerfano y es inofensivo (la reserva ya se devolvio en
   * PostgreSQL y el checkout la trata como linea normal).
   */
  async soltarTicketsDeCarritos(
    idOferta: number,
    usuarios: string[],
  ): Promise<void> {
    for (const idUsuario of usuarios) {
      await redis
        .hdel(`mesh:carrito:${idUsuario}`, `t:${idOferta}`)
        .catch(() => undefined);
    }
  }

  /** Pide que la proxima reconciliacion reconstruya Redis para esta oferta. */
  marcarParaRestaurar(idOferta: number): void {
    this.porRestaurar.add(idOferta);
  }

  /** Las marcadas hasta ahora, y las olvida: quien las pide las va a restaurar. */
  tomarPorRestaurar(): number[] {
    const ids = [...this.porRestaurar];
    this.porRestaurar.clear();
    return ids;
  }

  /**
   * Reconstruye el estado de Redis de una oferta desde PostgreSQL, que es la
   * verdad: el stock libre (`oferta.stock` menos las reservas activas sin
   * vencer), cada reserva viva con SU ticket y SU vencimiento, y el contador
   * de tickets desde el mas alto que la oferta repartio en toda su historia.
   * Las reservas hechas solo en PostgreSQL (Redis caido, `ticket` NULL)
   * reciben un ticket aqui y se guarda.
   *
   * Si la oferta ya no tiene una venta vigente, borra sus claves de Redis y
   * devuelve `false`. No lanza: es reconciliacion. Si falla, la deja marcada
   * para la proxima pasada.
   */
  async restaurar(idOferta: number): Promise<boolean> {
    try {
      await this.restaurarAhora(idOferta);
      return true;
    } catch (error) {
      if (error instanceof SinVentaVigente) {
        return false;
      }
      this.logger.warn(
        `No se pudo restaurar la venta relampago de la oferta ${idOferta}: ${error instanceof Error ? error.message : String(error)}`,
      );
      this.marcarParaRestaurar(idOferta);
      return false;
    }
  }

  /** Igual que `restaurar`, pero lanza. Una sola a la vez por oferta. */
  private async restaurarAhora(
    idOferta: number,
  ): Promise<{ stock_libre: number }> {
    const enCurso = this.restaurando.get(idOferta);
    if (enCurso != null) {
      await enCurso.catch(() => undefined);
    }
    const promesa = this.restaurarSinCandado(idOferta);
    this.restaurando.set(idOferta, promesa);
    try {
      return await promesa;
    } finally {
      if (this.restaurando.get(idOferta) === promesa) {
        this.restaurando.delete(idOferta);
      }
    }
  }

  private async restaurarSinCandado(
    idOferta: number,
  ): Promise<{ stock_libre: number }> {
    const { rows: ofertas } = await pool.query<{
      stock: number;
      vigente: boolean;
      ttl: number;
      ticket_base: string;
    }>(
      `SELECT o.stock,
              (o.es_inventario_limitado
               AND (o.fecha_vencimiento_venta_limitada IS NULL
                    OR o.fecha_vencimiento_venta_limitada > now())) AS vigente,
              COALESCE(CEIL(EXTRACT(EPOCH FROM
                  o.fecha_vencimiento_venta_limitada - now())), 0)::int AS ttl,
              COALESCE((SELECT MAX(r.ticket) FROM reserva_venta_relampago r
                         WHERE r.id_oferta = o.id_oferta), 0) AS ticket_base
         FROM oferta o
        WHERE o.id_oferta = $1`,
      [idOferta],
    );
    const oferta = ofertas[0];
    if (oferta == null || !oferta.vigente) {
      await redis
        .del(this.clave(idOferta), this.claveReservas(idOferta))
        .catch(() => undefined);
      throw new SinVentaVigente();
    }

    const { rows: reservas } = await pool.query<{
      id_reserva: string;
      ticket: string | null;
      id_usuario: string;
      cantidad: number;
      vence_ms: string;
    }>(
      `SELECT r.id_reserva, r.ticket, r.id_usuario, r.cantidad,
              (EXTRACT(EPOCH FROM r.fecha_vence) * 1000)::bigint AS vence_ms
         FROM reserva_venta_relampago r
        WHERE r.id_oferta = $1
          AND r.id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                      WHERE estado_reserva_nombre = 'activa')
          AND r.fecha_vence > now()
        ORDER BY r.id_reserva`,
      [idOferta],
    );

    // El contador de Redis puede ir mas adelante que PostgreSQL (un ticket que
    // Redis dio y todavia no se guardo): nunca se retrocede.
    const [ticketRedis, vendidasRedis] = await redis.hmget(
      this.clave(idOferta),
      'ticket',
      'vendidas',
    );
    const base = Math.max(Number(oferta.ticket_base), Number(ticketRedis ?? 0));
    const reservado = reservas.reduce((suma, r) => suma + r.cantidad, 0);
    const stockLibre = Math.max(0, oferta.stock - reservado);

    const argv: (string | number)[] = [
      'restaurar',
      stockLibre,
      // 0 = sin vencimiento. Una que vence se redondea hacia arriba (CEIL)
      // para que Redis no cierre antes que PostgreSQL.
      oferta.ttl > 0 ? oferta.ttl : 0,
      base,
      Number(vendidasRedis ?? 0),
      reservas.length,
    ];
    for (const r of reservas) {
      argv.push(
        r.ticket == null ? 0 : Number(r.ticket),
        r.id_usuario,
        r.cantidad,
        Number(r.vence_ms),
      );
    }

    const redisExtendido = redis as unknown as {
      restaurarVentaRelampago: ComandoInventarioLimitado;
    };
    const respuesta = await redisExtendido.restaurarVentaRelampago(
      this.clave(idOferta),
      this.claveReservas(idOferta),
      ...argv,
    );

    // Las que no tenian ticket (reservadas con Redis caido) ya tienen uno.
    const asignados = respuesta.slice(3).map(Number);
    for (let i = 0; i < reservas.length; i++) {
      if (reservas[i].ticket == null) {
        await pool.query(
          `UPDATE reserva_venta_relampago SET ticket = $2
            WHERE id_reserva = $1 AND ticket IS NULL`,
          [reservas[i].id_reserva, asignados[i]],
        );
      }
    }

    this.logger.log(
      `venta relampago de la oferta ${idOferta} restaurada desde PostgreSQL: ${stockLibre} libre(s), ${reservas.length} reserva(s)`,
    );
    return { stock_libre: stockLibre };
  }

  /**
   * `true` si esta oferta esta operando AHORA MISMO bajo el mecanismo de
   * venta relampago -- una sola consulta a Redis (`EXISTS`), **sin tocar
   * Postgres**. Es la comprobacion que va en el camino de agregar al
   * carrito (`PUT /carrito/lineas/:idOferta`): si la clave de Redis no
   * existe, la oferta se trata como normal, sin gastar una consulta a
   * `oferta.es_inventario_limitado` en cada `PUT`.
   */
  async existeVentaLimitada(idOferta: number): Promise<boolean> {
    try {
      const existe = await redis.exists(this.clave(idOferta));
      return existe === 1;
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * Reserva `cantidad` unidades de una venta relampago -- el paso 3 del
   * plan. Compara y descuenta en un solo paso atomico
   * (`redis/inventario_limitado.lua`, operacion `reservar`); si alcanza,
   * entrega un ticket que hay que guardar para poder `confirmar` o
   * `devolver` despues.
   */
  async reservar(
    idOferta: number,
    idUsuario: string,
    cantidad: number,
    ttlReservaSegundos: number,
  ): Promise<RespuestaReservar> {
    try {
      const redisExtendido = redis as unknown as {
        inventarioLimitado: ComandoInventarioLimitado;
      };
      const [resultado, ticket, numero] =
        await redisExtendido.inventarioLimitado(
          this.clave(idOferta),
          this.claveReservas(idOferta),
          'reservar',
          idUsuario,
          cantidad,
          ttlReservaSegundos,
        );
      return {
        resultado: resultado as ResultadoReservar,
        ticket: resultado === 'VENDIDO' ? Number(ticket) : null,
        numero: Number(numero),
      };
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * Cambia la cantidad de una reserva que ya existe (o crea una nueva si
   * `ticketViejo` es `null`), en un solo paso atomico -- ver
   * `plan pendiente/redimensionar-reserva.lua` para el porque. Es lo que
   * usa `PUT /carrito/lineas/:idOferta` cuando la linea ya tenia ticket:
   * acredita lo viejo y pide lo nuevo juntos, asi que solo hace falta la
   * DIFERENCIA de unidades libres, no la cantidad nueva completa.
   */
  async redimensionar(
    idOferta: number,
    idUsuario: string,
    ticketViejo: number | null,
    cantidadNueva: number,
    ttlReservaSegundos: number,
  ): Promise<RespuestaRedimensionar> {
    try {
      const redisExtendido = redis as unknown as {
        inventarioLimitado: ComandoInventarioLimitado;
      };
      const [resultado, ticket, numero] =
        await redisExtendido.inventarioLimitado(
          this.clave(idOferta),
          this.claveReservas(idOferta),
          'redimensionar',
          idUsuario,
          ticketViejo == null ? '' : ticketViejo,
          cantidadNueva,
          ttlReservaSegundos,
        );
      return {
        resultado: resultado as ResultadoRedimensionar,
        ticket: resultado === 'REDIMENSIONADO' ? Number(ticket) : null,
        numero: Number(numero),
      };
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * El pago de esa reserva salio bien en PostgreSQL: pasa de "reservada" a
   * "vendida". No toca el contador de `stock` -- ya se habia descontado al
   * reservar.
   */
  async confirmar(
    idOferta: number,
    idUsuario: string,
    ticket: number,
  ): Promise<RespuestaConfirmar> {
    try {
      const redisExtendido = redis as unknown as {
        inventarioLimitado: ComandoInventarioLimitado;
      };
      const [resultado, cantidad] = await redisExtendido.inventarioLimitado(
        this.clave(idOferta),
        this.claveReservas(idOferta),
        'confirmar',
        idUsuario,
        ticket,
      );
      return {
        resultado: resultado as ResultadoConfirmar,
        cantidad: Number(cantidad),
      };
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * El pago fallo (o la persona la solto antes de pagar): las unidades
   * vuelven al `stock` de esa oferta.
   */
  async devolver(
    idOferta: number,
    idUsuario: string,
    ticket: number,
  ): Promise<RespuestaDevolver> {
    try {
      const redisExtendido = redis as unknown as {
        inventarioLimitado: ComandoInventarioLimitado;
      };
      const [resultado, cantidad, restante] =
        await redisExtendido.inventarioLimitado(
          this.clave(idOferta),
          this.claveReservas(idOferta),
          'devolver',
          idUsuario,
          ticket,
        );
      return {
        resultado: resultado as ResultadoDevolver,
        cantidad: Number(cantidad),
        restante: Number(restante),
      };
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * `true` si el ticket de esa oferta sigue vivo (no vencio, no se
   * confirmo ni se devolvio todavia). Se usa desde `GET /carrito` para
   * avisar si una linea con reserva sigue siendo valida, sin gastar la
   * operacion completa de `estado` (que ademas cosecha).
   */
  async ticketVigente(idOferta: number, ticket: number): Promise<boolean> {
    try {
      const valor = await redis.hget(this.clave(idOferta), `r:${ticket}`);
      return valor != null;
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * El estado real de la venta relampago de una oferta -- operacion `estado`
   * del `.lua`, de solo lectura (no cosecha reservas vencidas). `null` si esa
   * oferta no tiene una venta relampago viva en Redis: el hash no existe
   * porque nunca se abrio, o ya cerro y vencio.
   *
   * NO lanza si Redis falla: sus unicos consumidores son pantallas de solo
   * lectura (la ficha del producto, el panel del vendedor) que tienen que
   * poder pintarse igual con el stock de PostgreSQL si el contador de Redis
   * no responde. Un blip de Redis no puede tumbar una lectura del catalogo.
   * En ese caso devuelve `null` y deja un warning.
   */
  async estado(idOferta: number): Promise<EstadoVentaLimitada | null> {
    try {
      const redisExtendido = redis as unknown as {
        inventarioLimitado: ComandoInventarioLimitado;
      };
      // ['ESTADO', stock, reservado, vendidas, rechazos, ticket, ZCARD, TTL]
      const r = await redisExtendido.inventarioLimitado(
        this.clave(idOferta),
        this.claveReservas(idOferta),
        'estado',
      );

      const stock = Number(r[1]);
      // El `.lua` devuelve -1 en cada contador cuando el hash no existe.
      if (stock === -1) {
        return null;
      }

      return {
        stock,
        reservado: Number(r[2]),
        vendidas: Number(r[3]),
        rechazos: Number(r[4]),
        ticket: Number(r[5]),
        pendientes: Number(r[6]),
        ttl_segundos: Number(r[7]),
      };
    } catch (error) {
      const detalle = error instanceof Error ? error.message : String(error);
      this.logger.warn(
        `No se pudo leer el estado de la venta relampago de la oferta ` +
          `${idOferta}: ${detalle}`,
      );
      return null;
    }
  }

  private async obtenerFila(idOferta: number): Promise<FilaOfertaLimitada> {
    try {
      const resultado = await pool.query<FilaOfertaLimitada>(
        `SELECT o.stock, o.es_inventario_limitado, eo.estado_oferta_nombre
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
          WHERE o.id_oferta = $1`,
        [idOferta],
      );
      const fila = resultado.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }
      return fila;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }
}

/** `restaurar` sobre una oferta que ya no tiene venta relampago vigente. */
class SinVentaVigente extends Error {}

/**
 * Las reservas activas de una oferta pasan a `devuelta`: la venta relampago
 * cerro (a mano, por una regla o porque vencio). Corre dentro de la
 * transaccion que la cierra, despues del UPDATE de `oferta`. La comparten
 * `InventarioLimitadoService.revertir` y el worker que apaga las vencidas
 * (`VentasLimitadasService`).
 */
export async function devolverReservasDeOferta(
  cliente: PoolClient,
  idOferta: number,
): Promise<string[]> {
  const { rows } = await cliente.query<{ id_usuario: string }>(
    `UPDATE reserva_venta_relampago
        SET id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                  WHERE estado_reserva_nombre = 'devuelta'),
            fecha_cierre = now()
      WHERE id_oferta = $1
        AND id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                  WHERE estado_reserva_nombre = 'activa')
  RETURNING id_usuario`,
    [idOferta],
  );
  return [...new Set(rows.map((r) => r.id_usuario))];
}
