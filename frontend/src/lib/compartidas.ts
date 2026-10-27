import { conJson, pedir, type RespuestaApi } from './api';

/**
 * El ACL de la aplicacion, por oferta (migracion 049, ADR-24).
 *
 * El dueno de una oferta le da a otra cuenta de vendedor permiso para verla,
 * editar su precio y su existencia, o ponerle y quitarle descuento. Lo que no
 * esta en la lista se niega: el backend contesta 404, igual que una oferta
 * ajena.
 *
 *   Lo que reparte el dueno   /vendedor/ofertas/:id/permisos      CompartirOferta.svelte
 *   Lo que me compartieron    /compartidas/ofertas                OfertasCompartidas.svelte
 */

export type PermisoOferta = 'ver' | 'editar' | 'descuento';

export const PERMISOS: { valor: PermisoOferta; texto: string; ayuda: string }[] = [
	{ valor: 'ver', texto: 'Ver', ayuda: 'Mirar precio, descuento y existencia' },
	{ valor: 'editar', texto: 'Editar', ayuda: 'Cambiar el precio y la existencia' },
	{ valor: 'descuento', texto: 'Descuento', ayuda: 'Poner y quitar el descuento' }
];

export function textoPermiso(p: string): string {
	return PERMISOS.find((x) => x.valor === p)?.texto ?? p;
}

export interface CuentaPermiso {
	id_usuario: string;
	usuario: string;
	nombre: string;
	apellido: string | null;
	correo: string;
}

export interface EntradaPermiso {
	id_permiso_oferta: string;
	permiso: PermisoOferta;
	receptor: CuentaPermiso;
	otorgado_por: string;
	fecha_otorgado: string;
	fecha_vencimiento: string | null;
	vigente: boolean;
}

export interface RegistroPermiso {
	fecha: string;
	accion: 'otorgar' | 'revocar' | 'editar' | 'poner_descuento' | 'quitar_descuento' | 'negado';
	permiso: string | null;
	actor: string | null;
	receptor: string | null;
	detalle: Record<string, unknown>;
}

export interface PermisosDeOferta {
	permisos: EntradaPermiso[];
	registro: RegistroPermiso[];
}

export interface OfertaCompartida {
	id_oferta: string;
	id_producto: string;
	id_variante: string;
	producto: string | null;
	variante: string | null;
	imagen: string | null;
	precio: string;
	porcentaje_descuento: string | null;
	precio_final: string;
	stock: number;
	estado: string;
	es_inventario_limitado: boolean;
	fecha_vencimiento_descuento: string | null;
	dueno: CuentaPermiso;
	permisos: { permiso: PermisoOferta; fecha_vencimiento: string | null }[];
}

// ---------- el dueno ----------

export function leerPermisos(idOferta: string): Promise<RespuestaApi<PermisosDeOferta>> {
	return pedir<PermisosDeOferta>(`/vendedor/ofertas/${idOferta}/permisos`);
}

export function darPermisos(
	idOferta: string,
	correo: string,
	permisos: PermisoOferta[],
	fechaVencimiento: string | null
): Promise<RespuestaApi<PermisosDeOferta>> {
	return pedir<PermisosDeOferta>(
		`/vendedor/ofertas/${idOferta}/permisos`,
		conJson('POST', { correo, permisos, fecha_vencimiento: fechaVencimiento })
	);
}

export function quitarPermiso(idOferta: string, idPermiso: string): Promise<RespuestaApi<PermisosDeOferta>> {
	return pedir<PermisosDeOferta>(`/vendedor/ofertas/${idOferta}/permisos/${idPermiso}`, {
		method: 'DELETE'
	});
}

// ---------- quien recibe ----------

export function listarCompartidas(): Promise<RespuestaApi<OfertaCompartida[]>> {
	return pedir<OfertaCompartida[]>('/compartidas/ofertas');
}

export function editarCompartida(
	idOferta: string,
	cambios: { precio?: string; ajuste_stock?: number }
): Promise<RespuestaApi<unknown>> {
	return pedir<unknown>(`/compartidas/ofertas/${idOferta}`, conJson('PATCH', cambios));
}

export function ponerDescuentoCompartida(idOferta: string, porcentaje: number): Promise<RespuestaApi<unknown>> {
	return pedir<unknown>(
		`/compartidas/ofertas/${idOferta}/descuento`,
		conJson('POST', { porcentaje_descuento: porcentaje })
	);
}

export function quitarDescuentoCompartida(idOferta: string): Promise<RespuestaApi<unknown>> {
	return pedir<unknown>(`/compartidas/ofertas/${idOferta}/descuento`, { method: 'DELETE' });
}

// ---------- textos ----------

export function quetzales(valor: string | number | null): string {
	const n = Number(valor ?? 0);
	return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export function fechaCorta(valor: string | null): string {
	if (!valor) return '';
	const d = new Date(valor);
	if (Number.isNaN(d.getTime())) return '';
	return d.toLocaleString('es-GT', {
		day: 'numeric',
		month: 'short',
		hour: '2-digit',
		minute: '2-digit'
	});
}

/** Una fila del registro, en una frase corta. */
export function textoRegistro(r: RegistroPermiso): string {
	const quien = r.actor ?? 'alguien';
	const permiso = r.permiso ? textoPermiso(r.permiso).toLowerCase() : '';
	switch (r.accion) {
		case 'otorgar':
			return `${quien} le dio ${permiso} a ${r.receptor ?? 'otra cuenta'}`;
		case 'revocar':
			return `${quien} le quito ${permiso} a ${r.receptor ?? 'otra cuenta'}`;
		case 'editar': {
			const partes: string[] = [];
			if (r.detalle?.precio != null) partes.push(`precio a ${quetzales(String(r.detalle.precio))}`);
			if (r.detalle?.ajuste_stock != null) {
				const n = Number(r.detalle.ajuste_stock);
				partes.push(`existencia ${n > 0 ? '+' : ''}${n}`);
			}
			return `${quien} cambio ${partes.join(' y ') || 'la oferta'}`;
		}
		case 'poner_descuento':
			return `${quien} puso ${String(r.detalle?.porcentaje_descuento ?? '')}% de descuento`;
		case 'quitar_descuento':
			return `${quien} quito el descuento`;
		case 'negado':
			return `A ${quien} se le nego ${permiso || 'el paso'}`;
		default:
			return quien;
	}
}
