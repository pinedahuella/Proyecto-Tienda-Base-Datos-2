import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { ErrorConflicto } from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';
import { TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS } from '../../helpers/constantes';

/** 24 h de inactividad: lo mismo que el TTL de la clave de Redis. */
export const VIDA_CARRITO_SEGUNDOS = 60 * 60 * 24;

/** Una reserva activa de venta relampago, tal como esta en PostgreSQL. */
export interface ReservaPostgres {
  id_reserva: string;
  ticket: number | null;
  cantidad: number;
  fecha_vence: Date;
}

/** Una linea del carrito de verdad (`pedido_producto` del pedido pendiente). */
export interface LineaCarritoPostgres {
  id_oferta: number;
  cantidad: number;
  id_precio_historial: string;
  id_producto: number;
  id_producto_variante: number;
  nombre_producto: string;
  nombre_variante: string;
  /** El precio final de la fila de precio con que se guardo: lo que la persona vio. */
  precio_visto: string;
  porcentaje_descuento_visto: string | null;
  reserva: ReservaPostgres | null;
}

/** El carrito de verdad: el pedido pendiente de la cuenta. */
export interface CarritoPostgres {
  id_pedido: string;
  version: number;
  fecha_ultima_actividad: Date;
  lineas: LineaCarritoPostgres[];
}

/** Lo que se quiere que quede en una linea despues de escribir. */
export interface LineaDeseada {
  id_oferta: number;
  cantidad: number;
  /** La fila de precio que se le mostro. `null` = la vigente. */
  id_precio_historial: string | null;
  nombre_producto: string;
  nombre_variante: string;
  id_producto: number;
  id_producto_variante: number;
  /** `null` = linea normal, sin reserva. */
  reserva: { ticket: number | null; fecha_vence: Date } | null;
}

/**
 * Como se compara la version del carrito de Redis contra la de PostgreSQL al
 * escribir:
 *   - `undefined`: no se compara (Redis caido: PostgreSQL es lo unico que hay).
 *   - `null`: Redis no conoce ninguna version (carrito nuevo o de antes del
 *     cambio). Solo se acepta si PostgreSQL no tiene nada que perder.
 *   - un numero: tiene que ser exactamente la de PostgreSQL.
 */
export type VersionEsperada = number | null | undefined;

/** Redis y PostgreSQL no cuentan la misma historia: hubo escrituras que Redis no vio. */
export class ConflictoVersion extends Error {
  constructor(
    readonly versionPostgres: number | null,
    readonly versionRedis: number | null,
  ) {
    super(
      `El carrito de Redis (version ${versionRedis ?? 'ninguna'}) no coincide con el de PostgreSQL (version ${versionPostgres ?? 'sin carrito'})`,
    );
  }
}

/** PostgreSQL no tiene unidades libres para una reserva que Redis ya dio. */
export class ConflictoCapacidad extends Error {
  constructor(
    readonly idOferta: number,
    readonly pedidas: number,
    readonly libres: number,
  ) {
    super(
      `No hay suficiente stock en la venta relampago de la oferta ${idOferta}: pediste ${pedidas} y hay ${libres} disponibles`,
    );
  }
}

export interface ResultadoEscritura {
  id_pedido: string | null;
  version: number;
  /** Ofertas cuyas reservas cambiaron (para que Redis las vuelva a mirar). */
  ofertas_reservas: number[];
  /** Lineas que no se pudieron guardar porque su oferta no existe. */
  omitidas: number[];
}

interface FilaPedido {
  id_pedido: string;
  version: string;
  fecha_ultima_actividad: Date;
  vencido: boolean;
}

interface FilaOfertaReserva {
  id_oferta: string;
  stock: number;
  venta_vigente: boolean;
}

