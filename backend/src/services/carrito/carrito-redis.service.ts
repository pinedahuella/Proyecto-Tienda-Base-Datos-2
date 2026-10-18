import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../../database/redis';
import { ErrorConflicto } from '../../helpers/errores';
import {
  esRedisInalcanzable,
  manejarErrorRedis,
} from '../../helpers/manejar-error-redis';
import { MotivoNoDisponible, ResumenCarrito } from '../../models/carrito';
import { VIDA_CARRITO_SEGUNDOS } from './carrito-postgres.service';

/** Campos de control del HASH del carrito. Empiezan con `_`: no son lineas. */
const CAMPO_VERSION = '_v';
const CAMPO_DESINCRONIZADO = '_d';

/** Escribe campos en el HASH solo si existe: no revive un carrito que ya se borro. */
const LUA_HSET_SI_EXISTE =
  "if redis.call('EXISTS', KEYS[1]) == 1 then redis.call('HSET', KEYS[1], unpack(ARGV)) return 1 end return 0";

/** Borra el HASH solo si ya no tiene ninguna linea (solo campos de control). */
const LUA_BORRAR_SI_VACIO =
  "for _, k in ipairs(redis.call('HKEYS', KEYS[1])) do if string.sub(k, 1, 1) ~= '_' then return 0 end end redis.call('DEL', KEYS[1]) return 1";

/**
 * Lo que se guarda por linea DENTRO del HASH de Redis, como JSON (campo =
 * `id_oferta`, valor = esto serializado). Es una FOTO tomada la ultima vez
 * que se hizo `PUT /carrito/lineas/:idOferta` -- no se refresca sola.
 */
export interface LineaCarritoRedis {
  cantidad: number;
  id_producto: number;
  id_producto_variante: number;
  nombre_producto: string;
  nombre_variante: string;
  imagen: string | null;
  /** El precio que de verdad se cobra/muestra -- YA con el descuento aplicado, si tenia uno al tomar la foto. */
  precio: string;
  /** El % de descuento que tenia la oferta al tomar la foto, o `null` -- solo informativo (badge), `precio` ya lo tiene aplicado. */
  porcentaje_descuento: string | null;
  vendedor_usuario: string;
  vendedor_nombre: string;
  stock_disponible: number;
  disponible: boolean;
  motivo: MotivoNoDisponible | null;
  /** La fila de precio que se le mostro: la que se guarda en PostgreSQL. Falta en carritos de antes del cambio. */
  id_precio_historial?: string | null;
  /** Cuando vence la reserva de venta relampago de esta linea (ISO), si tiene. */
  reserva_vence?: string | null;
}

/** El HASH del carrito ya separado: lineas, tickets y control. */
export interface HashCarrito {
  existe: boolean;
  lineas: Record<number, LineaCarritoRedis>;
  tickets: Record<number, number>;
  /** La version de PostgreSQL que Redis conoce, o `null` si no conoce ninguna. */
  version: number | null;
  desincronizado: boolean;
}

/** Una linea para escribir el carrito entero de una vez (`reemplazar`). */
export interface LineaParaRedis {
  idOferta: number;
  foto: LineaCarritoRedis;
  ticket: number | null;
}

/**
 * La copia rapida del carrito, en Redis: solo leer y escribir la clave. Que
 * escribir y cuando lo decide `CarritoService`; aqui no se habla con
 * PostgreSQL. Ver `elementos Generales/plan pendiente/carrito-postgres-verdad.md`.
 *
 * La clave es `mesh:carrito:<id_usuario>`, un HASH con:
 *   `<id_oferta>`    la FOTO de la linea (JSON, `LineaCarritoRedis`)
 *   `t:<id_oferta>`  el ticket de su reserva de venta relampago, si tiene
 *   `_v`             la version de PostgreSQL que Redis conoce
 *   `_d`             `1` si el carrito quedo desincronizado
 *
 * Un carrito vacio no existe como clave. El TTL son las 24 h de inactividad
 * y se re-pone en cada toque.
 *
 * Todo error de Redis sale como `ErrorConexionRedis` (`manejarErrorRedis`),
 * salvo en los metodos que dicen que no lanzan.
 */
@Injectable()
export class CarritoRedisService {
  private readonly logger = new Logger(CarritoRedisService.name);

  /** La clave del carrito de una cuenta en Redis. */
  private clave(idUsuario: string): string {
    return `mesh:carrito:${idUsuario}`;
  }

  /** El nombre del campo companero que guarda el ticket de una linea de venta relampago. */
  private campoTicket(idOferta: number): string {
    return `t:${idOferta}`;
  }

  // ---------------------------------------------------------------------
  // Leer
  // ---------------------------------------------------------------------

