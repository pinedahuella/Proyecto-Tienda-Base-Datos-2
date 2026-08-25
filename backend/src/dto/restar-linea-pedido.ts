/**
 * Cuerpo esperado en PATCH /comprador/pedidos/:id/detalles.
 *
 * El "-1" de POST /comprador/pedidos/:id/detalles (que suma): mismo
 * id_oferta y cantidad, pero resta en vez de sumar. Si la resta deja la
 * cantidad en 0 o menos, la linea se borra entera -- no hace falta un
 * DELETE aparte para eso.
 */
export interface RestarLineaPeticion {
  id_oferta: number;
  cantidad: number;
}

/** Respuesta de PATCH /comprador/pedidos/:id/detalles. */
export interface LineaRestada {
  id_pedido: number;
  /** Ausente si la resta dejo la linea en 0 y se borro (eliminada: true). */
  id_pedido_producto?: number;
  id_oferta: number;
  cantidad: number;
  /** true si la resta dejo la cantidad en 0 o menos y la linea se borro. */
  eliminada: boolean;
}