/**
 * El carrito de VERDAD, en PostgreSQL: el pedido `pendiente` de cada cuenta
 * (uno solo, `uq_pedido_pendiente_usuario`) y sus lineas en
 * `pedido_producto`, mas las reservas de venta relampago en
 * `reserva_venta_relampago`. Ver
 * `elementos Generales/plan pendiente/carrito-postgres-verdad.md`.
 *
 * Redis es la copia rapida (CarritoService). Aqui no se habla con Redis: este
 * servicio solo sabe leer y escribir la verdad, y lo hace siempre en una
 * transaccion, con el pedido bloqueado (`FOR UPDATE`) para que dos escrituras
 * de la misma cuenta no se pisen.
 *
 * Escribir es por DIFERENCIAS: quien llama dice como quiere que queden las
 * lineas (`LineaDeseada[]`) y aqui solo se toca lo que cambio. Asi una
 * escritura que repite el estado no mueve nada (ni el grafo ni las reservas).
 *
 * El orden de los bloqueos es siempre pedido -> oferta -> reserva, el mismo
 * que el checkout y que cerrar una venta relampago: no hay forma de que dos de
 * esas transacciones se esperen en cruz.
 */
@Injectable()
export class CarritoPostgresService {
  private readonly logger = new Logger(CarritoPostgresService.name);

