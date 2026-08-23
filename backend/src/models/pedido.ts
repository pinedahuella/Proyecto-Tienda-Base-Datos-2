/**
 * Tabla pedido. La compra: quien, cuando, a donde y en que estado.
 *
 * No lleva total: es la suma de sus lineas (pedido_producto), se calcula
 * cuando se necesita. id_direccion_historial apunta a la VERSION de la
 * direccion que regia al crear el pedido, no a la direccion vigente hoy.
 */
export interface Pedido {
  id_pedido: string;
  fecha_creacion: Date;
  id_usuario: string;
  id_direccion_historial: string;
  id_estado_pedido: number;
  estado_pedido_nombre: string;
}
