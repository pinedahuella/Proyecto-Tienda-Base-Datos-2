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

export interface ProductoVariante {
  id_producto_variante: number;
  nombre_variante: string;
  precio: Decimal128;
  descripcion: string;
  fecha_creacion: Date;
  estado: string;
  imagenes: string[];
  /** Opcional: caracteristicas propias de esta variante, segun la categoria. */
  caracteristicas_adicionales?: Record<string, unknown>;
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
  /** Opcional: caracteristicas del producto, segun la categoria. */
  caracteristicas_adicionales?: Record<string, unknown>;
}
