import { browser } from '$app/environment';
import { pedir, conJson, type RespuestaApi } from './api';

/**
 * El pedido abierto, y lo minimo para hablar con /comprador/pedidos.
 *
 * Las cuatro rutas que expuso el backend (ninguna pide rol, solo sesion:
 * comprar no es privilegio de un rol, cualquiera con cuenta compra):
 *   POST   /comprador/pedidos                        abre un pedido
 *   GET    /comprador/pedidos/:id                    el pedido, su direccion y sus lineas
 *   POST   /comprador/pedidos/:id/detalles           agrega (o suma) una linea
 *   DELETE /comprador/pedidos/:id/detalles/:idDetalle quita una linea
 *
 * OJO, dos cosas que cambian como hay que escribir el frontend:
 *
 * 1. NO hay ruta para listar los pedidos de uno, solo GET por id. Asi que el
 *    id del pedido abierto hay que recordarlo aqui; si se pierde, el pedido
 *    sigue existiendo en la base pero desde el navegador ya no se llega a el.
 *    Por eso vive en localStorage y no en memoria.
 *
 * 2. NO hay ruta para cerrar la compra. La funcion comprar_pedido() existe en
 *    PostgreSQL, pero el backend todavia no la expone: el pedido se queda en
 *    su estado inicial. Agregar lineas tampoco descuenta stock -- solo lo lee
 *    para avisar. Nada de esto se puede tapar desde aqui, asi que la pantalla
 *    lo dice tal cual en vez de ensenar un boton de "Comprar" que no existe.
 */

/**
 * El id del pedido abierto vive en localStorage, no en una cookie ni en la
 * URL: no es un secreto (el backend comprueba que el pedido sea tuyo y da 404
 * si no lo es) y tiene que sobrevivir a recargar la pagina.
 */
const LLAVE = 'mesh.pedido';

export interface LineaPedido {
	id_pedido_producto: string;
	id_pedido: string;
	id_producto_mongo: string;
	id_producto_variante_mongo: string;
	nombre_producto: string;
	nombre_variante: string;
	/** Decimal de PostgreSQL: viaja como texto para no perder centavos. */
	precio_unitario: string;
	porcentaje_comision: string;
	cantidad: number;
}

export interface CabeceraPedido {
	id_pedido: string;
	fecha_creacion: string;
	id_usuario: string;
	id_direccion_historial: string;
	id_estado_pedido: number;
	estado_pedido_nombre: string;
}

/**
 * La VERSION de la direccion que regia al crear el pedido, no la direccion
 * vigente hoy: por eso trae su propia fecha_creacion, que es desde cuando
 * rige esa version.
 */
export interface DireccionDelPedido {
	id_direccion_historial: string;
	id_direccion: string;
	pais: string;
	departamento: string;
	ciudad: string;
	codigo_postal: string | null;
	fecha_creacion: string;
}

/** Lo que devuelve GET /comprador/pedidos/:id. */
export interface PedidoCompleto {
	pedido: CabeceraPedido;
	direccion: DireccionDelPedido;
	detalles: LineaPedido[];
}

/** Lo que devuelve POST /comprador/pedidos/:id/detalles. */
export interface LineaAgregada {
	id_pedido: number;
	id_producto: number;
	id_producto_variante: number;
	/** La cantidad ACUMULADA de esa variante en el pedido, no la de esta llamada. */
	cantidad: number;
	stock_disponible: number;
}

export function leerPedidoAbierto(): string | null {
	if (!browser) return null;
	return localStorage.getItem(LLAVE);
}

export function guardarPedidoAbierto(idPedido: string) {
	if (!browser) return;
	localStorage.setItem(LLAVE, idPedido);
}

export function olvidarPedidoAbierto() {
	if (!browser) return;
	localStorage.removeItem(LLAVE);
}

/** Abre un pedido nuevo sobre una direccion del usuario. */
export function crearPedido(idDireccion: string | number) {
	return pedir<{ id_pedido: string }>(
		'/comprador/pedidos',
		conJson('POST', { id_direccion: Number(idDireccion) })
	);
}

export function traerPedido(idPedido: string) {
	return pedir<PedidoCompleto>(`/comprador/pedidos/${idPedido}`);
}

export function agregarLinea(
	idPedido: string,
	linea: { id_producto: number; id_producto_variante: number; cantidad: number }
) {
	return pedir<LineaAgregada>(
		`/comprador/pedidos/${idPedido}/detalles`,
		conJson('POST', linea)
	);
}

export function quitarLinea(idPedido: string, idDetalle: string) {
	return pedir<null>(`/comprador/pedidos/${idPedido}/detalles/${idDetalle}`, {
		method: 'DELETE'
	});
}

/**
 * Lo que cuesta una linea. El precio viaja como texto (es un decimal de
 * PostgreSQL) y hay que convertirlo aqui, no antes: hacerlo en el backend
 * seria devolver un float y ahi es donde se pierden los centavos.
 */
export function subtotal(linea: LineaPedido): number {
	return Number(linea.precio_unitario) * linea.cantidad;
}

export function totalPedido(detalles: LineaPedido[]): number {
	return detalles.reduce((suma, linea) => suma + subtotal(linea), 0);
}

export function quetzales(n: number): string {
	return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/**
 * true si la respuesta dice que el pedido guardado ya no sirve.
 *
 * El backend da 404 tanto si el pedido no existe como si es de otra persona
 * (no confirma por esta via que exista uno ajeno). En los dos casos lo que
 * hay guardado en este navegador esta caduco y hay que olvidarlo, o la
 * pantalla se queda pidiendo para siempre un pedido que nunca va a llegar.
 */
export function pedidoCaduco(r: RespuestaApi<unknown>): boolean {
	return r.estado === 404;
}
