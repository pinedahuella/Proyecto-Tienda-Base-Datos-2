import { ReglaDescuentoPeriodo } from '../models/regla-descuento-periodo';

/**
 * Query params esperados en GET /vendedor/reglas-descuento-periodos/paginado:
 * solo paginacion, sin filtros -- mismo criterio que
 * GET /vendedor/reglas-descuento/paginado.
 */
export interface PaginarReglasDescuentoPeriodoQuery {
  pagina?: string;
  limite?: string;
}

/** Respuesta de GET /vendedor/reglas-descuento-periodos/paginado. */
export interface ReglasDescuentoPeriodoPaginadas {
  reglas: ReglaDescuentoPeriodo[];
  pagina: number;
  limite: number;
  total_reglas: number;
  total_paginas: number;
}
