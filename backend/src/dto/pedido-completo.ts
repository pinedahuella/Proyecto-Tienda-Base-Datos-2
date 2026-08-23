import { DireccionHistorial } from '../models/direccion-historial';
import { Pedido } from '../models/pedido';
import { PedidoProducto } from '../models/pedido-producto';

/**
 * Respuesta de GET /comprador/pedidos/:id: el pedido, la version de la
 * direccion que regia al crearlo y sus lineas (vacio si todavia no tiene
 * ninguna). Todo sale de PostgreSQL, sin consultar Mongo -- lo que hace
 * falta para mostrar el pedido ya esta copiado en pedido_producto.
 */
export interface PedidoCompleto {
  pedido: Pedido;
  direccion: DireccionHistorial;
  detalles: PedidoProducto[];
}
