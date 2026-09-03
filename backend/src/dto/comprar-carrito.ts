import { TarjetaPeticion } from './tarjeta-pago';
import { StockResultanteOferta } from './comprar-pedido';

/** El precio que el cliente vio para una oferta, para comparar contra el actual al pagar. */
export interface LineaPrecioVistoCarrito {
  id_oferta: number;
  /** numeric(12,2) como texto, tal cual lo devolvio `precio` en GET /carrito. */
  precio_visto: string;
}

/**
 * Cuerpo esperado en POST /carrito/comprar.
 *
 * `id_direccion` es el id normal (el que devuelve GET /direccion-usuario);
 * el backend resuelve su version vigente en `direccion_historial`.
 * `tarjeta` solo se mira cuando `metodo_pago` es "tarjeta".
 *
 * El carrito de Redis no guarda el precio que se vio -- es el FRONTEND
 * quien tiene que acordarse del `precio` que le mostro el ultimo
 * `GET /carrito` (guardandolo en su lado, no en Redis) y mandarlo de vuelta
 * aca en `lineas_precio_visto`. Si para alguna oferta el precio actual ya
 * no coincide, la respuesta sale con `comprado: false` y la lista de
 * `avisos`, sin cobrar nada. Reenviar la misma peticion con
 * `confirmar_cambios: true` deja pasar la compra al precio de hoy. No sirve
 * para saltarse un bloqueo real (oferta pausada/retirada o sin stock): eso
 * siempre rechaza con 409. Mismo criterio que
 * `POST /comprador/pedidos/:id/comprar` (ver comprar-pedido.ts).
 */
export interface ComprarCarritoPeticion {
  id_direccion: number | string;
  metodo_pago: string;
  tarjeta?: TarjetaPeticion;
  lineas_precio_visto?: LineaPrecioVistoCarrito[];
  confirmar_cambios?: boolean;
}

/** Un cambio de precio detectado al pagar: informativo, no bloquea. */
export interface AvisoPrecioCarrito {
  id_oferta: number;
  nombre_producto: string;
  nombre_variante: string;
  precio_visto: string;
  precio_actual: string;
}

/** Respuesta de POST /carrito/comprar cuando la compra se completa. */
export interface CompraCarritoExitosa {
  comprado: true;
  /** El pedido que nacio. Con este se abre el detalle de la compra. */
  id_pedido: number;
  /** numeric(12,2), como texto. */
  total: string;
  /** El stock resultante de cada oferta tocada -- lo que ya se puso al dia en Mongo. */
  stock: StockResultanteOferta[];
}

/**
 * Todavia no se compro nada: al menos un precio cambio desde que se vio el
 * carrito y `confirmar_cambios` no vino en true. Ningun dato se toco -- es
 * seguro reintentar la misma peticion con `confirmar_cambios: true`.
 */
export interface CompraCarritoPendienteDeConfirmar {
  comprado: false;
  avisos: AvisoPrecioCarrito[];
}

export type ComprarCarritoRespuesta =
  | CompraCarritoExitosa
  | CompraCarritoPendienteDeConfirmar;
