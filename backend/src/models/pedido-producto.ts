/**
 * Tabla pedido_producto (migrations/006_pedidos.sql). Una linea del pedido:
 * que se llevo, cuanto y de quien -- pero ya no el precio directo.
 *
 * Modelo multi-vendedor: el precio y el vendedor NO se copian aqui. El
 * unico puntero que hace falta es `id_precio_historial`:
 *
 *   pedido_producto.id_precio_historial
 *     -> precio_historial.precio      cuanto se cobro
 *     -> precio_historial.id_oferta
 *          -> oferta.id_usuario       quien vendio
 *
 * Funciona porque cada eslabon es INMUTABLE (ver docs/base-de-datos.md).
 * Lo que SI se copia es `nombre_vendedor`, junto con nombre_producto y
 * nombre_variante: esos tres cambian con el tiempo y no se pueden deducir,
 * a diferencia del precio.
 *
 * id_producto_mongo e id_producto_variante_mongo no son llaves foraneas
 * (el catalogo vive en MongoDB, no en PostgreSQL): estan aqui solo para
 * poder volver al documento si hace falta.
 */
export interface PedidoProducto {
  id_pedido_producto: string;
  id_pedido: string;
  id_precio_historial: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  cantidad: number;
  nombre_producto: string;
  nombre_variante: string;
  nombre_vendedor: string;
}

/**
 * Una linea de pedido con el precio y la oferta ya resueltos (JOIN contra
 * precio_historial y oferta), tal como los necesita GET
 * /comprador/pedidos/:id para mostrar la orden completa. Ver
 * PedidosCompradorService.obtener().
 */
export interface DetallePedido extends PedidoProducto {
  /**
   * El precio que de verdad se cobro por esta linea, congelado al
   * agregarla al carrito -- YA con el descuento aplicado, si la oferta
   * tenia uno vigente en ese momento (ver `porcentaje_descuento_aplicado`
   * y `helpers/precio-descuento.ts`). numeric(12,2) de Postgres: string.
   */
  precio_unitario: string;
  /** El % de descuento que tenia la oferta cuando se congelo este precio, o `null` -- solo informativo, `precio_unitario` ya lo tiene aplicado. */
  porcentaje_descuento_aplicado: string | null;
  id_oferta: string;
  id_usuario_vendedor: string;
  /**
   * El id de la resena si esta cuenta ya reseno ESTE producto a ESTE
   * vendedor (el trio id_usuario/id_usuario_vendedor/id_producto_mongo, el
   * mismo que protege el UNIQUE de `resena`); `null` si todavia no. Nombre
   * y forma fijados por `docs/BACKEND-PENDIENTE.md` (bloque 5) -- el
   * frontend ya esta escrito contra este campo, no contra un booleano.
   */
  id_resena: string | null;
  /**
   * `true` si esta linea cumple la regla de `POST /resenas`: comprado y
   * pagado ESE producto a ESE vendedor (pedido no cancelado, misma
   * condicion que `ResenasService.exigirCompraPagada`), todavia sin
   * resenar, y el vendedor no es la propia cuenta (la tabla `resena` tiene
   * `CHECK (id_usuario <> id_usuario_vendedor)`; sin esta comprobacion el
   * boton apareceria y el POST reventaria). Calculado aca para que el
   * frontend muestre el boton "Resenar" directo desde el pedido sin
   * pegarle aparte a /resenas/comprobar-compra.
   */
  puede_resenar: boolean;
}
