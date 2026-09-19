import { OfertaPendiente, OfertaPropia } from '../models/oferta';

/**
 * Query params esperados en GET /vendedor/ofertas/paginado.
 *
 * La version paginada de GET /vendedor/ofertas (que se queda tal cual): las
 * mismas ofertas del panel del vendedor -- todo estado -- y la misma forma
 * de cada una, pero por numero de pagina en vez de "todas de golpe", igual
 * que GET /vendedor/productos/paginado (no por cursor). Un unico filtro
 * posible: `estado` (ver validarFiltroEstadoOferta en
 * helpers/validaciones-oferta.ts) -- uno de los cinco `ESTADOS_OFERTA`
 * (`pendiente`, `activa`, `pausada`, `retirada`, `rechazada`), no un
 * booleano: filtra a UNA sola de las cinco a la vez.
 *
 *   - `estado=activa`    -> solo las ofertas en estado `activa`.
 *   - `estado=pausada`   -> solo las `pausada`, y asi con cada una.
 *   - sin el parametro   -> todas, sin filtrar por estado (como la ruta sin
 *     paginar).
 */
export interface PaginarOfertasQuery {
  pagina?: string;
  limite?: string;
  estado?: string;
}

/** Respuesta de GET /vendedor/ofertas/paginado. */
export interface OfertasPropiasPaginadas {
  ofertas: OfertaPropia[];
  pagina: number;
  limite: number;
  total_ofertas: number;
  total_paginas: number;
}

/**
 * Query params esperados en GET /vendedor/ofertas/pendientes/paginado: solo
 * paginacion, sin filtros. La cola de revision es toda de estado
 * `pendiente` por definicion, asi que el filtro `activo` de la otra ruta no
 * tendria sentido aqui.
 */
export interface PaginarOfertasPendientesQuery {
  pagina?: string;
  limite?: string;
}

/** Respuesta de GET /vendedor/ofertas/pendientes/paginado. */
export interface OfertasPendientesPaginadas {
  ofertas: OfertaPendiente[];
  pagina: number;
  limite: number;
  total_ofertas: number;
  total_paginas: number;
}
