/**
 * Cuerpo de `POST /vendedor/ofertas/:id/venta-limitada`.
 *
 * `duracion_segundos` es CUANDO CIERRA la venta relampago entera: pasado
 * ese tiempo, las dos claves de Redis de la oferta desaparecen solas y la
 * venta vuelve al flujo normal. Es opcional -- sin el (o con `0`), la venta
 * no vence por si sola y hay que cerrarla a mano con el `DELETE`.
 *
 * No confundir con el plazo de una reserva individual del comprador
 * (`TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS`, 15 min), que es otra cosa:
 * esa es cuanto le dura a una persona lo que aparto antes de pagar.
 */
export interface AbrirVentaLimitadaPeticion {
  duracion_segundos?: number;
}
