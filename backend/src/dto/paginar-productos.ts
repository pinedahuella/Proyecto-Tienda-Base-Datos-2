import { Producto } from '../models/producto';

/**
 * Query params esperados en GET /productos/paginacion.
 *
 * Los mismos filtros que ListarProductosQuery (ver listar-productos.ts),
 * solo que la paginacion es por numero de pagina en vez de por cursor.
 */
export interface PaginarProductosQuery {
  pagina?: string;
  limite?: string;
  nombre?: string;
  estado?: string;
  id_categoria?: string;
  id_vendedor?: string;
  precio_min?: string;
  precio_max?: string;
  estado_variante?: string;
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
