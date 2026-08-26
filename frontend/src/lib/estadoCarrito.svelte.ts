import { leerPedidoAbierto, listarPedidos, traerPedido, guardarPedidoAbierto } from './pedido';

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
 * hay en el pedido vive en PostgreSQL y la pide el propio Carrito.svelte cada
 * vez que se abre. Aqui solo esta lo que hace falta para pintar el boton --
 * cuantas lineas hay -- y si el panel esta abierto.
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
			const guardado = leerPedidoAbierto();

			if (guardado) {
				const r = await traerPedido(guardado);
				if (r.ok && r.payload) {
					_cuenta = r.payload.detalles.length;
					return;
				}
				// 404: el pedido guardado ya no sirve (no existe, o es de otra
				// cuenta). Se sigue de largo y se busca entre los propios.
				if (r.estado !== 404) return;
			}

			const rLista = await listarPedidos();
			if (!rLista.ok || !rLista.payload) return;

			const pendiente = rLista.payload.find((p) => p.estado_pedido_nombre === 'pendiente');
			if (!pendiente) {
				_cuenta = 0;
				return;
			}

			guardarPedidoAbierto(pendiente.id_pedido);
			_cuenta = pendiente.cantidad_lineas;
		} catch {
			// Ver arriba: sin red no se sabe, y no saber no se pinta como cero.
		}
	}
}

export const carrito = new EstadoCarrito();
