import { ReglaDescuentoAutomatico } from '../models/regla-descuento-automatico';

/**
 * Query params esperados en GET /vendedor/reglas-descuento/paginado: solo
 * paginacion, sin filtros -- mismo criterio que
 * GET /vendedor/ofertas/pendientes/paginado (no hay un "estado" que filtrar
 * aca, a diferencia de GET /vendedor/ofertas/paginado).
 */
export interface PaginarReglasDescuentoQuery {
  pagina?: string;
  limite?: string;
}

/** Respuesta de GET /vendedor/reglas-descuento/paginado. */
export interface ReglasDescuentoPaginadas {
  reglas: ReglaDescuentoAutomatico[];
  pagina: number;
  limite: number;
  total_reglas: number;
  total_paginas: number;
}
