/**
 * Cuerpo esperado en POST /comprador/pedidos/:id/detalles.
 *
 * Modelo multi-vendedor: se agrega una OFERTA, no un producto+variante --
 * la misma variante la puede vender media docena de personas, cada una a
 * su precio, y hay que decir a cual. id_producto/id_producto_variante,
 * el nombre y el precio ya NO vienen del cliente: el backend los resuelve
 * el mismo (el par de ids de Mongo, desde la propia oferta en PostgreSQL;
 * los nombres, desde el documento del producto) antes de llamar a
 * agregar_linea() -- asi nadie puede mandar un nombre o un precio falso.
 */
export interface AgregarLineaPeticion {
  id_oferta: number;
  cantidad: number;
}

/**
 * Respuesta de POST /comprador/pedidos/:id/detalles: exactamente lo que
 * devuelve agregar_linea() en PostgreSQL (migrations/007_flujo_pedido.sql).
 * cantidad es la acumulada (la que ya tenia esa oferta en el pedido, mas la
 * que se acaba de agregar), no la de esta llamada sola.
 */
export interface LineaPedidoResultado {
  id_pedido: number;
  id_pedido_producto: number;
  id_oferta: number;
  id_usuario_vendedor: number;
  cantidad: number;
  stock_disponible: number;
}
