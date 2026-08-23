import { Decimal128 } from 'mongodb';

/**
 * Documentos de la coleccion `productos` en MongoDB.
 *
 * A diferencia de los modelos de src/models/*.ts que representan filas de
 * PostgreSQL, estos representan documentos de Mongo: _id es el id_producto
 * de PostgreSQL (no un ObjectId), y precio/porcentaje_comision son
 * Decimal128, no number, para no perder centavos.
 *
 * Estructura completa y ejemplos reales en
 * backend/elementos Generales/Elementos Documentales/ejemplos_bson_productos.md
 */

export interface ProductoVendedor {
  id_usuario: number;
  usuario: string;
  nombre: string;
  apellido: string;
}

export interface ProductoCategoria {
  id_categoria: number;
  nombre: string;
  categoria_padre: string;
  porcentaje_comision: Decimal128;
}

/**
 * El valor de una entrada de caracteristica: el tipo nativo de Mongo que le
 * corresponda segun su tipo_dato (Number para entero/decimal, Boolean para
 * booleano, String para texto). Ver productos_subproductos.md.
 *
 * Nota: la carga actual todavia guarda todos los valores como string (ver
 * pendientes-etl-caracteristicas.md), asi que en la practica un valor
 * "deberia" ser Number o Boolean pero hoy puede llegar como String. El tipo
 * de aqui es el correcto/deseado; el codigo que filtra es tolerante al caso
 * en que todavia no lo sea.
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
  precio: Decimal128;
  descripcion: string;
  fecha_creacion: Date;
  estado: string;
  imagenes: string[];
  /**
   * Cuantas unidades quedan de esta variante. Es una copia de lectura del
   * saldo real, que vive en `inventario` de PostgreSQL (ver
   * cambios-etl-productos.md); opcional porque las variantes publicadas
   * desde el panel del vendedor todavia no crean su fila de inventario.
   */
  stock?: number;
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
  vendedor: ProductoVendedor;
  categoria: ProductoCategoria;
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
 * Un Producto tal como lo devuelven las rutas publicas de listado y de
 * detalle, con `stock_total` agregado: la suma de `variantes[].stock` (las
 * variantes sin stock cuentan como 0). No se guarda en Mongo, se calcula al
 * responder, para poder mostrarlo y para poder filtrar por el (ver
 * ProductosService).
 */
export interface ProductoConStockTotal extends Producto {
  stock_total: number;
}
