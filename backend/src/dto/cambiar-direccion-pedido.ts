/**
 * Cuerpo esperado en PATCH /comprador/pedidos/:id.
 *
 * Mismo id_direccion que POST /comprador/pedidos (no id_direccion_historial):
 * el backend resuelve internamente cual es la version mas reciente en
 * direccion_historial antes de aplicar el cambio.
 */
export interface CambiarDireccionPedidoPeticion {
  /**
   * Se acepta number o el string que devuelve GET /direccion-usuario: es un
   * bigint y el driver pg lo entrega como texto para no perder precision.
   */
  id_direccion: number | string;
}

/** Respuesta de PATCH /comprador/pedidos/:id. */
export interface PedidoDireccionCambiada {
  id_pedido: number;
  id_direccion: number;
}
