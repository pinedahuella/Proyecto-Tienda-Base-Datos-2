/** Query params esperados en GET /buscador/productos/sugerencias. */
export interface BuscarSugerenciasQuery {
  prefijo?: string;
  limite?: string;
}

/** Lo minimo para pintar una lista desplegable de autocompletado. */
export interface Sugerencia {
  id_producto: number;
  nombre: string;
}
