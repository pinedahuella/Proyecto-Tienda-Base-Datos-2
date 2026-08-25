import { TarjetaPeticion } from './tarjeta-pago';

/**
 * Cuerpo esperado en POST /comprador/pedidos/:id/comprar.
 *
 * `tarjeta` solo hace falta (y solo se mira) cuando metodo_pago es
 * "tarjeta" -- ver helpers/validaciones-tarjeta.ts. Para "transferencia" o
 * "efectivo contra entrega" se ignora si viene.
 */
export interface ComprarPedidoPeticion {
  metodo_pago: string;
  tarjeta?: TarjetaPeticion;
  /**
   * Antes de comprar se revisa que ninguna oferta del pedido haya
   * cambiado desde que se agrego al carrito (ver
   * PedidosCompradorService.revisarCambiosAntesDeComprar). Si el UNICO
   * cambio es que el precio de hoy ya no es el que quedo congelado --que
   * no afecta lo que se va a cobrar, pero la persona merece saberlo--, la
   * respuesta sale con `comprado: false` y la lista de avisos, sin haber
   * comprado nada. Reenviar la misma peticion con esto en `true` deja
   * pasar la compra igual. No sirve para saltarse un bloqueo de verdad
   * (oferta pausada/retirada o sin stock): esos siempre rechazan con 409,
   * pase lo que pase con esta bandera.
   */
  confirmar_cambios?: boolean;
}

/** Una oferta cuyo stock quedo en un numero nuevo despues de comprar/cancelar. */
export interface StockResultanteOferta {
  id_oferta: number;
  id_usuario: number;
  id_producto: number;
  id_producto_variante: number;
  stock: number;
}

/** Un cambio de precio detectado al revisar antes de comprar: informativo, no bloquea. */
export interface AvisoPrecioPedido {
  id_pedido_producto: number;
  nombre_producto: string;
  nombre_variante: string;
  precio_congelado: string;
  precio_actual: string;
}

/** La compra se completo: lo que devuelve comprar_pedido() de PostgreSQL. */
export interface CompraExitosa {
  comprado: true;
  id_pedido: number;
  /** numeric(12,2), como texto. */
  total: string;
  stock: StockResultanteOferta[];
}

/**
 * Todavia no se compro nada: al menos un precio cambio desde que se agrego
 * al carrito y `confirmar_cambios` no vino en true. Ningun dato se toco en
 * PostgreSQL -- es seguro reintentar la misma peticion con
 * `confirmar_cambios: true` para comprar de todos modos.
 */
export interface CompraPendienteDeConfirmar {
  comprado: false;
  avisos: AvisoPrecioPedido[];
}

/** Respuesta de POST /comprador/pedidos/:id/comprar. */
export type ComprarPedidoRespuesta = CompraExitosa | CompraPendienteDeConfirmar;
