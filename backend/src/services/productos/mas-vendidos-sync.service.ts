import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { Decimal128 } from 'mongodb';
import { clickhouse } from '../../database/clickhouse';
import { redis } from '../../database/redis';
import { mongoDb } from '../../database/mongo';
import { ESTADO_PRODUCTO_VISIBLE } from '../../models/estado-producto';
import { Producto } from '../../models/producto';

/**
 * La version acotada de un producto que cachea este worker y lee
 * `MasVendidosService`: solo los campos que una tarjeta de "mas vendidos"
 * pinta -- nombre, una imagen representativa, precio, si tiene descuento,
 * calificacion y si sigue con existencias. Sin `variantes[]`, sin
 * `categoria`, sin `caracteristicas_adicionales`/`caracteristicas_personalizadas`:
 * esta vitrina nunca necesita mostrar eso (ver el comentario de la clase).
 */
export interface ProductoTarjetaMasVendido {
  _id: number;
  nombre: string;
  /** La primera imagen de la primera variante, o `null` si no tiene ninguna. */
  imagen: string | null;
  precio_tienda: Decimal128 | null;
  precio_desde: Decimal128 | null;
  hay_descuento: boolean;
  resenas_promedio: number;
  resenas_total: number;
  /** Unidades activas entre todos los vendedores. `0` = agotado en todos lados. */
  stock_total: number;
}

/** Forma cruda que devuelve la proyeccion de Mongo, antes de aplanar la imagen. */
interface FilaProductoProyectado {
  _id: number;
  nombre: string;
  precio_tienda: Decimal128 | null;
  precio_desde: Decimal128 | null;
  hay_descuento: boolean;
  resenas_promedio: number;
  resenas_total: number;
  stock_total: number;
  variantes: { imagenes: string[] }[];
}

/**
 * Worker que recalcula el ranking de "productos mas vendidos" a partir de
 * `compra_producto` (ClickHouse) y lo deja listo en Redis para lectura
 * rapida -- sin este worker, cada consulta tendria que agregar el evento en
 * vivo contra ClickHouse (y antes del 2026-09-23, tambien traer el detalle
 * en vivo desde Mongo) en vez de leer un resultado ya calculado.
 *
 * Ventana: ultimas 24 horas. Si no hubo NINGUNA compra en ese lapso (un
 * bache normal de trafico, no un error), cae a los ultimos 7 dias para no
 * dejar el ranking en blanco por algo tan corto. Si tampoco hay nada en 7
 * dias, Redis NO se toca -- se deja el ultimo calculo valido (aunque ya
 * este viejo) en vez de vaciarlo; mostrar algo desactualizado es mejor que
 * no mostrar nada.
 *
 * Solo cuenta `lote = 'real'` -- nunca mezcla con datos sembrados
 * (`lote = 'generado-<semilla>'`), sin excepcion ni parametro para pedir lo
 * contrario: un ranking de "mas vendidos" con ventas inventadas mostraria
 * un numero que nadie midio de verdad.
 *
 * Guarda mas productos de los que el catalogo va a mostrar
 * (`TOPE_ALMACENADO`): si mañana cambia cuantos se pintan en la pagina, no
 * hace falta tocar este worker ni la consulta a ClickHouse, solo el
 * `ZREVRANGE`/`HMGET` que lo lee.
 *
 * **Detalle de cada producto (2026-09-23):** ademas del ZSET con el
 * ranking, este worker consulta Mongo UNA vez por corrida (no en cada
 * request) y guarda el documento de cada producto ganador en un HASH --
 * mismo principio que se aplico al carrito: `GET /productos/mas-vendidos`
 * ya no toca Mongo, lee las dos estructuras de Redis y ya. Solo se cachean
 * productos `activo` (mismo filtro de visibilidad que el resto del
 * catalogo publico), asi que uno que se desactive a mitad de los 10
 * minutos puede seguir apareciendo hasta la proxima corrida -- antes esa
 * comprobacion era en vivo, en cada `GET`.
 *
 * **Version acotada, no el documento completo (2026-09-23):** esta vitrina
 * solo pinta una tarjeta (foto, nombre, precio, calificacion) -- no hace
 * falta el arreglo `variantes[]` entero (con precio/stock/caracteristicas
 * por variante) ni `caracteristicas_adicionales`/`caracteristicas_personalizadas`,
 * que es la mayor parte del peso de un documento `Producto`. Por eso la
 * consulta a Mongo pide una proyeccion (`ProductoTarjetaMasVendido`, mas
 * abajo) en vez de traer el documento entero: menos bytes en el HASH de
 * Redis y en la respuesta HTTP de `GET /productos/mas-vendidos`, que
 * ademas es la ruta de vitrina/home, la mas visitada del catalogo publico.
 * Distinto del resto de rutas de listado (`GET /productos`,
 * `GET /productos/:id`), que si devuelven el documento completo -- aqui se
 * justifica el recorte porque esta vitrina nunca necesita mostrar
 * variantes.
 *
 * El reemplazo de las dos estructuras es atomico: se arman en una llave
 * temporal cada una y se publican con `RENAME` (atomico en Redis), para
 * que nadie lea el ranking o el detalle a medio reconstruir.
 *
 * Mismo patron que `BuscadorSyncService`/`GrafoSyncService`: `@Interval`
 * con una bandera para que una corrida lenta no se pise con la siguiente,
 * y nunca lanza -- un fallo de ClickHouse, Mongo o Redis se loguea y se
 * reintenta en la proxima corrida, sin tumbar nada mas.
 */
