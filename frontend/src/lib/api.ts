/**
 * Lo minimo para hablar con el backend.
 *
 * La direccion esta aqui y no repartida por las paginas: si el backend
 * cambia de puerto, se cambia en esta linea y nada mas.
 */
export const API = 'http://localhost:3000';

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
		respuesta = await fetch(`${API}${ruta}`, {
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
export function mensajeUtil(respuesta: { mensaje?: string; estado: number }): string {
	const generico = 'No se pudo completar la operacion. Intenta de nuevo.';

	if (respuesta.estado === 0) {
		return 'No se pudo conectar con el servidor. Revisa que el backend este corriendo.';
	}

	const texto = String(respuesta.mensaje ?? '').trim();
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
