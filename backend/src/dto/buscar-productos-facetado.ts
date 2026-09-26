import { ResultadoBusquedaProducto } from './buscar-productos';

/**
 * Query params esperados en GET /buscador/productos/facetado. Todos
 * opcionales; los de faceta van separados por comas
 * (`categoria=7,9`, `precio=250-500,500-1000`).
 */
export interface BuscarProductosFacetadoQuery {
  nombre?: string;
  categoria?: string;
  precio?: string;
  calificacion?: string;
  disponible?: string;
  limite?: string;
  sesion?: string;
}

/** Una opcion de la faceta de categoria, con cuantos resultados tiene. */
export interface FacetaCategoria {
  id: number;
  nombre: string;
  cantidad: number;
}

/** Una opcion de las facetas de rango (precio, calificacion). */
export interface FacetaRango {
  clave: string;
  cantidad: number;
}

export interface RespuestaFacetada {
  resultados: ResultadoBusquedaProducto[];
  total: number;
  facetas: {
    categoria: FacetaCategoria[];
    precio: FacetaRango[];
    calificacion: FacetaRango[];
    /** Cuantos resultados tienen existencias, del total (sin el filtro propio). */
    disponible: number;
  };
}
