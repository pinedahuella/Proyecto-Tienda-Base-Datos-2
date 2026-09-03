import { Producto } from '../models/producto';

/**
 * Query params esperados en GET /productos/paginacion.
 *
 * Los mismos filtros que ListarProductosQuery (ver listar-productos.ts,
 * incluyendo los prefijos min_/max_/contiene_ para caracteristicas), solo
 * que la paginacion es por numero de pagina en vez de por cursor.
 */
export interface PaginarProductosQuery {
  pagina?: string;
  limite?: string;
  nombre?: string;
  estado?: string;
  id_categoria?: string;
  /** Filtra por precio_tienda. */
  precio_min?: string;
  precio_max?: string;
  estado_variante?: string;
  /** Filtra por stock_total: existencias activas entre todos los vendedores. */
  stock_min?: string;
  stock_max?: string;
  /** Filtra por stock_tienda: existencias activas solo de la tienda. */
  stock_tienda_min?: string;
  stock_tienda_max?: string;
  /** Filtra por resenas_promedio: nota media del producto (1 a 5). Exige tener >= 1 resena. */
  resenas_promedio_min?: string;
  resenas_promedio_max?: string;
  /** Filtra por resenas_total: cuantas resenas tiene el producto. */
  resenas_total_min?: string;
  resenas_total_max?: string;
  [claveAtributo: string]: string | undefined;
}

/** Respuesta de GET /productos/paginacion. */
export interface ProductosPaginados {
  productos: Producto[];
  pagina: number;
  limite: number;
  total_productos: number;
  total_paginas: number;
}
