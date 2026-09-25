/**
 * Cuerpo de `POST /vendedor/ofertas/:id/descuento`.
 *
 * `oferta.precio` nunca se toca por esto -- sigue siendo el precio de
 * lista. Ver `helpers/validaciones-oferta.ts` (`validarPorcentajeDescuento`)
 * para el rango exacto (1-90).
 *
 * `duracion_segundos` (agregado 2026-09-24) es puramente interno -- al
 * cliente no le llega ni le importa. Cuando cierra el descuento por su
 * cuenta: pasado ese tiempo, `VentasLimitadasService.revisarVencidas()` lo
 * quita solo, mismo mecanismo (TTL de Redis) que ya tenia
 * `POST .../venta-limitada`. Opcional -- sin el (o con `0`), el descuento
 * no vence por si solo y hay que quitarlo a mano con el `DELETE`, igual
 * que siempre.
 */
export interface AplicarDescuentoPeticion {
  porcentaje_descuento: number;
  duracion_segundos?: number;
}
