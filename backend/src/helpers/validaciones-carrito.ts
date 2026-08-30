import { ErrorValidacion } from './errores';

/**
 * Reglas de PUT /carrito/lineas/:idOferta.
 */

/** Tope de sanidad por linea. El limite real es el stock, que se comprueba al pintar el carrito y al pagar; esto solo evita un `cantidad: 999999999`. */
const CANTIDAD_MAXIMA_LINEA = 1000;

/**
 * La cantidad absoluta que se quiere de una oferta en el carrito: entero de
 * 1 a 1000. No se valida contra el stock aca a proposito -- agregar al
 * carrito no toca PostgreSQL; el stock se comprueba en `GET /carrito` (en
 * lote) y de forma bloqueante al pagar.
 */
export function validarCantidadCarrito(valor: unknown): number {
  if (
    typeof valor !== 'number' ||
    !Number.isInteger(valor) ||
    valor < 1 ||
    valor > CANTIDAD_MAXIMA_LINEA
  ) {
    throw new ErrorValidacion(
      `La cantidad debe ser un numero entero entre 1 y ${CANTIDAD_MAXIMA_LINEA}`,
    );
  }
  return valor;
}
