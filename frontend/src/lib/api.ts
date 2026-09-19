/**
 * Lo minimo para hablar con el backend.
 *
 * El navegador no le habla al backend directo: le pide a `/api` del mismo
 * sitio que sirvio la pagina, y el proxy de `vite.config.ts` lo pasa al
 * backend. Asi funciona igual en `localhost:5173` que por un tunel desde un
 * celular, sin saber la direccion del tunel, sin CORS y con la cookie de
 * sesion en el mismo sitio. Ver docs/ENTRAR-DESDE-EL-CELULAR.md.
 *
 * El `localhost:3000` es solo para cuando esto corre en el servidor al
 * renderizar, donde un `/api` suelto no tiene a quien pedirle. Si el backend
 * cambia de puerto, se cambia aqui y en `vite.config.ts`.
 */
export const API = typeof window === 'undefined' ? 'http://localhost:3000' : '/api';

/**
 * La forma unica de respuesta de la API: todos los endpoints devuelven
 * estos tres campos, salga bien o salga mal. Esta explicado en
 * backend/elementos Generales/api.md
 */
export interface RespuestaApi<T> {
	ok: boolean;
	mensaje: string;
	payload: T;
	/**
	 * El codigo HTTP con el que contesto el backend, o 0 si la peticion ni
	 * llego a salir.
	 *
	 * Hace falta porque no todos los fallos se tratan igual: un 401 quiere
	 * decir que la sesion se acabo y hay que mandar a iniciar sesion, pero un
	 * 503 o un 0 quieren decir que el problema es del servidor y la sesion
	 * puede seguir buena. Con solo "ok" los dos casos se ven identicos.
	 */
	estado: number;
}

/**
 * El proxy de Vite (vite.config.ts) pone esta cabecera cuando NO alcanzo al
 * backend, por ejemplo mientras se reinicia. Quiere decir que la peticion nunca
 * llego, asi que reintentarla es seguro aunque sea un POST.
 */
const CABECERA_PROXY = 'x-mesh-proxy-error';

/** Cuantas veces se reintenta y cuanto se espera entre una y otra: unos 12 segundos, lo que tarda `nest start --watch` en volver. */
const REINTENTOS = 8;
const ESPERA_MS = 1500;

const esperar = (ms: number) => new Promise<void>((resolver) => setTimeout(resolver, ms));

/**
 * fetch, pero aguanta que el backend se este reiniciando.
 *
 * Reintenta en dos casos y solo en el navegador (al renderizar en el servidor
 * no hay proxy, y hacer esperar al HTML doce segundos seria peor):
 *
 *   - el proxy dijo que no llego al backend (cabecera de arriba): cualquier
 *     metodo, porque no hubo nada que duplicar;
 *   - el fetch fallo del todo (sin red) y era un GET: repetir una lectura no
 *     cambia nada. Un POST que fallo asi NO se reintenta: puede haber llegado.
 *
 * Si se agotan los intentos devuelve la ultima respuesta, que es el JSON del
 * proxy con el texto de "se esta reiniciando", o relanza el error de red.
 */
async function conReintento(url: string, opciones: RequestInit): Promise<Response> {
	const metodo = (opciones.method ?? 'GET').toUpperCase();
	const reintenta = typeof window !== 'undefined';

	for (let intento = 0; ; intento++) {
		const agotado = !reintenta || intento >= REINTENTOS || opciones.signal?.aborted === true;
		try {
			const respuesta = await fetch(url, opciones);
			if (agotado || respuesta.headers.get(CABECERA_PROXY) !== '1') return respuesta;
		} catch (error) {
			if (agotado || metodo !== 'GET') throw error;
		}
		await esperar(ESPERA_MS);
	}
}

/**
 * Hace la peticion y siempre devuelve una RespuestaApi, nunca lanza.
 *
 * Es a proposito: el backend ya responde con la misma forma en 200, 400,
 * 409, 503 y 500, asi que lo unico que se sale de ese molde es que la
 * peticion no llegue (backend apagado, sin red) o que conteste algo que no
 * es JSON. Esos dos casos se traducen aqui a la misma forma, para que quien
 * llama solo tenga que mirar "ok" y no tambien envolver todo en try/catch.
 */
export async function pedir<T>(ruta: string, opciones: RequestInit = {}): Promise<RespuestaApi<T>> {
	let respuesta: Response;

	try {
		respuesta = await conReintento(`${API}${ruta}`, {
			// credentials para que el navegador mande y guarde la cookie de
			// sesion que pone /usuario/login. El registro todavia no la usa,
			// pero el resto de las rutas si.
			credentials: 'include',
			...opciones
		});
	} catch {
		return {
			ok: false,
			mensaje: 'No se pudo contactar al servidor. Revisa que el backend este corriendo.',
			payload: null as T,
			estado: 0
		};
	}

	try {
		const cuerpo = (await respuesta.json()) as RespuestaApi<T>;
		return { ...cuerpo, estado: respuesta.status };
	} catch {
		return {
			ok: false,
			mensaje: 'El servidor respondio algo inesperado.',
			payload: null as T,
			estado: respuesta.status
		};
	}
}

