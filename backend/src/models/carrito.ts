/**
 * Los tipos de las rutas de `/carrito`. El carrito vive solo en Redis como
 * un HASH `mesh:carrito:<id_usuario>` de `id_oferta -> cantidad`. Todo lo
 * demas (nombre, precio, stock, imagen) se resuelve al vuelo desde
 * PostgreSQL y MongoDB cuando se pinta el carrito.
 */

/** Por que una linea no se puede comprar tal como esta. */
export type MotivoNoDisponible =
  | 'oferta_no_disponible' // la oferta esta pausada/retirada/pendiente/rechazada
  | 'agotado' // stock 0
  | 'stock_insuficiente' // hay stock, pero menos que la cantidad pedida
  | 'oferta_no_existe'; // el id de oferta del carrito no existe (id invalido en un PUT)

/** Una linea del carrito, ya enriquecida con los datos del catalogo. */
export interface CarritoLinea {
  id_oferta: number;
  cantidad: number;
  id_producto: number;
  id_producto_variante: number;
  nombre_producto: string;
  nombre_variante: string;
  /** La primera imagen de la variante, o null. */
  imagen: string | null;
  /** El precio ACTUAL de la oferta (numeric(12,2) -> string). */
  precio: string;
  /** `precio` * `cantidad`, como texto. */
  subtotal: string;
  vendedor: { usuario: string; nombre: string };
  /** El stock que tiene la oferta ahora mismo. */
  stock_disponible: number;
  /** true si esta linea se puede comprar tal cual (oferta activa y stock suficiente). */
  disponible: boolean;
  /** Por que no, si `disponible` es false. `null` si `disponible` es true. */
  motivo: MotivoNoDisponible | null;
}

/** La respuesta de GET /carrito. */
export interface Carrito {
  lineas: CarritoLinea[];
  /** Suma de todos los subtotales, como texto. */
  total: string;
  /** Cuantas ofertas distintas hay en el carrito. */
  total_lineas: number;
  /** Suma de todas las cantidades. */
  total_items: number;
}

/**
 * Lo que devuelven las mutaciones del carrito (`PUT` / `DELETE
 * /carrito/lineas/:idOferta`): un resumen LIGERO, calculado solo con Redis,
 * para que el frontend actualice el contador sin esperar el enriquecido.
 * Para la vista completa se llama a `GET /carrito`.
 */
export interface ResumenCarrito {
  total_lineas: number;
  total_items: number;
}

/** El resumen mas el eco de la linea que se acaba de fijar (respuesta del PUT). */
export interface LineaCarritoDefinida extends ResumenCarrito {
  id_oferta: number;
  cantidad: number;
}
