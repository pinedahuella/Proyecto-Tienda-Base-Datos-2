<script lang="ts">
	import { onMount } from 'svelte';
	import type { RespuestaApi } from './api';
	import {
		cancelarPedido,
		listarPedidos,
		quetzales,
		subtotal,
		totalPedido,
		traerPedido,
		traerProductoEnFecha,
		type PedidoCompleto,
		type ResumenPedido
	} from './pedido';

	/**
	 * El historial de pedidos de quien esta logueado.
	 *
	 * Dos rutas y media, mas una del catalogo:
	 *   GET  /comprador/pedidos              la lista resumida (sin lineas)
	 *   GET  /comprador/pedidos/:id          el detalle, solo al desplegar uno
	 *   POST /comprador/pedidos/:id/cancelar cancelar
	 *   GET  /productos/:id/historial        el producto como estaba ese dia
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
	 * Solo se guardan los dos campos que se pintan. El payload trae el producto
	 * entero, pero cada evento aporta unicamente lo que cambio, asi que un campo
	 * puede no venir en la fusion: por eso los dos admiten null aunque el tipo
	 * de la ruta diga que el nombre siempre esta.
	 */
	interface ProductoEnFecha {
		nombre: string | null;
		descripcion: string | null;
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
	 * Que panel esta abierto va por LINEA (id_pedido_producto) y no por la clave
	 * de la reconstruccion: un pedido puede llevar dos lineas del mismo producto
	 * (dos variantes, o la misma variante a dos vendedores), y con la clave
	 * compartida abrir una abria tambien la otra. Lo pedido si se comparte: es
	 * la misma peticion y no tiene por que hacerse dos veces.
	 */
	let abiertoHistorial = $state<Record<string, boolean>>({});
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
	 * y preguntando por otra. El corte es sobre el texto ISO (UTC) mientras que
	 * la fila lo ensena en hora de Guatemala, asi que un pedido de la tarde cae
	 * en el dia UTC siguiente -- y no estorba para lo que importa: el backend
	 * cuenta "hasta el final de ese dia" (medianoche de Guatemala), asi que un
	 * dia de mas sigue incluyendo la compra, nunca la deja fuera. Lo que si
	 * puede colarse son los cambios del catalogo de esas horas de mas: la
	 * reconstruccion es por DIA, no por instante, y por eso lo que se pinta
	 * dice "el <dia>" y no "al momento de comprar".
	 */
	function diaDe(iso: string | null): string {
		return (iso ?? '').slice(0, 10);
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
			historial = {
				...historial,
				[clave]: { nombre: r.payload.nombre ?? null, descripcion: r.payload.descripcion ?? null }
			};
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
	function alternarHistorial(idLinea: string, idProducto: string, dia: string) {
		if (abiertoHistorial[idLinea]) {
			abiertoHistorial = { ...abiertoHistorial, [idLinea]: false };
			return;
		}

		abiertoHistorial = { ...abiertoHistorial, [idLinea]: true };

		const clave = claveHistorial(idProducto, dia);
		if (historial[clave] || falloHistorial[clave]) return;

		cargarHistorial(idProducto, dia);
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
												{@const clave = claveHistorial(l.id_producto_mongo, dia)}
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
															aria-expanded={abiertoHistorial[l.id_pedido_producto] === true}
															onclick={() =>
																alternarHistorial(l.id_pedido_producto, l.id_producto_mongo, dia)}
														>
															{abiertoHistorial[l.id_pedido_producto]
																? 'Ocultar como se veia'
																: 'Como se veia al comprarlo'}
														</button>
													</div>
													<div class="cuentas">
														<span class="menor">
															{dinero(l.precio_unitario)} x {l.cantidad}
														</span>
														<strong>{quetzales(subtotal(l))}</strong>
													</div>

													{#if abiertoHistorial[l.id_pedido_producto]}
														<div class="antes">
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
																	<button
																		type="button"
																		onclick={() => cargarHistorial(l.id_producto_mongo, dia)}
																	>
																		Reintentar
																	</button>
																{/if}
															{:else if historial[clave]}
																{@const antes = historial[clave]}
																<!-- Un nombre vacio cuenta como no tenerlo: pintarlo en
																     negrita dejaria dos comillas con nada dentro. -->
																{@const cambio = !!antes.nombre && antes.nombre !== l.nombre_producto}

																<h5>Asi se veia el {dia}</h5>

																{#if cambio}
																	<!-- El cambio es lo que esta pantalla existe para ensenar:
																	     se pintan los dos nombres, no solo el reconstruido. -->
																	<p class="cambio">
																		El catalogo lo llamaba <strong>{antes.nombre}</strong>. En tu
																		pedido quedo guardado como <strong>{l.nombre_producto}</strong>.
																	</p>
																{:else if antes.nombre}
																	<p class="menor">
																		Se llamaba <strong>{antes.nombre}</strong>, igual que en tu
																		pedido.
																	</p>
																{:else}
																	<p class="menor">Ese dia el producto no tenia nombre guardado.</p>
																{/if}

																<!-- El ?? no basta: una descripcion vacia no es nula y dejaria
																     el renglon en blanco, que se lee como que algo fallo. -->
																<p class="descripcion">
																	{antes.descripcion || 'Ese dia no tenia descripcion.'}
																</p>

																<p class="menor">
																	Reconstruido con el historial del catalogo, que ensena el
																	producto aunque hoy ya no se venda.
																</p>
															{/if}
														</div>
													{/if}
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

<style>
	.mis-pedidos {
		margin-top: 2rem;
	}

	.titulo {
		display: flex;
		align-items: flex-end;
		justify-content: space-between;
		gap: 1rem;
		margin-bottom: 1.25rem;
	}

	h2 {
		font-size: 1.5rem;
	}

	h3 {
		font-size: 1.02rem;
		margin: 0 0 0.15rem;
	}

	h4 {
		font-size: 0.95rem;
		margin-bottom: 0.2rem;
	}

	.sub,
	.menor {
		font-size: 0.88rem;
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
		font-size: 0.9rem;
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
		font-size: 0.85rem;
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
		gap: 0.4rem;
		margin-bottom: 1rem;
	}

	.pestana {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		padding: 0.35rem 0.85rem;
		font-size: 0.9rem;
		background: transparent;
		border-radius: 999px;
	}

	.pestana.elegida {
		background: var(--indigo-cl);
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.cuenta {
		font-size: 0.78rem;
		color: var(--gris);
	}

	.pestana.elegida .cuenta {
		color: var(--indigo);
	}

	/* ---------- la lista ---------- */

	.tabla {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	.fila {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 1rem;
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
		gap: 0.1rem;
	}

	.numeros {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 0.15rem;
	}

	.grande {
		font-size: 1.05rem;
		color: var(--tinta);
	}

	.acciones {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}

	.chip {
		display: inline-block;
		margin-top: 0.25rem;
		padding: 2px 10px;
		font-size: 0.75rem;
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
		font-size: 0.9rem;
		color: var(--rojo);
	}

	/* ---------- el detalle ---------- */

	.entrega {
		padding: 0.8rem 1rem;
		margin-bottom: 0.9rem;
		background: var(--panel);
		border-left: 3px solid var(--indigo);
		border-radius: var(--r2);
	}

	.lineas {
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
		list-style: none;
	}

	.linea {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
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
		font-size: 0.82rem;
		color: var(--gris);
	}

	.ver-antes:hover:not(:disabled) {
		color: var(--indigo);
		border-bottom-color: var(--indigo);
	}

	/* Se abre debajo de la linea entera, no dentro de la columna del nombre. */
	.antes {
		flex-basis: 100%;
		margin-top: 0.7rem;
		padding: 0.7rem 0.9rem;
		background: var(--panel);
		border-left: 3px solid var(--indigo);
		border-radius: var(--r2);
	}

	.antes h5 {
		font-size: 0.9rem;
		margin-bottom: 0.3rem;
	}

	.antes p {
		font-size: 0.88rem;
		color: var(--gris);
	}

	.antes strong {
		color: var(--tinta);
	}

	/* El cambio de nombre es lo que se viene a ver: se marca en indigo para que
	   no se lea como un renglon mas de la ficha. */
	.antes .cambio {
		margin-bottom: 0.35rem;
		color: var(--indigo-os);
	}

	.antes .cambio strong {
		color: var(--indigo);
	}

	.antes .descripcion {
		margin: 0.35rem 0;
		color: var(--texto);
	}

	/* El color se repite porque `.antes p` es mas especifico que `.malo` y le
	   estaba borrando el rojo al mensaje de error. */
	.antes .malo {
		margin-bottom: 0.6rem;
		color: var(--rojo);
	}

	.cuentas {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 0.1rem;
	}

	.cuentas strong {
		color: var(--tinta);
	}

	.total {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		justify-content: space-between;
		gap: 0.5rem;
		margin-top: 0.9rem;
		padding-top: 0.75rem;
		border-top: 1px solid var(--linea);
	}

	.total strong {
		font-size: 1.1rem;
		color: var(--tinta);
	}

	.ir {
		color: var(--indigo);
	}
</style>
