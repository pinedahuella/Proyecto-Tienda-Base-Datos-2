/**
 * Los tres eventos de analitica que el NAVEGADOR tiene que avisar (los
 * otros tres del plan -- compra, devolucion, busqueda_realizada -- los
 * dispara el backend solo, sin que el frontend haga nada). Ver
 * `backend/elementos Generales/endpoints/endpoints-eventos.md`.
 *
 * Las tres funciones de aqui son fire-and-forget A PROPOSITO, igual que la
 * ruta que llaman: nunca se espera con `await` desde donde se usan, y nunca
 * lanzan -- un fallo aqui (ClickHouse caido, la red, lo que sea) no tiene
 * que interrumpir a nadie mirando un producto, buscando algo o comprando.
 * Por eso ninguna revisa `respuesta.ok`: si la escritura fallo, no hay nada
 * que la persona pueda hacer al respecto, y avisarle seria alarmar por un
 * dato que ni siquiera es suyo.
 */

import { pedir, conJson } from './api';
import { sesionAnalitica } from './sesionAnalitica';

export type OrigenVista = 'catalogo' | 'buscador' | 'enlace_directo';

/** POST /eventos/vista -- se vio la ficha de un producto. Publica: funciona sin sesion iniciada. */
export function registrarVista(idProducto: number, origen: OrigenVista): void {
	void pedir(
		'/eventos/vista',
		conJson('POST', {
			id_producto: idProducto,
			sesion: sesionAnalitica(),
			origen
		})
	);
}

/** POST /eventos/busqueda-clic -- se hizo clic en un resultado de busqueda. Publica. */
export function registrarClicBusqueda(termino: string, idProducto: number, posicion: number): void {
	void pedir(
		'/eventos/busqueda-clic',
		conJson('POST', {
			termino,
			id_producto: idProducto,
			posicion,
			sesion: sesionAnalitica()
		})
	);
}

/**
 * POST /eventos/carrito -- se agrego un producto al carrito. Exige sesion
 * (el carrito siempre exige cuenta en este proyecto, no hay carrito de
 * invitado): si no hay sesion, el backend contesta 401 y aqui simplemente
 * se ignora -- no es un error que valga la pena mostrar, porque agregar al
 * carrito sin sesion nunca deberia haber sido posible en primer lugar.
 */
export function registrarCarrito(idProducto: number, idOferta: number, cantidad: number): void {
	void pedir(
		'/eventos/carrito',
		conJson('POST', {
			id_producto: idProducto,
			id_oferta: idOferta,
			cantidad
		})
	);
}
