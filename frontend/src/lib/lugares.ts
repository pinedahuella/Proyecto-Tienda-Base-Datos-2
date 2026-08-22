/**
 * Paises, departamentos y ciudades para el formulario de direcciones.
 *
 * Los datos salen de countriesnow.space, que es publica y no pide llave. Se
 * usan tres de sus rutas, y cada una se pide solo cuando hace falta:
 *
 *   /countries/states                              paises con sus departamentos
 *   /countries/state/cities/q?country=&state=      ciudades de un departamento
 *   /countries/cities/q?country=                   ciudades de un pais entero
 *
 * La lista de paises con departamentos pesa unos 226 KB y se baja una sola vez
 * al abrir el formulario. Las otras dos son de unos pocos KB y se piden segun
 * lo que el usuario vaya eligiendo. Existe una cuarta ruta que trae todos los
 * paises con todas sus ciudades de golpe, pero pesa 971 KB y ademas trae menos
 * ciudades que la ruta por pais: Guatemala sale con 43 ahi y con 394 aqui.
 *
 * Lo que se midio antes de escribir esto, sobre los 246 paises que devuelve:
 *
 *   195 tienen departamentos y 50 no. Por eso ese campo no puede depender de
 *   que exista una lista: para Aruba o las Islas Caiman no hay ninguna.
 *
 *   Tener departamentos no garantiza tener ciudades por departamento. Espana y
 *   Francia devuelven cero ciudades en todos sus estados, y sin embargo tienen
 *   7635 y 15974 a nivel pais. Por eso la ciudad cae al listado del pais
 *   cuando el del departamento sale vacio.
 *
 *   6 paises no tienen ciudades por ningun lado (Monaco, Kiribati, Tonga,
 *   Vaticano, Islas Marianas del Norte y Heard e Islas McDonald). Ahi no queda
 *   mas que escribir a mano.
 *
 *   Y las rutas no llaman igual a los mismos paises: 31 nombres solo existen en
 *   la de departamentos y 13 solo en la de ciudades ("Fiji Islands" contra
 *   "Fiji", "Man (Isle of)" contra "Isle of Man"). Por eso las ciudades se
 *   piden con el nombre que vino de la propia respuesta y nunca con uno
 *   escrito a mano.
 *
 * Nada de esto es seguridad: es calidad del dato. Quien llame a la API del
 * backend por su cuenta puede mandar el pais que quiera, porque alla solo se
 * revisa que no venga vacio y que no pase de 100 caracteres.
 */

const BASE = 'https://countriesnow.space/api/v0.1';

/** Cuanto se espera a la API antes de darla por caida y dejar escribir a mano. */
const ESPERA_MS = 12000;

export interface Pais {
	nombre: string;
	/** Como vino en la respuesta. Es el que hay que mandar de vuelta a la API. */
	departamentos: string[];
}

/**
 * Cada pais llama distinto a su division de en medio. Guatemala tiene
 * departamentos, Mexico estados, Espana provincias y Japon prefecturas, y la
 * API lo dice pegando la palabra al final del nombre: "Alta Verapaz
 * Department", "Alajuela Province", "Aichi Prefecture".
 *
 * Se contaron las 246 respuestas: aparecen 14 palabras distintas, y 70 paises
 * no traen ninguna (Mexico, Estados Unidos, Francia, Alemania, Brasil, Italia).
 * De ahi salen las dos funciones de abajo.
 */
const TIPOS: Record<string, string> = {
	Department: 'Departamento',
	Province: 'Provincia',
	Prefecture: 'Prefectura',
	Region: 'Region',
	State: 'Estado',
	County: 'Condado',
	District: 'Distrito',
	Governorate: 'Gobernacion',
	Parish: 'Parroquia',
	Municipality: 'Municipio',
	Canton: 'Canton',
	Oblast: 'Oblast',
	Territory: 'Territorio',
	Emirate: 'Emirato',
	Division: 'Division',
	Voivodeship: 'Voivodato'
};

const SUFIJO = new RegExp(' (' + Object.keys(TIPOS).join('|') + ')$');

/**
 * El nombre sin la palabra del tipo, que es como se escribe en una direccion:
 * "Sacatepequez" y no "Sacatepequez Department". El original se conserva
 * aparte porque es el que la API entiende cuando se le piden las ciudades.
 */
export function paraLeer(departamento: string): string {
	return departamento.replace(SUFIJO, '');
}

/**
 * Como rotular el campo para el pais que se eligio. Se mira que palabra usan
 * sus divisiones y se traduce; si no traen ninguna se pone algo neutro, porque
 * inventarle "Departamento" a Mexico seria decir algo falso.
 */
export function etiquetaDivision(departamentos: string[]): string {
	const cuenta: Record<string, number> = {};
	for (const d of departamentos) {
		const m = d.match(SUFIJO);
		if (m) cuenta[m[1]] = (cuenta[m[1]] ?? 0) + 1;
	}

	const gana = Object.entries(cuenta).sort((a, b) => b[1] - a[1])[0];
	return gana ? TIPOS[gana[0]] : 'Estado o provincia';
}

/** fetch con limite de tiempo. Sin esto una API lenta deja el formulario colgado. */
async function traer(ruta: string): Promise<unknown> {
	const corte = new AbortController();
	const reloj = setTimeout(() => corte.abort(), ESPERA_MS);
	try {
		const respuesta = await fetch(BASE + ruta, { signal: corte.signal });
		if (!respuesta.ok) throw new Error(String(respuesta.status));
		return await respuesta.json();
	} finally {
		clearTimeout(reloj);
	}
}

/**
 * Los paises con sus departamentos.
 *
 * Devuelve una lista vacia si la API no contesta. Quien llama tiene que
 * tratar esa lista vacia como "no hay sugerencias, que escriba a mano", no
 * como "no hay paises": si no, el formulario se vuelve imposible de enviar sin
 * decir por que.
 */
export async function cargarPaises(): Promise<Pais[]> {
	try {
		const cuerpo = (await traer('/countries/states')) as {
			error?: boolean;
			data?: { name: string; states?: { name: string }[] }[];
		};
		if (cuerpo.error || !cuerpo.data) return [];

		return cuerpo.data
			.map((p) => ({
				nombre: p.name,
				departamentos: (p.states ?? []).map((e) => e.name).sort((a, b) => a.localeCompare(b))
			}))
			.sort((a, b) => a.nombre.localeCompare(b.nombre));
	} catch {
		return [];
	}
}

/** Las ciudades de un departamento. Lista vacia si no hay o si la API fallo. */
export async function ciudadesDeDepartamento(pais: string, departamento: string): Promise<string[]> {
	try {
		const cuerpo = (await traer(
			`/countries/state/cities/q?country=${encodeURIComponent(pais)}&state=${encodeURIComponent(departamento)}`
		)) as { error?: boolean; data?: string[] };
		if (cuerpo.error || !cuerpo.data) return [];
		return cuerpo.data.slice().sort((a, b) => a.localeCompare(b));
	} catch {
		return [];
	}
}

/** Las ciudades de un pais entero. Es el respaldo cuando el departamento no da ninguna. */
export async function ciudadesDePais(pais: string): Promise<string[]> {
	try {
		const cuerpo = (await traer(`/countries/cities/q?country=${encodeURIComponent(pais)}`)) as {
			error?: boolean;
			data?: string[];
		};
		if (cuerpo.error || !cuerpo.data) return [];
		return cuerpo.data.slice().sort((a, b) => a.localeCompare(b));
	} catch {
		return [];
	}
}
