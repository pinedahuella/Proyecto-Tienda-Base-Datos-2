import { Decimal128 } from 'mongodb';
import { OfertaVendedor } from './oferta';

/**
 * Documentos de la coleccion `productos` en MongoDB.
 *
 * A diferencia de los modelos de src/models/*.ts que representan filas de
 * PostgreSQL, estos representan documentos de Mongo: _id es el id_producto
 * de PostgreSQL (no un ObjectId), y los precios son Decimal128, no number,
 * para no perder centavos.
 *
 * Modelo multi-vendedor (ver docs/base-de-datos.md y
 * backend/elementos Generales/cambios-multivendedor.md): el producto ya no
 * tiene dueno ni precio propio. Quien lo vende, a como y con cuantas
 * unidades es de la oferta, que vive solo en PostgreSQL (tabla `oferta`) y
 * no tiene coleccion propia en Mongo. Lo unico que queda embebido son
 * cuatro numeros calculados por el ETL/el backend: el precio y las
 * existencias de la tienda, las existencias totales entre todos los
 * vendedores, y cuantos vendedores lo ofertan — lo que la LISTA del
 * catalogo necesita en cada tarjeta sin ir a buscar las ofertas reales.
 *
 * Estructura completa y ejemplos reales en
 * backend/elementos Generales/Elementos Documentales/ejemplos_bson_productos.md
 */

export interface ProductoCategoria {
  id_categoria: number;
  nombre: string;
  categoria_padre: string | null;
}

/**
 * El valor de una entrada de caracteristica: el tipo nativo de Mongo que le
 * corresponda segun su tipo_dato (Number para entero/decimal, Boolean para
 * booleano, String para texto, Array<string> para lista). Ver
 * productos_subproductos.md.
 */
export type ValorCaracteristica = string | number | boolean | string[];

/**
 * Una entrada de caracteristicas_adicionales o caracteristicas_personalizadas:
 * siempre estas tres llaves, nunca mas ni menos. Es la misma forma para las
 * dos, y para las del producto y las de la variante.
 */
export interface EntradaCaracteristica {
  nombre: string;
  valor: ValorCaracteristica;
  /** null cuando la caracteristica no se mide en nada. */
  unidad: string | null;
}

export interface ProductoVariante {
  id_producto_variante: number;
  nombre_variante: string;
  descripcion: string | null;
  fecha_creacion: Date;
  estado: string;
  imagenes: string[];
  /** El precio de la oferta de la tienda para esta variante. Copia calculada; null si la tienda no la oferta. */
  precio_tienda: Decimal128 | null;
  /** Unidades activas de la oferta de la tienda para esta variante. Copia calculada. */
  stock_tienda: number;
  /** Unidades activas sumadas entre TODOS los vendedores de esta variante. Copia calculada. */
  stock_total: number;
  /** Cuantos vendedores distintos la tienen activa. Copia calculada. */
  total_ofertas: number;
  /** Opcional: caracteristicas de esta variante, del catalogo de la app. */
  caracteristicas_adicionales?: EntradaCaracteristica[];
  /**
   * Opcional: caracteristicas propias que quien crea el producto le agrega
   * a esta variante, fuera del catalogo, con la misma forma que las de
   * arriba. Tan filtrables como esas (ver ProductosService).
   */
  caracteristicas_personalizadas?: EntradaCaracteristica[];
}

export interface Producto {
  _id: number;
  nombre: string;
  /** Unico campo obligatorio de la raiz que admite nulo. */
  descripcion: string | null;
  fecha_creacion: Date;
  estado: string;
  categoria: ProductoCategoria;
  /** El precio de la tienda; a nivel de producto es el menor entre sus variantes. Copia calculada. */
  precio_tienda: Decimal128 | null;
  /** Unidades activas de la tienda, SUMADAS sobre todas las variantes. Copia calculada. */
  stock_tienda: number;
  /** Unidades activas entre TODOS los vendedores, SUMADAS sobre todas las variantes. Copia calculada. */
  stock_total: number;
  /** Cuantos vendedores distintos lo tienen activo. Copia calculada. */
  total_ofertas: number;
  variantes: ProductoVariante[];
  /** Opcional: caracteristicas del producto, del catalogo de la app. */
  caracteristicas_adicionales?: EntradaCaracteristica[];
  /**
   * Opcional: caracteristicas propias que quien crea el producto le agrega,
   * fuera del catalogo, con la misma forma que las de arriba. Tan filtrables
   * como esas (ver ProductosService).
   */
  caracteristicas_personalizadas?: EntradaCaracteristica[];
}

/**
 * Producto tal como lo devuelve GET /productos/:id: el documento de Mongo
 * mas sus ofertas reales, pedidas a PostgreSQL en el momento (ver
 * ProductosService.obtenerPublico y models/oferta.ts). No se guarda en
 * Mongo: se arma solo para responder esta ruta.
 *
 * Ordenadas por variante y despues por precio (la mas barata primero, tal
 * como usa el indice idx_oferta_catalogo_precio de 005_ofertas.sql):
 * agruparlas por id_producto_variante_mongo es trabajo de quien lea la
 * respuesta.
 */
export interface ProductoConOfertas extends Producto {
  ofertas: OfertaVendedor[];
}
