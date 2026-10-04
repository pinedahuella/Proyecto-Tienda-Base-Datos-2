/**
 * El buscador de la Entrega 3, del lado del navegador.
 *
 * Habla con GET /buscador/productos, que consulta el indice `mesh_productos`
 * de Elasticsearch. Ese indice es una PROYECCION que carga
 * `etl/cargar_busqueda.sh` desde el catalogo de MongoDB, asi que lo que
 * devuelve es un RESUMEN por producto -- lo justo para pintar una fila de
 * resultados -- y no el producto entero. Para el detalle esta la ficha,
 * /producto/:id, que sigue leyendo de MongoDB.
 *
 * Por que existe este archivo y no se llama a `pedir` desde el componente:
 * la cabecera y la pagina de resultados hacen LA MISMA consulta con distinto
 * limite, y el trato de la respuesta (que hacer con un 400, con un 503, con
 * una tanda vacia) tiene que ser identico en las dos. Escrito dos veces se
 * separa a la primera correccion.
 */

import { pedir, mensajeUtil } from './api';
import { sesionAnalitica } from './sesionAnalitica';

/**
 * Un resultado tal como lo devuelve el indice. Es el mismo contrato que
 * documenta `backend/elementos Generales/endpoints-buscador.md`.
 *
 * `categoria` y los dos precios pueden venir nulos: el documento indexado
 * los copia del catalogo, y en el catalogo un producto puede estar sin
 * categoria o todavia sin precio de tienda.
 */
export interface ResultadoBusqueda {
	id_producto: number;
	nombre: string;
	/**
	 * En la ruta publica SIEMPRE llega "activo": ese filtro esta fijo del lado
	 * del backend y no se puede pedir otra cosa. En la de admin puede ser
	 * cualquiera, y es justo lo que deja distinguir un producto rechazado de
	 * uno vivo en la misma lista.
	 */
	estado: string;
	categoria: string | null;
	/** El mas barato entre todos los vendedores. */
	precio_desde: number | null;
	/** El de la tienda, que es el que se ensena primero. */
	precio_tienda: number | null;
	stock_total: number;
	resenas_promedio: number;
	resenas_total: number;
	/**
	 * Alguna presentacion tiene una oferta con descuento. Llega desde 37ad2e6
	 * (2026-09-26); un indice armado antes no lo trae, por eso es opcional.
	 */
	hay_descuento?: boolean;
}

/**
 * Lo que sale de una busqueda: o la lista, o el motivo por el que no hay
 * lista. Nunca las dos cosas, y nunca ninguna.
 *
 * Se devuelve asi, y no lanzando, por la misma razon que `pedir`: quien
 * llama tiene que poder pintar el error en pantalla, y un try/catch alrededor
 * de cada busqueda en cada componente es la forma segura de que un dia falte
 * uno y la pagina se quede en blanco sin decir nada.
 */
export interface Busqueda {
	resultados: ResultadoBusqueda[];
	/** Vacio cuando la consulta salio bien, aunque no haya encontrado nada. */
	error: string;
	/**
	 * "Tal vez quisiste decir": lo escrito con las palabras mal tecleadas
	 * cambiadas por la sugerencia de Elasticsearch, o null si estaba bien. Lo
	 * manda el backend desde 3305cf3; la ruta de admin no lo trae.
	 */
	quisiste_decir?: string | null;
}

/** Lo minimo que se escribe antes de molestar al servidor. */
export const MINIMO_LETRAS = 2;

/**
 * Busca en el indice.
 *
 * `limite` lo acota tambien el backend (20 por defecto, 50 de tope), asi que
 * aqui no se valida: mandar el numero y dejar que la fuente de verdad lo
 * recorte es mejor que tener dos topes que un dia dejan de coincidir.
 *
 * Un texto mas corto que MINIMO_LETRAS no llega a salir. No es un capricho de
 * rendimiento: con una sola letra la busqueda difusa (`fuzziness: AUTO`)
 * engancha medio catalogo y la lista que sale no ayuda a nadie a elegir.
 *
 * `verTodo` cambia de ruta, no de parametro: son DOS rutas distintas en el
 * backend, `/buscador/productos` y `/buscador/productos/admin`. La segunda
 * pide sesion de admin y no filtra por estado, asi que trae tambien lo que no
 * circula -- propuestas en revision, rechazadas, pausadas. Al backend no se le
 * puede pedir "sin filtro" desde la ruta publica: ese filtro esta fijo en su
 * codigo, y esta bien que lo este.
 */
