import { Producto } from '../models/producto';

/**
 * Query params esperados en GET /productos.
 *
 * Los que no estan aqui listados explicitamente (marca, ram, color, etc.)
 * son filtros dinamicos sobre caracteristicas_adicionales/personalizadas:
 * cualquier query param que no sea uno de estos nombres fijos se trata como
 * uno. Por defecto es igualdad (`ram=16`); un prefijo `min_`, `max_` o
 * `contiene_` en el nombre pide ese operador en vez de igualdad
 * (`min_ram=8`, `contiene_color=roj`) — ver interpretarFiltroCaracteristica
 * en validaciones-productos.ts.
 */
export interface ListarProductosQuery {
  limite?: string;
  despues_de?: string;
  nombre?: string;
  estado?: string;
  id_categoria?: string;
  id_vendedor?: string;
  precio_min?: string;
  precio_max?: string;
  estado_variante?: string;
  [claveAtributo: string]: string | undefined;
}

/** Respuesta de GET /productos: la tanda de productos y el cursor para pedir la siguiente. */
export interface ProductosPagina {
  productos: Producto[];
  /** El _id del ultimo producto de esta tanda. null si ya no hay mas. */
  siguiente_cursor: number | null;
}
