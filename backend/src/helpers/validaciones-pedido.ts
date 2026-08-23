import { ErrorValidacion } from './errores';

/**
 * Reglas de POST /comprador/pedidos/:id/detalles: el id_producto de la
 * linea. id_producto_variante y cantidad reutilizan validarIdProductoVariante
 * y validarCantidadMovimiento de validaciones-inventario.ts -- son las
 * mismas reglas (entero positivo), no hace falta duplicarlas.
 */
export function validarIdProducto(valor: unknown): number {
  if (typeof valor !== 'number' || !Number.isInteger(valor) || valor <= 0) {
    throw new ErrorValidacion(
      'El id_producto es obligatorio y debe ser un numero entero mayor a 0',
    );
  }
  return valor;
}
