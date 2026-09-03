import { Injectable, Logger } from '@nestjs/common';
import { readFileSync } from 'fs';
import { join } from 'path';
import { redis } from '../../database/redis';
import { pool } from '../../database/postgres';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { manejarErrorRedis } from '../../helpers/manejar-error-redis';

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

/**
 * `redimensionar-reserva.lua` vive en `elementos Generales/plan pendiente/`
 * (DENTRO de `backend/`, a diferencia del script de arriba): es la
 * operacion provisional que escribio Claude, no el companero -- ver
 * `plan pendiente/inventario-limitado.md` y
 * `cambio_propuestas/2026-09-03_1700-redimensionar-reserva-lua.md`. El
 * dia que el companero la revise y la sume a `inventario_limitado.lua`,
 * esta constante y su `defineCommand` se borran.
 */
const RUTA_SCRIPT_REDIMENSIONAR = join(
  __dirname,
  '../../../elementos Generales/plan pendiente/redimensionar-reserva.lua',
);

redis.defineCommand('redimensionarReserva', {
  numberOfKeys: 2,
  lua: readFileSync(RUTA_SCRIPT_REDIMENSIONAR, 'utf8'),
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
export type ResultadoRedimensionar = 'REDIMENSIONADO' | 'AGOTADO' | 'TICKET_AJENO';
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
 */
@Injectable()
export class InventarioLimitadoService {
  private readonly logger = new Logger(InventarioLimitadoService.name);

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
        'UPDATE oferta SET es_inventario_limitado = true WHERE id_oferta = $1',
        [idOferta],
      );
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    try {
      // Llamado como metodo (redisExtendido.inventarioLimitado(...)) y no
      // extraido a una variable aparte: ioredis necesita su propio `this`
      // (el cliente) para resolver el comando definido -- una funcion
      // suelta lo pierde y revienta con un error críptico ("Cannot read
      // properties of undefined (reading 'options')").
      const redisExtendido = redis as unknown as {
        inventarioLimitado: ComandoInventarioLimitado;
      };
      const resultado = await redisExtendido.inventarioLimitado(
        this.clave(idOferta),
        this.claveReservas(idOferta),
        'sembrar',
        fila.stock,
        ttlSegundos,
      );
      return { stock_sembrado: Number(resultado[1]) };
    } catch (error) {
      // El UPDATE de arriba ya se comprometio. Si Redis falla aca, hay
      // que deshacerlo -- si no, la oferta queda marcada como limitada en
      // Postgres sin nada sembrado en Redis, y nadie podria comprarla por
      // ningun camino hasta que alguien note el error a mano.
      try {
        await pool.query(
          'UPDATE oferta SET es_inventario_limitado = false WHERE id_oferta = $1',
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
   * Apaga el modo de venta limitada: `es_inventario_limitado = false` en
   * Postgres y `DEL` de las dos llaves de esa oferta en Redis.
   */
  async revertir(idOferta: number): Promise<void> {
    if (!Number.isInteger(idOferta) || idOferta <= 0) {
      throw new ErrorValidacion('El id de la oferta no es valido');
    }

    try {
      const resultado = await pool.query(
        'UPDATE oferta SET es_inventario_limitado = false WHERE id_oferta = $1 RETURNING id_oferta',
        [idOferta],
      );
      if (resultado.rowCount === 0) {
        throw new ErrorNoEncontrado('No existe una oferta con ese id');
      }
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }

    try {
      await redis.del(this.clave(idOferta), this.claveReservas(idOferta));
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
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
        redimensionarReserva: ComandoInventarioLimitado;
      };
      const [resultado, ticket, numero] =
        await redisExtendido.redimensionarReserva(
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
