/**
 * Cuerpo esperado en PUT /carrito/lineas/:idOferta.
 *
 * `cantidad` es la cantidad **absoluta** que se quiere de esa oferta en el
 * carrito (no un +1 / -1). Para quitar la linea se usa
 * DELETE /carrito/lineas/:idOferta, no `cantidad: 0`.
 */
export interface DefinirCantidadCarritoPeticion {
  /** Entero de 1 a 1000. */
  cantidad: number;
}
