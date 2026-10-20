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
		type PedidoCompleto,
		type ResumenPedido
	} from './pedido';
	import { textoPorcentaje, tieneDescuento } from './descuento';

	/**
	 * El historial de pedidos de quien esta logueado.
	 *
	 * Dos rutas y media:
	 *   GET  /comprador/pedidos              la lista resumida (sin lineas)
	 *   GET  /comprador/pedidos/:id          el detalle, solo al desplegar uno
	 *   POST /comprador/pedidos/:id/cancelar cancelar
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
												<li class="linea">
													<div class="que">
														<!-- Se enlaza al producto del catalogo, que es lo unico
														     que sigue existiendo hoy: la oferta pudo retirarse. -->
														<a class="nombre" href="/producto/{l.id_producto_mongo}">
															{l.nombre_producto}
														</a>
														<span class="menor">{l.nombre_variante}</span>
														<span class="menor">Vendido por {l.nombre_vendedor}</span>
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

	/* Resenar esta compra. Se pinta como accion: es lo unico de este renglon
	   que le pide algo a la persona. */
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
</style>
