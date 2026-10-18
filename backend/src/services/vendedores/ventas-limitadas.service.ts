import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { CORREO_TIENDA } from '../../helpers/constantes';
import { validarDuracionVencimiento } from '../../helpers/validaciones-oferta';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import {
  devolverReservasDeOferta,
  InventarioLimitadoService,
} from '../inventario-limitado/inventario-limitado.service';
import { ProductosService } from '../productos/productos.service';
import { RegistroOfertasRedisService } from './registro-ofertas-redis.service';
import {
  exigirSinOtroMecanismoActivo,
  MecanismoDescuento,
} from '../../helpers/exclusion-mecanismos-descuento';
import { AbrirVentaLimitadaPeticion } from '../../dto/abrir-venta-limitada';
import { VentaLimitadaAbierta } from '../../models/oferta';

const REGEX_ID = /^\d+$/;

/**
 * Paso 2 de `elementos Generales/plan pendiente/inventario-limitado.md`:
 * el vendedor abre o cierra la venta relampago (inventario limitado en
 * Redis) de UNA oferta suya.
 *
 * Va en su propio servicio, aparte de `OfertasVendedorService`, a
 * proposito: el CRUD de ofertas es PostgreSQL puro y el mecanismo de venta
 * relampago vive en Redis (`InventarioLimitadoService` + el script Lua).
 * Aqui solo estan la autorizacion (la oferta tiene que ser del vendedor) y
 * la validacion del cuerpo; el trabajo real lo hace
 * `InventarioLimitadoService.activar` / `revertir`, que ya existian y ya
 * las usa tambien `CarritoService`.
 */
@Injectable()
export class VentasLimitadasService {
  private readonly logger = new Logger(VentasLimitadasService.name);

  constructor(
    private readonly inventarioLimitadoService: InventarioLimitadoService,
    private readonly productosService: ProductosService,
    private readonly registroOfertasRedis: RegistroOfertasRedisService,
  ) {}

  /**
   * Abre la venta relampago: siembra el contador de Redis con el `stock`
   * que la oferta tiene AHORA en PostgreSQL y marca
   * `oferta.es_inventario_limitado`.
   *
   * Exige que la oferta ya tenga un descuento activo
   * (`oferta.porcentaje_descuento`) -- una venta relampago sin descuento no
   * tiene sentido de negocio (409 si falta, pidiendo aplicarlo primero con
   * `POST .../descuento`).
   *
   * `activar()` hace el resto y lanza los dos 409 que el panel distingue:
   * la oferta no esta `activa`, o ya esta en modo venta relampago (un
   * segundo clic no puede volver a sembrar: borraria las reservas vivas).
   *
   * Tambien rechaza con 409 si la oferta tiene una regla de descuento
   * automatico o por periodo activa (`exigirSinOtroMecanismoActivo()`) --
   * los cuatro mecanismos de descuento/venta relampago son mutuamente
   * excluyentes, salvo descuento+venta relampago manuales entre si (la
   * linea de arriba ya lo exige).
   *
   * `mecanismo` (agregado 2026-09-24, opcional, por defecto
   * `'venta_relampago_manual'`): con que identidad se presenta esta
   * activacion. Cuando es una regla (no `'venta_relampago_manual'`), el
   * chequeo de exclusion mutua se SALTA por completo -- se asume que ya lo
   * validaron el `aplicarDescuento(..., mecanismo)` que la misma regla
   * llamo un instante antes (`DisparadorReglasPeriodoService.aplicarEfecto()`
   * siempre hace descuento-y-luego-relampago para la misma regla, nunca al
   * reves). Si no se saltara, este chequeo veria el `porcentaje_descuento`
   * que la propia regla ACABA de poner como si fuera "un descuento manual
   * activo" y se rechazaria a si misma.
   */
  async abrir(
    idOfertaParametro: string,
    idUsuarioToken: string,
    idRolUsuario: number,
    datos: AbrirVentaLimitadaPeticion,
    mecanismo: MecanismoDescuento = 'venta_relampago_manual',
  ): Promise<VentaLimitadaAbierta> {
    const idOferta = this.validarIdOferta(idOfertaParametro);
    const duracion = validarDuracionVencimiento(datos.duracion_segundos);

    const fila = await this.exigirOfertaPropia(
      idOferta,
      idUsuarioToken,
      idRolUsuario,
    );
    if (fila.porcentaje_descuento == null) {
      throw new ErrorConflicto(
        `La oferta ${idOferta} necesita un descuento activo antes de abrir una venta relampago: aplicalo primero`,
      );
    }
    if (mecanismo === 'venta_relampago_manual') {
      await exigirSinOtroMecanismoActivo(
        this.logger,
        pool,
        idOferta,
        mecanismo,
      );
    }

    const { stock_sembrado } = await this.inventarioLimitadoService.activar(
      idOferta,
      duracion,
    );
    await this.registroOfertasRedis.sincronizar(idOferta);

    return { id_oferta: String(idOferta), stock_sembrado };
  }

