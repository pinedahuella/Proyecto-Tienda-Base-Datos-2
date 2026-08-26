import { Producto } from '../models/producto';

/**
 * Query params esperados en GET /vendedor/productos/paginado.
 *
 * A diferencia de GET /productos/paginacion (el catalogo publico), esta
 * ruta no excluye ningun estado -- trae borrador/activo/inactivo por
 * igual, es el panel completo de la tienda/admin -- y tiene un solo
 * filtro posible: `nombre`, "contiene" insensible a mayusculas y a
 * tildes (ver construirRegexNombreFlexible en helpers/validaciones-productos.ts).
 * Nada de categoria, precio, stock ni caracteristicas: ese es el filtrado
 * del catalogo publico, no el de este panel.
 */
export interface PaginarProductosVendedorQuery {
  pagina?: string;
  limite?: string;
  nombre?: string;
}

/** Respuesta de GET /vendedor/productos/paginado. */
export interface ProductosVendedorPaginados {
  productos: Producto[];
  pagina: number;
  limite: number;
  total_productos: number;
  total_paginas: number;
}