/**
 * El texto que se le puede ensenar a una persona cuando algo falla.
 *
 * El backend de Mesh contesta con mensajes escritos para leerse ("No existe
 * una oferta con ese id"), asi que lo normal es que devuelva el suyo tal cual.
 * Esto es una RED, para los casos en que lo que llega no es eso:
 *
 *   - la peticion no salio (backend apagado, sin red): `estado` es 0
 *   - el cuerpo no traia `mensaje` -- por ejemplo un 404 de Nest, que usa
 *     `message` y no `mensaje`, o un proxy que se metio en el medio. Sin esto,
 *     el mensaje quedaba en `undefined` y la caja de error salia VACIA
 *   - el texto es de maquina y no de persona: "Cannot PATCH /vendedor/ofertas",
 *     un volcado de pila, un HTML entero
 *
 * Lo ultimo es lo que hay que atajar de verdad. Que alguien que esta
 * publicando una oferta lea la palabra PATCH no le dice nada y le hace pensar
 * que rompio algo: no es su vocabulario, es el nuestro. Se cambia por un texto
 * que si le sirve, y el original queda en la consola para quien lo tenga que
 * depurar -- porque esconderselo a la persona no es motivo para perderlo.
 */
export function mensajeUtil(respuesta: {
	mensaje?: string;
	/**
	 * El nombre que usa Nest cuando contesta EL, y no un controlador de Mesh.
	 * Un 404 de ruta inexistente llega asi:
	 *
	 *   { "message": "Cannot GET /admin/eventos/tendencias",
	 *     "error": "Not Found", "statusCode": 404 }
	 *
	 * Hay que leerlo, y hasta el 2026-09-06 no se leia. Ver abajo.
	 */
	message?: string;
	estado: number;
}): string {
	const generico = 'No se pudo completar la operacion. Intenta de nuevo.';

	if (respuesta.estado === 0) {
		return 'No se pudo conectar con el servidor. Revisa que el backend este corriendo.';
	}

	// SE MIRAN LOS DOS NOMBRES, Y ESA LINEA ES LA QUE HACIA FALTA.
	//
	// Aqui se leia solo `mensaje`. El comentario de arriba ya decia que el caso
	// a cubrir era "un 404 de Nest, que usa `message` y no `mensaje`", pero el
	// codigo nunca miraba ese campo: `pedir()` devuelve el cuerpo tal cual, asi
	// que en un 404 de Nest `mensaje` viene undefined, `texto` quedaba vacio, y
	// la funcion se iba por el `return generico` de la linea siguiente.
	//
	// O sea que la deteccion de mensajes de maquina y la frase especial del 404
	// -- las dos cosas que esta funcion existe para hacer -- eran CODIGO MUERTO
	// justo en el caso para el que se escribieron. Nunca se ejecutaron ni una
	// vez. Se encontro el 2026-09-06 mirando la pantalla de Tendencias, que
	// pedia una ruta que el backend todavia no publica: en vez de "esa opcion
	// todavia no esta disponible", salia el generico.
	//
	// `mensaje` va primero a proposito: cuando un controlador de Mesh contesta,
	// el suyo es el bueno y esta escrito para leerse.
	const texto = String(respuesta.mensaje ?? respuesta.message ?? '').trim();
	if (texto === '') return generico;

	// Lo que delata a un mensaje de maquina. Se mira el verbo HTTP solo cuando
	// va pegado a una ruta ("PATCH /algo"), para no censurar una frase legitima
	// que por casualidad lleve una de esas palabras.
	const deMaquina =
		/\b(?:GET|POST|PATCH|PUT|DELETE)\s+\//.test(texto) ||
		/^Cannot\s/i.test(texto) ||
		/\b(?:ECONNREFUSED|ETIMEDOUT|ENOTFOUND|ERR_[A-Z_]+)\b/.test(texto) ||
		/\bat\s+\S+\s+\(.*:\d+:\d+\)/.test(texto) ||
		/^\s*<(?:!doctype|html)\b/i.test(texto);

	if (deMaquina) {
		console.warn('[Mesh] el servidor devolvio un mensaje tecnico:', texto);
		if (respuesta.estado === 404) {
			return 'Esa opcion todavia no esta disponible en el servidor.';
		}
		return generico;
	}

	return texto;
}

/** Atajo para las peticiones que mandan un cuerpo JSON. */
export function conJson(metodo: string, cuerpo: unknown): RequestInit {
	return {
		method: metodo,
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify(cuerpo)
	};
}
