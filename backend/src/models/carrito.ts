/**
 * Los tipos de las rutas de `/carrito`. El carrito vive solo en Redis como
 * un HASH `mesh:carrito:<id_usuario>` de `id_oferta -> <linea en JSON>`.
 * Nombre, precio, imagen y vendedor se toman de PostgreSQL/MongoDB UNA vez,
 * al agregar o cambiar la cantidad, y quedan guardados ahi mismo -- `GET
 * /carrito` ya no consulta nada mas que Redis (ver `CarritoService`). El
 * checkout (`POST /carrito/comprar`) es la excepcion: sigue verificando en
 * vivo antes de cobrar.
 */

/** Por que una linea no se puede comprar tal como esta. */
export type MotivoNoDisponible =
  | 'oferta_no_disponible' // la oferta esta pausada/retirada/pendiente/rechazada
  | 'variante_no_disponible' // la variante se desactivo en el catalogo
  | 'agotado' // stock 0
  | 'stock_insuficiente' // hay stock, pero menos que la cantidad pedida
  | 'oferta_no_existe' // el id de oferta del carrito no existe (id invalido en un PUT)
  | 'reserva_vencida'; // era de inventario limitado y la reserva vencio sola

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
  /** El precio a pagar -- YA con el descuento aplicado, si la oferta tenia uno (numeric(12,2) -> string). */
  precio: string;
  /** El % de descuento que tenia la oferta, o `null` -- solo informativo (badge), `precio` ya lo tiene aplicado. */
  porcentaje_descuento: string | null;
  /** `precio` * `cantidad`, como texto. */
  subtotal: string;
  vendedor: { usuario: string; nombre: string };
  /** El stock que tiene la oferta ahora mismo. */
  stock_disponible: number;
  /** true si esta linea se puede comprar tal cual (oferta activa y stock suficiente). */
  disponible: boolean;
  /** Por que no, si `disponible` es false. `null` si `disponible` es true. */
  motivo: MotivoNoDisponible | null;
  /**
   * `true` si esta oferta esta operando bajo el mecanismo de venta
   * relampago de Redis (`oferta.es_inventario_limitado` -- ver
   * `plan pendiente/inventario-limitado.md`). Cuando es `true`, agregarla
   * al carrito reservo de verdad esas unidades (a diferencia de una linea
   * normal, que nunca reserva nada al agregar).
   */
  es_inventario_limitado: boolean;
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
  /**
   * `false` si lo que se ve en Redis no quedo guardado en PostgreSQL (la
   * verdad): el intento de guardarlo fallo, o PostgreSQL tiene cambios que
   * Redis no vio. El checkout no compra un carrito asi; se arregla con
   * `POST /carrito/sincronizar`.
   */
  sincronizado: boolean;
  /**
   * De donde salio esta respuesta: `redis` (lo normal, rapido) o `postgres`
   * (Redis no respondia y se leyo la verdad directo, mas lento).
   */
  fuente: 'redis' | 'postgres';
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
  /** Ver `CarritoLinea.es_inventario_limitado`. */
  es_inventario_limitado: boolean;
}