export async function buscarProductos(
	texto: string,
	limite = 20,
	verTodo = false
): Promise<Busqueda> {
	const consulta = texto.trim();
	if (consulta.length < MINIMO_LETRAS) {
		return { resultados: [], error: '' };
	}

	const base = verTodo ? '/buscador/productos/admin' : '/buscador/productos';
	let ruta = `${base}?nombre=${encodeURIComponent(consulta)}&limite=${limite}`;

	// El evento `busqueda_realizada` en ClickHouse lo dispara el backend SOLO,
	// enganchado a esta misma peticion -- nunca a la de admin (ver
	// endpoints-eventos.md): las busquedas de un admin revisando el catalogo
	// no son parte del embudo de un comprador real, y mandar `sesion` ahi
	// contaminaria la analitica sin que nadie lo pidiera.
	if (!verTodo) {
		ruta += `&sesion=${encodeURIComponent(sesionAnalitica())}`;
	}

	const respuesta = await pedir<ResultadoBusqueda[] | { resultados?: ResultadoBusqueda[]; quisiste_decir?: string | null }>(ruta);

	if (!respuesta.ok) {
		return { resultados: [], error: mensajeUtil(respuesta) };
	}

	// La ruta publica devuelve { resultados, quisiste_decir } desde 3305cf3, y
	// la de admin sigue devolviendo la lista sola. Se aceptan las dos formas:
	// leer solo la lista dejaba la cabecera con cero resultados y sin ningun
	// error, que es justo lo que paso al jalar ese commit.
	const p = respuesta.payload;
	if (Array.isArray(p)) return { resultados: p, error: '' };
	return {
		resultados: Array.isArray(p?.resultados) ? p.resultados : [],
		error: '',
		quisiste_decir: p?.quisiste_decir ?? null
	};
}

/** Un resultado de la busqueda hibrida: el resumen de siempre y por donde salio. */
export interface ResultadoHibrido extends ResultadoBusqueda {
	puntaje: number;
	/** 'texto' por las palabras, 'significado' por el vector, o los dos. */
	origen: ('texto' | 'significado')[];
	similitud: number | null;
}

/**
 * La busqueda hibrida, GET /buscador/productos/hibrida (3305cf3 y 1f1f480):
 * las palabras y el significado juntos en una sola lista, ordenada por
 * posicion en las dos (RRF). "labtop gamer" sale por las palabras y "algo
 * para escuchar musica mientras corro" por el significado.
 *
 * `modo` es 'solo_texto' cuando Ollama no contesto: la lista sale igual, solo
 * con las palabras. No registra el evento de analitica; por eso /buscar la pide
 * junto con la facetada, que si lo registra y trae los filtros.
 */
export async function buscarHibrida(
	texto: string,
	limite = 50
): Promise<{ resultados: ResultadoHibrido[]; error: string; modo: string | null }> {
	const consulta = texto.trim();
	if (consulta.length < MINIMO_LETRAS) return { resultados: [], error: '', modo: null };
	const respuesta = await pedir<{ modo?: string; resultados?: ResultadoHibrido[] }>(
		`/buscador/productos/hibrida?q=${encodeURIComponent(consulta)}&limite=${limite}`
	);
	if (!respuesta.ok) return { resultados: [], error: mensajeUtil(respuesta), modo: null };
	const p = respuesta.payload ?? {};
	return { resultados: Array.isArray(p.resultados) ? p.resultados : [], error: '', modo: p.modo ?? null };
}

/** La resena que explica por que un producto salio en la busqueda por intencion. */
export interface MotivoIntencion {
	id_resena: number;
	calificacion: number;
	comentario: string;
	/** Que tan cerca esta de lo que se pidio, de 0 a 1. */
	similitud: number;
}

export interface ResultadoIntencion extends ResultadoBusqueda {
	puntaje: number;
	origen: ('resenas' | 'producto')[];
	/** null si el producto salio solo por su descripcion. */
	motivo: MotivoIntencion | null;
	resenas_coincidentes: number;
}

/**
 * Cuando lo escrito parece una frase y no el nombre de un producto. Con tres
 * palabras o mas ("algo para salir a pedalear") la busqueda por nombre casi
 * nunca acierta, y es justo el caso de la busqueda por intencion.
 */
export function pareceFrase(texto: string): boolean {
	return texto.trim().split(/\s+/).filter((p) => p.length > 1).length >= 3;
}

