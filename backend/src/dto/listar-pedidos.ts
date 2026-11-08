/**
 * Respuesta de GET /comprador/pedidos: un resumen por pedido, para una
 * lista de "mis pedidos" -- no el detalle completo (para eso esta
 * GET /comprador/pedidos/:id) y no un historial de eventos.
 */
export interface PedidoResumen {
  id_pedido: string;
  fecha_creacion: Date;
  id_estado_pedido: number;
  estado_pedido_nombre: string;
  /** Suma de precio_unitario * cantidad de sus lineas. numeric, como texto. "0.00" si todavia no tiene ninguna. */
  total: string;
  /** Cuantas lineas distintas tiene, para poder mostrar "3 productos" sin traerlas todas. */
  cantidad_lineas: number;
  /** null mientras el pedido sigue pendiente: todavia no existe pago. */
  metodo_pago: string | null;
  /** null mientras el pedido sigue pendiente. */
  estado_pago: string | null;
  /** Cuando se salda el pago (ver Pago.fecha_cancelacion). null mientras el pedido sigue pendiente. */
  fecha_cancelacion: Date | null;
  /**
   * true si el pedido lo cancelo la tienda y no el comprador
   * (`pedido_cambio_estado`, migracion 051). false en todo lo demas.
   */
  cancelado_por_tienda: boolean;
}
