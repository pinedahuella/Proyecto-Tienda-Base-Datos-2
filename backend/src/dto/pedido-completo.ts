import { DireccionHistorial } from '../models/direccion-historial';
import { Pedido } from '../models/pedido';
import { DetallePedido } from '../models/pedido-producto';

/**
 * Respuesta de GET /comprador/pedidos/:id: el pedido, la version de la
 * direccion que regia al crearlo y sus lineas (vacio si todavia no tiene
 * ninguna). Todo sale de PostgreSQL, sin consultar Mongo.
 *
 * Cada detalle trae su precio y su oferta ya resueltos con un JOIN contra
 * precio_historial (ver DetallePedido): el precio ya no se copia directo
 * en pedido_producto, se llega a el por `id_precio_historial`.
 */
export interface PedidoCompleto {
  pedido: Pedido;
  direccion: DireccionHistorial;
  detalles: DetallePedido[];
}
