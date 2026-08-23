/** Cuerpo esperado en POST /comprador/pedidos/:id/detalles. */
export interface AgregarLineaPeticion {
  id_producto: number;
  id_producto_variante: number;
  cantidad: number;
}

/**
 * Respuesta de POST /comprador/pedidos/:id/detalles: exactamente lo que
 * devuelve agregar_linea() en PostgreSQL. cantidad es la acumulada (la que
 * ya tenia esa variante en el pedido, mas la que se acaba de agregar), no
 * la de esta llamada sola.
 */
export interface LineaPedidoResultado {
  id_pedido: number;
  id_producto: number;
  id_producto_variante: number;
  cantidad: number;
  stock_disponible: number;
}
