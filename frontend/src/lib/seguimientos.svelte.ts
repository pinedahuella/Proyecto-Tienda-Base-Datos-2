import { conJson, pedir } from './api';

/**
 * Los seguimientos de ofertas, el "avisame" del comprador (Jose David,
 * 2026-10-17, plan pendiente/seguimiento-ofertas.md).
 *
 *   POST   /comprador/seguimientos              pide un aviso
 *   GET    /comprador/seguimientos              los suyos (?estado=activos|cumplidos)
 *   DELETE /comprador/seguimientos/:id          lo borra (y su aviso con el)
 *   GET    /comprador/seguimientos/avisos       los avisos (?no_leidos=true) y cuantos sin leer
 *   PATCH  /comprador/seguimientos/avisos/:id   { leido: true | false }
 *
 * Dos tipos:
 *   busqueda     busco algo, no lo encontro, y quiere saber cuando llegue
 *   baja_precio  esta viendo una variante y quiere saber cuando baje
 *
 * Cada seguimiento vive en PostgreSQL y, mientras espera, como una consulta
 * guardada en el percolator de Elasticsearch. Cada oferta que cambia pasa por
 * ahi, y la primera que cumple da UN solo aviso. Solo avisa cuando una oferta
 * CAMBIA: una que ya cumplia y no se mueve no dispara nada.
 *
 * Todas piden sesion y ningun rol: comprar no es privilegio de nadie.
 *
 * Va en un `.svelte.ts` por el contador de no leidos, que comparten la
 * cabecera y el panel: con dos copias, marcar uno como leido en el panel no
 * bajaria el numero de arriba.
 */

export interface Seguimiento {
	id_seguimiento: string;
	tipo: 'busqueda' | 'baja_precio';
	texto: string | null;
	precio_maximo: string | null;
	id_producto: string | null;
	id_producto_variante: string | null;
	nombre_producto: string | null;
	nombre_variante: string | null;
	precio_referencia: string | null;
	solo_tienda: boolean;
	fecha_creacion: string;
	/** null = sigue esperando. */
	fecha_cumplido: string | null;
	id_aviso: string | null;
}

export interface AvisoSeguimiento {
	id_aviso: string;
	leido: boolean;
	fecha_aviso: string;
	fecha_leida: string | null;
	/** El precio que tenia la oferta cuando aviso. Despues puede cambiar. */
	precio_final_aviso: string;
	seguimiento: {
		id_seguimiento: string;
		tipo: 'busqueda' | 'baja_precio';
		texto: string | null;
		precio_maximo: string | null;
		precio_referencia: string | null;
		solo_tienda: boolean;
	};
	/** La oferta como esta AHORA, no como estaba al avisar. */
	oferta: {
		id_oferta: string;
		id_producto: string;
		id_producto_variante: string;
		nombre_producto: string;
		nombre_variante: string;
		vendedor_usuario: string;
		precio_final: string;
		stock: number;
		estado: string;
	};
}

export function seguirBusqueda(texto: string, precioMaximo?: string) {
	return pedir<Seguimiento>(
		'/comprador/seguimientos',
		conJson('POST', {
			tipo: 'busqueda',
			texto,
			...(precioMaximo ? { precio_maximo: precioMaximo } : {})
		})
	);
}

/**
 * Sin `precio_referencia` el backend toma el precio final mas bajo de ese
 * momento (el de la tienda si `soloTienda`), y avisa cuando una oferta quede
 * POR DEBAJO. Si no hay ninguna oferta activa con stock contesta 400.
 */
export function seguirBajaDePrecio(idProducto: number | string, idVariante: number | string, soloTienda = false) {
	return pedir<Seguimiento>(
		'/comprador/seguimientos',
		conJson('POST', {
			tipo: 'baja_precio',
			id_producto: Number(idProducto),
			id_producto_variante: Number(idVariante),
			solo_tienda: soloTienda
		})
	);
}

export function listarSeguimientos(estado?: 'activos' | 'cumplidos') {
	return pedir<Seguimiento[]>(`/comprador/seguimientos${estado ? `?estado=${estado}` : ''}`);
}

export function borrarSeguimiento(id: string) {
	return pedir(`/comprador/seguimientos/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

export function listarAvisos(soloNoLeidos = false) {
	return pedir<{ avisos: AvisoSeguimiento[]; total_no_leidos: number }>(
		`/comprador/seguimientos/avisos${soloNoLeidos ? '?no_leidos=true' : ''}`
	);
}

export function marcarAviso(id: string, leido: boolean) {
	return pedir(`/comprador/seguimientos/avisos/${encodeURIComponent(id)}`, conJson('PATCH', { leido }));
}

/**
 * Cuantos avisos sin leer tiene la cuenta. -1 = todavia no se sabe (sin
 * sesion, o sin preguntar), para que el numero no parpadee en 0.
 */
let _noLeidos = $state(-1);

class ContadorAvisos {
	get noLeidos() {
		return _noLeidos;
	}

	fijar(n: number) {
		_noLeidos = n;
	}

	/** Nunca lanza: es un adorno de la cabecera. */
	async recontar(): Promise<void> {
		try {
			const r = await listarAvisos(true);
			if (r.estado === 401) {
				_noLeidos = -1;
				return;
			}
			if (r.ok && r.payload) _noLeidos = r.payload.total_no_leidos;
		} catch {
			// Sin red no se sabe, y no saber no se pinta como cero.
		}
	}
}

export const avisos = new ContadorAvisos();