/**
 * Que resultado de la busqueda por intencion vale la pena ensenar.
 *
 * El backend deja pasar un producto con parecido 0,40 a su descripcion, y
 * medido el 2026-10-04 eso es poco: "xqzwv", que no significa nada, traia seis
 * productos con 0,41. Y como no agrupa las copias del generador, una frase
 * sobre ciclismo llenaba la lista con el mismo maillot cinco veces. Aqui se
 * pide mas: una resena que se parezca de verdad (0,5 o mas), o un producto que
 * se parezca mucho (0,6 o mas). Se le dejo dicho a Jose David en
 * docs/BACKEND-PENDIENTE.md para que lo resuelva en la ruta.
 */
export function vale(r: ResultadoIntencion): boolean {
	return (r.motivo !== null && r.motivo.similitud >= 0.5) || r.puntaje >= 0.6;
}

/**
 * La busqueda por intencion, GET /buscador/productos/intencion.
 *
 * Quien busca dice lo que quiere lograr y salen productos cuyas resenas (o
 * descripcion) se parecen en significado, aunque no compartan una palabra. Lo
 * resuelve el backend con los vectores que ya viven en Elasticsearch, y cada
 * resultado trae la resena que lo explica (`motivo`).
 *
 * Nunca rompe la pagina: si la ruta no existe o Ollama no contesta, devuelve
 * la lista vacia con el error, y quien llama decide si lo ensena.
 */
export async function buscarPorIntencion(texto: string, limite = 6): Promise<{ resultados: ResultadoIntencion[]; error: string }> {
	const consulta = texto.trim();
	if (consulta.length < MINIMO_LETRAS) return { resultados: [], error: '' };
	const respuesta = await pedir<ResultadoIntencion[]>(
		`/buscador/productos/intencion?q=${encodeURIComponent(consulta)}&limite=${limite}`
	);
	if (!respuesta.ok) return { resultados: [], error: mensajeUtil(respuesta) };
	return { resultados: Array.isArray(respuesta.payload) ? respuesta.payload : [], error: '' };
}

