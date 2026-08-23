/**
 * Respuesta de GET /vendedor/productos/inventario y
 * GET /vendedor/productos/:id/inventario.
 *
 * Es el stock REAL (PostgreSQL, tabla inventario), no la copia de lectura
 * que trae variantes[].stock en Mongo. Un item por variante, sin agrupar
 * por producto.
 */
export interface InventarioVariante {
  id_producto: number;
  id_producto_variante: number;
  stock: number;
}

/**
 * Cuerpo de POST /vendedor/productos/:id/inventario. id_producto sale de
 * la URL; esto es solo lo que falta para crear la fila por primera vez.
 */
export interface CrearInventarioPeticion {
  id_producto_variante: number;
  stock_inicial: number;
}
