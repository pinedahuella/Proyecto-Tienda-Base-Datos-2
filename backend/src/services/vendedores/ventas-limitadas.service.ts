import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { redis } from '../../database/redis';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { CORREO_TIENDA } from '../../helpers/constantes';
import { validarDuracionVencimiento } from '../../helpers/validaciones-oferta';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { InventarioLimitadoService } from '../inventario-limitado/inventario-limitado.service';
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
        `La oferta ${idOferta} necesita un descuento activo antes de abrir una venta relampago: aplicalo primero con POST /vendedor/ofertas/${idOferta}/descuento`,
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
   * Cuando una venta relampago tiene `duracion_segundos`, Redis le pone un
   * `EXPIRE` a `mesh:oferta:<id>` (y `redis/inventario_limitado.lua`
   * sincroniza el de su ZSET de reservas con el mismo TTL) -- al vencer,
   * las dos claves desaparecen SOLAS, sin avisarle a nadie.
   *
   * **Bug corregido (2026-09-24):** hasta ahora, cuando eso pasaba, solo se
   * apagaba `oferta.es_inventario_limitado` -- `porcentaje_descuento`
   * quedaba pegado para siempre, porque nada mas lo tocaba (`revertir()`
   * tampoco lo toca; `quitarDescuento()` de `OfertasVendedorService` ni
   * siquiera se puede llamar mientras `es_inventario_limitado` sigue en
   * `true`). Una venta relampago que vencia sola dejaba el descuento activo
   * de manera permanente, sin que el panel del vendedor lo mostrara como
   * "en venta relampago" pero tampoco como "sin descuento". Ahora esta
   * revision apaga las dos columnas EN LA MISMA sentencia y recalcula los
   * campos calculados de Mongo (`hay_descuento`/`precio_tienda`/
   * `precio_desde`) para las ofertas que toco, igual que
   * `OfertasVendedorService.quitarDescuento()`.
   *
   * Cada minuto, este `@Interval` (mismo mecanismo que el worker del outbox
   * del grafo, `GrafoSyncService`) revisa las ofertas marcadas y, para cada
   * una, reusa `InventarioLimitadoService.existeVentaLimitada()` (un
   * `EXISTS` de Redis, sin tocar nada). Si la clave ya no existe, apaga las
   * dos columnas. Nunca borra nada en Redis -- si vencio sola, las dos
   * claves ya se fueron solas; si la revirtieron por `DELETE`, tambien. No
   * relanza si algo falla: es mantenimiento, no debe tumbar nada del resto
   * de la app.
   *
   * Vive aca (y no en `InventarioLimitadoService`, donde vivia antes de
   * este arreglo) porque necesita `ProductosService` para el recalculo de
   * Mongo, y `ProductosService` ya inyecta `InventarioLimitadoService`
   * (para `estado()` en la ficha) -- ponerlo alla habria sido una
   * dependencia circular.
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
        'SELECT id_oferta, id_producto_mongo FROM oferta WHERE es_inventario_limitado = true',
      );
      filas = resultado.rows;
    } catch (error) {
      this.logger.warn(
        `revision de ventas limitadas vencidas: no se pudo leer Postgres (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    let apagadas = 0;
    const idsProductoMongoTocados: number[] = [];
    for (const fila of filas) {
      let sigueViva: boolean;
      try {
        sigueViva = await this.inventarioLimitadoService.existeVentaLimitada(
          fila.id_oferta,
        );
      } catch (error) {
        this.logger.warn(
          `revision de ventas limitadas vencidas: no se pudo leer Redis para la oferta ${fila.id_oferta} (${(error as Error)?.message ?? error})`,
        );
        continue;
      }
      if (sigueViva) {
        continue;
      }
      try {
        await pool.query(
          `UPDATE oferta
              SET es_inventario_limitado = false, porcentaje_descuento = NULL
            WHERE id_oferta = $1 AND es_inventario_limitado = true`,
          [fila.id_oferta],
        );
        apagadas++;
        idsProductoMongoTocados.push(Number(fila.id_producto_mongo));
        // La clave del TTL del DESCUENTO (ver revisarDescuentosVencidos())
        // tambien se borra aca -- si no, un descuento sin vencimiento propio
        // (duracion_segundos: 0, la clave nunca expira sola) que quedo
        // debajo de esta venta relampago se quedaria en Redis para siempre,
        // sin que nada la borre nunca (la oferta ya no entra en la consulta
        // de abajo porque porcentaje_descuento acaba de quedar NULL).
        this.borrarClaveDescuentoSinLanzar(fila.id_oferta);
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
    if (idsProductoMongoTocados.length > 0) {
      try {
        await this.productosService.recalcularCamposCalculados(
          idsProductoMongoTocados,
        );
      } catch (error) {
        this.logger.warn(
          `revision de ventas limitadas vencidas: no se pudo recalcular Mongo (${(error as Error)?.message ?? error})`,
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
   * (Agregado 2026-09-24) El mismo mecanismo que
   * `revisarVentasLimitadasVencidas()`, pero para el descuento MANUAL puro
   * (`POST .../descuento`, sin venta relampago) cuando se aplico con
   * `duracion_segundos`. Es puramente interno -- el cliente nunca ve nada
   * de este TTL, solo el resultado (el descuento desaparece solo).
   *
   * `OfertasVendedorService.aplicarDescuento()` siempre siembra
   * `claveDescuento(idOferta)` al aplicar un descuento (con `EXPIRE` si
   * `duracion_segundos > 0`, sin el si es `0` -- igual que
   * `InventarioLimitadoService.activar()` hace con su propia clave), y la
   * borra en `quitarDescuento()`. Esta revision solo mira las ofertas con
   * `porcentaje_descuento` puesto que NO estan en venta relampago (esas ya
   * las cubre `revisarVentasLimitadasVencidas()`); si la clave ya no
   * existe, el descuento vencio y se quita.
   *
   * Limitacion conocida y aceptada: un descuento puesto por fuera de esta
   * ruta (a mano en Postgres, sin pasar por `aplicarDescuento()`) nunca
   * tuvo esta clave sembrada, asi que el `EXISTS` de abajo daria `false` y
   * esta revision lo quitaria en el proximo tick. No aplica a nada de lo
   * que hoy existe en la base (ningun descuento activo se creo asi), pero
   * queda anotado por si algun dia se siembra un descuento directo por SQL.
   */
  private async revisarDescuentosVencidos(): Promise<void> {
    let filas: { id_oferta: number; id_producto_mongo: string }[];
    try {
      const resultado = await pool.query<{
        id_oferta: number;
        id_producto_mongo: string;
      }>(
        `SELECT id_oferta, id_producto_mongo FROM oferta
          WHERE porcentaje_descuento IS NOT NULL AND es_inventario_limitado = false`,
      );
      filas = resultado.rows;
    } catch (error) {
      this.logger.warn(
        `revision de descuentos vencidos: no se pudo leer Postgres (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    let quitados = 0;
    const idsProductoMongoTocados: number[] = [];
    for (const fila of filas) {
      let sigueVivo: boolean;
      try {
        sigueVivo =
          (await redis.exists(this.claveDescuento(fila.id_oferta))) === 1;
      } catch (error) {
        this.logger.warn(
          `revision de descuentos vencidos: no se pudo leer Redis para la oferta ${fila.id_oferta} (${(error as Error)?.message ?? error})`,
        );
        continue;
      }
      if (sigueVivo) {
        continue;
      }
      try {
        await pool.query(
          `UPDATE oferta SET porcentaje_descuento = NULL
            WHERE id_oferta = $1 AND porcentaje_descuento IS NOT NULL`,
          [fila.id_oferta],
        );
        quitados++;
        idsProductoMongoTocados.push(Number(fila.id_producto_mongo));
        await this.registroOfertasRedis.sincronizar(fila.id_oferta);
      } catch (error) {
        this.logger.warn(
          `revision de descuentos vencidos: no se pudo quitar el descuento de la oferta ${fila.id_oferta} (${(error as Error)?.message ?? error})`,
        );
      }
    }
    if (idsProductoMongoTocados.length > 0) {
      try {
        await this.productosService.recalcularCamposCalculados(
          idsProductoMongoTocados,
        );
      } catch (error) {
        this.logger.warn(
          `revision de descuentos vencidos: no se pudo recalcular Mongo (${(error as Error)?.message ?? error})`,
        );
      }
    }
    if (quitados > 0) {
      this.logger.log(
        `revision de descuentos vencidos: ${quitados} descuento(s) quitado(s) (vencieron solos)`,
      );
    }
  }

  private claveDescuento(idOferta: number): string {
    return `mesh:oferta:${idOferta}:descuento`;
  }

  private borrarClaveDescuentoSinLanzar(idOferta: number): void {
    redis.del(this.claveDescuento(idOferta)).catch((error: unknown) => {
      this.logger.warn(
        `no se pudo borrar la clave de TTL del descuento de la oferta ${idOferta} (${(error as Error)?.message ?? error})`,
      );
    });
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
}
