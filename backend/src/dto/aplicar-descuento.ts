/**
 * Cuerpo de `POST /vendedor/ofertas/:id/descuento`.
 *
 * `oferta.precio` nunca se toca por esto -- sigue siendo el precio de
 * lista. Ver `helpers/validaciones-oferta.ts` (`validarPorcentajeDescuento`)
 * para el rango exacto (1-90).
 */
export interface AplicarDescuentoPeticion {
  porcentaje_descuento: number;
}
