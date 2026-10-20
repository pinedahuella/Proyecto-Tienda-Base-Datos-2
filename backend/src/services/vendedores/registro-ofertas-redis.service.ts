import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { mongoDb } from '../../database/mongo';
import { redis } from '../../database/redis';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';
import { Producto } from '../../models/producto';

/**
 * Version representativa de una oferta con descuento, guardada en Redis --
 * mismo criterio de "tarjeta, no la fila cruda" que
 * `ProductoTarjetaMasVendido` (ver `mas-vendidos-sync.service.ts`): lo que
 * hace falta para pintarla (nombre, imagen, precio, vendedor), nada de
 * columnas internas de auditoria.
 */
export interface OfertaRegistroRedis {
  id_producto: number;
  id_producto_variante: number;
  nombre_producto: string;
  nombre_variante: string;
  /** La primera imagen de la variante, o `null` si no tiene ninguna. */
  imagen: string | null;
  /** El precio de LISTA, sin descuento. */
  precio: string;
  porcentaje_descuento: string;
  /** El precio que de verdad se cobra/muestra, con el descuento aplicado. */
  precio_final: string;
  vendedor_usuario: string;
  vendedor_nombre: string;
  stock: number;
}

/** Fila cruda de `oferta` + el vendedor (JOIN a `usuarios`), para armar `OfertaRegistroRedis`. */
interface FilaOfertaRegistro {
  precio: string;
  porcentaje_descuento: string | null;
  precio_final: string;
  stock: number;
  es_inventario_limitado: boolean;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  vendedor_usuario: string;
  vendedor_nombre: string;
}

/** Solo lo que hace falta de un producto para nombrar la oferta -- mismo `ProductoLigero` que ya usa `ofertas.service.ts`/`carrito.service.ts`. */
interface ProductoLigero {
  _id: number;
  nombre: string;
  variantes: {
    id_producto_variante: number;
    nombre_variante: string;
    imagenes: string[];
  }[];
}

/**
 * Mantiene dos HASH de Redis con las ofertas que tienen un descuento activo
 * ahora mismo, separadas por si estan o no en venta relampago -- pensado
 * como el registro que alimentaria una futura vitrina de "ofertas del dia" /
 * "ventas relampago activas", igual que `MasVendidosSyncService` alimenta la
 * de "mas vendidos".
 *
 *   mesh:ofertas:descuento         HASH { id_oferta: <OfertaRegistroRedis> }
 *   mesh:ofertas:venta_relampago   HASH { id_oferta: <OfertaRegistroRedis> }
 *
 * Un `HASH` (campo = id_oferta, valor = JSON) en vez de un `SET` de ids
 * sueltos: un campo de hash no puede duplicarse (mismo criterio de "nunca
 * duplicados" que un `SET`, `HSET` sobre un campo existente lo reemplaza en
 * vez de repetirlo) y de paso guarda el detalle representativo, no solo el
 * id -- mismo patron que `mesh:productos:mas_vendidos:detalle` y
 * `mesh:carrito:<id_usuario>`.
 *
 * Las dos llaves son mutuamente excluyentes: una oferta vive en una O LA
 * OTRA, nunca en las dos (una oferta en venta relampago siempre tiene
 * descuento -- ver `VentasLimitadasService.abrir` -- pero se cuenta ahi, no
 * en la de "solo descuento"). `sincronizar()` se encarga de que mover una
 * oferta de una a otra nunca la deje en las dos ni en ninguna a medias.
 *
 * Quien llama a `sincronizar()`:
 *   - Los 4 escritos que pueden cambiar `porcentaje_descuento` o
 *     `es_inventario_limitado`: `OfertasVendedorService.aplicarDescuento`/
 *     `quitarDescuento`, `VentasLimitadasService.abrir`/`cerrar` -- ahi
 *     mismo, justo despues de comitear la transaccion (los campos calculados
 *     de Mongo los recalcula aparte `EventoProductoSyncService`).
 *   - `RegistroOfertasSyncService` (worker), para reparar una oferta cuyo
 *     escrito reactivo se perdio.
 */
