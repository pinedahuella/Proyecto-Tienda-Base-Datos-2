import { ErrorValidacion } from './errores';
import { ESTADOS_OFERTA_VALIDOS } from '../models/estado-oferta';

/**
 * Reglas de PATCH /vendedor/ofertas/:id: que estado se le puede poner a una
 * oferta propia, y el ajuste manual de su stock.
 */

export function validarEstadoOferta(valor: unknown): string {
  if (typeof valor !== 'string' || !ESTADOS_OFERTA_VALIDOS.includes(valor)) {
    throw new ErrorValidacion(
      `El estado debe ser uno de: ${ESTADOS_OFERTA_VALIDOS.join(', ')}`,
    );
  }
  return valor;
}

/**
 * Un ajuste manual de stock: entero distinto de 0. Positivo repone (motivo
 * "reposicion"), negativo corrige a la baja (motivo "ajuste") -- los dos
 * unicos motivos que reponer_stock() admite fuera del flujo del pedido
 * (ver migrations/007_flujo_pedido.sql).
 */
export function validarAjusteStock(valor: unknown): number {
  if (typeof valor !== 'number' || !Number.isInteger(valor) || valor === 0) {
    throw new ErrorValidacion(
      'El ajuste_stock debe ser un numero entero distinto de 0',
    );
  }
  return valor;
}