  /**
   * El HASH del carrito completo, separado: las lineas (`<id_oferta>: <foto
   * JSON>`), los tickets de venta relampago (`t:<id_oferta>: ticket`) y los
   * campos de control (`_v` la version, `_d` desincronizado). Un campo que no
   * parsea se descarta en silencio: es basura de una version vieja del
   * carrito, no algo que deba tumbar el `GET`.
   */
  async leerHashCompleto(idUsuario: string): Promise<HashCarrito> {
    let crudo: Record<string, string>;
    try {
      crudo = await redis.hgetall(this.clave(idUsuario));
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
    const lineas: Record<number, LineaCarritoRedis> = {};
    const tickets: Record<number, number> = {};
    let version: number | null = null;
    let desincronizado = false;

    for (const [campo, valor] of Object.entries(crudo)) {
      if (campo === CAMPO_VERSION) {
        const numero = Number(valor);
        version = Number.isInteger(numero) && numero >= 0 ? numero : null;
        continue;
      }
      if (campo === CAMPO_DESINCRONIZADO) {
        desincronizado = valor === '1';
        continue;
      }
      if (campo.startsWith('t:')) {
        const idOferta = Number(campo.slice(2));
        const ticket = Number(valor);
        if (Number.isInteger(idOferta) && Number.isInteger(ticket)) {
          tickets[idOferta] = ticket;
        }
        continue;
      }
      const id = Number(campo);
      if (!Number.isInteger(id)) {
        continue;
      }
      try {
        const linea = JSON.parse(valor) as LineaCarritoRedis;
        if (Number.isInteger(linea.cantidad) && linea.cantidad > 0) {
          lineas[id] = linea;
        }
      } catch {
        // Campo corrupto o de un formato viejo del carrito -- se ignora.
      }
    }
    // Un ticket sin su linea no sirve de nada.
    for (const id of Object.keys(tickets).map(Number)) {
      if (lineas[id] == null) {
        delete tickets[id];
      }
    }
    return {
      existe: Object.keys(crudo).length > 0,
      lineas,
      tickets,
      version,
      desincronizado,
    };
  }

  async existeCarrito(idUsuario: string): Promise<boolean> {
    try {
      return (await redis.exists(this.clave(idUsuario))) === 1;
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /** El ticket guardado para esta linea, o `null` si no tiene. */
  async leerTicket(
    idUsuario: string,
    idOferta: number,
  ): Promise<number | null> {
    try {
      const valor = await redis.hget(
        this.clave(idUsuario),
        this.campoTicket(idOferta),
      );
      return valor == null ? null : Number(valor);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /** Resumen ligero (solo Redis) para las respuestas de PUT/DELETE. */
  async resumen(idUsuario: string): Promise<ResumenCarrito> {
    const { lineas } = await this.leerHashCompleto(idUsuario);
    const cantidades = Object.values(lineas).map((l) => l.cantidad);
    return {
      total_lineas: cantidades.length,
      total_items: cantidades.reduce((suma, c) => suma + c, 0),
    };
  }

  // ---------------------------------------------------------------------
  // Escribir
  // ---------------------------------------------------------------------

  /**
   * Guarda la foto de una linea y renueva el TTL. Con `ticket`, guarda
   * tambien el de su reserva de venta relampago; sin el, borra el que
   * hubiera: si la linea arrastraba el ticket de una venta que ya cerro,
   * seguiria saliendo como de inventario limitado.
   */
  async guardarLinea(
    idUsuario: string,
    idOferta: number,
    foto: LineaCarritoRedis,
    ticket: number | null,
  ): Promise<void> {
    const clave = this.clave(idUsuario);
    try {
      if (ticket != null) {
        await redis.hset(
          clave,
          String(idOferta),
          JSON.stringify(foto),
          this.campoTicket(idOferta),
          String(ticket),
        );
      } else {
        await redis.hset(clave, String(idOferta), JSON.stringify(foto));
        // `HDEL` de un campo que no esta no hace nada.
        await redis.hdel(clave, this.campoTicket(idOferta));
      }
      await redis.expire(clave, VIDA_CARRITO_SEGUNDOS);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /** Quita una linea (y su ticket, si tenia) y renueva el TTL. */
  async borrarLinea(idUsuario: string, idOferta: number): Promise<void> {
    const clave = this.clave(idUsuario);
    try {
      await redis.hdel(clave, String(idOferta), this.campoTicket(idOferta));
      await redis.expire(clave, VIDA_CARRITO_SEGUNDOS);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /** Borra el carrito entero de Redis. */
  async borrar(idUsuario: string): Promise<void> {
    try {
      await redis.del(this.clave(idUsuario));
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * Borra la clave solo si ya no tiene lineas (un carrito vacio no existe
   * como clave). No lanza: si Redis no esta, la clave vence sola.
   */
  async borrarSiVacio(idUsuario: string): Promise<void> {
    await redis
      .eval(LUA_BORRAR_SI_VACIO, 1, this.clave(idUsuario))
      .catch(() => undefined);
  }

  /**
   * Escribe el carrito entero de una vez (MULTI): tira lo que habia y deja
   * las lineas, sus tickets, la version y el TTL dados.
   */
  async reemplazar(
    idUsuario: string,
    version: number,
    lineas: LineaParaRedis[],
    ttlSegundos: number,
  ): Promise<void> {
    const campos: string[] = [CAMPO_VERSION, String(version)];
    for (const { idOferta, foto, ticket } of lineas) {
      campos.push(String(idOferta), JSON.stringify(foto));
      if (ticket != null) {
        campos.push(this.campoTicket(idOferta), String(ticket));
      }
    }
    try {
      const clave = this.clave(idUsuario);
      await redis
        .multi()
        .del(clave)
        .hset(clave, ...campos)
        .expire(clave, ttlSegundos)
        .exec();
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * Deja el carrito vacio. Con `version` (PostgreSQL tiene un carrito vacio
   * pero existente) Redis guarda esa version, para que la proxima escritura
   * se compare contra ella; sin ella, la clave simplemente no queda.
   */
  async dejarVacio(
    idUsuario: string,
    version: number | null,
    ttlSegundos: number,
  ): Promise<void> {
    const clave = this.clave(idUsuario);
    try {
      await redis.del(clave);
      if (version != null) {
        await redis.hset(clave, CAMPO_VERSION, String(version));
        await redis.expire(clave, ttlSegundos);
      }
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  async renovarTtl(idUsuario: string): Promise<void> {
    try {
      await redis.expire(this.clave(idUsuario), VIDA_CARRITO_SEGUNDOS);
    } catch (error) {
      manejarErrorRedis(this.logger, error);
    }
  }

  /**
   * Guarda la version que quedo en PostgreSQL y quita la marca de
   * desincronizado. No lanza: si falla, la proxima escritura choca y el
   * carrito se marca desincronizado.
   */
  async marcarSincronizado(idUsuario: string, version: number): Promise<void> {
    try {
      await redis.eval(
        LUA_HSET_SI_EXISTE,
        1,
        this.clave(idUsuario),
        CAMPO_VERSION,
        String(version),
      );
      await redis.hdel(this.clave(idUsuario), CAMPO_DESINCRONIZADO);
    } catch (error) {
      this.logger.warn(
        `No se pudo anotar en Redis la version ${version} del carrito de ${idUsuario}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  /** Marca el carrito como desincronizado. No lanza. */
  async marcarDesincronizado(idUsuario: string): Promise<void> {
    try {
      await redis.eval(
        LUA_HSET_SI_EXISTE,
        1,
        this.clave(idUsuario),
        CAMPO_DESINCRONIZADO,
        '1',
      );
    } catch {
      // Si Redis no esta, tampoco hay nada que marcar: lo que vale es PostgreSQL.
    }
  }

  // ---------------------------------------------------------------------
  // Candado del checkout
  // ---------------------------------------------------------------------

  /**
   * Corre `fn` bajo un candado corto en Redis exclusivo del checkout de
   * esta cuenta (`mesh:checkout:<id_usuario>`). Si ya hay una compra en
   * curso para la misma cuenta, corta con 409 sin tocar nada.
   *
   * Cierra el hueco del doble submit: dos `POST /carrito/comprar`
   * identicos y concurrentes. `SET ... NX` es atomico, asi que de dos
   * peticiones que llegan juntas solo una consigue el candado.
   *
   * Si Redis no responde se sigue sin candado: el `FOR UPDATE` del pedido en
   * PostgreSQL hace que la segunda compra espere a la primera y encuentre el
   * carrito ya comprado (409 "vacio"), asi que no se cobra dos veces.
   *
   * El candado vence solo a los 30 s (`EX`) por si el proceso muere a
   * mitad del checkout.
   */
  async conCandadoCheckout<T>(
    idUsuario: string,
    fn: () => Promise<T>,
  ): Promise<T> {
    const clave = `mesh:checkout:${idUsuario}`;
    if (esRedisInalcanzable()) {
      return fn();
    }

    let obtenido: string | null = null;
    try {
      obtenido = await redis.set(clave, '1', 'EX', 30, 'NX');
    } catch (error) {
      if (esRedisInalcanzable(error)) {
        return fn();
      }
      manejarErrorRedis(this.logger, error);
    }

    if (obtenido == null) {
      throw new ErrorConflicto(
        'Ya tienes una compra en curso, espera un momento antes de reintentar',
      );
    }

    try {
      return await fn();
    } finally {
      try {
        await redis.del(clave);
      } catch (error) {
        this.logger.warn(
          `No se pudo soltar el candado de checkout de ${idUsuario} (vence solo en 30 s): ` +
            (error instanceof Error ? error.message : String(error)),
        );
      }
    }
  }
}
