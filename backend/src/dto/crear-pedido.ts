/**
 * Cuerpo esperado en POST /comprador/pedidos.
 *
 * id_direccion, no id_direccion_historial: quien compra conoce sus
 * direcciones por el id normal (el que devuelve GET /direccion-usuario);
 * el backend resuelve internamente cual es su version mas reciente en
 * direccion_historial antes de llamar a crear_pedido().
 */
export interface CrearPedidoPeticion {
  id_direccion: number;
}

/** Respuesta de POST /comprador/pedidos. */
export interface PedidoCreado {
  id_pedido: string;
}
