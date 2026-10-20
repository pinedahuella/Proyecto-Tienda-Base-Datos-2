import { Decimal128 } from 'mongodb';
import { mongoDb } from '../database/mongo';
import { ESTADO_PRODUCTO_VISIBLE } from '../models/estado-producto';
import { Producto } from '../models/producto';
import {
  conRespaldoDeMongo,
  productosDesdePostgres,
} from './catalogo-respaldo';

/**
 * La version acotada de un producto que pintan las vitrinas de la portada
 * (lo mas vendido, lo mas visto, se compran juntos): nombre, una imagen,
 * precio, si tiene descuento, calificacion y si le quedan existencias. Sin
 * `variantes[]` ni caracteristicas, que es la mayor parte del peso del
 * documento (ver `mas-vendidos-sync.service.ts`).
 */
export interface TarjetaProducto {
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

/** Forma cruda de la proyeccion de Mongo, antes de aplanar la imagen. */
interface FilaProyectada {
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
 * Las tarjetas de los productos `ids` que son publicos (`activo`), por id. De
 * Mongo, con una proyeccion que solo trae lo de la tarjeta; si Mongo no
 * responde, de la copia del catalogo en PostgreSQL (`conRespaldoDeMongo`), que
 * calcula los mismos numeros desde `oferta` y `resena`.
 *
 * Antes cada worker de las vitrinas tenia su propia copia de la consulta a
 * Mongo, la misma tres veces, y con Mongo caido dejaba la vitrina sin
 * recalcular. Ahora la usan los workers y tambien las vitrinas cuando Redis no
 * esta y el ranking se calcula en el momento (2026-10-20).
 */
export async function tarjetasDeProductos(
  ids: number[],
): Promise<Map<number, TarjetaProducto>> {
  if (ids.length === 0) {
    return new Map();
  }
  const tarjetas = await conRespaldoDeMongo<TarjetaProducto[]>(
    async () => {
      const filas = await mongoDb
        .collection<Producto>('productos')
        .find<FilaProyectada>(
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
              // Mongo no deja combinar un $slice sobre variantes con esta
              // subruta ("path collision"): vienen las imagenes de todas.
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
    },
    async () =>
      (await productosDesdePostgres(ids, true)).map((p) => ({
        _id: p._id,
        nombre: p.nombre,
        imagen: p.variantes[0]?.imagenes[0] ?? null,
        precio_tienda: p.precio_tienda,
        precio_desde: p.precio_desde,
        hay_descuento: p.hay_descuento,
        resenas_promedio: p.resenas_promedio,
        resenas_total: p.resenas_total,
        stock_total: p.stock_total,
      })),
  );
  return new Map(tarjetas.map((t) => [t._id, t]));
}

/**
 * Un resultado calculado en el momento, guardado `ms` milisegundos. Lo usan las
 * vitrinas cuando Redis no esta: la portada la piden todos los que entran, y
 * sin esto cada visita le haria a ClickHouse la consulta que el worker hace
 * cada 10 minutos. Si el calculo falla no se guarda nada, y la siguiente
 * peticion vuelve a intentar.
 */
export class Memoria<T> {
  private valor: T | undefined;
  private hasta = 0;
  private enCurso: Promise<T> | null = null;

  constructor(private readonly ms: number) {}

  async obtener(calcular: () => Promise<T>): Promise<T> {
    if (this.valor !== undefined && Date.now() < this.hasta) {
      return this.valor;
    }
    // Dos peticiones a la vez esperan el mismo calculo, no hacen dos.
    this.enCurso ??= calcular()
      .then((valor) => {
        this.valor = valor;
        this.hasta = Date.now() + this.ms;
        return valor;
      })
      .finally(() => {
        this.enCurso = null;
      });
    return this.enCurso;
  }
}
