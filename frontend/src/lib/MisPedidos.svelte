<script lang="ts">
	import { onMount } from 'svelte';
	import type { RespuestaApi } from './api';
	import { fade, fly } from 'svelte/transition';
	import {
		cancelarPedido,
		listarPedidos,
		quetzales,
		subtotal,
		totalPedido,
		traerOfertaEnFecha,
		traerPedido,
		traerProductoEnFecha,
		type CaracteristicaEnFecha,
		type LineaPedido,
		type OfertaEnFecha,
		type PedidoCompleto,
		type ProductoEnFecha,
		type ResumenPedido
	} from './pedido';
	import { textoPorcentaje, tieneDescuento } from './descuento';

	/**
	 * El historial de pedidos de quien esta logueado.
	 *
	 * Dos rutas y media, mas una del catalogo:
	 *   GET  /comprador/pedidos              la lista resumida (sin lineas)
	 *   GET  /comprador/pedidos/:id          el detalle, solo al desplegar uno
	 *   POST /comprador/pedidos/:id/cancelar cancelar
	 *   GET  /productos/:id/historial        el producto como estaba ese dia
	 *   GET  /productos/ofertas/:id/historial  su precio y stock ese dia
	 *
	 * La lista y el detalle son dos peticiones a proposito: el resumen ya trae
	 * total y cantidad de lineas calculados, asi que pedir el detalle de los 30
	 * pedidos para pintar una lista serian 30 consultas para no ensenar nada
	 * que no estuviera ya en la primera.
	 *
	 * Esta pantalla no ARMA pedidos: eso es del carrito. Aqui solo se mira lo
	 * que ya paso, y lo unico que se puede cambiar es cancelar.
	 */

	let { alExpirarSesion }: { alExpirarSesion?: () => void } = $props();

	// ---------------------------------------------------------------- estado
	let pedidos = $state<ResumenPedido[]>([]);
	let cargando = $state(true);
	let error = $state('');
	let aviso = $state('');

	/** 'todos' o el nombre de un estado. El filtro es local, la ruta los trae todos. */
	let filtro = $state('todos');

	/**
	 * El detalle ya traido, por id de pedido.
	 *
	 * Se guarda para que cerrar y volver a abrir una fila no gaste otra
	 * peticion: el detalle de un pedido no cambia solo -- excepto al
	 * cancelarlo, y ahi se borra su entrada a mano (ver cancelar()).
	 */
	let detalles = $state<Record<string, PedidoCompleto>>({});

	/** El pedido desplegado. Uno a la vez: dos abiertos no caben en pantalla. */
	let abierto = $state<string | null>(null);
	let cargandoDetalle = $state<string | null>(null);
	/** El fallo del detalle va por pedido, no en la variable general: el error de una fila no habla de la lista. */
	let errorDetalle = $state<Record<string, string>>({});

	/** El pedido cuya cancelacion se esta confirmando, y el que se esta cancelando. */
	let confirmando = $state<string | null>(null);
	let cancelando = $state<string | null>(null);

	// ---------------------------------------------------------------- helpers
	/** true si la sesion se acabo. Se avisa al panel para que saque a la persona. */
	function expiro(r: RespuestaApi<unknown>): boolean {
		if (r.estado === 401) {
			alExpirarSesion?.();
			return true;
		}
		return false;
	}

	function textoDelFallo(r: RespuestaApi<unknown>): string {
		return r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
	}

	/**
	 * Los cinco estados del catalogo, en el orden en que ocurren.
	 *
	 * Solo ordena las pestanas: cual existe de verdad lo dice lo que se trajo,
	 * y un estado que el backend agregue despues igual aparece (ver
	 * estadosPresentes), solo que al final.
	 */
	const ORDEN_ESTADOS = ['pendiente', 'comprado', 'enviado', 'entregado', 'cancelado'];

	/** Un pedido se cancela mientras nadie lo despacho. El backend rechaza el resto con 409. */
	const CANCELABLES = ['pendiente', 'comprado'];

	function sePuedeCancelar(p: ResumenPedido): boolean {
		return CANCELABLES.includes(p.estado_pedido_nombre);
	}

	/**
	 * Los precios viajan como texto (son decimales de PostgreSQL) y hay que
	 * convertirlos justo al pintarlos. Si el texto no fuera un numero se
	 * ensena crudo: inventar un "Q0.00" seria decir que el pedido no costo nada.
	 */
	function dinero(texto: string | null): string {
		if (texto == null) return '-';
		const n = Number(texto);
		return Number.isNaN(n) ? texto : quetzales(n);
	}

	function fecha(iso: string | null): string {
		if (!iso) return '-';
		const d = new Date(iso);
		if (Number.isNaN(d.getTime())) return iso;
		return d.toLocaleString('es-GT', {
			day: '2-digit',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}

	let estadosPresentes = $derived.by(() => {
		const vistos = new Set(pedidos.map((p) => p.estado_pedido_nombre));
		const conocidos = ORDEN_ESTADOS.filter((e) => vistos.has(e));
		const otros = [...vistos].filter((e) => !ORDEN_ESTADOS.includes(e)).sort();
		return [...conocidos, ...otros];
	});

	let conteos = $derived.by(() => {
		const cuenta: Record<string, number> = {};
		for (const p of pedidos) {
			cuenta[p.estado_pedido_nombre] = (cuenta[p.estado_pedido_nombre] ?? 0) + 1;
		}
		return cuenta;
	});

	let listaFiltrada = $derived(
		filtro === 'todos' ? pedidos : pedidos.filter((p) => p.estado_pedido_nombre === filtro)
	);

	// ---------------------------------------------------------------- cargar
	async function cargar() {
		cargando = true;
		error = '';

		const r = await listarPedidos();
		if (expiro(r)) {
			// Se apaga el "Cargando..." aunque nos vayamos: alExpirarSesion es
			// opcional, y si no lo mandaron nadie saca a la persona de aqui y la
			// pantalla se quedaria con el spinner puesto para siempre.
			cargando = false;
			return;
		}

		if (r.ok && r.payload) {
			pedidos = r.payload;
			// Si el filtro puesto se quedo sin pedidos (se cancelo el ultimo
			// pendiente, por ejemplo), la pantalla se veria vacia con datos
			// cargados y parecia que no habia nada. Se vuelve a "todos".
			if (filtro !== 'todos' && !pedidos.some((p) => p.estado_pedido_nombre === filtro)) {
				filtro = 'todos';
			}
			// El detalle cacheado se tira si su resumen ya no cuadra (se edito el
			// carrito en otra pestana, por ejemplo). Sin esto se pintaria un
			// desglose viejo junto a un total nuevo, y saltaria la alarma de "no
			// cuadra" hablando de la cache y no de los datos.
			detalles = Object.fromEntries(
				Object.entries(detalles).filter(([id, d]) => {
					const resumen = pedidos.find((p) => p.id_pedido === id);
					return resumen != null && resumen.cantidad_lineas === d.detalles.length;
				})
			);
		} else {
			pedidos = [];
			// ok con payload nulo no es un fallo del backend, pero tampoco hay
			// lista: sin este caso se pintaria su mensaje de exito en rojo.
			error = r.ok ? 'El servidor contesto sin la lista de pedidos.' : textoDelFallo(r);
		}
		cargando = false;
	}

	onMount(cargar);

	// ---------------------------------------------------------------- detalle
	/**
	 * Pide el detalle de un pedido. Esta separado de alternar() a proposito:
	 * el boton de reintentar necesita volver a pedirlo con la fila YA abierta,
	 * y alternar() con la fila abierta lo que hace es cerrarla.
	 */
	async function cargarDetalle(id: string) {
		cargandoDetalle = id;
		errorDetalle = { ...errorDetalle, [id]: '' };

		const r = await traerPedido(id);
		cargandoDetalle = null;

		if (expiro(r)) {
			// Se deja dicho tambien aqui: si no, la fila queda abierta y en blanco
			// (sin spinner, sin error y sin detalle) mientras el panel decide.
			errorDetalle = { ...errorDetalle, [id]: 'Tu sesion termino. Vuelve a entrar.' };
			return;
		}

		if (r.ok && r.payload) {
			detalles = { ...detalles, [id]: r.payload };
		} else {
			// Un 404 aqui quiere decir que el pedido no existe o no es tuyo, y
			// las dos cosas son raras viniendo de tu propia lista: se cita el
			// mensaje del backend en vez de traducirlo a una suposicion.
			errorDetalle = {
				...errorDetalle,
				[id]: r.ok ? 'El servidor contesto sin el detalle del pedido.' : textoDelFallo(r)
			};
		}
	}

	function alternar(id: string) {
		if (abierto === id) {
			abierto = null;
			return;
		}

		abierto = id;
		if (detalles[id]) return; // ya esta en memoria: no se vuelve a pedir

		cargarDetalle(id);
	}

	/** Cuanto suman las lineas, para contrastarlo con el total del resumen. */
	function sumaDeLineas(d: PedidoCompleto): number {
		return totalPedido(d.detalles);
	}

	/**
	 * true si el desglose no cuadra con el total que devolvio la lista.
	 *
	 * No deberia pasar nunca (los dos salen del mismo precio congelado), pero
	 * si pasara hay que decirlo: un resumen que no cuadra con su detalle y no
	 * avisa es peor que uno que avisa. Se compara con medio centavo de holgura
	 * porque aqui los decimales ya pasaron por Number().
	 */
	function descuadra(p: ResumenPedido, d: PedidoCompleto): boolean {
		const total = Number(p.total);
		if (Number.isNaN(total)) return false;
		return Math.abs(total - sumaDeLineas(d)) > 0.005;
	}

	function direccionEnTexto(d: PedidoCompleto['direccion']): string {
		const partes = [d.ciudad, d.departamento, d.pais].filter((x) => x);
		return partes.join(', ') + (d.codigo_postal ? ` — ${d.codigo_postal}` : '');
	}

	// ------------------------------------------- asi se veia cuando lo compraste
	/**
	 * El producto reconstruido al dia del pedido.
	 *
	 * GET /productos/:id/historial fusiona los eventos del catalogo hasta esa
	 * fecha, y a diferencia de GET /productos/:id **no esconde** los productos
	 * en borrador ni los inactivos: un pedido tiene que poder ensenar lo que se
	 * compro aunque hoy ya no se venda.
	 *
	 * El payload entero se guarda tal como llega. Cada evento aporta unicamente
	 * lo que cambio, asi que un campo puede no venir en la fusion: por eso casi
	 * todos admiten null en `ProductoEnFecha` aunque el tipo de la ruta diga
	 * que el nombre siempre esta.
	 *
	 * Esto estuvo mal hasta hoy, y merece quedar escrito porque no daba ningun
	 * error: el tipo se habia ampliado con la categoria, las variantes y las
	 * caracteristicas, y el marcado de abajo ya las pintaba, pero al guardar se
	 * hacia `{ nombre, descripcion }` y se tiraba el resto. El resultado eran
	 * tres bloques de pantalla que no se ejecutaban nunca -- no fallaban, no
	 * existian. Si algun dia hace falta recortar lo que se guarda, que sea por
	 * un motivo, y que ese motivo este aqui.
	 */

	/** Un valor de caracteristica, como texto. Una lista se une con comas. */
	function valorTexto(v: CaracteristicaEnFecha['valor']): string {
		if (Array.isArray(v)) return v.join(', ');
		if (typeof v === 'boolean') return v ? 'si' : 'no';
		return String(v);
	}

	/**
	 * La clave lleva la fecha ademas del producto: el mismo producto en dos
	 * pedidos de distinto dia se reconstruye distinto, y cachear solo por
	 * producto ensenaria dentro de un pedido la version que vio el otro.
	 */
	function claveHistorial(idProducto: string, dia: string): string {
		return `${idProducto}@${dia}`;
	}

	/** Lo ya reconstruido. Se conserva al cerrar para no volver a pedirlo. */
	let historial = $state<Record<string, ProductoEnFecha>>({});
	let cargandoHistorial = $state<Record<string, boolean>>({});
	/**
	 * La linea que tiene el modal abierto, o null.
	 *
	 * Se guarda la LINEA entera y no su id: el modal ensena tambien lo que se
	 * pago (precio_unitario, cantidad, vendedor, variante), que vive en la
	 * linea del pedido y no en la reconstruccion. Con solo el id habria que
	 * volver a buscarla dentro de `detalles` en cada renglon del modal.
	 *
	 * Uno a la vez, que es lo que significa un modal. Antes era un
	 * `Record<idLinea, boolean>` porque cada linea desplegaba su propio panel
	 * en su sitio; ahora que hay una sola ventana, un registro de abiertos
	 * permitiria dos "abiertos" a la vez de los que solo uno se veria.
	 *
	 * El dia viaja al lado por comodidad: sale de la cabecera del pedido, y
	 * dentro del modal ya no se tiene el pedido a mano.
	 */
	let lineaAbierta = $state<{ linea: LineaPedido; dia: string } | null>(null);

	/**
	 * Precio y stock de la oferta ese dia, por `id_oferta@dia`.
	 *
	 * La clave lleva el dia por lo mismo que la del producto: la misma oferta
	 * comprada en dos pedidos de distinto dia valia distinto.
	 *
	 * Van en su propio estado y no dentro de `historial` porque son OTRA
	 * peticion a OTRA base -- el catalogo de Mongo no guarda ni precio ni
	 * stock. Que una falle no tiene por que tumbar a la otra.
	 */
	let ofertaHistorial = $state<Record<string, OfertaEnFecha>>({});
	let cargandoOferta = $state<Record<string, boolean>>({});
	/**
	 * Aqui no hay `grave` ni `reintentar` como en el producto, y es a proposito:
	 * el precio es un ADORNO de esta ventana. Lo que se vino a ver es como se
	 * veia el producto, y eso ya esta en pantalla; pintar un error rojo y un
	 * boton de reintentar por no poder anadir el precio le daria a un extra el
	 * peso de un fallo. Mismo criterio que PanelVendedor.reconstruirOfertas().
	 */
	let falloOferta = $state<Record<string, string>>({});
	/**
	 * `grave` decide el color (un dato en gris, un fallo en rojo) y `reintentar`
	 * si se ofrece el boton. Son dos cosas distintas: una fecha mal armada o una
	 * sesion caida son fallos de verdad, pero insistir no los arregla, y poner
	 * "Reintentar" al lado prometeria que si.
	 */
	let falloHistorial =
		$state<Record<string, { texto: string; grave: boolean; reintentar: boolean }>>({});

	/** La ruta pide AAAA-MM-DD y la fecha del pedido viene ISO completa. */
	const REGEX_DIA = /^\d{4}-\d{2}-\d{2}$/;

	/**
	 * El dia que se manda a reconstruir.
	 *
	 * Sale del mismo `fecha_creacion` que ya pinta la fila, no de una segunda
	 * fuente: si alguna vez difirieran, la pantalla estaria ensenando una fecha
	 * y preguntando por otra.
	 *
	 * El dia se saca en hora de GUATEMALA, no recortando el texto ISO. Antes
	 * era `iso.slice(0, 10)`, que es UTC: un pedido de las 8:52 p. m. son las
	 * 02:52 UTC del dia siguiente, asi que la cabecera decia "25 ago" y dos
	 * renglones mas abajo "Asi se veia el 2026-08-26". No daba un resultado
	 * incorrecto -- el backend cuenta hasta el final de ese dia, asi que el dia
	 * de mas seguia incluyendo la compra -- pero en pantalla se leia como una
	 * contradiccion, y la fila de arriba ya usa la hora de Guatemala.
	 *
	 * Lo que sigue en pie: la reconstruccion es por DIA y no por instante, y
	 * por eso lo que se pinta dice "el <dia>" y no "al momento de comprar".
	 */
	function diaDe(iso: string | null): string {
		if (!iso) return '';
		const d = new Date(iso);
		if (Number.isNaN(d.getTime())) return iso.slice(0, 10);
		// 'en-CA' da AAAA-MM-DD, que es justo lo que espera la ruta, y
		// timeZone lo calcula en hora de Guatemala.
		return d.toLocaleDateString('en-CA', { timeZone: 'America/Guatemala' });
	}

	async function cargarHistorial(idProducto: string, dia: string) {
		const clave = claveHistorial(idProducto, dia);

		if (!REGEX_DIA.test(dia)) {
			// Sin fecha no hay a que reconstruir. Se corta aqui en vez de mandar la
			// peticion porque el 400 del backend diria lo mismo tras el viaje.
			falloHistorial = {
				...falloHistorial,
				[clave]: {
					texto: 'Este pedido no trae una fecha con la que reconstruir el producto.',
					grave: true,
					reintentar: false
				}
			};
			return;
		}

		cargandoHistorial = { ...cargandoHistorial, [clave]: true };
		const { [clave]: _viejo, ...restoFallos } = falloHistorial;
		falloHistorial = restoFallos;

		const r = await traerProductoEnFecha(idProducto, dia);
		cargandoHistorial = { ...cargandoHistorial, [clave]: false };

		if (expiro(r)) {
			// Igual que en el detalle: sin esto el panel queda abierto y en blanco
			// mientras el panel de arriba decide que hacer con la sesion.
			falloHistorial = {
				...falloHistorial,
				[clave]: {
					texto: 'Tu sesion termino. Vuelve a entrar.',
					grave: true,
					reintentar: false
				}
			};
			return;
		}

		if (r.ok && r.payload) {
			// Entero, no dos campos: ver el comentario de arriba. Lo que la ruta
			// mande de mas se pinta o se ignora, pero llega.
			historial = { ...historial, [clave]: r.payload };
			return;
		}

		let texto: string;
		let grave = true;
		let reintentar = true;

		if (r.estado === 404) {
			// No es un fallo: es la respuesta. El producto se creo despues de este
			// pedido (o ya no esta en Mongo), y decirlo en rojo con un "Reintentar"
			// al lado prometeria que insistiendo va a aparecer.
			texto = r.mensaje;
			grave = false;
			reintentar = false;
		} else if (r.estado === 400) {
			// Este si es nuestro: la fecha salio mal armada desde aqui. Se ensena
			// cual se mando, que es lo unico que ayuda a arreglarlo. No se ofrece
			// reintentar: se mandaria la misma fecha y contestaria lo mismo.
			texto = `${r.mensaje} (se pidio la fecha ${dia})`;
			reintentar = false;
		} else if (r.estado === 0 || r.estado === 503) {
			texto = `${textoDelFallo(r)}. Es el servidor, no tu pedido: el dato sigue guardado.`;
		} else if (r.ok) {
			texto = 'El servidor contesto sin el producto reconstruido.';
		} else {
			texto = textoDelFallo(r);
		}

		falloHistorial = { ...falloHistorial, [clave]: { texto, grave, reintentar } };
	}

	/**
	 * Abre o cierra el "como se veia" de una linea.
	 *
	 * Al reabrir no se vuelve a pedir nada, ni siquiera cuando la vez anterior
	 * fallo: lo que hay se conserva y el reintento es un boton aparte, para que
	 * cerrar y abrir no dispare peticiones sin que nadie las pida.
	 */
	function claveOferta(idOferta: string, dia: string): string {
		return `${idOferta}@${dia}`;
	}

	/**
	 * El precio y el stock que tenia ESA oferta ese dia.
	 *
	 * Una sola peticion, porque la linea del pedido ya trae su `id_oferta`.
	 * PanelVendedor necesita dos pasos (pedir las ofertas del producto para
	 * sacar los ids) porque alli se parte del producto, no de una compra.
	 */
	async function cargarOferta(idOferta: string, dia: string) {
		const clave = claveOferta(idOferta, dia);
		if (ofertaHistorial[clave] || cargandoOferta[clave]) return;

		cargandoOferta = { ...cargandoOferta, [clave]: true };
		const { [clave]: _viejo, ...resto } = falloOferta;
		falloOferta = resto;

		const r = await traerOfertaEnFecha(idOferta, dia);
		cargandoOferta = { ...cargandoOferta, [clave]: false };

		// La sesion caida la atiende el producto, que se pide a la vez: si se
		// avisara tambien desde aqui, una sesion expirada dispararia dos veces
		// el mismo cierre de sesion.
		if (r.ok && r.payload) {
			ofertaHistorial = { ...ofertaHistorial, [clave]: r.payload };
			return;
		}

		falloOferta = {
			...falloOferta,
			[clave]:
				r.estado === 404
					? 'Esa oferta todavia no existia ese dia.'
					: 'No se pudo recuperar el precio de ese dia.'
		};
	}

	/**
	 * Abre el modal de una linea y pide lo que le falte.
	 *
	 * Las dos peticiones salen a la vez y no una detras de otra: van a bases
	 * distintas (Mongo y PostgreSQL) y ninguna necesita el resultado de la
	 * otra, asi que encadenarlas solo sumaria las dos esperas.
	 */
	function abrirHistorial(linea: LineaPedido, dia: string) {
		lineaAbierta = { linea, dia };

		const clave = claveHistorial(linea.id_producto_mongo, dia);
		if (!historial[clave] && !falloHistorial[clave]) {
			cargarHistorial(linea.id_producto_mongo, dia);
		}

		if (REGEX_DIA.test(dia)) {
			void cargarOferta(linea.id_oferta, dia);
		}
	}

	function cerrarHistorial() {
		lineaAbierta = null;
	}

	/**
	 * Escape cierra el modal.
	 *
	 * En la fase normal, no en captura, y sin cortar la propagacion: Checkout
	 * si necesita las dos cosas porque el carrito escucha Escape en esta misma
	 * ventana y una sola tecla cerraria los dos, pero en esta pantalla nadie
	 * mas la escucha. Copiar alli el `capture` habria dejado una precaucion
	 * sin nada de que precaverse, y de las que se leen como si hicieran falta.
	 *
	 * Sale por lo alto si no hay modal abierto: sin esa guarda, un Escape con
	 * todo cerrado igual entraria a cerrar y no haria dano, pero tampoco tiene
	 * por que ejecutarse.
	 */
	function alTecla(evento: KeyboardEvent) {
		if (!lineaAbierta || evento.key !== 'Escape') return;
		cerrarHistorial();
	}

	// ---------------------------------------------------------------- cancelar
	/**
	 * La confirmacion es en linea y no un confirm() del navegador: un confirm()
	 * bloquea la pagina entera, y ademas aqui hace falta decir dos cosas
	 * distintas segun el estado (un comprado devuelve stock, un pendiente no).
	 */
	function pedirConfirmacion(id: string) {
		confirmando = id;
		aviso = '';
		error = '';
	}

	async function cancelar(p: ResumenPedido) {
		confirmando = null;
		cancelando = p.id_pedido;
		error = '';
		aviso = '';

		const r = await cancelarPedido(p.id_pedido);
		cancelando = null;

		if (expiro(r)) return;

		if (r.ok) {
			// Se mira "ok" y no "ok && payload": si el backend contesto que si, el
			// pedido QUEDO cancelado aunque el payload venga vacio, y darlo por
			// fallido seria mentir sobre algo que ya paso.
			//
			// estado_previo lo dice el backend, no se deduce de lo que habia en
			// pantalla: entre que se pinto la lista y este click, el pedido pudo
			// haber cambiado de estado. Si no viene, no se afirma nada del stock.
			const previo = r.payload?.estado_previo ?? null;
			const devueltas = r.payload?.stock?.length ?? 0;
			aviso =
				previo === 'comprado'
					? `Pedido ${p.id_pedido} cancelado. Estaba comprado, asi que se devolvieron las unidades a ${devueltas} ${devueltas === 1 ? 'oferta' : 'ofertas'} y el pago quedo reembolsado.`
					: previo === 'pendiente'
						? `Pedido ${p.id_pedido} cancelado. Estaba pendiente: no se habia descontado stock, asi que no habia nada que devolver.`
						: `Pedido ${p.id_pedido} cancelado.`;

			// El detalle en memoria quedo con el estado viejo. Se borra en vez de
			// parchearlo: el estado del pedido lo manda la base, no esta pantalla.
			const { [p.id_pedido]: _quitado, ...resto } = detalles;
			detalles = resto;

			await cargar();
		} else {
			error = textoDelFallo(r);
		}
	}
</script>

<section class="mis-pedidos">
	<div class="titulo">
		<div>
			<!-- "Pedidos anteriores" y no "Mis pedidos": la pagina que lo monta ya
			     se titula asi, y el mismo rotulo dos veces seguidas no dice cual es
			     cual. Aqui lo que hay es lo ya cerrado; lo abierto esta arriba. -->
			<h2>Pedidos anteriores</h2>
			<p class="sub">
				Todo lo que has pedido, del mas nuevo al mas viejo. Despliega uno para ver a donde iba
				y que llevaba.
			</p>
		</div>
		{#if !cargando && pedidos.length > 0}
			<button type="button" onclick={cargar}>Actualizar</button>
		{/if}
	</div>

	{#if aviso}
		<p class="ok" role="status">{aviso}</p>
	{/if}

	{#if error && !cargando}
		<p class="malo" role="alert">{error}</p>
	{/if}

	{#if cargando}
		<p class="quieto">Cargando tus pedidos...</p>
	{:else if error && pedidos.length === 0}
		<button type="button" class="principal" onclick={cargar}>Reintentar</button>
	{:else if pedidos.length === 0}
		<p class="quieto">
			Todavia no has hecho ningun pedido. <a class="ir" href="/">Ve al catalogo</a> y agrega
			algo a tu carrito.
		</p>
	{:else}
		<div class="pestanas">
			<button
				type="button"
				class="pestana"
				class:elegida={filtro === 'todos'}
				onclick={() => (filtro = 'todos')}
			>
				Todos <span class="cuenta">{pedidos.length}</span>
			</button>
			{#each estadosPresentes as e (e)}
				<button
					type="button"
					class="pestana"
					class:elegida={filtro === e}
					onclick={() => (filtro = e)}
				>
					{e[0].toUpperCase() + e.slice(1)}
					<span class="cuenta">{conteos[e] ?? 0}</span>
				</button>
			{/each}
		</div>

		{#if listaFiltrada.length === 0}
			<p class="quieto">Ningun pedido {filtro}.</p>
		{:else}
			<div class="tabla">
				{#each listaFiltrada as p (p.id_pedido)}
					<article class="fila">
						<div class="datos">
							<h3>Pedido {p.id_pedido}</h3>
							<p class="menor">{fecha(p.fecha_creacion)}</p>
							<span
								class="chip"
								class:comprado={p.estado_pedido_nombre === 'comprado'}
								class:cancelado={p.estado_pedido_nombre === 'cancelado'}
							>
								{p.estado_pedido_nombre}
							</span>
						</div>

						<div class="pago">
							<!-- Los tres campos del pago nacen recien al comprar: mientras el
							     pedido sigue pendiente vienen null. Pintar "null" o un guion
							     suelto se lee como "el pago fallo", que es otra cosa. -->
							{#if p.metodo_pago}
								<span class="menor">Pago: {p.metodo_pago} · {p.estado_pago ?? 'sin estado'}</span>
								{#if p.fecha_cancelacion}
									<!-- fecha_cancelacion es del PAGO y quiere decir cuando se
									     salda, no cuando se anula el pedido: el backend la pone en
									     el momento de la compra. Sin la etiqueta, con ese nombre
									     de campo, se lee como la fecha de cancelacion. -->
									<span class="menor">Pago registrado el {fecha(p.fecha_cancelacion)}</span>
								{/if}
							{:else if p.estado_pedido_nombre === 'cancelado'}
								<!-- Cancelado y sin pago: nunca existio la fila de Pago, asi que
								     este ya no va a pagarse. Decir "todavia" prometeria un pago
								     que no va a llegar. -->
								<span class="menor">Se cancelo sin pagarse</span>
							{:else}
								<span class="menor">Sin pago todavia</span>
							{/if}
						</div>

						<div class="numeros">
							<strong class="grande">{dinero(p.total)}</strong>
							<span class="menor">
								{p.cantidad_lineas}
								{p.cantidad_lineas === 1 ? 'linea' : 'lineas'}
							</span>
						</div>

						<div class="acciones">
							<button
								type="button"
								aria-expanded={abierto === p.id_pedido}
								onclick={() => alternar(p.id_pedido)}
							>
								{abierto === p.id_pedido ? 'Ocultar detalle' : 'Ver detalle'}
							</button>

							{#if sePuedeCancelar(p)}
								<button
									type="button"
									class="quitar"
									onclick={() => pedirConfirmacion(p.id_pedido)}
									disabled={cancelando === p.id_pedido || confirmando === p.id_pedido}
								>
									{cancelando === p.id_pedido ? 'Cancelando...' : 'Cancelar'}
								</button>
							{/if}
						</div>

						{#if confirmando === p.id_pedido}
							<div class="confirmar">
								<p>
									{#if p.estado_pedido_nombre === 'comprado'}
										Este pedido ya esta comprado. Al cancelarlo se devuelven las unidades a
										cada vendedor y el pago pasa a reembolsado. No se puede deshacer.
									{:else}
										Se cancela el pedido entero, con todas sus lineas. No se puede deshacer.
									{/if}
								</p>
								<div class="acciones">
									<button type="button" class="principal" onclick={() => cancelar(p)}>
										Si, cancelar el pedido
									</button>
									<button type="button" onclick={() => (confirmando = null)}>Mejor no</button>
								</div>
							</div>
						{/if}

						{#if abierto === p.id_pedido}
							<div class="detalle">
								{#if cargandoDetalle === p.id_pedido}
									<p class="quieto">Cargando el detalle...</p>
								{:else if errorDetalle[p.id_pedido]}
									<p class="malo" role="alert">{errorDetalle[p.id_pedido]}</p>
									<button type="button" onclick={() => cargarDetalle(p.id_pedido)}>
										Reintentar
									</button>
								{:else if detalles[p.id_pedido]}
									{@const d = detalles[p.id_pedido]}

									<div class="entrega">
										<h4>Entrega</h4>
										<p>{direccionEnTexto(d.direccion)}</p>
										<!-- Es la VERSION de la direccion que regia al crear el pedido,
										     no la de hoy: por eso trae su propia fecha. Si la persona
										     edito su direccion despues, el pedido sigue diciendo a donde
										     se mando de verdad. -->
										<p class="menor">
											Es la direccion tal como estaba al crear el pedido (version del
											{fecha(d.direccion.fecha_creacion)}), no la que tengas guardada hoy.
										</p>
									</div>

									{#if d.detalles.length === 0}
										<p class="quieto">Este pedido no tiene ninguna linea.</p>
									{:else}
										<ul class="lineas">
											{#each d.detalles as l (l.id_pedido_producto)}
												{@const dia = diaDe(p.fecha_creacion)}
												<li class="linea">
													<div class="que">
														<!-- Se enlaza al producto del catalogo, que es lo unico
														     que sigue existiendo hoy: la oferta pudo retirarse. -->
														<a class="nombre" href="/producto/{l.id_producto_mongo}">
															{l.nombre_producto}
														</a>
														<span class="menor">{l.nombre_variante}</span>
														<span class="menor">Vendido por {l.nombre_vendedor}</span>
														<button
															type="button"
															class="ver-antes"
															aria-haspopup="dialog"
															onclick={() => abrirHistorial(l, dia)}
														>
															Ver el detalle de ese dia
														</button>

														<!--
															Resenar lo que ya se compro.

															Los dos campos los manda el backend por linea, y son
															los que deciden que se ensena. No se calcula nada
															aqui: la regla de quien puede resenar vive en el
															backend y preguntarla dos veces es tener dos reglas
															que se pueden separar.

															Es un ENLACE y no un formulario. El POST de una resena
															pide el CORREO del vendedor y la linea del pedido
															solo trae su nombre y su id, asi que aqui no se puede
															publicar directamente. La ficha del producto si tiene
															esa lista, y ademas ya tiene el formulario entero
															escrito y probado. Duplicarlo seria mantener dos.

															El nombre del vendedor viaja en la direccion para que
															la ficha preseleccione al correcto. Un producto se le
															puede comprar a varios, y en el pedido 17 de la
															semilla son TRES los calificables: sin esa pista, la
															persona podria calificar sin querer a otro.
														-->
														{#if l.ya_reseno}
															<span class="ya-resenado">Ya la resenaste</span>
														{:else if l.puede_resenar}
															<a
																class="resenar"
																href="/producto/{l.id_producto_mongo}?resenar=1&vendedor={encodeURIComponent(
																	l.nombre_vendedor
																)}"
															>
																Resenar esta compra
															</a>
														{/if}
													</div>
													<div class="cuentas">
														<span class="menor">
															{dinero(l.precio_unitario)} x {l.cantidad}
															{#if tieneDescuento(l.porcentaje_descuento_aplicado)}
																<span class="descuento">-{textoPorcentaje(l.porcentaje_descuento_aplicado)}</span>
															{/if}
														</span>
														<strong>{quetzales(subtotal(l))}</strong>
													</div>
												</li>
											{/each}
										</ul>

										<div class="total">
											<span class="menor">
												Total del pedido · precios congelados al agregarlos
											</span>
											<strong>{dinero(p.total)}</strong>
										</div>

										{#if descuadra(p, d)}
											<!-- No deberia pasar; si pasa, se dice. Un resumen que no
											     cuadra con su desglose y se queda callado es peor. -->
											<p class="malo" role="alert">
												Ojo: el total del resumen ({dinero(p.total)}) no cuadra con la suma
												de las lineas ({quetzales(sumaDeLineas(d))}).
											</p>
										{/if}
									{/if}
								{/if}
							</div>
						{/if}
					</article>
				{/each}
			</div>
		{/if}
	{/if}
</section>

<svelte:window onkeydown={alTecla} />

{#if lineaAbierta}
	{@const l = lineaAbierta.linea}
	{@const dia = lineaAbierta.dia}
	{@const clave = claveHistorial(l.id_producto_mongo, dia)}
	{@const claveO = claveOferta(l.id_oferta, dia)}
	{@const antes = historial[clave]}
	{@const oferta = ofertaHistorial[claveO]}

	<!-- El velo es un <button> y no un <div> con onclick, igual que en
	     CarritoRedis: hace falta poder cerrarlo con el teclado, y un boton ya
	     trae Enter, Espacio y el foco sin escribir nada. -->
	<button
		type="button"
		class="velo"
		aria-label="Cerrar el detalle"
		onclick={cerrarHistorial}
		transition:fade={{ duration: 150 }}
	></button>

	<div
		class="modal"
		role="dialog"
		aria-modal="true"
		aria-label="Detalle de {l.nombre_producto} el {dia}"
		transition:fly={{ y: 24, duration: 200 }}
	>
		<header class="modal-titulo">
			<div>
				<h4>{l.nombre_producto}</h4>
				<p class="menor">Tal como estaba el {dia}, el dia de tu pedido.</p>
			</div>
			<button type="button" class="cerrar" onclick={cerrarHistorial} aria-label="Cerrar">
				&times;
			</button>
		</header>

		<div class="modal-cuerpo">
			<!-- ------------------------------------------------ lo que se pago -->
			<!-- Esto sale de la LINEA del pedido, no de ninguna reconstruccion: es
			     lo que se cobro de verdad, y esta guardado. Va primero porque es
			     lo unico de esta ventana que no puede fallar ni faltar. -->
			<section class="bloque">
				<h5>Lo que pagaste</h5>
				<dl class="fichas">
					<div class="ficha">
						<dt>Presentacion</dt>
						<dd>{l.nombre_variante}</dd>
					</div>
					<div class="ficha">
						<dt>Vendedor</dt>
						<dd>{l.nombre_vendedor}</dd>
					</div>
					<div class="ficha">
						<dt>Precio unitario</dt>
						<dd>
							{dinero(l.precio_unitario)}
							{#if tieneDescuento(l.porcentaje_descuento_aplicado)}
								<span class="descuento">-{textoPorcentaje(l.porcentaje_descuento_aplicado)}</span>
							{/if}
						</dd>
					</div>
					<div class="ficha">
						<dt>Cantidad</dt>
						<dd>{l.cantidad}</dd>
					</div>
					<div class="ficha">
						<dt>Subtotal</dt>
						<dd><strong>{quetzales(subtotal(l))}</strong></dd>
					</div>
				</dl>
			</section>

			<!-- --------------------------------- precio y stock de la oferta -->
			<!-- Estos dos NO salen de Mongo y no pueden: al volverse multi-vendedor
			     dejaron de ser del producto. Vienen de precio_historial y
			     stock_movimiento, en PostgreSQL. Que esten aqui al lado de lo
			     pagado es justo lo que deja comparar. -->
			<section class="bloque">
				<h5>La oferta ese dia</h5>
				{#if cargandoOferta[claveO]}
					<p class="menor">Recuperando el precio y las existencias...</p>
				{:else if falloOferta[claveO]}
					<p class="menor">{falloOferta[claveO]}</p>
				{:else if oferta}
					{@const cambioPrecio = Number(oferta.precio) !== Number(l.precio_unitario)}
					<!-- Si la linea llevaba descuento, el precio de lista del dia con ese
					     descuento tiene que dar lo cobrado. Si no da, ademas cambio el
					     precio ese dia, y eso se dice aparte. -->
					{@const soloDescuento =
						tieneDescuento(l.porcentaje_descuento_aplicado) &&
						Math.abs(
							Number(oferta.precio) * (1 - Number(l.porcentaje_descuento_aplicado) / 100) -
								Number(l.precio_unitario)
						) < 0.006}
					<dl class="fichas">
						<div class="ficha">
							<dt>Precio publicado</dt>
							<dd>{dinero(oferta.precio)}</dd>
						</div>
						{#if tieneDescuento(oferta.porcentaje_descuento)}
							<div class="ficha">
								<dt>Descuento ese dia</dt>
								<dd>{Number(oferta.porcentaje_descuento)} %</dd>
							</div>
						{/if}
						<div class="ficha">
							<dt>Existencias</dt>
							<dd>
								{oferta.stock}
								<span class="menor">{oferta.stock === 1 ? 'unidad' : 'unidades'}</span>
							</dd>
						</div>
					</dl>
					{#if cambioPrecio && soloDescuento}
						<!-- El historial da el precio de LISTA; la linea, el que se cobro con
						     el descuento. Que difieran es lo normal y no un cambio de precio. -->
						<p class="menor">
							El precio publicado es sin descuento. Tu compra llevaba
							{textoPorcentaje(l.porcentaje_descuento_aplicado)} de descuento y se te cobro
							{dinero(l.precio_unitario)}.
						</p>
					{:else if cambioPrecio}
						<!-- Los dos numeros salen de sitios distintos y por eso pueden
						     diferir: el de la linea es el que se congelo al comprar, y
						     el reconstruido es el ultimo precio del DIA. Un cambio de
						     precio ese mismo dia, despues de la compra, los separa sin
						     que ninguno de los dos este mal. -->
						<p class="menor">
							Publicado a {dinero(oferta.precio)} al cerrar el dia, y a ti se te cobro
							{dinero(l.precio_unitario)}: el precio de tu linea se congelo al comprar.
						</p>
					{/if}
				{:else}
					<p class="menor">No hay precio guardado para ese dia.</p>
				{/if}
			</section>

			<!-- ------------------------------------ el producto reconstruido -->
			<section class="bloque">
				<h5>El producto en el catalogo</h5>

				{#if cargandoHistorial[clave]}
					<p class="menor">Reconstruyendo el producto al {dia}...</p>
				{:else if falloHistorial[clave]}
					{@const fallo = falloHistorial[clave]}
					{#if fallo.grave}
						<p class="malo" role="alert">{fallo.texto}</p>
					{:else}
						<!-- Un 404 aqui es un dato, no un fallo: se dice en gris. -->
						<p class="menor">{fallo.texto}</p>
					{/if}
					{#if fallo.reintentar}
						<button type="button" onclick={() => cargarHistorial(l.id_producto_mongo, dia)}>
							Reintentar
						</button>
					{/if}
				{:else if antes}
					<!-- Un nombre vacio cuenta como no tenerlo: pintarlo en negrita
					     dejaria dos comillas con nada dentro. -->
					{@const cambio = !!antes.nombre && antes.nombre !== l.nombre_producto}

					{#if cambio}
						<!-- El cambio es lo que esta pantalla existe para ensenar: se
						     pintan los dos nombres, no solo el reconstruido. -->
						<p class="cambio">
							El catalogo lo llamaba <strong>{antes.nombre}</strong>. En tu pedido quedo
							guardado como <strong>{l.nombre_producto}</strong>.
						</p>
					{:else if antes.nombre}
						<p class="menor">
							Se llamaba <strong>{antes.nombre}</strong>, igual que en tu pedido.
						</p>
					{:else}
						<p class="menor">Ese dia el producto no tenia nombre guardado.</p>
					{/if}

					<!-- El ?? no basta: una descripcion vacia no es nula y dejaria el
					     renglon en blanco, que se lee como que algo fallo. -->
					<p class="descripcion">{antes.descripcion || 'Ese dia no tenia descripcion.'}</p>

					{#if antes.categoria?.nombre}
						<!-- La categoria de ESE dia, que puede no ser la de hoy: es justo
						     el caso que justifica `productos_historial.id_categoria` (el
						     balon nacio en Fitness y se movio a Futbol). -->
						<p class="menor">
							Estaba en
							<strong>
								{#if antes.categoria.categoria_padre}{antes.categoria.categoria_padre}
									&rsaquo;
								{/if}{antes.categoria.nombre}
							</strong>
						</p>
					{/if}

					<!-- Las dos listas van por separado y no concatenadas: las
					     "adicionales" salen de la paleta de la categoria y las
					     "personalizadas" las invento el vendedor, y juntarlas
					     borraria esa diferencia justo en la pantalla que existe
					     para ensenar de donde sale cada dato. -->
					{#if antes.caracteristicas_adicionales?.length}
						<h6>Caracteristicas</h6>
						<dl class="fichas">
							{#each antes.caracteristicas_adicionales as c (c.nombre)}
								<div class="ficha">
									<dt>{c.nombre}</dt>
									<!-- El &nbsp; no es decorativo: Svelte recorta el espacio que
									     rodea a un bloque, y sin el se leia "18meses". -->
									<dd>
										{valorTexto(c.valor)}{#if c.unidad}<span class="menor"
												>&nbsp;{c.unidad}</span
											>{/if}
									</dd>
								</div>
							{/each}
						</dl>
					{/if}

					{#if antes.caracteristicas_personalizadas?.length}
						<h6>Caracteristicas propias del vendedor</h6>
						<dl class="fichas">
							{#each antes.caracteristicas_personalizadas as c (c.nombre)}
								<div class="ficha">
									<dt>{c.nombre}</dt>
									<!-- El &nbsp; no es decorativo: Svelte recorta el espacio que
									     rodea a un bloque, y sin el se leia "18meses". -->
									<dd>
										{valorTexto(c.valor)}{#if c.unidad}<span class="menor"
												>&nbsp;{c.unidad}</span
											>{/if}
									</dd>
								</div>
							{/each}
						</dl>
					{/if}
				{:else}
					<p class="menor">No hay nada reconstruido todavia.</p>
				{/if}
			</section>

			<!-- -------------------------------------------- las presentaciones -->
			{#if antes?.variantes?.length}
				<!-- Las variantes se traian desde que se amplio el tipo y no se
				     pintaban en ningun sitio. Son las que llevan las
				     caracteristicas que distinguen una presentacion de otra (la RAM
				     de una laptop, la talla de una camisa), asi que sin ellas la
				     ficha de un producto con variantes se veia medio vacia.
				     La que se compro va marcada: es la que importa de las cinco. -->
				<section class="bloque">
					<h5>Las presentaciones de ese dia</h5>
					<ul class="variantes">
						{#each antes.variantes as v (v.id_producto_variante)}
							{@const esLaTuya = String(v.id_producto_variante) === l.id_producto_variante_mongo}
							{@const suyas = [
								...(v.caracteristicas_adicionales ?? []),
								...(v.caracteristicas_personalizadas ?? [])
							]}
							<li class:tuya={esLaTuya}>
								<div class="cabeza-variante">
									<strong>{v.nombre_variante}</strong>
									{#if esLaTuya}<span class="marca">la que compraste</span>{/if}
								</div>
								{#if v.descripcion}
									<p class="menor">{v.descripcion}</p>
								{/if}
								{#if suyas.length}
									<ul class="rasgos">
										{#each suyas as c (c.nombre)}
											<li>
												<span class="menor">{c.nombre}:</span>
												{valorTexto(c.valor)}{#if c.unidad}&nbsp;{c.unidad}{/if}
											</li>
										{/each}
									</ul>
								{/if}
							</li>
						{/each}
					</ul>
				</section>
			{/if}

			<p class="menor pie-modal">Asi era el producto cuando lo compraste, aunque hoy ya no se venda.</p>
		</div>
	</div>
{/if}

<style>
	/* El % de descuento que llevaba la linea. Colores del layout. */
	.descuento {
		display: inline-block;
		margin-left: 4px;
		padding: 1px 7px;
		font-size: var(--f-xs);
		font-weight: 600;
		line-height: 1.2;
		white-space: nowrap;
		border-radius: 999px;
		color: var(--descuento-tinta);
		background: var(--descuento-fondo);
		border: 1px solid var(--descuento-linea);
	}

	.mis-pedidos {
		margin-top: 2rem;
	}

	.titulo {
		display: flex;
		align-items: flex-end;
		justify-content: space-between;
		gap: var(--e4);
		margin-bottom: 1.25rem;
	}

	h2 {
		font-size: var(--f-xl);
	}

	h3 {
		font-size: var(--f-md);
		margin: 0 0 0.15rem;
	}

	h4 {
		font-size: var(--f-base);
		margin-bottom: 0.2rem;
	}

	.sub,
	.menor {
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.quieto {
		padding: 1.25rem 0;
		color: var(--gris);
	}

	.ok,
	.malo {
		padding: 0.6rem 0.9rem;
		margin-bottom: 0.9rem;
		border-radius: var(--r);
		font-size: var(--f-ms);
	}

	.ok {
		background: var(--indigo-cl);
		color: var(--indigo-os);
	}

	.malo {
		background: var(--panel);
		color: var(--rojo);
		border: 1px solid var(--rojo);
	}

	/* ---------- botones ---------- */

	button {
		padding: 0.45rem 0.8rem;
		background: var(--blanco);
		color: var(--tinta);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		font: inherit;
		font-size: var(--f-sm);
		cursor: pointer;
		transition: border-color var(--t);
	}

	button:hover:not(:disabled) {
		border-color: var(--indigo);
	}

	button:disabled {
		opacity: 0.55;
		cursor: default;
	}

	.principal {
		background: var(--indigo);
		color: var(--blanco);
		border-color: var(--indigo);
	}

	.quitar:hover:not(:disabled) {
		border-color: var(--rojo);
		color: var(--rojo);
	}

	/* ---------- filtro por estado ---------- */

	.pestanas {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e2);
		margin-bottom: 1rem;
	}

	.pestana {
		display: inline-flex;
		align-items: center;
		gap: var(--e2);
		padding: 0.35rem 0.85rem;
		font-size: var(--f-ms);
		background: transparent;
		border-radius: 999px;
	}

	.pestana.elegida {
		background: var(--indigo-cl);
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.cuenta {
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.pestana.elegida .cuenta {
		color: var(--indigo);
	}

	/* ---------- la lista ---------- */

	.tabla {
		display: flex;
		flex-direction: column;
		gap: var(--e3);
	}

	.fila {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: var(--e4);
		padding: 1rem 1.1rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	/* Que el numero y la fecha se coman el hueco sobrante, para que el total no
	   quede flotando a medio camino de sus botones. */
	.fila .datos {
		flex: 1;
		min-width: 11rem;
	}

	.pago {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
	}

	.numeros {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: var(--e1);
	}

	.grande {
		font-size: var(--f-md);
		color: var(--tinta);
	}

	.acciones {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e2);
	}

	.chip {
		display: inline-block;
		margin-top: 0.25rem;
		padding: 2px 10px;
		font-size: var(--f-xs);
		letter-spacing: 0.03em;
		text-transform: uppercase;
		border-radius: 999px;
		background: var(--panel);
		color: var(--gris);
	}

	/* Comprado en indigo y cancelado en rojo; pendiente se queda neutro porque
	   es el estado de reposo. Enviado y entregado tambien quedan neutros a
	   proposito: darles color inventaria una jerarquia que nadie definio. */
	.chip.comprado {
		background: var(--indigo-cl);
		color: var(--indigo);
	}

	.chip.cancelado {
		background: var(--panel);
		color: var(--rojo);
	}

	/* ---------- confirmar la cancelacion ---------- */

	/* Ocupa el ancho entero de la fila: se abre debajo, no al lado. */
	.confirmar,
	.detalle {
		flex-basis: 100%;
		border-top: 1px solid var(--linea);
		padding-top: 0.9rem;
	}

	.confirmar p {
		margin-bottom: 0.7rem;
		font-size: var(--f-ms);
		color: var(--rojo);
	}

	/* ---------- el detalle ---------- */

	.entrega {
		padding: 0.8rem 1rem;
		margin-bottom: 0.9rem;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.lineas {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
		list-style: none;
	}

	.linea {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: var(--e3);
		padding: 0.7rem 0.9rem;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.que {
		display: flex;
		flex-direction: column;
		min-width: 0;
	}

	.nombre {
		color: var(--tinta);
		text-decoration: none;
		border-bottom: 1px solid var(--linea);
		align-self: flex-start;
	}

	.nombre:hover {
		color: var(--indigo);
		border-bottom-color: var(--indigo);
	}

	/* ---------- como se veia al comprarlo ---------- */

	/* Discreto a proposito: es un extra de la linea, no compite con el nombre
	   del producto ni con el subtotal. */
	.ver-antes {
		align-self: flex-start;
		margin-top: 0.35rem;
		padding: 0.15rem 0;
		background: transparent;
		border: none;
		border-bottom: 1px dashed var(--linea);
		border-radius: 0;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.ver-antes:hover:not(:disabled) {
		color: var(--indigo);
		border-bottom-color: var(--indigo);
	}

	/* Resenar esta compra. Se pinta como accion y no como el enlace gris de
	   arriba: es lo unico de este renglon que le pide algo a la persona, y
	   compite con "Ver el detalle de ese dia", que es solo mirar. */
	.resenar {
		align-self: flex-start;
		margin-top: 0.35rem;
		padding: 0.2rem 0.55rem;
		border: 1px solid var(--indigo);
		border-radius: 999px;
		font-size: var(--f-sm);
		color: var(--indigo);
		text-decoration: none;
		line-height: 1.4;
	}

	.resenar:hover {
		background: var(--indigo);
		color: #fff;
	}

	/* Y cuando ya se reseno no queda un hueco. Un renglon que pierde su boton
	   sin decir nada se lee como que algo fallo. */
	.ya-resenado {
		align-self: flex-start;
		margin-top: 0.35rem;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	/* ------------------------------------------------------------- el modal */
	/* El velo de atras. Cubre todo y cierra al pulsarlo. Mismo z-index que en
	   CarritoRedis, un piso por debajo del panel. */
	.velo {
		position: fixed;
		inset: 0;
		z-index: 40;
		border: 0;
		padding: 0;
		background: rgba(20, 20, 30, 0.38);
		cursor: pointer;
	}

	/* Centrado y con tope de alto: el contenido puede ser largo (un producto
	   con cinco variantes y sus rasgos), y sin `max-height` la ventana se
	   saldria de la pantalla por abajo sin poder llegar al final. */
	.modal {
		position: fixed;
		z-index: 41;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(46rem, calc(100vw - 2rem));
		max-height: min(85vh, 52rem);
		display: flex;
		flex-direction: column;
		background: var(--blanco);
		border-radius: var(--r2);
		box-shadow: 0 18px 48px rgba(20, 20, 30, 0.22);
	}

	/* La cabecera no se va con el scroll: dice de que producto y de que dia es
	   todo lo de abajo, y perderla a media lectura deja los numeros sin dueno. */
	.modal-titulo {
		position: sticky;
		top: 0;
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: var(--e4);
		padding: 1rem 1.25rem 0.75rem;
		background: var(--blanco);
		border-bottom: 1px solid var(--linea);
		border-radius: var(--r2) var(--r2) 0 0;
	}

	.modal-titulo h4 {
		font-size: var(--f-md);
		color: var(--tinta);
	}

	.cerrar {
		flex-shrink: 0;
		padding: 0 0.4rem;
		background: transparent;
		border: none;
		font-size: var(--f-xl);
		line-height: 1;
		color: var(--gris);
	}

	.cerrar:hover {
		color: var(--tinta);
	}

	.modal-cuerpo {
		overflow-y: auto;
		padding: 0.25rem 1.25rem 1.25rem;
	}

	/* Cada bloque es una FUENTE distinta (la linea del pedido, PostgreSQL,
	   Mongo). La separacion es lo que deja ver de donde sale cada numero, que
	   es medio punto de la entrega. */
	.bloque {
		padding-top: 0.9rem;
	}

	.bloque + .bloque {
		margin-top: 0.4rem;
		border-top: 1px solid var(--linea);
	}

	.bloque h5 {
		font-size: var(--f-base);
		color: var(--tinta);
		margin-bottom: 0.2rem;
	}

	.bloque h6 {
		margin-top: 0.75rem;
		font-size: var(--f-sm);
		color: var(--gris);
		font-weight: 600;
	}

	.bloque p {
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.bloque strong {
		color: var(--tinta);
	}

	/* El cambio de nombre es lo que se viene a ver: se marca en indigo para que
	   no se lea como un renglon mas de la ficha. */
	.bloque .cambio {
		margin-bottom: 0.35rem;
		color: var(--indigo-os);
	}

	.bloque .cambio strong {
		color: var(--indigo);
	}

	.bloque .descripcion {
		margin: 0.35rem 0;
		color: var(--texto);
	}

	/* El color se repite porque `.bloque p` es mas especifico que `.malo` y le
	   estaba borrando el rojo al mensaje de error. */
	.bloque .malo {
		margin-bottom: 0.6rem;
		color: var(--rojo);
	}

	/* Una tarjeta por presentacion. */
	.variantes {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr));
		gap: var(--e2);
		margin-top: 0.7rem;
		list-style: none;
	}

	.variantes > li {
		padding: 0.55rem 0.7rem;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	/* La comprada se marca con borde y no solo con la etiqueta: es la que se
	   busca de un vistazo cuando hay cinco. */
	.variantes > li.tuya {
		border-color: var(--indigo);
		background: var(--blanco);
	}

	.cabeza-variante {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		gap: var(--e2);
	}

	.marca {
		padding: 0.05rem 0.4rem;
		background: var(--indigo);
		border-radius: 999px;
		font-size: var(--f-xs);
		color: var(--blanco);
	}

	.rasgos {
		margin-top: 0.35rem;
		list-style: none;
		font-size: var(--f-sm);
		color: var(--texto);
	}

	.pie-modal {
		margin-top: 1rem;
		padding-top: 0.7rem;
		border-top: 1px solid var(--linea);
	}

	.cuentas {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: var(--e1);
	}

	.cuentas strong {
		color: var(--tinta);
	}

	.total {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		justify-content: space-between;
		gap: var(--e2);
		margin-top: 0.9rem;
		padding-top: 0.75rem;
		border-top: 1px solid var(--linea);
	}

	.total strong {
		font-size: var(--f-md);
		color: var(--tinta);
	}

	.ir {
		color: var(--indigo);
	}

	/* Las caracteristicas de ese dia, en dos columnas.
	   Sin borde propio: dentro del modal cada bloque ya trae su separador, y
	   los dos juntos dibujaban dos lineas pegadas. */
	.fichas {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
		gap: var(--e2) var(--e4);
		margin-top: 0.5rem;
	}

	.ficha dt {
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.ficha dd {
		color: var(--tinta);
		font-size: var(--f-ms);
	}
</style>