@Injectable()
export class RegistroOfertasRedisService {
  private readonly logger = new Logger(RegistroOfertasRedisService.name);

  static readonly CLAVE_DESCUENTO = 'mesh:ofertas:descuento';
  static readonly CLAVE_VENTA_RELAMPAGO = 'mesh:ofertas:venta_relampago';

  /**
   * Deja la oferta en el registro que le corresponde SEGUN SU ESTADO ACTUAL
   * en PostgreSQL -- nunca segun lo que el llamador cree que acaba de
   * cambiar, para que sea igual de correcta llamada despues de un escrito
   * reactivo o desde el worker de reconciliacion. Sin descuento: fuera de
   * las dos llaves. Con descuento y sin venta relampago: `CLAVE_DESCUENTO`.
   * En venta relampago: `CLAVE_VENTA_RELAMPAGO` (y se asegura de sacarla de
   * la otra, para que nunca quede en las dos a la vez).
   *
   * Nunca lanza: un fallo aca (Postgres, Mongo o Redis) no debe tumbar la
   * operacion de negocio que ya se comiteo -- se loguea como warning, y el
   * worker de reconciliacion la corrige en su proxima corrida.
   */
  async sincronizar(idOferta: number): Promise<void> {
    try {
      const fila = await this.consultarFila(idOferta);
      if (fila == null || fila.porcentaje_descuento == null) {
        await this.quitarDeAmbos(idOferta);
        return;
      }

      const datos = await this.construirDatos(fila, fila.porcentaje_descuento);
      const claveDestino = fila.es_inventario_limitado
        ? RegistroOfertasRedisService.CLAVE_VENTA_RELAMPAGO
        : RegistroOfertasRedisService.CLAVE_DESCUENTO;
      const claveOtra = fila.es_inventario_limitado
        ? RegistroOfertasRedisService.CLAVE_DESCUENTO
        : RegistroOfertasRedisService.CLAVE_VENTA_RELAMPAGO;

      await redis.hset(claveDestino, String(idOferta), JSON.stringify(datos));
      await redis.hdel(claveOtra, String(idOferta));
    } catch (error) {
      this.logger.warn(
        `no se pudo sincronizar el registro de Redis de la oferta ${idOferta} -- ${mensajeCorto(error)}`,
      );
    }
  }

  /**
   * Lo mismo que guarda una de las dos llaves, armado en el momento desde
   * PostgreSQL: las ofertas con descuento (o en venta relampago con descuento,
   * con `ventaRelampago`), con las mismas condiciones que
   * `RegistroOfertasSyncService.reconciliar()`. Los nombres y la imagen salen
   * de la copia del catalogo (`producto_catalogo` y `variante_catalogo`), no de
   * Mongo, asi que no necesita ninguna otra base.
   *
   * Es el respaldo de las vitrinas de la portada cuando Redis no esta
   * (`OfertasDestacadasService`, 2026-10-20). Las ofertas nacen en
   * PostgreSQL: el HASH de Redis es solo la copia ya armada.
   */
  async desdePostgres(
    ventaRelampago: boolean,
  ): Promise<(OfertaRegistroRedis & { id_oferta: number })[]> {
    const { rows } = await pool.query<
      FilaOfertaRegistro & {
        id_oferta: string;
        nombre_producto: string | null;
        nombre_variante: string | null;
        imagen: string | null;
      }
    >(
      `SELECT o.id_oferta, o.precio, o.porcentaje_descuento,
              ${expresionPrecioFinal('o')}::text AS precio_final,
              o.stock, o.es_inventario_limitado,
              o.id_producto_mongo, o.id_producto_variante_mongo,
              u.usuario AS vendedor_usuario,
              u.nombre || COALESCE(' ' || u.apellido, '') AS vendedor_nombre,
              pc.nombre AS nombre_producto,
              vc.nombre_variante, vc.imagen
         FROM oferta o
         JOIN usuarios u ON u.id_usuario = o.id_usuario
         LEFT JOIN producto_catalogo pc ON pc.id_producto_mongo = o.id_producto_mongo
         LEFT JOIN variante_catalogo vc
                ON vc.id_producto_mongo = o.id_producto_mongo
               AND vc.id_producto_variante_mongo = o.id_producto_variante_mongo
        WHERE o.porcentaje_descuento IS NOT NULL
          AND o.es_inventario_limitado = $1
        ORDER BY o.id_oferta`,
      [ventaRelampago],
    );
    return rows.map((fila) => ({
      id_oferta: Number(fila.id_oferta),
      id_producto: Number(fila.id_producto_mongo),
      id_producto_variante: Number(fila.id_producto_variante_mongo),
      nombre_producto: fila.nombre_producto ?? '(producto no encontrado)',
      nombre_variante: fila.nombre_variante ?? '(variante no encontrada)',
      imagen: fila.imagen,
      precio: fila.precio,
      porcentaje_descuento: fila.porcentaje_descuento!,
      precio_final: fila.precio_final,
      vendedor_usuario: fila.vendedor_usuario,
      vendedor_nombre: fila.vendedor_nombre,
      stock: fila.stock,
    }));
  }

