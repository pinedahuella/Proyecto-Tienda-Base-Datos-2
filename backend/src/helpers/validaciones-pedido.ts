import { ErrorValidacion } from './errores';

/**
 * Reglas de los pedidos del comprador. cantidad reutiliza
 * validarCantidadMovimiento de validaciones-inventario.ts -- es la misma
 * regla (entero positivo), no hace falta duplicarla.
 */

/** El id_oferta de POST /comprador/pedidos/:id/detalles. */
export function validarIdOferta(valor: unknown): number {
  if (typeof valor !== 'number' || !Number.isInteger(valor) || valor <= 0) {
    throw new ErrorValidacion(
      'El id_oferta es obligatorio y debe ser un numero entero mayor a 0',
    );
  }
  return valor;
}