@Injectable()
export class MasVendidosSyncService {
  private readonly logger = new Logger(MasVendidosSyncService.name);

  static readonly CLAVE_RANKING = 'mesh:productos:mas_vendidos';
  private static readonly CLAVE_TEMPORAL = `${MasVendidosSyncService.CLAVE_RANKING}:tmp`;

  /** HASH `{ id_producto: <ProductoTarjetaMasVendido en JSON> }`. */
  static readonly CLAVE_DETALLE = 'mesh:productos:mas_vendidos:detalle';
  private static readonly CLAVE_DETALLE_TEMPORAL = `${MasVendidosSyncService.CLAVE_DETALLE}:tmp`;

  private static readonly INTERVALO_MS = 10 * 60 * 1000; // 10 minutos

  /** Cuantos productos guarda el ZSET -- mas de los que se van a mostrar. */
  private static readonly TOPE_ALMACENADO = 20;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  @Interval('mas-vendidos-sync', MasVendidosSyncService.INTERVALO_MS)
  async recalcular(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      let filas = await this.consultarVentana(24, 'HOUR');
      let ventana = 'ultimas 24h';

      if (filas.length === 0) {
        filas = await this.consultarVentana(7, 'DAY');
        ventana = 'ultimos 7 dias (sin compras en 24h)';
      }

      if (filas.length === 0) {
        this.logger.log(
          'worker de mas vendidos: sin compras en 24h ni en 7 dias -- se deja el ranking anterior tal cual',
        );
        return;
      }

      const ids = filas.map((fila) => Number(fila.id_producto));
      const productos = await this.consultarProductosMongo(ids);

      await this.reemplazarRanking(filas);
      await this.reemplazarDetalle(productos);
      this.logger.log(
        `worker de mas vendidos: ranking recalculado con ${filas.length} producto(s) (${ventana}), ${productos.length} con detalle cacheado`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de mas vendidos: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /**
   * Agrega `compra_producto` de los ultimos `cantidad` `unidad` hacia atras.
   * `unidad` nunca sale del cliente -- son las dos constantes literales que
   * llama `recalcular()` -- asi que interpolarla en el `INTERVAL` es segura,
   * mismo criterio que `direccion` en `AdminTendenciasService.consultarRanking`.
   */
  private async consultarVentana(
    cantidad: number,
    unidad: 'HOUR' | 'DAY',
  ): Promise<FilaRankingClickHouse[]> {
    const resultado = await clickhouse.query({
      query: `SELECT id_producto, sum(cantidad) AS total
                FROM compra_producto
               WHERE fecha >= now() - INTERVAL {cantidad:UInt32} ${unidad}
                 AND lote = 'real'
               GROUP BY id_producto
               ORDER BY total DESC
               LIMIT {tope:UInt32}`,
      query_params: { cantidad, tope: MasVendidosSyncService.TOPE_ALMACENADO },
      format: 'JSONEachRow',
    });
    return resultado.json<FilaRankingClickHouse>();
  }

  /**
   * `total` es un `UInt64` (ClickHouse promueve `sum(UInt32)` a 64 bits) y
   * por eso llega como STRING -- mismo motivo que `id_producto`/`id_oferta`
   * en `models/evento-clickhouse.ts`. Se convierte a `number` recien aqui,
   * al armar el score para Redis.
   */
  private async reemplazarRanking(
    filas: FilaRankingClickHouse[],
  ): Promise<void> {
    const paresScoreMiembro: (string | number)[] = [];
    for (const fila of filas) {
      paresScoreMiembro.push(Number(fila.total), fila.id_producto);
    }

    await redis.del(MasVendidosSyncService.CLAVE_TEMPORAL);
    await redis.zadd(
      MasVendidosSyncService.CLAVE_TEMPORAL,
      ...paresScoreMiembro,
    );
    await redis.rename(
      MasVendidosSyncService.CLAVE_TEMPORAL,
      MasVendidosSyncService.CLAVE_RANKING,
    );
  }

  /**
   * La version acotada (`ProductoTarjetaMasVendido`) de cada producto
   * ganador -- no el documento completo (ver el comentario de la clase).
   * La proyeccion pide solo los campos de la tarjeta, mas
   * `variantes.imagenes` (Mongo no deja combinar un `$slice` sobre
   * `variantes` con una subruta de esa misma proyeccion en un `find` --
   * "path collision" -- asi que vienen las imagenes de TODAS las variantes,
   * cada una sin el resto de sus campos, y en JS se toma solo la primera
   * imagen de la primera variante); el resto de cada variante (precio,
   * stock, caracteristicas) nunca viaja desde Mongo. Solo `activo`: un
   * producto que se desactivo no debe quedar cacheado como si se pudiera
   * mostrar (ver el comentario de la clase sobre la ventana de hasta 10 min
   * que esto abre).
   */
  private async consultarProductosMongo(
    ids: number[],
  ): Promise<ProductoTarjetaMasVendido[]> {
    const filas = await mongoDb
      .collection<Producto>('productos')
      .find<FilaProductoProyectado>(
        { _id: { $in: ids }, estado: ESTADO_PRODUCTO_VISIBLE },
        {
          projection: {
            _id: 1,
            nombre: 1,
            precio_tienda: 1,
            precio_desde: 1,
            hay_descuento: 1,
            resenas_promedio: 1,
            resenas_total: 1,
            stock_total: 1,
            'variantes.imagenes': 1,
          },
        },
      )
      .toArray();

    return filas.map((fila) => ({
      _id: fila._id,
      nombre: fila.nombre,
      imagen: fila.variantes[0]?.imagenes[0] ?? null,
      precio_tienda: fila.precio_tienda,
      precio_desde: fila.precio_desde,
      hay_descuento: fila.hay_descuento,
      resenas_promedio: fila.resenas_promedio,
      resenas_total: fila.resenas_total,
      stock_total: fila.stock_total,
    }));
  }

  /**
   * Reemplazo atomico del HASH de detalle -- mismo patron `RENAME` que
   * `reemplazarRanking`. Si ningun producto del ranking quedo `activo`
   * (caso raro: los mas vendidos son justo los que se desactivaron), no hay
   * nada que renombrar -- se borra la clave directo en vez de armar un
   * `RENAME` sobre una clave temporal vacia (Redis lo rechaza).
   */
  private async reemplazarDetalle(
    productos: ProductoTarjetaMasVendido[],
  ): Promise<void> {
    if (productos.length === 0) {
      await redis.del(MasVendidosSyncService.CLAVE_DETALLE);
      return;
    }

    const camposValores: string[] = [];
    for (const producto of productos) {
      camposValores.push(String(producto._id), JSON.stringify(producto));
    }

    await redis.del(MasVendidosSyncService.CLAVE_DETALLE_TEMPORAL);
    await redis.hset(
      MasVendidosSyncService.CLAVE_DETALLE_TEMPORAL,
      ...camposValores,
    );
    await redis.rename(
      MasVendidosSyncService.CLAVE_DETALLE_TEMPORAL,
      MasVendidosSyncService.CLAVE_DETALLE,
    );
  }
}

interface FilaRankingClickHouse {
  id_producto: string;
  total: string;
}

/** Un mensaje de error corto para el log. */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
