<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import { fade, fly } from 'svelte/transition';
	import { conJson, mensajeUtil, pedir } from './api';
	import type { LineaPedido } from './pedido';
	import { textoPorcentaje, tieneDescuento } from './descuento';

	/**
	 * El carrito de la Entrega 2, sobre Redis.
	 *
	 * REEMPLAZA a Carrito.svelte, que leia una fila de `pedido` en `pendiente`
	 * de PostgreSQL con su id en localStorage.
	 *
	 * Lo que se gano con la mudanza, y conviene tenerlo escrito porque es lo
	 * que hay que defender en la presentacion:
	 *
	 *   - caduca solo a las 24 h sin tocarlo, y el reloj vuelve a empezar en
	 *     cada toque. Antes un pedido `pendiente` se quedaba ahi para siempre
	 *   - no hay id que guardar: la clave sale del token, asi que el carrito
	 *     aparece igual desde otro dispositivo sin buscar nada
	 *   - agregar y quitar no tocan PostgreSQL
	 *
	 *
	 * LO QUE HAY QUE ENTENDER DEL MODELO, QUE NO ES OBVIO
	 * ---------------------------------------------------------------
	 * En Redis cada linea es `id_oferta -> linea en JSON`: una FOTO con la
	 * cantidad, el nombre, la imagen, el vendedor y el precio de cuando se
	 * agrego o se cambio la cantidad por ultima vez. `GET /carrito` lee solo
	 * Redis (cambio del backend del 2026-09-23, commit e7f1e02).
	 *
	 * Consecuencia directa, y es la que hay que decirle a quien mira: el precio
	 * que se ve aqui es el de la foto. Si el vendedor lo mueve mientras el
	 * carrito espera, no cambia aqui: el backend lo compara al pagar y, si no
	 * cuadra, no cobra y avisa (ver Checkout.svelte).
	 *
	 * `precio` ya viene con el descuento aplicado. `porcentaje_descuento` es
	 * solo para la etiqueta: aqui no se recalcula nada con el.
	 *
	 *
	 * LAS RUTAS
	 * ---------------------------------------------------------------
	 *   GET    /carrito                      lo trae enriquecido
	 *   PUT    /carrito/lineas/:idOferta     fija la cantidad ABSOLUTA
	 *   DELETE /carrito/lineas/:idOferta     quita una linea
	 *   DELETE /carrito                      lo vacia entero
	 *
	 * `PUT` fija, no suma: para "uno mas" se manda `cantidad + 1`, no un +1. Y
	 * para quitar va el DELETE, no `cantidad: 0` -- el backend lo rechaza.
	 */

	let {
		abierto = false,
		alCerrar,
		alExpirarSesion,
		alPedirComprar
	}: {
		abierto?: boolean;
		alCerrar?: () => void;
		alExpirarSesion?: () => void;
		/**
		 * Avisa al layout de que hay que cobrar. El carrito NO compra: junta lo
		 * que hay y se aparta, igual que hacia el de antes.
		 *
		 * El primer parametro es el id del pedido, y aqui va SIEMPRE vacio: con
		 * el carrito en Redis el pedido no existe hasta que se compra -- lo crea
		 * POST /carrito/comprar en la misma transaccion. Se mantiene en la firma
		 * para no cambiar la del layout mientras conviven los dos caminos.
		 */
		alPedirComprar?: (idPedido: string, lineas: LineaPedido[]) => void;
	} = $props();

	interface Linea {
		id_oferta: number;
		cantidad: number;
		id_producto: number;
		id_producto_variante: number;
		nombre_producto: string;
		nombre_variante: string;
		imagen: string | null;
		/** Ya con el descuento aplicado, si la oferta tenia uno. */
		precio: string;
		/** "25.00" o null. Solo para la etiqueta: `precio` ya lo trae aplicado. */
		porcentaje_descuento: string | null;
		subtotal: string;
		vendedor: { usuario: string; nombre: string };
		stock_disponible: number;
		disponible: boolean;
		motivo: string | null;
		/**
		 * true si TENES UNIDADES RESERVADAS de esta oferta, con un plazo.
		 *
		 * El nombre invita a leerlo como "esta oferta es de venta relampago", y
		 * NO es eso. El backend lo calcula como `ticket != null` (ver
		 * carrito.service.ts, la linea del `const esInventarioLimitado`): mira
		 * si VOS tenes un ticket de reserva, no si la oferta esta marcada.
		 *
		 * La diferencia se midio y muerde: una linea de una oferta marcada como
		 * relampago, metida al carrito sin pasar por la reserva, llega aqui con
		 * este campo en FALSE. Correctamente, porque no hay nada apartado.
		 *
		 * Por eso la insignia dice lo que dice. No anuncia una promocion:
		 * avisa de que esas unidades ya son tuyas por un rato y se sueltan
		 * solas si tardas. Una linea normal no reserva nada al agregarse, solo
		 * al pagar; esta es la unica excepcion a esa regla.
		 */
		es_inventario_limitado: boolean;
	}

	interface CarritoApi {
		lineas: Linea[];
		total: string;
		total_lineas: number;
		total_items: number;
	}

	/**
	 * Los motivos que manda el backend, traducidos a algo que se pueda leer.
	 *
	 * El mapa esta aqui y no en el servidor a proposito: el motivo es un CODIGO
	 * -- un dato -- y la frase es presentacion. Si el backend mandara la frase,
	 * cambiarla obligaria a tocar el backend, y traducir la pantalla algun dia
	 * seria imposible.
	 */
	const MOTIVO: Record<string, string> = {
		oferta_no_disponible: 'El vendedor pauso o retiro esta oferta',
		agotado: 'Se agoto',
		stock_insuficiente: 'No hay tantas unidades',
		oferta_no_existe: 'Esta oferta ya no existe',
		// Este motivo es distinto de todos los de arriba y conviene que la
		// frase lo diga. Los otros cuatro hablan de la OFERTA: el vendedor la
		// pauso, se agoto, no hay tantas. Este habla del TIEMPO: la oferta
		// sigue ahi y puede quedar stock, lo que se acabo es el plazo de la
		// reserva. Por eso la frase invita a volver a intentarlo en vez de dar
		// a entender que ya no se puede comprar.
		reserva_vencida: 'Se vencio el tiempo de tu reserva. Cambia la cantidad para intentar de nuevo'
	};

	let carrito = $state<CarritoApi | null>(null);
	let cargando = $state(true);
	let error = $state('');
	let sinSesion = $state(false);
	let sinConectar = $state(false);

	/** La linea que se esta guardando, por id. Va por id y no como una sola
	 *  variable para que dos cambios seguidos no se pisen el estado. */
	let ocupada = $state<number | null>(null);

	let hayLineas = $derived((carrito?.lineas.length ?? 0) > 0);
	let noComprables = $derived(carrito?.lineas.filter((l) => !l.disponible) ?? []);

	// onMount para la primera vez. Con $effect se repetiria solo.
	onMount(cargar);

	/**
	 * Y se recarga cada vez que se ABRE, no solo al montar.
	 *
	 * El panel vive en el layout, asi que se monta una sola vez en toda la
	 * sesion: sin esto ensenaria lo que habia la primera vez que se abrio.
	 * La dependencia registrada es solo `abierto` -- cargar() escribe estado y
	 * sin el untrack el efecto se dispararia a si mismo en bucle.
	 */
	let estabaAbierto = false;
	$effect(() => {
		const ahora = abierto;
		untrack(() => {
			if (ahora && !estabaAbierto) cargar();
			estabaAbierto = ahora;
		});
	});

	async function cargar() {
		cargando = true;
		error = '';
		sinSesion = false;
		sinConectar = false;

		const r = await pedir<CarritoApi>('/carrito');
		cargando = false;

		if (r.estado === 401) {
			sinSesion = true;
			// El layout decide que hacer con una sesion vencida (cerrarla y
			// mandar a /entrar). Aqui no se navega: un panel que se cierra solo
			// y cambia de pagina desde dentro es imposible de seguir.
			alExpirarSesion?.();
			return;
		}
		if (r.estado === 404) {
			sinConectar = true;
			return;
		}
		if (!r.ok || !r.payload) {
			error = mensajeUtil(r);
			return;
		}
		carrito = r.payload;
	}

	/**
	 * Cambia la cantidad de una linea.
	 *
	 * `PUT` fija la cantidad ABSOLUTA, asi que aqui se manda el total nuevo y
	 * no el delta. Es lo contrario del ajuste de stock del panel de vendedor,
	 * donde el numero SI es un delta -- dos campos que se parecen y significan
	 * cosas opuestas, por eso el comentario.
	 */
	async function cambiarCantidad(linea: Linea, nueva: number) {
		if (nueva < 1) return quitar(linea);
		if (nueva > 1000) {
			error = 'El maximo por linea es 1000';
			return;
		}
		// EL TOPE DE STOCK, aqui y no en el servidor, y es POR DISENO: el carrito de
		// Redis es solo intencion y el backend lo documenta asi ("el stock no se
		// comprueba al agregar", endpoints-carrito.md); quien frena es el frontend
		// y el servidor rechaza al pagar. El PUT acepta cualquier
		// cantidad y contesta 200 dejando la linea marcada "no hay tantas
		// unidades", o sea que sin este limite el "+" te lleva a una linea que no
		// se puede comprar. Solo se frena SUBIR: bajar siempre se puede, incluso
		// desde una linea que ya se paso (5 con 4 en stock).
		if (nueva > linea.cantidad && nueva > linea.stock_disponible) {
			error =
				linea.stock_disponible > 0
					? `Solo hay ${linea.stock_disponible} ${linea.stock_disponible === 1 ? 'unidad' : 'unidades'} de esta oferta.`
					: 'Esta oferta no tiene unidades disponibles.';
			return;
		}

		ocupada = linea.id_oferta;
		const r = await pedir(
			`/carrito/lineas/${linea.id_oferta}`,
			conJson('PUT', { cantidad: nueva })
		);
		ocupada = null;

		if (!r.ok) {
			error = mensajeUtil(r);
			return;
		}
		// Se recarga entero y no se parchea la linea a mano: el subtotal, el
		// total y la disponibilidad los calcula el servidor, y recalcularlos
		// aqui seria una segunda verdad que se puede desincronizar.
		await cargar();
	}

	async function quitar(linea: Linea) {
		ocupada = linea.id_oferta;
		const r = await pedir(`/carrito/lineas/${linea.id_oferta}`, { method: 'DELETE' });
		ocupada = null;

		if (!r.ok) {
			error = mensajeUtil(r);
			return;
		}
		await cargar();
	}

	async function vaciar() {
		const r = await pedir('/carrito', { method: 'DELETE' });
		if (!r.ok) {
			error = mensajeUtil(r);
			return;
		}
		await cargar();
	}


	/**
	 * Traduce las lineas del carrito de Redis a la forma que espera Checkout.
	 *
	 * Se MAPEA campo por campo y no se castea: las dos formas se parecen y no
	 * son iguales -- aqui el precio se llama `precio` y alla `precio_unitario`,
	 * el vendedor viene anidado y alla es un texto plano. Un `as LineaPedido`
	 * compilaba igual y el checkout ensenaba "Pagar QNaN", porque sumaba un
	 * campo que no existia. TypeScript no puede avisar de eso: el cast es una
	 * promesa que le hace quien escribe.
	 *
	 * Los campos que no existen todavia van vacios a proposito:
	 * `id_pedido_producto`, `id_pedido` e `id_precio_historial` los crea la
	 * compra -- POST /carrito/comprar -- y aqui NO hay pedido. Checkout solo
	 * los usa para pintar el resumen, no para cobrar.
	 */
	function aLineasDePedido(lineas: Linea[]): LineaPedido[] {
		return lineas.map((l) => ({
			id_pedido_producto: '',
			id_pedido: '',
			id_producto_mongo: String(l.id_producto),
			id_producto_variante_mongo: String(l.id_producto_variante),
			nombre_producto: l.nombre_producto,
			nombre_variante: l.nombre_variante,
			nombre_vendedor: l.vendedor.nombre,
			id_oferta: String(l.id_oferta),
			id_usuario_vendedor: '',
			precio_unitario: l.precio,
			porcentaje_descuento_aplicado: l.porcentaje_descuento,
			cantidad: l.cantidad
		}));
	}

	function quetzales(valor: string | number): string {
		const n = typeof valor === 'number' ? valor : Number(valor);
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}
</script>

