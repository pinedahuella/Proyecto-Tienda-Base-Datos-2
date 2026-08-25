/**
 * Tabla metodo_pago (migrations/006_pedidos.sql): catalogo cerrado, los
 * tres valores con los que se sembro la base (tarjeta, transferencia,
 * efectivo contra entrega). Lo que espera comprar_pedido(id_pedido,
 * metodo_pago) en su segundo parametro es `metodo_nombre`, no el id.
 */
export interface MetodoPago {
  id_metodo_pago: number;
  metodo_nombre: string;
}

/** El nombre exacto con el que comprar_pedido() reconoce el pago con tarjeta. */
export const METODO_PAGO_TARJETA = 'tarjeta';
