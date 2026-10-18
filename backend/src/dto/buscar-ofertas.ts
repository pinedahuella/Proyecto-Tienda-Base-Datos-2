/**
 * Query params de GET /vendedor/ofertas/buscar, el buscador de ofertas sobre
 * Elasticsearch (`mesh_ofertas`). Todos opcionales; las reglas estan en
 * helpers/validaciones-oferta.ts y en BuscarOfertasService.
 *
 *   - `q`              texto difuso: nombre del producto, de la variante y
 *                      del vendedor. Sin `q` se listan por filtros.
 *   - `alcance`        `propias` (por defecto) o `todas`. `todas` es solo de
 *                      la tienda y de los admin.
 *   - `id_vendedor`    solo con `alcance=todas`: las de un vendedor.
 *   - `id_producto`    las ofertas de un producto.
 *   - `estado`         uno de los cinco `ESTADOS_OFERTA`.
 *   - `con_descuento`  `true` / `false`.
 *   - `stock`          `agotadas` (stock 0) o `con_stock`.
 *   - `precio_min`, `precio_max`  sobre el precio final (con descuento).
 *   - `orden`          `relevancia`, `precio_asc`, `precio_desc`,
 *                      `descuento_desc`, `stock_asc` o `recientes`.
 *   - `pagina`, `limite`  como GET /vendedor/ofertas/paginado.
 */
export interface BuscarOfertasQuery {
  q?: string;
  alcance?: string;
  id_vendedor?: string;
  id_producto?: string;
  estado?: string;
  con_descuento?: string;
  stock?: string;
  precio_min?: string;
  precio_max?: string;
  orden?: string;
  pagina?: string;
  limite?: string;
}

/**
 * El documento de `mesh_ofertas`, tal como lo escribe EventoOfertaSyncService.
 * Mismo orden y mismos nombres que `plan pendiente/ofertas-indice.json`.
 */
export interface DocumentoOferta {
  id_oferta: number;
  id_producto: number;
  id_producto_variante: number;
  nombre_producto: string | null;
  nombre_variante: string | null;
  estado_variante: string | null;
  id_vendedor: number;
  vendedor_usuario: string;
  vendedor_nombre: string;
  estado_vendedor: string;
  precio: number;
  porcentaje_descuento: number | null;
  precio_final: number;
  stock: number;
  estado: string;
}

/**
 * Una oferta encontrada. Ids y montos como texto, igual que OfertaVendedor
 * (bigint y numeric(12,2) de PostgreSQL, sin perder precision).
 */
export interface OfertaEncontrada {
  id_oferta: string;
  id_producto: string;
  id_producto_variante: string;
  nombre_producto: string | null;
  nombre_variante: string | null;
  estado_variante: string | null;
  vendedor: {
    id_usuario: string;
    usuario: string;
    nombre: string;
    estado: string;
  };
  precio: string;
  porcentaje_descuento: string | null;
  precio_final: string;
  stock: number;
  estado: string;
}

/**
 * Las agregaciones de Elasticsearch sobre TODAS las ofertas que cumplen la
 * busqueda (no solo la pagina). `por_vendedor` solo viene con `alcance=todas`.
 */
export interface ResumenBusquedaOfertas {
  por_estado: Record<string, number>;
  con_descuento: number;
  agotadas: number;
  precio_final: {
    minimo: string | null;
    maximo: string | null;
    promedio: string | null;
  };
  por_vendedor?: {
    id_vendedor: string;
    usuario: string;
    ofertas: number;
  }[];
}

/** Respuesta de GET /vendedor/ofertas/buscar. */
export interface OfertasEncontradas {
  ofertas: OfertaEncontrada[];
  pagina: number;
  limite: number;
  total_ofertas: number;
  total_paginas: number;
  resumen: ResumenBusquedaOfertas;
}
