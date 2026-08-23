import { ErrorValidacion } from './errores';

/**
 * Reglas de id_producto_variante, stock_inicial y cantidad: las usan
 * POST /vendedor/productos/:id/inventario (directo, del cuerpo),
 * POST /vendedor/productos y PATCH /vendedor/productos/:id (el
 * stock_inicial opcional de cada variante, antes de crear/editar nada,
 * para que un dato invalido rechace toda la operacion en vez de fallar a
 * medias creando su inventario) y PATCH /vendedor/productos/:id/inventario
 * (id de variante y la cantidad del ajuste).
 */

export function validarIdProductoVariante(valor: unknown): number {
  if (typeof valor !== 'number' || !Number.isInteger(valor) || valor <= 0) {
    throw new ErrorValidacion(
      'El id_producto_variante es obligatorio y debe ser un numero entero mayor a 0',
    );
  }
  return valor;
}

export function validarStockInicial(valor: unknown): number {
  if (typeof valor !== 'number' || !Number.isInteger(valor) || valor < 0) {
    throw new ErrorValidacion(
      'El stock_inicial es obligatorio y debe ser un numero entero mayor o igual a 0',
    );
  }
  return valor;
}

/**
 * La cantidad de un movimiento (stock_movimiento.cantidad) nunca es 0: un
 * movimiento representa unidades que de verdad se movieron. Por eso es
 * "mayor a 0", a diferencia de stock_inicial que si admite 0.
 */
export function validarCantidadMovimiento(valor: unknown): number {
  if (typeof valor !== 'number' || !Number.isInteger(valor) || valor <= 0) {
    throw new ErrorValidacion(
      'La cantidad es obligatoria y debe ser un numero entero mayor a 0',
    );
  }
  return valor;
}