  /**
   * El carrito de la cuenta, o `null` si no tiene. Aplica el vencimiento
   * pasivo: un carrito con mas de 24 h sin tocar se borra aqui mismo y se
   * contesta `null`, como si nunca hubiera existido.
   */
  async leer(idUsuario: string): Promise<CarritoPostgres | null> {
    const cliente = await this.conectar();
    try {
      await cliente.query('BEGIN');
      const carrito = await this.leerEnTransaccion(cliente, idUsuario, false);
      await cliente.query('COMMIT');
      return carrito;
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }

  /**
   * Lo mismo, dentro de una transaccion que ya abrio quien llama. Con
   * `bloquear`, el pedido queda tomado (`FOR UPDATE`) hasta el COMMIT.
   */
  async leerEnTransaccion(
    cliente: PoolClient,
    idUsuario: string,
    bloquear: boolean,
  ): Promise<CarritoPostgres | null> {
    const pedido = await this.buscarPedido(cliente, idUsuario, bloquear);
    if (pedido == null) {
      return null;
    }
    if (pedido.vencido) {
      await this.vencer(cliente, pedido.id_pedido);
      return null;
    }
    return {
      id_pedido: pedido.id_pedido,
      version: Number(pedido.version),
      fecha_ultima_actividad: pedido.fecha_ultima_actividad,
      lineas: await this.leerLineas(cliente, pedido.id_pedido),
    };
  }

  /**
   * Escribe el carrito de verdad. `transformar` recibe las lineas que hay y
   * devuelve como tienen que quedar; aqui se aplican las diferencias, sube la
   * `version` y se renueva `fecha_ultima_actividad`.
   *
   * Lanza `ConflictoVersion` si Redis y PostgreSQL no coinciden (ver
   * `VersionEsperada`). Con `capacidad: 'conflicto'` (la replica de lo que
   * Redis ya acepto) una reserva sin unidades lanza `ConflictoCapacidad`; con
   * `capacidad: 'rechazar'` (Redis caido, la persona espera la respuesta)
   * lanza un `ErrorConflicto` (409) con el mismo mensaje que da Redis.
   */
  async escribir(
    idUsuario: string,
    transformar: (actuales: LineaCarritoPostgres[]) => LineaDeseada[],
    opciones: {
      versionEsperada: VersionEsperada;
      capacidad: 'conflicto' | 'rechazar';
    },
  ): Promise<ResultadoEscritura> {
    // Dos intentos: si dos escrituras de la misma cuenta crean el carrito a la
    // vez, la segunda choca con `uq_pedido_pendiente_usuario` (23505) y al
    // reintentar ya encuentra el pedido de la primera.
    for (let intento = 1; ; intento++) {
      const cliente = await this.conectar();
      const estado = { vencio: false };
      try {
        await cliente.query('BEGIN');
        const resultado = await this.escribirEnTransaccion(
          cliente,
          idUsuario,
          transformar,
          opciones,
          estado,
        );
        await cliente.query('COMMIT');
        return resultado;
      } catch (error) {
        // Si el carrito estaba vencido y se borro antes de chocar la version,
        // ese borrado se guarda igual (no se habia escrito nada mas): el
        // carrito vencio, haya o no haya choque.
        const guardarVencimiento =
          estado.vencio && error instanceof ConflictoVersion;
        await cliente
          .query(guardarVencimiento ? 'COMMIT' : 'ROLLBACK')
          .catch(() => undefined);
        if (
          error instanceof ConflictoVersion ||
          error instanceof ConflictoCapacidad ||
          error instanceof ErrorConflicto
        ) {
          throw error;
        }
        if ((error as { code?: string })?.code === '23505' && intento < 2) {
          continue;
        }
        manejarErrorConexion(this.logger, error);
      } finally {
        cliente.release();
      }
    }
  }

  private async escribirEnTransaccion(
    cliente: PoolClient,
    idUsuario: string,
    transformar: (actuales: LineaCarritoPostgres[]) => LineaDeseada[],
    opciones: {
      versionEsperada: VersionEsperada;
      capacidad: 'conflicto' | 'rechazar';
    },
    estado: { vencio: boolean },
  ): Promise<ResultadoEscritura> {
    let pedido = await this.buscarPedido(cliente, idUsuario, true);
    if (pedido?.vencido) {
      await this.vencer(cliente, pedido.id_pedido);
      estado.vencio = true;
      pedido = null;
    }

    const actuales =
      pedido == null ? [] : await this.leerLineas(cliente, pedido.id_pedido);
    this.comprobarVersion(pedido, actuales.length, opciones.versionEsperada);

    const deseadas = this.sinRepetidas(transformar(actuales));

    if (pedido == null) {
      if (deseadas.length === 0) {
        return {
          id_pedido: null,
          version: 0,
          ofertas_reservas: [],
          omitidas: [],
        };
      }
      pedido = await this.crearPedido(cliente, idUsuario);
    }

    const omitidas = await this.aplicarLineas(
      cliente,
      pedido.id_pedido,
      actuales,
      deseadas,
    );
    const ofertasReservas = await this.aplicarReservas(
      cliente,
      pedido.id_pedido,
      idUsuario,
      actuales,
      deseadas.filter((d) => !omitidas.includes(d.id_oferta)),
      opciones.capacidad,
    );

    if (deseadas.length === 0) {
      // Quedo vacio: un carrito vacio no existe, tampoco en PostgreSQL. Sus
      // lineas ya se borraron y sus reservas ya se devolvieron (quedan como
      // historial, con el pedido en NULL).
      await cliente.query('DELETE FROM pedido WHERE id_pedido = $1', [
        pedido.id_pedido,
      ]);
      return {
        id_pedido: null,
        version: 0,
        ofertas_reservas: ofertasReservas,
        omitidas,
      };
    }

    const { rows } = await cliente.query<{ version: string }>(
      `UPDATE pedido
          SET version = version + 1, fecha_ultima_actividad = now()
        WHERE id_pedido = $1
    RETURNING version`,
      [pedido.id_pedido],
    );

    return {
      id_pedido: pedido.id_pedido,
      version: Number(rows[0].version),
      ofertas_reservas: ofertasReservas,
      omitidas,
    };
  }

  /**
   * Renueva el reloj de las 24 h sin cambiar nada mas (ni la version: no es
   * una escritura del contenido). Lo usa ver el carrito, que tambien cuenta
   * como actividad. No lanza: es mantenimiento.
   */
  async tocar(idUsuario: string): Promise<void> {
    try {
      await pool.query(
        `UPDATE pedido p SET fecha_ultima_actividad = now()
           FROM estado_pedido ep
          WHERE ep.id_estado_pedido = p.id_estado_pedido
            AND ep.estado_pedido_nombre = 'pendiente'
            AND p.id_usuario = $1
            AND p.fecha_ultima_actividad > now() - make_interval(secs => $2)`,
        [idUsuario, VIDA_CARRITO_SEGUNDOS],
      );
    } catch (error) {
      this.logger.warn(
        `No se pudo renovar la actividad del carrito de ${idUsuario}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  /**
   * Borra un carrito vencido entero: sus reservas activas pasan a `vencida`
   * (quedan como historial, con el pedido en NULL por el SET NULL), se van sus
   * lineas y el pedido. Corre dentro de la transaccion de quien llama.
   */
  async vencer(cliente: PoolClient, idPedido: string): Promise<void> {
    await cliente.query(
      `UPDATE reserva_venta_relampago r
          SET id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                    WHERE estado_reserva_nombre = 'vencida'),
              fecha_cierre = now()
        WHERE r.id_pedido = $1
          AND r.id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                      WHERE estado_reserva_nombre = 'activa')`,
      [idPedido],
    );
    await cliente.query('DELETE FROM pedido_producto WHERE id_pedido = $1', [
      idPedido,
    ]);
    await cliente.query('DELETE FROM pedido WHERE id_pedido = $1', [idPedido]);
    this.logger.log(
      `carrito ${idPedido} vencido (24 h sin actividad): borrado`,
    );
  }

  /** Una conexion para una transaccion propia (la usa tambien el checkout). */
  async conectar(): Promise<PoolClient> {
    try {
      return await pool.connect();
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  // -------------------------------------------------------------------
  // Privados
  // -------------------------------------------------------------------

  private async buscarPedido(
    cliente: PoolClient,
    idUsuario: string,
    bloquear: boolean,
  ): Promise<FilaPedido | null> {
    const { rows } = await cliente.query<FilaPedido>(
      `SELECT p.id_pedido, p.version, p.fecha_ultima_actividad,
              p.fecha_ultima_actividad <= now() - make_interval(secs => $2) AS vencido
         FROM pedido p
         JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
        WHERE p.id_usuario = $1 AND ep.estado_pedido_nombre = 'pendiente'
        ${bloquear ? 'FOR UPDATE OF p' : ''}`,
      [idUsuario, VIDA_CARRITO_SEGUNDOS],
    );
    return rows[0] ?? null;
  }

  private async leerLineas(
    cliente: PoolClient,
    idPedido: string,
  ): Promise<LineaCarritoPostgres[]> {
    const { rows } = await cliente.query<{
      id_oferta: string;
      cantidad: number;
      id_precio_historial: string;
      id_producto_mongo: string;
      id_producto_variante_mongo: string;
      nombre_producto: string;
      nombre_variante: string;
      precio_visto: string;
      porcentaje_descuento_visto: string | null;
      id_reserva: string | null;
      ticket: string | null;
      cantidad_reserva: number | null;
      fecha_vence: Date | null;
    }>(
      `SELECT ph.id_oferta, pp.cantidad, pp.id_precio_historial,
              pp.id_producto_mongo, pp.id_producto_variante_mongo,
              pp.nombre_producto, pp.nombre_variante,
              ${expresionPrecioFinal('ph')}::text AS precio_visto,
              ph.porcentaje_descuento::text AS porcentaje_descuento_visto,
              r.id_reserva, r.ticket, r.cantidad AS cantidad_reserva, r.fecha_vence
         FROM pedido_producto pp
         JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
         LEFT JOIN reserva_venta_relampago r
                ON r.id_pedido = pp.id_pedido
               AND r.id_oferta = ph.id_oferta
               AND r.id_estado_reserva = (SELECT id_estado_reserva
                                            FROM estado_reserva_venta_relampago
                                           WHERE estado_reserva_nombre = 'activa')
        WHERE pp.id_pedido = $1
        ORDER BY pp.id_pedido_producto`,
      [idPedido],
    );
    return rows.map((fila) => ({
      id_oferta: Number(fila.id_oferta),
      cantidad: fila.cantidad,
      id_precio_historial: fila.id_precio_historial,
      id_producto: Number(fila.id_producto_mongo),
      id_producto_variante: Number(fila.id_producto_variante_mongo),
      nombre_producto: fila.nombre_producto,
      nombre_variante: fila.nombre_variante,
      precio_visto: fila.precio_visto,
      porcentaje_descuento_visto: fila.porcentaje_descuento_visto,
      reserva:
        fila.id_reserva == null
          ? null
          : {
              id_reserva: fila.id_reserva,
              ticket: fila.ticket == null ? null : Number(fila.ticket),
              cantidad: fila.cantidad_reserva ?? 0,
              fecha_vence: fila.fecha_vence!,
            },
    }));
  }

  private comprobarVersion(
    pedido: FilaPedido | null,
    cantidadLineas: number,
    esperada: VersionEsperada,
  ): void {
    if (esperada === undefined) {
      return;
    }
    if (pedido == null) {
      // Redis cree conocer un carrito que en PostgreSQL ya no esta (se compro
      // desde otra pestana, vencio): no se puede revivir con lo que dice Redis.
      if (esperada != null && esperada > 0) {
        throw new ConflictoVersion(null, esperada);
      }
      return;
    }
    const version = Number(pedido.version);
    if (esperada == null) {
      // Redis no conoce ninguna version. Solo se acepta si PostgreSQL no tiene
      // nada que perder (un pedido pendiente sin lineas).
      if (cantidadLineas > 0) {
        throw new ConflictoVersion(version, null);
      }
      return;
    }
    if (version !== esperada) {
      throw new ConflictoVersion(version, esperada);
    }
  }

  private sinRepetidas(deseadas: LineaDeseada[]): LineaDeseada[] {
    const porOferta = new Map<number, LineaDeseada>();
    for (const linea of deseadas) {
      if (linea.cantidad > 0) {
        porOferta.set(linea.id_oferta, linea);
      }
    }
    return [...porOferta.values()];
  }

  private async crearPedido(
    cliente: PoolClient,
    idUsuario: string,
  ): Promise<FilaPedido> {
    const { rows } = await cliente.query<FilaPedido>(
      `INSERT INTO pedido (id_usuario, id_direccion_historial, id_estado_pedido)
       VALUES ($1, NULL, (SELECT id_estado_pedido FROM estado_pedido
                           WHERE estado_pedido_nombre = 'pendiente'))
    RETURNING id_pedido, version, fecha_ultima_actividad, false AS vencido`,
      [idUsuario],
    );
    return rows[0];
  }

  /**
   * Inserta, cambia o borra las lineas que cambiaron. Devuelve las ofertas
   * que no se pudieron guardar porque no existen (no tienen fila de precio).
   */
  private async aplicarLineas(
    cliente: PoolClient,
    idPedido: string,
    actuales: LineaCarritoPostgres[],
    deseadas: LineaDeseada[],
  ): Promise<number[]> {
    const ids = deseadas.map((d) => d.id_oferta);
    const { rows: precios } = await cliente.query<{
      id_oferta: string;
      vigente: string;
      pedido: string | null;
      nombre_vendedor: string;
    }>(
      `SELECT o.id_oferta,
              (SELECT ph.id_precio_historial FROM precio_historial ph
                WHERE ph.id_oferta = o.id_oferta
                ORDER BY ph.fecha_creacion DESC, ph.id_precio_historial DESC
                LIMIT 1) AS vigente,
              (SELECT ph.id_precio_historial FROM precio_historial ph
                WHERE ph.id_oferta = o.id_oferta
                  AND ph.id_precio_historial = (t.pedido)::bigint) AS pedido,
              trim(u.nombre || ' ' || coalesce(u.apellido, '')) AS nombre_vendedor
         FROM unnest($1::bigint[], $2::text[]) AS t (id_oferta, pedido)
         JOIN oferta o ON o.id_oferta = t.id_oferta
         JOIN usuarios u ON u.id_usuario = o.id_usuario`,
      [ids, deseadas.map((d) => d.id_precio_historial)],
    );
    const porOferta = new Map(precios.map((p) => [Number(p.id_oferta), p]));
    const actualPorOferta = new Map(actuales.map((l) => [l.id_oferta, l]));

    const omitidas: number[] = [];
    for (const deseada of deseadas) {
      const precio = porOferta.get(deseada.id_oferta);
      if (precio?.vigente == null) {
        omitidas.push(deseada.id_oferta);
        continue;
      }
      const idPrecio = precio.pedido ?? precio.vigente;
      const nombreProducto = deseada.nombre_producto.slice(0, 200);
      const nombreVariante = deseada.nombre_variante.slice(0, 100);
      const actual = actualPorOferta.get(deseada.id_oferta);

      if (actual == null) {
        await cliente.query(
          `INSERT INTO pedido_producto (
               id_pedido, id_precio_historial, id_producto_mongo,
               id_producto_variante_mongo, cantidad, nombre_producto,
               nombre_variante, nombre_vendedor)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
          [
            idPedido,
            idPrecio,
            deseada.id_producto,
            deseada.id_producto_variante,
            deseada.cantidad,
            nombreProducto,
            nombreVariante,
            precio.nombre_vendedor.slice(0, 200),
          ],
        );
      } else if (
        actual.cantidad !== deseada.cantidad ||
        actual.id_precio_historial !== idPrecio ||
        actual.nombre_producto !== nombreProducto ||
        actual.nombre_variante !== nombreVariante
      ) {
        await cliente.query(
          `UPDATE pedido_producto pp
              SET cantidad = $3, id_precio_historial = $4,
                  nombre_producto = $5, nombre_variante = $6
             FROM precio_historial ph
            WHERE ph.id_precio_historial = pp.id_precio_historial
              AND pp.id_pedido = $1 AND ph.id_oferta = $2`,
          [
            idPedido,
            deseada.id_oferta,
            deseada.cantidad,
            idPrecio,
            nombreProducto,
            nombreVariante,
          ],
        );
      }
    }

    const quedan = new Set(ids);
    const sobran = actuales
      .filter((l) => !quedan.has(l.id_oferta))
      .map((l) => l.id_oferta);
    if (sobran.length > 0) {
      await cliente.query(
        `DELETE FROM pedido_producto pp
          USING precio_historial ph
          WHERE ph.id_precio_historial = pp.id_precio_historial
            AND pp.id_pedido = $1 AND ph.id_oferta = ANY($2::bigint[])`,
        [idPedido, sobran],
      );
    }
    return omitidas;
  }

  /**
   * Deja las reservas como piden las lineas. Una linea con reserva sobre una
   * oferta cuya venta relampago ya no esta vigente se guarda como linea
   * normal: la venta cerro y su reserva ya se devolvio.
   *
   * Una reserva nueva (o con otra cantidad) solo se da si hay unidades
   * (`reservarSiHayUnidades`). La oferta se bloquea (`FOR UPDATE`), en orden
   * de id, para que dos cuentas no tomen la misma unidad.
   */
  private async aplicarReservas(
    cliente: PoolClient,
    idPedido: string,
    idUsuario: string,
    actuales: LineaCarritoPostgres[],
    deseadas: LineaDeseada[],
    capacidad: 'conflicto' | 'rechazar',
  ): Promise<number[]> {
    const actualPorOferta = new Map(actuales.map((l) => [l.id_oferta, l]));
    const conReserva = deseadas.filter((d) => d.reserva != null);

    const ofertas = new Map<number, FilaOfertaReserva>();
    if (conReserva.length > 0) {
      const { rows } = await cliente.query<FilaOfertaReserva>(
        `SELECT o.id_oferta, o.stock,
                (o.es_inventario_limitado
                 AND (o.fecha_vencimiento_venta_limitada IS NULL
                      OR o.fecha_vencimiento_venta_limitada > now())) AS venta_vigente
           FROM oferta o
          WHERE o.id_oferta = ANY($1::bigint[])
          ORDER BY o.id_oferta
            FOR UPDATE`,
        [conReserva.map((d) => d.id_oferta)],
      );
      for (const fila of rows) {
        ofertas.set(Number(fila.id_oferta), fila);
      }
    }

    const tocadas: number[] = [];
    const devolver: string[] = [];

    for (const deseada of deseadas) {
      const actual = actualPorOferta.get(deseada.id_oferta)?.reserva ?? null;
      const oferta = ofertas.get(deseada.id_oferta);
      const quiere =
        deseada.reserva != null && oferta?.venta_vigente === true
          ? deseada.reserva
          : null;

      if (quiere == null) {
        if (actual != null) {
          devolver.push(actual.id_reserva);
          tocadas.push(deseada.id_oferta);
        }
        continue;
      }

      if (
        actual != null &&
        actual.ticket === quiere.ticket &&
        actual.cantidad === deseada.cantidad &&
        actual.fecha_vence.getTime() === quiere.fecha_vence.getTime()
      ) {
        continue;
      }

      const { reservada, libres } = await this.reservarSiHayUnidades(cliente, {
        idPedido,
        idUsuario,
        idOferta: deseada.id_oferta,
        cantidad: deseada.cantidad,
        stock: oferta!.stock,
        ticket: quiere.ticket,
        fechaVence: quiere.fecha_vence,
        idReservaActual: actual?.id_reserva ?? null,
      });
      if (!reservada) {
        if (capacidad === 'rechazar') {
          throw new ErrorConflicto(
            `No hay suficiente stock en la venta relampago de la oferta ${deseada.id_oferta}: pediste ${deseada.cantidad} y hay ${libres} disponibles (contando lo que ya tenias reservado)`,
          );
        }
        throw new ConflictoCapacidad(
          deseada.id_oferta,
          deseada.cantidad,
          libres,
        );
      }
      tocadas.push(deseada.id_oferta);
    }

    // Las reservas de lineas que ya no estan.
    const quedan = new Set(deseadas.map((d) => d.id_oferta));
    for (const linea of actuales) {
      if (linea.reserva != null && !quedan.has(linea.id_oferta)) {
        devolver.push(linea.reserva.id_reserva);
        tocadas.push(linea.id_oferta);
      }
    }
    if (devolver.length > 0) {
      await cliente.query(
        `UPDATE reserva_venta_relampago
            SET id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                      WHERE estado_reserva_nombre = 'devuelta'),
                fecha_cierre = now()
          WHERE id_reserva = ANY($1::bigint[])`,
        [devolver],
      );
    }
    return [...new Set(tocadas)];
  }

  /**
   * Da la reserva de venta relampago de una linea, o reescribe la que ya
   * tenia (`idReservaActual`), solo si hay unidades: `stock` menos lo que
   * tienen reservado las demas cuentas (activas y sin vencer). Si no
   * alcanzan no escribe nada y devuelve `reservada: false` con las unidades
   * libres, para que quien llama arme su mensaje.
   *
   * Es la unica comprobacion de capacidad de PostgreSQL: la usan la escritura
   * del carrito (`aplicarReservas`) y el checkout. Quien llama ya tiene la
   * oferta bloqueada (`FOR UPDATE`) en su transaccion.
   */
  async reservarSiHayUnidades(
    cliente: PoolClient,
    reserva: {
      idPedido: string;
      idUsuario: string;
      idOferta: number;
      cantidad: number;
      stock: number;
      ticket: number | null;
      fechaVence: Date;
      idReservaActual: string | null;
    },
  ): Promise<{ reservada: boolean; libres: number }> {
    const libres = await this.unidadesLibres(
      cliente,
      reserva.idOferta,
      reserva.idPedido,
      reserva.stock,
    );
    if (reserva.cantidad > libres) {
      return { reservada: false, libres };
    }

    const desde = new Date(
      reserva.fechaVence.getTime() -
        TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS * 1000,
    );
    if (reserva.idReservaActual != null) {
      await cliente.query(
        `UPDATE reserva_venta_relampago
            SET ticket = $2, cantidad = $3, fecha_reserva = $4, fecha_vence = $5
          WHERE id_reserva = $1`,
        [
          reserva.idReservaActual,
          reserva.ticket,
          reserva.cantidad,
          desde,
          reserva.fechaVence,
        ],
      );
    } else {
      await cliente.query(
        `INSERT INTO reserva_venta_relampago (
             id_pedido, id_usuario, id_oferta, cantidad, ticket,
             fecha_reserva, fecha_vence, id_estado_reserva)
         VALUES ($1, $2, $3, $4, $5, $6, $7,
                 (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                   WHERE estado_reserva_nombre = 'activa'))`,
        [
          reserva.idPedido,
          reserva.idUsuario,
          reserva.idOferta,
          reserva.cantidad,
          reserva.ticket,
          desde,
          reserva.fechaVence,
        ],
      );
    }
    return { reservada: true, libres };
  }

  /** Las unidades de la oferta que no tiene reservadas ninguna OTRA cuenta. */
  private async unidadesLibres(
    cliente: PoolClient,
    idOferta: number,
    idPedidoPropio: string | null,
    stock: number,
  ): Promise<number> {
    const { rows } = await cliente.query<{ reservado: string }>(
      `SELECT COALESCE(SUM(r.cantidad), 0) AS reservado
         FROM reserva_venta_relampago r
        WHERE r.id_oferta = $1
          AND r.id_estado_reserva = (SELECT id_estado_reserva FROM estado_reserva_venta_relampago
                                      WHERE estado_reserva_nombre = 'activa')
          AND r.fecha_vence > now()
          AND r.id_pedido IS DISTINCT FROM $2::bigint`,
      [idOferta, idPedidoPropio],
    );
    return Math.max(0, stock - Number(rows[0].reservado));
  }
}
