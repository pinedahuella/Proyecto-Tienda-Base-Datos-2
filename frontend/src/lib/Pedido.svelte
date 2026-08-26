<script lang="ts">
	import { onMount } from 'svelte';
	import { pedir, type RespuestaApi } from './api';
	import {
		agregarLinea,
		crearPedido,
		guardarPedidoAbierto,
		leerPedidoAbierto,
		olvidarPedidoAbierto,
		pedidoCaduco,
		quetzales,
		quitarLinea,
		subtotal,
		totalPedido,
		traerPedido,
		type PedidoCompleto
	} from './pedido';

	/**
	 * El pedido abierto de quien esta logueado: sus lineas, su direccion y su
	 * total.
	 *
	 * Consume las cuatro rutas que subio el backend en /comprador/pedidos (ver
	 * lib/pedido.ts, que tiene el detalle de cada una y de las dos que NO
	 * existen todavia).
	 *
	 * Lo que esta pantalla NO hace, y no por descuido:
	 *   - no cierra la compra: no hay ruta que llame a comprar_pedido()
	 *   - no reserva stock: agregar una linea solo LEE el inventario
	 * Las dos cosas se dicen en pantalla en vez de esconderlas tras un boton
	 * que no llevaria a ningun lado.
	 */

	let { alExpirarSesion }: { alExpirarSesion?: () => void } = $props();

	interface Direccion {
		id_direccion: string;
		pais: string;
		departamento: string;
		ciudad: string;
		codigo_postal: string | null;
	}

	let pedido = $state<PedidoCompleto | null>(null);
	let direcciones = $state<Direccion[]>([]);
	let direccionElegida = $state('');
	let cargando = $state(true);
	let error = $state('');
	/** true si no se pudo PREGUNTAR por las direcciones, que no es "no hay". */
	let direccionesFallaron = $state(false);
	let aviso = $state('');
	let trabajando = $state(false);

	/** true si la sesion se acabo. Se avisa al panel para que saque a la persona. */
	function expiro(r: RespuestaApi<unknown>): boolean {
		if (r.estado === 401) {
			alExpirarSesion?.();
			return true;
		}
		return false;
	}

	async function cargar() {
		cargando = true;
		error = '';
		direccionesFallaron = false;

		const rDirecciones = await pedir<Direccion[]>('/direccion-usuario');
		if (expiro(rDirecciones)) {
			cargando = false;
			return;
		}
		if (rDirecciones.ok && rDirecciones.payload) {
			direcciones = rDirecciones.payload;
			if (!direccionElegida && direcciones[0]) {
				direccionElegida = direcciones[0].id_direccion;
			}
		} else {
			// Sin esto, un fallo del servidor dejaba `direcciones` vacio y la
			// pantalla afirmaba "hace falta una direccion de entrega": mandaba a
			// crear una que a lo mejor ya existe, por un fallo que no era suyo.
			direccionesFallaron = true;
			error = rDirecciones.estado === 0 ? 'No se pudo conectar con el servidor' : rDirecciones.mensaje;
		}

		const guardado = leerPedidoAbierto();
		if (!guardado) {
			pedido = null;
			cargando = false;
			return;
		}

		const r = await traerPedido(guardado);
		if (expiro(r)) return;

		if (r.ok && r.payload) {
			pedido = r.payload;
		} else if (pedidoCaduco(r)) {
			// El pedido guardado ya no existe o no es de esta cuenta (pasa al
			// cambiar de usuario en el mismo navegador). Se olvida en vez de
			// dejar la pantalla pidiendolo para siempre.
			olvidarPedidoAbierto();
			pedido = null;
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
		cargando = false;
	}

	onMount(cargar);

	async function abrir() {
		if (!direccionElegida) {
			error = 'Elegi una direccion de entrega';
			return;
		}
		trabajando = true;
		error = '';
		const r = await crearPedido(direccionElegida);
		trabajando = false;
		if (expiro(r)) return;

		if (r.ok && r.payload) {
			guardarPedidoAbierto(r.payload.id_pedido);
			aviso = `Pedido ${r.payload.id_pedido} abierto`;
			await cargar();
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	async function quitar(idDetalle: string, nombre: string) {
		if (!pedido) return;
		trabajando = true;
		error = '';
		const r = await quitarLinea(pedido.pedido.id_pedido, idDetalle);
		trabajando = false;
		if (expiro(r)) return;

		if (r.ok) {
			aviso = `"${nombre}" quitado del pedido`;
			await cargar();
		} else if (pedidoCaduco(r)) {
			// Aqui el 404 solo puede ser del pedido o de la linea, y las dos
			// cosas quieren decir que lo que hay en pantalla ya no existe. Sin
			// esto la pantalla seguia enseñando el pedido y todos sus botones
			// fallaban, uno tras otro, hasta recargar a mano.
			await olvidarSiYaNoEsta('Esa linea ya no estaba en el pedido.');
		} else {
			error = r.mensaje;
		}
	}

	/**
	 * Comprueba si el pedido sigue vivo y, si no, lo suelta.
	 *
	 * Se pregunta en vez de darlo por muerto: el 404 de quitar una linea
	 * tambien sale cuando la linea ya no esta pero el pedido si.
	 */
	async function olvidarSiYaNoEsta(mensajeSiVive: string) {
		if (!pedido) return;
		const r = await traerPedido(pedido.pedido.id_pedido);
		if (pedidoCaduco(r)) {
			olvidarPedidoAbierto();
			pedido = null;
			aviso = 'Ese pedido ya no existe. Puedes abrir uno nuevo.';
			error = '';
		} else {
			// El pedido vive: lo que no estaba era otra cosa. Se relee para que
			// la pantalla deje de enseñar algo que ya no existe.
			error = mensajeSiVive;
			await cargar();
		}
	}

	/**
	 * Suma una unidad mas de una linea que ya esta. No hay ruta para "poner la
	 * cantidad en N": agregar_linea() SUMA a lo que ya habia, asi que subir de
	 * a uno es lo unico que se puede prometer. Para bajar hay que quitar la
	 * linea entera y volver a agregarla.
	 */
	async function sumarUna(linea: PedidoCompleto['detalles'][number]) {
		if (!pedido) return;
		trabajando = true;
		error = '';
		// Sobre la MISMA oferta, no sobre la variante: sumar una unidad tiene
		// que comprarsela al mismo vendedor y al precio que ya se congelo.
		const r = await agregarLinea(pedido.pedido.id_pedido, {
			id_oferta: Number(linea.id_oferta),
			cantidad: 1
		});
		trabajando = false;
		if (expiro(r)) return;

		if (r.ok && r.payload) {
			aviso = `"${linea.nombre_variante}" queda en ${r.payload.cantidad} (hay ${r.payload.stock_disponible} en existencia)`;
			await cargar();
		} else if (pedidoCaduco(r)) {
			// El 404 de agregar tambien sale si el producto o la variante se
			// ocultaron. Por eso no se da por muerto el pedido: se pregunta.
			await olvidarSiYaNoEsta('Ese producto o esa variante ya no estan disponibles.');
		} else {
			// El 409 de aqui es del negocio y su texto ya viene claro del backend
			// ("no hay suficiente stock", "el pedido ya no se puede cambiar",
			// "no hay inventario para la variante N"): se cita tal cual.
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	/**
	 * Soltar el pedido pide confirmacion, y no por ceremonia: NO hay ruta para
	 * listar los pedidos de uno, asi que el id guardado aqui es el unico hilo
	 * que une este navegador con ese pedido. Un click lo corta y no hay vuelta
	 * atras desde la interfaz. La confirmacion es en linea, no un dialogo del
	 * navegador: un confirm() bloquea la pagina entera.
	 */
	let confirmandoSoltar = $state(false);

	function cerrarPedidoLocal() {
		olvidarPedidoAbierto();
		pedido = null;
		confirmandoSoltar = false;
		aviso = 'Este navegador ya no recuerda ese pedido. Sigue existiendo en la base.';
	}

	function comoTexto(d: { pais: string; departamento: string; ciudad: string; codigo_postal: string | null }) {
		const partes = [d.ciudad, d.departamento, d.pais].filter((x) => x);
		return partes.join(', ') + (d.codigo_postal ? ` — ${d.codigo_postal}` : '');
	}

	let total = $derived(pedido ? totalPedido(pedido.detalles) : 0);
	let unidades = $derived(
		pedido ? pedido.detalles.reduce((s, l) => s + l.cantidad, 0) : 0
	);
</script>

<section class="panel">
	<div class="titulo">
		<div>
			<h2>Tu pedido</h2>
			<p class="sub">
				{#if pedido}
					Pedido {pedido.pedido.id_pedido} · {pedido.pedido.estado_pedido_nombre}
				{:else}
					Todavia no tienes un pedido abierto
				{/if}
			</p>
		</div>
		{#if pedido}
			<div class="acciones">
				{#if confirmandoSoltar}
					<span class="menor">
						Vas a perder el acceso a este pedido desde aqui, y no hay forma de volver a
						encontrarlo. ¿Seguro?
					</span>
					<button type="button" class="quitar" onclick={cerrarPedidoLocal}>Si, soltarlo</button>
					<button type="button" onclick={() => (confirmandoSoltar = false)}>Cancelar</button>
				{:else}
					<button type="button" onclick={() => (confirmandoSoltar = true)}>
						Dejar de seguirlo
					</button>
				{/if}
			</div>
		{/if}
	</div>

	{#if aviso}
		<p class="ok" role="status">{aviso}</p>
	{/if}
	{#if error}
		<p class="malo" role="alert">{error}</p>
	{/if}

	{#if cargando}
		<p class="quieto">Cargando tu pedido...</p>
	{:else if !pedido}
		{#if direccionesFallaron}
			<p class="quieto">
				No se pudieron consultar tus direcciones, asi que no se puede abrir un pedido
				todavia. El error esta arriba.
				<button type="button" class="enlace" onclick={cargar}>Reintentar</button>
			</p>
		{:else if direcciones.length === 0}
			<p class="quieto">
				Para abrir un pedido hace falta una direccion de entrega. Agrega una arriba, en
				"Tus direcciones".
			</p>
		{:else}
			<div class="abrir">
				<div class="campo">
					<label for="p-dir">Direccion de entrega</label>
					<select id="p-dir" bind:value={direccionElegida}>
						{#each direcciones as d (d.id_direccion)}
							<option value={d.id_direccion}>{comoTexto(d)}</option>
						{/each}
					</select>
				</div>
				<button type="button" class="principal" onclick={abrir} disabled={trabajando}>
					{trabajando ? 'Abriendo...' : 'Abrir pedido'}
				</button>
			</div>
			<p class="menor">
				El pedido guarda la version de la direccion que rige hoy: si la editas despues, este
				pedido conserva la de ahora.
			</p>
		{/if}
	{:else}
		<div class="explica">
			<p class="menor">
				Entrega en <strong>{comoTexto(pedido.direccion)}</strong>, abierto el
				{new Date(pedido.pedido.fecha_creacion).toLocaleDateString('es-GT', {
					day: 'numeric',
					month: 'long',
					year: 'numeric'
				})}.
			</p>
			<!-- Aqui decia que "el backend aun no expone esa ruta" para cerrar la
			     compra. Dejo de ser cierto: POST /comprador/pedidos/:id/comprar
			     existe, y de hecho este mismo comprador ya tiene pedidos pagados.
			     Un aviso caducado es peor que ninguno: manda a la persona a
			     esperar algo que ya puede hacer. -->
			<p class="menor">
				Agregar cosas <strong>no reserva existencias</strong>: se comprueba que haya, pero
				se descuentan al comprar. Si alguien mas se lleva la ultima unidad antes, la compra
				lo avisa y no cobra nada.
			</p>
		</div>

		{#if pedido.detalles.length === 0}
			<p class="quieto">
				El pedido esta vacio. Agrega productos desde el catalogo, en la ficha de cada uno.
			</p>
		{:else}
			<div class="tabla">
				{#each pedido.detalles as l (l.id_pedido_producto)}
					<article class="fila">
						<div class="datos">
							<h3>{l.nombre_variante}</h3>
							<p class="menor">
								{l.nombre_producto} · producto {l.id_producto_mongo} · variante
								{l.id_producto_variante_mongo}
							</p>
						</div>

						<div class="numeros">
							<span class="menor">{quetzales(Number(l.precio_unitario))} x {l.cantidad}</span>
							<strong class="grande">{quetzales(subtotal(l))}</strong>
						</div>

						<div class="acciones">
							<button type="button" onclick={() => sumarUna(l)} disabled={trabajando}>
								Una mas
							</button>
							<button
								type="button"
								class="quitar"
								onclick={() => quitar(l.id_pedido_producto, l.nombre_variante)}
								disabled={trabajando}
							>
								Quitar
							</button>
						</div>
					</article>
				{/each}
			</div>

			<div class="total">
				<span class="menor">
					{pedido.detalles.length}
					{pedido.detalles.length === 1 ? 'linea' : 'lineas'} ·
					{unidades}
					{unidades === 1 ? 'unidad' : 'unidades'}
				</span>
				<strong>Total {quetzales(total)}</strong>
			</div>
		{/if}
	{/if}
</section>

<style>
	.panel {
		padding: 1.5rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.titulo {
		display: flex;
		flex-wrap: wrap;
		align-items: flex-start;
		justify-content: space-between;
		gap: 0.75rem;
		margin-bottom: 1rem;
	}

	h2 {
		font-size: 1.1rem;
		font-weight: 600;
		color: var(--tinta);
	}

	.sub,
	.menor {
		font-size: 0.85rem;
		color: var(--gris);
	}

	.abrir {
		display: flex;
		flex-wrap: wrap;
		align-items: flex-end;
		gap: 0.75rem;
		margin-bottom: 0.6rem;
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
		min-width: 15rem;
		flex: 1;
	}

	label {
		font-size: 0.8rem;
		color: var(--gris);
	}

	select {
		padding: 0.5rem 0.6rem;
		background: var(--off);
		color: var(--tinta);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		font: inherit;
	}

	.explica {
		padding: 0.8rem 1rem;
		margin-bottom: 1rem;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-left: 3px solid var(--indigo);
		border-radius: var(--r2);
	}

	.explica p + p {
		margin-top: 0.35rem;
	}

	.tabla {
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
	}

	.fila {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
		padding: 0.75rem 0.9rem;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.fila h3 {
		font-size: 0.95rem;
		font-weight: 600;
		color: var(--tinta);
	}

	.numeros {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 0.1rem;
	}

	.grande {
		font-size: 1.05rem;
		color: var(--tinta);
	}

	.acciones {
		display: flex;
		gap: 0.4rem;
	}

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

	.quieto {
		padding: 1.25rem 0;
		color: var(--gris);
		font-size: 0.9rem;
	}

	.ok,
	.malo {
		padding: 0.6rem 0.8rem;
		margin-bottom: 0.9rem;
		border-radius: var(--r);
		font-size: 0.88rem;
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
</style>
