/**
 * Tabla pedido_producto. Una linea del pedido: que se llevo, cuanto y a
 * que precio, con lo acordado copiado tal como estaba ese dia.
 *
 * id_producto_mongo e id_producto_variante_mongo no son llaves foraneas
 * (el producto vive en MongoDB, no en PostgreSQL): estan aqui solo para
 * poder volver al documento si hace falta. Para mostrar la linea no hace
 * falta -- nombre_producto, nombre_variante, precio_unitario y
 * porcentaje_comision ya estan copiados al lado.
 */
export interface PedidoProducto {
  id_pedido_producto: string;
  id_pedido: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  nombre_producto: string;
  nombre_variante: string;
  precio_unitario: string;
  porcentaje_comision: string;
  cantidad: number;
}