  /**
   * Cierra la venta relampago: `revertir()` apaga la columna y borra las
   * dos claves de Redis de la oferta. Rechaza con 409 si la oferta no
   * estaba en una venta relampago (el panel no deberia ofrecer el boton
   * "Cerrar" en ese caso, pero se comprueba igual).
   *
   * OJO: `revertir` NO confirma las reservas que hubiera en curso -- lo que
   * de verdad quedo vendido solo se sabe con `confirmar` por ticket, y eso
   * es el flujo del checkout. Por ahora cerrar una venta con reservas
   * vivas las descarta; sirve para cerrar una venta tranquila o deshacer
   * una prueba, no para cortar en seco una que esta caliente.
   */
  async cerrar(
    idOfertaParametro: string,
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<void> {
    const idOferta = this.validarIdOferta(idOfertaParametro);

    const fila = await this.exigirOfertaPropia(
      idOferta,
      idUsuarioToken,
      idRolUsuario,
    );

    if (!fila.es_inventario_limitado) {
      throw new ErrorConflicto(
        `La oferta ${idOferta} no esta en una venta relampago`,
      );
    }

    await this.inventarioLimitadoService.revertir(idOferta);
    await this.registroOfertasRedis.sincronizar(idOferta);
  }

  // ---------------------------------------------------------------------
  // Apagar sola la marca de las que vencieron sin que nadie las cerrara
  // ---------------------------------------------------------------------

  /** Cada cuanto se revisan las ofertas marcadas en venta limitada. */
  private static readonly INTERVALO_REVISION_VENCIDAS_MS = 60000;

  /** `true` mientras una revision esta en curso: la siguiente se salta. */
  private revisandoVencidas = false;

  /**
   * Cuando una venta relampago tiene `duracion_segundos`, `activar()` guarda
   * el mismo vencimiento por partida doble: un `EXPIRE` en Redis sobre
   * `mesh:oferta:<id>` (lo que de verdad usa el checkout para saber si la
   * venta sigue viva) y `oferta.fecha_vencimiento_venta_limitada` en
   * Postgres (lo que usa ESTA revision para decidir si ya vencio).
   *
   * **Bug corregido (2026-09-27): antes esta revision le preguntaba a
   * Redis** (`existeVentaLimitada()`, un `EXISTS`) si la clave seguia ahi --
   * y Redis no distingue "vencio de verdad" de "se perdio" (un `FLUSHALL`,
   * un volumen borrado). Una venta relampago SIN vencimiento propio
   * tambien tiene su clave en Redis (solo que sin TTL); si Redis se
   * vaciaba, esa clave desaparecia igual que una que si vencio, y esta
   * revision la apagaba en Postgres PARA SIEMPRE, sin que nadie lo pidiera.
   * Detalle completo del bug y la decision de arreglarlo asi en
   * `plan pendiente/vencimiento-automatico-oferta.md`.
   *
   * **Ahora esta revision ya NO toca Redis para decidir**: la consulta de
   * `revisarVentasLimitadasVencidas()` filtra directo por
   * `fecha_vencimiento_venta_limitada <= now()`, asi que cada fila que
   * llega aca ya vencio de verdad segun Postgres, sin importar que haya
   * pasado en Redis. Una venta relampago PERMANENTE
   * (`fecha_vencimiento_venta_limitada IS NULL`) ni siquiera entra en la
   * consulta -- nunca se apaga sola, pase lo que pase en Redis.
   *
   * Fuera de alcance a proposito: si la venta vencio segun Postgres pero su
   * clave de Redis (el contador de stock del checkout) sigue viva por algun
   * motivo, esta revision no la borra a mano -- las dos se sembraron con el
   * MISMO `ttlSegundos` en `activar()`, asi que para cuando este worker
   * (cada minuto) nota el vencimiento en Postgres, el `EXPIRE` de Redis ya
   * paso tambien en la enorme mayoria de los casos; tampoco se intenta
   * revivir una clave de Redis que se haya perdido -- eso es un problema
   * aparte (que stock resembrar, que las reservas en curso se pierden si o
   * si), decision del usuario dejarlo fuera de esta ronda.
   *
   * **Bug corregido (2026-09-24, sigue vigente):** cuando una venta vence,
   * ademas de apagar `es_inventario_limitado` tambien se quita el
   * `porcentaje_descuento` -- si no, quedaba pegado para siempre
   * (`revertir()` no lo toca; `quitarDescuento()` de `OfertasVendedorService`
   * ni siquiera se puede llamar mientras `es_inventario_limitado` sigue en
   * `true`). Recalcula tambien los campos calculados de Mongo
   * (`hay_descuento`/`precio_tienda`/`precio_desde`) para las ofertas que
   * toco.
   *
   * Cada minuto, este `@Interval` (mismo mecanismo que el worker del outbox
   * del grafo, `GrafoSyncService`). No relanza si algo falla: es
   * mantenimiento, no debe tumbar nada del resto de la app.
   *
   * Vive aca (y no en `InventarioLimitadoService`, donde vivia antes del
   * arreglo del 2026-09-24) porque necesita `ProductosService` para el
   * recalculo de Mongo, y `ProductosService` ya inyecta
   * `InventarioLimitadoService` (para `estado()` en la ficha) -- ponerlo
   * alla habria sido una dependencia circular.
   */
  @Interval(
    'inventario-limitado-vencidas',
    VentasLimitadasService.INTERVALO_REVISION_VENCIDAS_MS,
  )
  async revisarVencidas(): Promise<void> {
    if (this.revisandoVencidas) {
      return;
    }
    this.revisandoVencidas = true;
    try {
      await this.revisarVentasLimitadasVencidas();
      await this.revisarDescuentosVencidos();
    } finally {
      this.revisandoVencidas = false;
    }
  }

  private async revisarVentasLimitadasVencidas(): Promise<void> {
    let filas: { id_oferta: number; id_producto_mongo: string }[];
    try {
      const resultado = await pool.query<{
        id_oferta: number;
        id_producto_mongo: string;
      }>(
        `SELECT id_oferta, id_producto_mongo FROM oferta
          WHERE es_inventario_limitado = true
            AND fecha_vencimiento_venta_limitada IS NOT NULL
            AND fecha_vencimiento_venta_limitada <= now()`,
      );
      filas = resultado.rows;
    } catch (error) {
      this.logger.warn(
        `revision de ventas limitadas vencidas: no se pudo leer Postgres (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    let apagadas = 0;
    // Resuelto una sola vez por corrida, y solo si de verdad hay algo que
    // apagar -- ver apagarVentaLimitadaVencida() para el porque.
    let idTienda: string | null = null;
    for (const fila of filas) {
      try {
        idTienda ??= await this.obtenerIdTienda();
        await this.apagarVentaLimitadaVencida(fila.id_oferta, idTienda);
        apagadas++;
        // sincronizar() nunca lanza (ver registro-ofertas-redis.service.ts)
        // -- un problema de Redis aca no debe tumbar esta revision, que ya
        // logro lo que le importa (apagar las columnas en Postgres). Si
        // falla, el worker de reconciliacion (RegistroOfertasSyncService)
        // lo corrige en su proxima corrida.
        await this.registroOfertasRedis.sincronizar(fila.id_oferta);
      } catch (error) {
        this.logger.warn(
          `revision de ventas limitadas vencidas: no se pudo apagar la oferta ${fila.id_oferta} (${(error as Error)?.message ?? error})`,
        );
      }
    }
    if (apagadas > 0) {
      this.logger.log(
        `revision de ventas limitadas vencidas: ${apagadas} oferta(s) apagada(s) y su descuento quitado (vencieron solas)`,
      );
    }
  }

  /**
   * (Agregado 2026-09-25) El `UPDATE` real de `revisarVentasLimitadasVencidas()`,
   * en su propia transaccion -- `set_config('mesh.id_usuario', ..., true)`
   * (el equivalente parametrizado de `SET LOCAL`) solo dura mientras dura
   * la transaccion que lo puso, así que no sirve de nada fuera de un
   * `BEGIN`/`COMMIT`. Pone `mesh.id_usuario` en el id de la TIENDA antes
   * del `UPDATE` para que `trg_oferta_registrar_precio`
   * (`005_ofertas.sql`/`020_descuentos_oferta.sql`) atribuya la fila nueva
   * de `precio_historial` a la tienda, no al dueño de la oferta -- sin
   * esto, quien apaga la venta relampago es este worker, pero
   * `precio_historial.id_usuario_modifico` quedaba con el vendedor, como si
   * el la hubiera cerrado el mismo (bug de atribucion, corregido aca).
   */
  private async apagarVentaLimitadaVencida(
    idOferta: number,
    idTienda: string,
  ): Promise<void> {
    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');
      await cliente.query('SELECT set_config($1, $2, true)', [
        'mesh.id_usuario',
        idTienda,
      ]);
      await cliente.query(
        `UPDATE oferta
            SET es_inventario_limitado = false,
                porcentaje_descuento = NULL,
                fecha_vencimiento_venta_limitada = NULL,
                fecha_vencimiento_descuento = NULL
          WHERE id_oferta = $1 AND es_inventario_limitado = true`,
        [idOferta],
      );
      // La venta cerro sola: sus reservas activas se devuelven en la misma
      // transaccion (ver devolverReservasDeOferta). Las claves de Redis
      // vencen solas con el mismo plazo.
      const usuarios = await devolverReservasDeOferta(cliente, idOferta);
      await cliente.query('COMMIT');
      await this.inventarioLimitadoService.soltarTicketsDeCarritos(
        idOferta,
        usuarios,
      );
    } catch (error) {
      await this.intentarRollback(cliente);
      throw error;
    } finally {
      cliente.release();
    }
  }

  /**
   * (Agregado 2026-09-24) El mismo proposito que
   * `revisarVentasLimitadasVencidas()`, pero para el descuento MANUAL puro
   * (`POST .../descuento`, sin venta relampago) cuando se aplico con
   * `duracion_segundos`. Puramente interno -- el cliente nunca ve nada de
   * este vencimiento, solo el resultado (el descuento desaparece solo).
   *
   * **Bug corregido (2026-09-27):** hasta el 2026-09-26 esta revision
   * miraba si `claveDescuento(idOferta)` seguia viva en Redis -- y un
   * descuento SIN vencimiento (`duracion_segundos: 0`) tambien tenia esa
   * clave, solo que sin TTL. Si Redis se vaciaba (un `FLUSHALL`, un
   * volumen borrado), la clave desaparecia igual que si hubiera vencido de
   * verdad, y esta revision quitaba el descuento PERMANENTE para siempre,
   * sin que nadie lo pidiera. Detalle completo en
   * `plan pendiente/vencimiento-automatico-oferta.md`.
   *
   * Ahora la consulta de abajo filtra directo por
   * `fecha_vencimiento_descuento <= now()` en Postgres -- ya no se le
   * pregunta nada a Redis, y esa clave de Redis (`mesh:oferta:<id>:descuento`)
   * dejo de sembrarse/leerse por completo: nada mas la usaba. Un descuento
   * permanente (`fecha_vencimiento_descuento IS NULL`) ni siquiera entra en
   * la consulta -- nunca se quita solo.
   *
   * Solo mira las ofertas que NO estan en venta relampago (esas ya las
   * cubre `revisarVentasLimitadasVencidas()`, que tiene su propia columna,
   * `fecha_vencimiento_venta_limitada`).
   */
  private async revisarDescuentosVencidos(): Promise<void> {
    let filas: { id_oferta: number; id_producto_mongo: string }[];
    try {
      const resultado = await pool.query<{
        id_oferta: number;
        id_producto_mongo: string;
      }>(
        `SELECT id_oferta, id_producto_mongo FROM oferta
          WHERE porcentaje_descuento IS NOT NULL
            AND es_inventario_limitado = false
            AND fecha_vencimiento_descuento IS NOT NULL
            AND fecha_vencimiento_descuento <= now()`,
      );
      filas = resultado.rows;
    } catch (error) {
      this.logger.warn(
        `revision de descuentos vencidos: no se pudo leer Postgres (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    let quitados = 0;
    // Resuelto una sola vez por corrida, y solo si de verdad hay algo que
    // quitar -- ver quitarDescuentoVencido() para el porque.
    let idTienda: string | null = null;
    for (const fila of filas) {
      try {
        idTienda ??= await this.obtenerIdTienda();
        await this.quitarDescuentoVencido(fila.id_oferta, idTienda);
        quitados++;
        await this.registroOfertasRedis.sincronizar(fila.id_oferta);
      } catch (error) {
        this.logger.warn(
          `revision de descuentos vencidos: no se pudo quitar el descuento de la oferta ${fila.id_oferta} (${(error as Error)?.message ?? error})`,
        );
      }
    }
    if (quitados > 0) {
      this.logger.log(
        `revision de descuentos vencidos: ${quitados} descuento(s) quitado(s) (vencieron solos)`,
      );
    }
  }

  /** (Agregado 2026-09-25) Mismo motivo y mismo patron que `apagarVentaLimitadaVencida()`. */
  private async quitarDescuentoVencido(
    idOferta: number,
    idTienda: string,
  ): Promise<void> {
    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');
      await cliente.query('SELECT set_config($1, $2, true)', [
        'mesh.id_usuario',
        idTienda,
      ]);
      await cliente.query(
        `UPDATE oferta
            SET porcentaje_descuento = NULL, fecha_vencimiento_descuento = NULL
          WHERE id_oferta = $1 AND porcentaje_descuento IS NOT NULL`,
        [idOferta],
      );
      await cliente.query('COMMIT');
    } catch (error) {
      await this.intentarRollback(cliente);
      throw error;
    } finally {
      cliente.release();
    }
  }

  // ---------------------------------------------------------------------
  // Privados
  // ---------------------------------------------------------------------

  private validarIdOferta(valor: string): number {
    if (!REGEX_ID.test(valor)) {
      throw new ErrorValidacion('El id no es valido');
    }
    return Number(valor);
  }

  /**
   * La oferta tiene que ser del vendedor que la toca. Un admin actua como
   * la cuenta de la tienda (mismo criterio que `OfertasVendedorService`).
   * Una oferta ajena o inexistente da el MISMO 404 generico que usa el
   * resto del panel -- nunca se confirma que exista.
   *
   * Devuelve la marca `es_inventario_limitado` (que `cerrar()` necesita) y
   * `porcentaje_descuento` (que `abrir()` necesita).
   */
  private async exigirOfertaPropia(
    idOferta: number,
    idUsuarioToken: string,
    idRolUsuario: number,
  ): Promise<{
    es_inventario_limitado: boolean;
    porcentaje_descuento: string | null;
  }> {
    try {
      const idDueno =
        idRolUsuario === ID_ROL_ADMIN
          ? await this.obtenerIdTienda()
          : idUsuarioToken;

      const resultado = await pool.query<{
        es_inventario_limitado: boolean;
        porcentaje_descuento: string | null;
      }>(
        `SELECT o.es_inventario_limitado, o.porcentaje_descuento
           FROM oferta o
          WHERE o.id_oferta = $1 AND o.id_usuario = $2`,
        [idOferta, idDueno],
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

  /**
   * El id_usuario real de la cuenta de la tienda (tienda@mesh.com),
   * resuelto por correo -- nunca por un id fijo. Si no existe (no deberia:
   * es parte de los datos base) falla fuerte.
   */
  private async obtenerIdTienda(): Promise<string> {
    try {
      const resultado = await pool.query<{ id_usuario: string }>(
        'SELECT id_usuario FROM usuarios WHERE correo_electronico = $1',
        [CORREO_TIENDA],
      );
      const fila = resultado.rows[0];
      if (fila == null) {
        throw new Error('No existe la cuenta de la tienda (tienda@mesh.com)');
      }
      return fila.id_usuario;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private async intentarRollback(cliente: PoolClient): Promise<void> {
    try {
      await cliente.query('ROLLBACK');
    } catch {
      // Si ni el rollback funciona, la conexion seguramente ya se cayo.
    }
  }
}