/** Los quetzales se escriben igual en todas partes que en el catalogo. */
export function quetzales(n: number): string {
	return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/**
 * El precio que se ensena de un resultado.
 *
 * Primero el de la tienda, que es la regla del catalogo. Si un producto no
 * tiene precio de tienda pero si lo vende alguien, se ensena ese en vez de
 * dejar el hueco: el indice guarda los dos justo para esto.
 */
export function precioVisible(r: ResultadoBusqueda): string | null {
	if (r.precio_tienda && r.precio_tienda > 0) return quetzales(r.precio_tienda);
	if (r.precio_desde && r.precio_desde > 0) return quetzales(r.precio_desde);
	return null;
}

/**
 * El segundo precio, cuando alguien lo tiene mas barato que la tienda.
 *
 * Devuelve null si el de la tienda ya es el mejor, para no pintar dos numeros
 * iguales, y tambien cuando no hay precio de tienda: en ese caso el de abajo
 * ya subio arriba y repetirlo seria decir lo mismo dos veces.
 */
export function precioSegundo(r: ResultadoBusqueda): string | null {
	const tienda = r.precio_tienda ?? 0;
	const desde = r.precio_desde ?? 0;
	if (desde <= 0 || tienda <= 0) return null;
	if (desde >= tienda) return null;
	return quetzales(desde);
}

/**
 * Como se lee la nota de un producto en una fila de resultados.
 *
 * Sin resenas NO se escribe "0 estrellas": el indice guarda 0 tanto para
 * "le pusieron cero" como para "nadie lo ha calificado", y son cosas muy
 * distintas de leer cuando estas eligiendo que comprar. Con `resenas_total`
 * en 0 se distingue, y se dice.
 */
export function nota(r: ResultadoBusqueda): string | null {
	if (r.resenas_total <= 0) return null;
	const puntos = r.resenas_promedio.toFixed(1);
	const cuantas = r.resenas_total === 1 ? '1 resena' : `${r.resenas_total} resenas`;
	return `${puntos} de 5 con ${cuantas}`;
}

/**
 * Si un resultado hay que marcarlo por su estado.
 *
 * Solo aparece con la busqueda de admin, que es la unica que trae productos
 * que no estan activos. En la publica todos llegan "activo" y una etiqueta
 * que dice lo mismo en todas las filas no informa de nada, asi que no sale.
 */
export function marcaDeEstado(r: ResultadoBusqueda): string | null {
	if (!r.estado || r.estado === 'activo') return null;
	return r.estado;
}

/**
 * Los filtros facetados del buscador (Entrega 3).
 *
 * La consulta de Elasticsearch esta hecha y probada en `elastic/pruebas/facetas.py`
 * (`consulta()`), y la ruta que la sirve la pide `docs/BACKEND-PENDIENTE.md`:
 *
 *   GET /buscador/productos/facetado?nombre=&categoria=7,9&precio=250-500
 *       &calificacion=4-o-mas&disponible=si&limite=&sesion=
 *
 * Mientras esa ruta no exista contesta 404, y entonces se cae a la busqueda de
 * siempre sin facetas: la pagina no se rompe, solo no pinta el panel.
 */
export interface OpcionFaceta {
	clave: string;
	nombre: string;
	cantidad: number;
}

export interface Facetas {
	categoria: OpcionFaceta[];
	precio: OpcionFaceta[];
	calificacion: OpcionFaceta[];
	disponible: number;
}

/** Lo elegido, con las mismas claves que viajan en la direccion y a la ruta. */
export interface Elegidos {
	categoria: string[];
	precio: string[];
	calificacion: string[];
	disponible: boolean;
}

export const NOMBRE_PRECIO: Record<string, string> = {
	'hasta-250': 'Hasta Q250',
	'250-500': 'Q250 a Q500',
	'500-1000': 'Q500 a Q1,000',
	'1000-3000': 'Q1,000 a Q3,000',
	'desde-3000': 'Mas de Q3,000'
};

export const NOMBRE_CALIFICACION: Record<string, string> = {
	'4-o-mas': '4 estrellas o mas',
	'3-o-mas': '3 estrellas o mas'
};

export interface BusquedaFacetada extends Busqueda {
	/** null si la ruta todavia no existe o no mando facetas. */
	facetas: Facetas | null;
	total: number;
}

interface PayloadFacetado {
	resultados?: ResultadoBusqueda[];
	total?: number;
	quisiste_decir?: string | null;
	facetas?: {
		categoria?: { id: number | string; nombre: string; cantidad: number }[];
		precio?: { clave: string; cantidad: number }[];
		calificacion?: { clave: string; cantidad: number }[];
		disponible?: number;
	};
}

export async function buscarFacetado(texto: string, elegidos: Elegidos, limite = 50): Promise<BusquedaFacetada> {
	const consulta = texto.trim();
	if (consulta.length < MINIMO_LETRAS) {
		return { resultados: [], error: '', facetas: null, total: 0 };
	}

	const partes = [`nombre=${encodeURIComponent(consulta)}`, `limite=${limite}`];
	if (elegidos.categoria.length) partes.push(`categoria=${encodeURIComponent(elegidos.categoria.join(','))}`);
	if (elegidos.precio.length) partes.push(`precio=${encodeURIComponent(elegidos.precio.join(','))}`);
	if (elegidos.calificacion.length) partes.push(`calificacion=${encodeURIComponent(elegidos.calificacion.join(','))}`);
	if (elegidos.disponible) partes.push('disponible=si');
	partes.push(`sesion=${encodeURIComponent(sesionAnalitica())}`);

	const respuesta = await pedir<PayloadFacetado>(`/buscador/productos/facetado?${partes.join('&')}`);

	if (respuesta.estado === 404) {
		const simple = await buscarProductos(consulta, limite);
		return { ...simple, facetas: null, total: simple.resultados.length };
	}
	if (!respuesta.ok) {
		return { resultados: [], error: mensajeUtil(respuesta), facetas: null, total: 0 };
	}

	const p = respuesta.payload ?? {};
	const resultados = Array.isArray(p.resultados) ? p.resultados : [];
	const f = p.facetas;
	const facetas: Facetas | null = f
		? {
				categoria: (f.categoria ?? []).map((c) => ({ clave: String(c.id), nombre: c.nombre, cantidad: c.cantidad })),
				precio: (f.precio ?? []).map((c) => ({ clave: c.clave, nombre: NOMBRE_PRECIO[c.clave] ?? c.clave, cantidad: c.cantidad })),
				calificacion: (f.calificacion ?? []).map((c) => ({
					clave: c.clave,
					nombre: NOMBRE_CALIFICACION[c.clave] ?? c.clave,
					cantidad: c.cantidad
				})),
				disponible: f.disponible ?? 0
			}
		: null;
	return { resultados, error: '', facetas, total: p.total ?? resultados.length, quisiste_decir: p.quisiste_decir ?? null };
}
