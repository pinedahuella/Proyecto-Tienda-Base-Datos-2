import { pedir } from './api';

/**
 * El estado del carrito, compartido por toda la aplicacion.
 *
 * Existe porque el carrito es UNO solo y se abre desde cualquier parte: desde
 * la ficha al agregar algo, desde el boton de la cabecera, desde el panel.
 * Si cada pagina montara el suyo, la cuenta que ensena la cabecera y lo que
 * hay dentro del panel se irian separando.
 *
 * Va en un archivo `.svelte.ts` porque las runas ($state) solo funcionan en
 * archivos que Svelte compila, y un `.ts` normal no lo es.
 *
 * OJO con lo que este modulo NO es: no guarda las lineas. La verdad de lo que
 * hay en el carrito vive en REDIS y la pide el propio CarritoRedis.svelte cada
 * vez que se abre. Aqui solo esta lo que hace falta para pintar el boton --
 * cuantas lineas hay -- y si el panel esta abierto.
 *
 * Esto cambio con la Entrega 2: antes el carrito era una fila de `pedido` en
 * `pendiente` de PostgreSQL, con su id en localStorage. Ya no hay id que
 * guardar -- el carrito es de la CUENTA y sale del token -- asi que tampoco
 * hay que buscarlo entre los pedidos propios al entrar desde otro navegador:
 * simplemente esta.
 */

/**
 * El estado vive suelto en el modulo y la clase solo lo expone con getters.
 *
 * Es la forma que recomienda Svelte 5 para el estado compartido entre modulos:
 * la dependencia se registra donde se lee de verdad, sin depender de como se
 * exporte el objeto que lo envuelve.
 */
let _abierto = $state(false);
let _cuenta = $state(-1);

class EstadoCarrito {
	/** Si el panel lateral se ve. */
	get abierto() {
		return _abierto;
	}

	/**
	 * Cuantas LINEAS tiene el pedido pendiente. No cuantas unidades: dos
	 * unidades de la misma oferta son una sola linea, y la burbuja cuenta
	 * cosas distintas en el carrito, que es lo que la gente espera.
	 *
	 * -1 quiere decir "todavia no lo se". Se distingue de 0 a proposito: con
	 * los dos en 0, la burbuja parpadearia en "vacio" en cada carga antes de
	 * saber la verdad.
	 */
	get cuenta() {
		return _cuenta;
	}

	abrir() {
		_abierto = true;
	}

	cerrar() {
		_abierto = false;
	}

	alternar() {
		_abierto = !_abierto;
	}

	/** Para cuando ya se sabe el numero exacto y no hace falta preguntar. */
	fijarCuenta(n: number) {
		_cuenta = n;
	}

	olvidar() {
		_cuenta = -1;
		_abierto = false;
	}

	/**
	 * Vuelve a contar preguntandole al backend.
	 *
	 * Si no hay un pedido guardado en este navegador, lo busca entre los
	 * propios: asi la burbuja aparece bien al entrar desde otro dispositivo, o
	 * despues de que se borrara el localStorage, sin que la persona tenga que
	 * volver a armar el carrito.
	 *
	 * Nunca lanza: es un adorno de la cabecera. Si falla, se queda con lo que
	 * sabia y ya; tumbar la pagina por no poder pintar una burbuja seria
	 * cambiar un detalle por la pantalla entera.
	 */
	async recontar(): Promise<void> {
		try {
			// UNA peticion, y ya no hace falta el rodeo de antes: se leia el id
			// del localStorage, se pedia ese pedido, y si no servia se listaban
			// todos los pedidos propios para encontrar el pendiente. Tres
			// caminos posibles para contestar "cuantas lineas tengo".
			//
			// Con el carrito en Redis la clave sale del token, asi que la
			// pregunta se contesta preguntando.
			const r = await pedir<{ total_lineas: number }>('/carrito');

			// 401 = no hay sesion. No es 0: es "no se sabe", y pintar un cero
			// donde no se sabe es lo que hacia parpadear la burbuja.
			if (r.estado === 401) {
				_cuenta = -1;
				return;
			}

			if (r.ok && r.payload) _cuenta = r.payload.total_lineas;
		} catch {
			// Ver arriba: sin red no se sabe, y no saber no se pinta como cero.
		}
	}
}

export const carrito = new EstadoCarrito();
