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
 * Valor de una caracteristica personalizada: solo un dato suelto (texto,
 * numero o boolean), nunca un array ni un objeto. A diferencia de
 * caracteristicas_adicionales (que sale del catalogo de la app y admite
 * cualquier forma), esta la escribe quien crea el producto, a su gusto.
 */
export type ValorCaracteristicaPersonalizada = string | number | boolean;

export interface ProductoVariante {
  id_producto_variante: number;
  nombre_variante: string;
  precio: Decimal128;
  descripcion: string;
  fecha_creacion: Date;
  estado: string;
  imagenes: string[];
  /** Opcional: caracteristicas de esta variante, del catalogo de la app. */
  caracteristicas_adicionales?: Record<string, unknown>;
  /**
   * Opcional: caracteristicas propias que quien crea el producto le agrega
   * a esta variante, fuera del catalogo. Nunca son filtrables en
   * GET /productos ni GET /productos/paginacion (ver ProductosService).
   */
  caracteristicas_personalizadas?: Record<
    string,
    ValorCaracteristicaPersonalizada
  >;
}

export interface Producto {
  _id: number;
  nombre: string;
  descripcion: string;
  fecha_creacion: Date;
  estado: string;
  vendedor: ProductoVendedor;
  categoria: ProductoCategoria;
  variantes: ProductoVariante[];
  /** Opcional: caracteristicas del producto, del catalogo de la app. */
  caracteristicas_adicionales?: Record<string, unknown>;
  /**
   * Opcional: caracteristicas propias que quien crea el producto le agrega,
   * fuera del catalogo. Nunca son filtrables en GET /productos ni
   * GET /productos/paginacion (ver ProductosService).
   */
  caracteristicas_personalizadas?: Record<
    string,
    ValorCaracteristicaPersonalizada
  >;
}
