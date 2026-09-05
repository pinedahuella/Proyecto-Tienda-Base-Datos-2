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
	categoria: string | null;
	/** El mas barato entre todos los vendedores. */
	precio_desde: number | null;
	/** El de la tienda, que es el que se ensena primero. */
	precio_tienda: number | null;
	stock_total: number;
	resenas_promedio: number;
	resenas_total: number;
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
 */
export async function buscarProductos(texto: string, limite = 20): Promise<Busqueda> {
	const consulta = texto.trim();
	if (consulta.length < MINIMO_LETRAS) {
		return { resultados: [], error: '' };
	}

	const ruta = `/buscador/productos?nombre=${encodeURIComponent(consulta)}&limite=${limite}`;
	const respuesta = await pedir<ResultadoBusqueda[]>(ruta);

	if (!respuesta.ok) {
		return { resultados: [], error: mensajeUtil(respuesta) };
	}

	// El payload de un 200 siempre es una lista, pero se comprueba: si el dia
	// de manana llega otra cosa, es preferible una busqueda sin resultados a
	// un `.map is not a function` que tumba la pagina entera.
	const lista = Array.isArray(respuesta.payload) ? respuesta.payload : [];
	return { resultados: lista, error: '' };
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
