import { TarjetaPeticion } from './tarjeta-pago';
import { StockResultanteOferta } from './comprar-pedido';

/**
 * Cuerpo esperado en POST /carrito/comprar.
 *
 * `id_direccion` es el id normal (el que devuelve GET /direccion-usuario);
 * el backend resuelve su version vigente en `direccion_historial`.
 * `tarjeta` solo se mira cuando `metodo_pago` es "tarjeta".
 *
 * No hay `confirmar_cambios`: el carrito de Redis no guarda el precio que
 * se vio, asi que `comprar_carrito()` congela el precio del momento de
 * pagar, que es el mismo que muestra `GET /carrito`. La ventana de carrera
 * entre ver y pagar se cerraria guardando `id_precio_historial` en el
 * carrito -- pendiente (fase 2), ver endpoints-carrito.md.
 */
export interface ComprarCarritoPeticion {
  id_direccion: number | string;
  metodo_pago: string;
  tarjeta?: TarjetaPeticion;
}

/** Respuesta de POST /carrito/comprar cuando la compra se completa. */
export interface ComprarCarritoRespuesta {
  comprado: true;
  /** El pedido que nacio. Con este se abre el detalle de la compra. */
  id_pedido: number;
  /** numeric(12,2), como texto. */
  total: string;
  /** El stock resultante de cada oferta tocada -- lo que ya se puso al dia en Mongo. */
  stock: StockResultanteOferta[];
}
