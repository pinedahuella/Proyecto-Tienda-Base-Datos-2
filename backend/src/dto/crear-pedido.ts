/**
 * Cuerpo esperado en POST /comprador/pedidos.
 *
 * id_direccion, no id_direccion_historial: quien compra conoce sus
 * direcciones por el id normal (el que devuelve GET /direccion-usuario);
 * el backend resuelve internamente cual es su version mas reciente en
 * direccion_historial antes de llamar a crear_pedido().
 */
export interface CrearPedidoPeticion {
  /**
   * Se acepta number o el string que devuelve GET /direccion-usuario: es un
   * bigint y el driver pg lo entrega como texto para no perder precision.
   * Exigir solo number rechazaba lo que esta misma API acababa de dar.
   */
  id_direccion: number | string;
}

/** Respuesta de POST /comprador/pedidos. */
export interface PedidoCreado {
  id_pedido: string;
}