  /** Quita la oferta de las dos llaves -- usado cuando ya no tiene descuento. */
  private async quitarDeAmbos(idOferta: number): Promise<void> {
    await redis.hdel(
      RegistroOfertasRedisService.CLAVE_DESCUENTO,
      String(idOferta),
    );
    await redis.hdel(
      RegistroOfertasRedisService.CLAVE_VENTA_RELAMPAGO,
      String(idOferta),
    );
  }

  private async consultarFila(
    idOferta: number,
  ): Promise<FilaOfertaRegistro | null> {
    const resultado = await pool.query<FilaOfertaRegistro>(
      `SELECT o.precio, o.porcentaje_descuento,
              ${expresionPrecioFinal('o')}::text AS precio_final,
              o.stock, o.es_inventario_limitado,
              o.id_producto_mongo, o.id_producto_variante_mongo,
              u.usuario AS vendedor_usuario,
              u.nombre || COALESCE(' ' || u.apellido, '') AS vendedor_nombre
         FROM oferta o
         JOIN usuarios u ON u.id_usuario = o.id_usuario
        WHERE o.id_oferta = $1`,
      [idOferta],
    );
    return resultado.rows[0] ?? null;
  }

  private async construirDatos(
    fila: FilaOfertaRegistro,
    porcentajeDescuento: string,
  ): Promise<OfertaRegistroRedis> {
    const idProducto = Number(fila.id_producto_mongo);
    const idVariante = Number(fila.id_producto_variante_mongo);

    const producto = await mongoDb
      .collection<Producto>('productos')
      .findOne<ProductoLigero>(
        { _id: idProducto },
        {
          projection: {
            _id: 1,
            nombre: 1,
            'variantes.id_producto_variante': 1,
            'variantes.nombre_variante': 1,
            'variantes.imagenes': 1,
          },
        },
      );
    const variante = producto?.variantes.find(
      (v) => v.id_producto_variante === idVariante,
    );

    return {
      id_producto: idProducto,
      id_producto_variante: idVariante,
      nombre_producto: producto?.nombre ?? '(producto no encontrado)',
      nombre_variante: variante?.nombre_variante ?? '(variante no encontrada)',
      imagen: variante?.imagenes[0] ?? null,
      precio: fila.precio,
      porcentaje_descuento: porcentajeDescuento,
      precio_final: fila.precio_final,
      vendedor_usuario: fila.vendedor_usuario,
      vendedor_nombre: fila.vendedor_nombre,
      stock: fila.stock,
    };
  }
}

/** Un mensaje de error corto para el log -- mismo patron que los demas workers (ver mas-vendidos-sync.service.ts). */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
