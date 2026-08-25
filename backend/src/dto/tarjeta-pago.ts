/**
 * La tarjeta que manda el cliente en POST /comprador/pedidos/:id/comprar
 * cuando metodo_pago es "tarjeta". Solo existe en memoria durante la
 * peticion: no hay ninguna tabla que la guarde (ver
 * helpers/validaciones-tarjeta.ts) y nunca se escribe en un log.
 */
export interface TarjetaPeticion {
  numero: string;
  /** Formato MM/AA, por ejemplo "08/27". */
  vencimiento: string;
  cvv: string;
  titular: string;
}
