/**
 * Cuerpo esperado en PATCH /vendedor/ofertas/:id.
 *
 * Los tres campos son opcionales, pero al menos uno tiene que venir. Cada
 * uno cae en la tabla que le corresponde, no se registra a mano en esta
 * ruta: `precio` lo escribe el trigger `trg_oferta_registrar_precio` en
 * `precio_historial`; `ajuste_stock` lo escribe `reponer_stock()` en
 * `stock_movimiento`.
 */
export interface EditarOfertaPeticion {
  /** Mismo formato que al crear: numero > 0, hasta 2 decimales. */
  precio?: string;
  estado?: string;
  /** Entero != 0. Positivo repone stock, negativo lo corrige a la baja. */
  ajuste_stock?: number;
}