{#if abierto}
	<!-- El fondo es un <button> y no un <div> con onclick: hace falta poder
	     cerrarlo con el teclado, y un boton ya trae Enter, Espacio y el foco
	     sin escribir nada. Calcado de Carrito.svelte, que se va con esto. -->
	<button
		type="button"
		class="fondo"
		aria-label="Cerrar el carrito"
		onclick={() => alCerrar?.()}
		transition:fade={{ duration: 150 }}
	></button>

	<div
		class="panel"
		role="dialog"
		aria-modal="true"
		aria-label="Tu carrito"
		transition:fly={{ x: 400, duration: 220 }}
	>
		<section class="carrito">
	<div class="titulo">
		<h2>Tu carrito</h2>
		{#if carrito && carrito.total_lineas > 0}
			<span class="etiqueta">
				{carrito.total_items}
				{carrito.total_items === 1 ? 'articulo' : 'articulos'}
			</span>
		{/if}
		{#if hayLineas}
			<div class="acciones">
				<button type="button" onclick={cargar}>Actualizar</button>
				<button type="button" onclick={vaciar}>Vaciar</button>
			</div>
		{/if}
	</div>

	<p class="intro">
		Vive en <strong>Redis</strong>, no en la base relacional. Caduca a las 24 horas sin tocarlo,
		y el reloj vuelve a empezar cada vez que lo abres o lo cambias.
	</p>

	<!-- El precio es el de cuando agregaste. Decirlo aqui y no en el checkout:
	     es donde la persona mira los numeros y decide. -->
	<p class="nota-precio">
		Ves el precio de cuando agregaste cada producto. Si cambia antes de pagar, te avisamos
		antes de cobrar.
	</p>

	{#if cargando}
		<p class="gris">Cargando tu carrito...</p>
	{:else if sinSesion}
		<div class="caja">
			<h3>Inicia sesion para tener carrito</h3>
			<p class="gris">
				El carrito es de la cuenta, no del navegador: se guarda con tu usuario, asi que lo
				encuentras igual desde el telefono y desde la computadora.
			</p>
			<a class="ir" href="/entrar">Iniciar sesion</a>
		</div>
	{:else if sinConectar}
		<div class="caja">
			<h3>El carrito todavia no esta conectado</h3>
			<p class="gris">
				Esta pantalla espera <code>GET /carrito</code>, que el backend todavia no expone.
			</p>
		</div>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if !hayLineas}
		<div class="caja">
			<h3>Tu carrito esta vacio</h3>
			<p class="gris">
				Un carrito vacio no ocupa nada: en Redis simplemente no existe la clave hasta que
				agregas el primer producto.
			</p>
		</div>
	{:else if carrito}
		{#if noComprables.length > 0}
			<!-- Se avisa ARRIBA y ademas se marca cada linea. La linea no se
			     quita sola: si desapareciera, el total cambiaria sin que nadie
			     entienda por que. -->
			<p class="aviso" role="status">
				{noComprables.length}
				{noComprables.length === 1 ? 'linea no se puede' : 'lineas no se pueden'} comprar ahora
				mismo. {noComprables.length === 1 ? 'Esta marcada' : 'Estan marcadas'} abajo.
			</p>
		{/if}

		<ul class="lineas">
			{#each carrito.lineas as l (l.id_oferta)}
				<li class="linea" class:no-disponible={!l.disponible}>
					{#if l.imagen}
						<img src={l.imagen} alt="" loading="lazy" />
					{:else}
						<div class="sin-foto" aria-hidden="true"></div>
					{/if}

					<div class="datos">
						<a class="nombre" href="/producto/{l.id_producto}">{l.nombre_producto}</a>
						<span class="variante">{l.nombre_variante}</span>
						<span class="gris">Vendido por {l.vendedor.nombre}</span>

						<!--
							La insignia de venta relampago.

							Se ensena SIEMPRE que la linea es de inventario limitado,
							este disponible o no, y eso es a proposito: la diferencia
							que marca no es si se puede comprar, es que estas unidades
							YA ESTAN APARTADAS a nombre de quien mira. Esconderla en
							cuanto algo va mal dejaria a la persona sin la unica pista
							de por que su reserva vencio.

							Va antes del motivo y no despues porque explica el motivo:
							"reserva vencida" no significa nada si primero no se sabe
							que habia una reserva.
						-->
						{#if l.es_inventario_limitado}
							<span class="relampago" title="Estas unidades quedaron apartadas para vos por un tiempo limitado">
								Venta por tiempo limitado
							</span>
						{/if}

						{#if !l.disponible && l.motivo}
							<span class="motivo">
								{MOTIVO[l.motivo] ?? 'No se puede comprar'}
								{#if l.motivo === 'stock_insuficiente'}
									— quedan {l.stock_disponible}
									<button
										type="button"
										class="ajustar"
										disabled={ocupada === l.id_oferta}
										onclick={() => cambiarCantidad(l, l.stock_disponible)}
									>
										Ajustar a {l.stock_disponible}
									</button>
								{/if}
							</span>
						{/if}
					</div>

					<div class="cantidad">
						<!-- Botones y no un input libre: la cantidad es un numero
						     chico y se ajusta de uno en uno. Y el PUT manda el
						     TOTAL nuevo, no un delta. -->
						<button
							type="button"
							aria-label="Quitar uno"
							disabled={ocupada === l.id_oferta}
							onclick={() => cambiarCantidad(l, l.cantidad - 1)}>-</button
						>
						<span class="numero">{l.cantidad}</span>
						<button
							type="button"
							aria-label="Agregar uno"
							disabled={ocupada === l.id_oferta || l.cantidad >= Math.min(1000, l.stock_disponible)}
							title={l.cantidad >= Math.min(1000, l.stock_disponible) ? 'No hay mas unidades' : undefined}
							onclick={() => cambiarCantidad(l, l.cantidad + 1)}>+</button
						>
					</div>

					<div class="precios">
						<span class="subtotal">{quetzales(l.subtotal)}</span>
						<span class="gris unitario">{quetzales(l.precio)} c/u</span>
						{#if tieneDescuento(l.porcentaje_descuento)}
							<span class="descuento">-{textoPorcentaje(l.porcentaje_descuento)}</span>
						{/if}
						<button
							type="button"
							class="quitar"
							disabled={ocupada === l.id_oferta}
							onclick={() => quitar(l)}>Quitar</button
						>
					</div>
				</li>
			{/each}
		</ul>

		<div class="total">
			<div>
				<span class="gris">{carrito.total_lineas} ofertas · {carrito.total_items} articulos</span>
				<strong>{quetzales(carrito.total)}</strong>
			</div>

			<!-- El boton existe y esta apagado, con el motivo. Esconderlo daria a
			     entender que el carrito no sirve para comprar; asi se ve que
			     falta una pieza y cual. -->
			<div class="pagar">
				<button
					type="button"
					disabled={noComprables.length > 0}
					title={noComprables.length > 0 ? 'Quita o ajusta las lineas marcadas' : ''}
						onclick={() => alPedirComprar?.('', aLineasDePedido(carrito?.lineas ?? []))}
				>
					Continuar al pago
				</button>
				{#if noComprables.length > 0}
					<!-- Apagado y con el motivo, no escondido: un boton que no esta
					     no explica que falta hacer para que aparezca. -->
					<span class="gris pendiente-nota">
						Ajusta o quita {noComprables.length === 1 ? 'la linea marcada' : 'las lineas marcadas'} para poder pagar.
					</span>
				{/if}
			</div>
		</div>
	{/if}
		</section>
	</div>
{/if}

<style>
	/* El velo de atras. Cubre todo y cierra al pulsarlo. */
	.fondo {
		position: fixed;
		inset: 0;
		z-index: 40;
		border: 0;
		padding: 0;
		background: rgba(20, 20, 30, 0.38);
		cursor: pointer;
	}

	/* El panel entra desde la derecha y ocupa el alto completo. `max-width`
	   con `100%` para que en un telefono no se salga de la pantalla. */
	.panel {
		position: fixed;
		top: 0;
		right: 0;
		bottom: 0;
		z-index: 41;
		width: 480px;
		max-width: 100%;
		overflow-y: auto;
		background: var(--blanco);
		box-shadow: -8px 0 32px rgba(20, 20, 30, 0.14);
	}

	/* Dentro del panel no lleva borde ni fondo propios: los pone el panel. */
	.carrito {
		padding: 24px 26px;
	}

	.titulo {
		display: flex;
		align-items: center;
		gap: var(--e2);
		flex-wrap: wrap;
		margin-bottom: 8px;
	}

	.titulo h2 {
		font-size: var(--f-xl);
	}

	.etiqueta {
		padding: 3px 11px;
		font-size: var(--f-sm);
		color: var(--indigo);
		background: var(--indigo-cl);
		border-radius: 999px;
	}

	.acciones {
		margin-left: auto;
		display: flex;
		gap: var(--e2);
	}

	.intro,
	.nota-precio {
		max-width: 640px;
		color: var(--gris);
		font-size: var(--f-base);
	}

	.intro {
		margin-bottom: 6px;
	}

	.nota-precio {
		margin-bottom: 20px;
		font-size: var(--f-ms);
	}

	.gris {
		color: var(--gris);
	}

	code {
		padding: 1px 6px;
		font-size: 0.88em;
		background: var(--panel);
		border-radius: 4px;
	}

	button {
		font-family: inherit;
		cursor: pointer;
	}

	.acciones button,
	.fallo button,
	.quitar {
		padding: 7px 14px;
		font-size: var(--f-ms);
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		transition:
			border-color var(--t),
			color var(--t);
	}

	.acciones button:hover,
	.quitar:hover,

	button:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.caja {
		padding: 22px 24px;
		background: var(--panel);
		border-radius: var(--r2);
	}

	.caja h3 {
		font-size: var(--f-md);
		margin-bottom: 8px;
	}

	.caja p {
		max-width: 600px;
		margin-bottom: 14px;
		font-size: var(--f-base);
	}

	.ir {
		display: inline-block;
		padding: 9px 18px;
		font-size: var(--f-base);
		color: var(--blanco);
		background: var(--indigo);
		border-radius: var(--r);
		text-decoration: none;
	}

	.fallo {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		flex-wrap: wrap;
		padding: 14px 18px;
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	.aviso {
		margin-bottom: 16px;
		padding: 10px 14px;
		font-size: var(--f-base);
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	/* -- las lineas -- */

	.lineas {
		list-style: none;
	}

	.linea {
		display: grid;
		grid-template-columns: 64px 1fr auto auto;
		align-items: center;
		gap: var(--e4);
		padding: 16px 0;
		border-bottom: 1px solid var(--linea);
	}

	.linea:first-child {
		padding-top: 0;
	}

	/* La linea no se esconde: se apaga y se explica. */
	.linea.no-disponible img,
	.linea.no-disponible .datos .nombre,
	.linea.no-disponible .precios {
		opacity: 0.55;
	}

	.linea img,
	.sin-foto {
		width: 64px;
		height: 64px;
		object-fit: cover;
		border-radius: var(--r);
		background: var(--panel);
	}

	.datos {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		min-width: 0;
	}

	.nombre {
		font-weight: 500;
		color: var(--tinta);
		text-decoration: none;
		overflow-wrap: anywhere;
	}

	.nombre:hover {
		color: var(--indigo);
	}

	.variante {
		font-size: var(--f-ms);
		color: var(--texto);
	}

	.datos .gris {
		font-size: var(--f-sm);
	}

	/*
	   La insignia de venta relampago. Naranja y no roja: no es un error, es una
	   condicion de la compra. El rojo de .motivo tiene que seguir siendo el
	   color que solo aparece cuando algo esta mal, o deja de querer decir eso.
	*/
	.relampago {
		align-self: flex-start;
		font-size: var(--f-xs);
		font-weight: 600;
		line-height: 1.2;
		padding: 0.15rem 0.45rem;
		border-radius: 0.35rem;
		color: #7c3a00;
		background: #ffe8cc;
		border: 1px solid #ffc98a;
	}

	/* El % de descuento de la linea. Los colores salen del layout, igual en
	   todas las pantallas que pintan un descuento. */
	.descuento {
		font-size: var(--f-xs);
		font-weight: 600;
		line-height: 1.2;
		padding: 0.15rem 0.45rem;
		border-radius: 999px;
		color: var(--descuento-tinta);
		background: var(--descuento-fondo);
		border: 1px solid var(--descuento-linea);
	}

	.motivo {
		margin-top: 4px;
		font-size: var(--f-sm);
		color: var(--rojo);
	}

	.cantidad {
		display: flex;
		align-items: center;
		gap: var(--e1);
	}

	.cantidad button {
		width: 30px;
		height: 30px;
		font-size: var(--f-md);
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.cantidad button:hover:not(:disabled) {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.numero {
		min-width: 28px;
		text-align: center;
	}

	.precios {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: var(--e1);
	}

	.subtotal {
		font-weight: 500;
	}

	.unitario {
		font-size: var(--f-sm);
	}

	.quitar {
		margin-top: 4px;
		padding: 4px 10px;
		font-size: var(--f-sm);
	}

	/* -- el total -- */

	.total {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		flex-wrap: wrap;
		margin-top: 22px;
		padding-top: 20px;
		border-top: 2px solid var(--linea);
	}

	.total > div:first-child {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
	}

	.total strong {
		font-size: var(--f-xl);
	}

	.pagar {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: var(--e1);
	}

	.pagar button {
		padding: 12px 26px;
		font-size: var(--f-md);
		color: var(--blanco);
		background: var(--indigo);
		border: 0;
		border-radius: var(--r);
	}

	.pendiente-nota {
		max-width: 320px;
		text-align: right;
		font-size: var(--f-sm);
	}


	/* -- el andamiaje -- */








	@media (max-width: 620px) {
		.carrito {
			padding: 22px 20px;
		}
		.acciones {
			margin-left: 0;
			width: 100%;
		}
		.linea {
			grid-template-columns: 52px 1fr;
			row-gap: var(--e2);
		}
		.linea img,
		.sin-foto {
			width: 52px;
			height: 52px;
		}
		.cantidad,
		.precios {
			grid-column: 2;
			align-items: flex-start;
		}
		.precios {
			flex-direction: row;
			align-items: center;
			gap: var(--e3);
		}
		.pagar {
			align-items: flex-start;
			width: 100%;
		}
		.pendiente-nota {
			text-align: left;
		}
	}
	/* "Ajustar a N": deja una linea que se paso en lo que si hay. */
	.ajustar {
		margin-left: 6px;
		padding: 0;
		font: inherit;
		color: var(--indigo);
		text-decoration: underline;
		background: none;
		border: 0;
		cursor: pointer;
	}

	.ajustar:disabled {
		color: var(--gris);
		cursor: default;
	}
</style>
