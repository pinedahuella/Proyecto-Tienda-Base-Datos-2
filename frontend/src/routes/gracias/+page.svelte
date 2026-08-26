<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import {
		direccionEnUnaLinea,
		quetzales,
		subtotal,
		totalPedido,
		traerPedido,
		type PedidoCompleto
	} from '$lib/pedido';

	/**
	 * La pantalla de despues de comprar.
	 *
	 * Antes la compra terminaba cerrando el checkout y nada mas: el carrito se
	 * vaciaba y la persona se quedaba en la misma ficha, con los MISMOS numeros
	 * de existencias que tenia antes de comprar. El descuento si habia pasado en
	 * la base, pero en pantalla no se veia, asi que parecia que no habia pasado
	 * nada.
	 *
	 * Aqui se aterriza con el pedido ya comprado, y el boton de volver al inicio
	 * hace una navegacion de verdad: el catalogo se vuelve a pedir y las
	 * existencias salen ya descontadas.
	 *
	 * El pedido se pide otra vez a `GET /comprador/pedidos/:id` en vez de
	 * arrastrar lo que devolvio la compra: asi lo que se ensena es lo que quedo
	 * guardado -- el estado, el metodo de pago y la direccion incluidos -- y no
	 * lo que el navegador creia. Si el id no viene o no se puede traer, se dice
	 * y se deja igual la salida al catalogo: la compra ya se hizo, quedarse sin
	 * pantalla por no poder releerla seria peor.
	 */

	let idPedido = $derived(page.url.searchParams.get('pedido') ?? '');

	let datos = $state<PedidoCompleto | null>(null);
	let cargando = $state(true);
	let error = $state('');

	onMount(async () => {
		if (!idPedido) {
			cargando = false;
			error = 'No se sabe que pedido enseñar.';
			return;
		}

		const r = await traerPedido(idPedido);
		cargando = false;

		if (r.ok && r.payload) {
			datos = r.payload;
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	});

	let total = $derived(datos ? totalPedido(datos.detalles) : 0);

	function fecha(iso: string): string {
		const d = new Date(iso);
		return Number.isNaN(d.getTime())
			? iso
			: d.toLocaleDateString('es-GT', { day: 'numeric', month: 'long', year: 'numeric' });
	}
</script>

<svelte:head>
	<title>Gracias por tu compra · Mesh</title>
</svelte:head>

<Cabecera />

<main class="env">
	<section class="gracias">
		<div class="sello" aria-hidden="true">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">
				<path d="M20 6 9 17l-5-5" stroke-linecap="round" stroke-linejoin="round" />
			</svg>
		</div>

		<h1>Gracias por tu compra</h1>

		<!--
			El texto no afirma nada hasta haberlo comprobado.

			Antes decia "quedo registrado y las unidades ya se descontaron" nada
			mas entrar, aunque la peticion que lo confirma siguiera en vuelo o
			hubiera fallado: si el id era de otra persona salia el 404 debajo de
			una frase que juraba que todo habia ido bien.
		-->
		{#if cargando}
			<p class="sub">Confirmando tu pedido...</p>
		{:else if datos}
			<p class="sub">
				Tu pedido <strong>#{idPedido}</strong> quedo registrado y las unidades ya se
				descontaron.
			</p>
		{:else}
			<p class="sub">No se pudo leer el detalle de tu pedido.</p>
		{/if}

		{#if cargando}
			<p class="quieto">Cargando el detalle...</p>
		{:else if error}
			<p class="malo" role="alert">{error}</p>
		{:else if datos}
			<div class="tarjeta">
				<div class="cabeza">
					<div>
						<span class="rotulo">Estado</span>
						<p class="valor">{datos.pedido.estado_pedido_nombre}</p>
					</div>
					<div>
						<span class="rotulo">Fecha</span>
						<p class="valor">{fecha(datos.pedido.fecha_creacion)}</p>
					</div>
					<div>
						<span class="rotulo">Pedido</span>
						<p class="valor">#{datos.pedido.id_pedido}</p>
					</div>
					<!-- El metodo de pago no se ensena aqui: `GET
					     /comprador/pedidos/:id` devuelve la cabecera sin el
					     (`CabeceraPedido` no lo trae), y solo aparece en la fila
					     de `GET /comprador/pedidos`. Pedir la lista entera para
					     un dato de adorno no vale la pena; en /pedidos si sale. -->
				</div>

				<div class="lineas">
					{#each datos.detalles as d (d.id_pedido_producto)}
						<div class="linea">
							<div class="que">
								<strong>{d.nombre_producto}</strong>
								<span class="menor">
									{d.nombre_variante} · {d.nombre_vendedor} · {d.cantidad}
									{d.cantidad === 1 ? 'unidad' : 'unidades'}
								</span>
							</div>
							<span class="importe">{quetzales(subtotal(d))}</span>
						</div>
					{/each}
				</div>

				<div class="total">
					<span>Total</span>
					<strong>{quetzales(total)}</strong>
				</div>

				{#if datos.direccion}
					<div class="entrega">
						<span class="rotulo">Se entrega en</span>
						<p class="valor">{direccionEnUnaLinea(datos.direccion)}</p>
					</div>
				{/if}
			</div>
		{/if}

		<div class="salidas">
			<!--
				Un enlace de verdad y no un goto(): la navegacion completa vuelve
				a pedir el catalogo, y por eso las existencias salen ya
				descontadas. Con una navegacion del lado del cliente se
				reaprovecharia lo que ya estaba en memoria y los numeros
				seguirian siendo los de antes de comprar, que es justo lo que se
				queria arreglar.
			-->
			<a class="boton principal" href="/" data-sveltekit-reload>Volver al inicio</a>
			<a class="boton" href="/pedidos">Ver mis pedidos</a>
		</div>
	</section>
</main>

<Pie />

<style>
	.gracias {
		max-width: 660px;
		margin: 0 auto;
		padding: 4rem 0 5rem;
		text-align: center;
	}

	.sello {
		width: 64px;
		height: 64px;
		margin: 0 auto 1.5rem;
		display: grid;
		place-items: center;
		color: var(--sobre-indigo);
		background: var(--indigo);
		border-radius: 999px;
	}

	.sello svg {
		width: 32px;
		height: 32px;
	}

	.sub {
		margin-top: 0.75rem;
		color: var(--gris);
	}

	.quieto,
	.malo {
		margin-top: 2rem;
		color: var(--gris);
	}

	.malo {
		color: var(--rojo);
	}

	.tarjeta {
		margin-top: 2.5rem;
		padding: 1.5rem;
		text-align: left;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.cabeza {
		display: flex;
		flex-wrap: wrap;
		gap: 2rem;
		padding-bottom: 1.25rem;
		border-bottom: 1px solid var(--linea);
	}

	.rotulo {
		display: block;
		font-size: 0.8rem;
		color: var(--gris);
	}

	.valor {
		margin-top: 0.15rem;
		color: var(--tinta);
	}

	.lineas {
		padding: 0.5rem 0;
	}

	.linea {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 1rem;
		padding: 0.75rem 0;
		border-bottom: 1px solid var(--linea);
	}

	.que {
		display: flex;
		flex-direction: column;
	}

	.menor {
		font-size: 0.85rem;
		color: var(--gris);
	}

	.importe {
		white-space: nowrap;
		color: var(--tinta);
	}

	.total {
		display: flex;
		justify-content: space-between;
		padding-top: 1rem;
		font-size: 1.1rem;
		color: var(--tinta);
	}

	.entrega {
		margin-top: 1.25rem;
		padding-top: 1.25rem;
		border-top: 1px solid var(--linea);
	}

	.salidas {
		display: flex;
		flex-wrap: wrap;
		gap: 0.75rem;
		justify-content: center;
		margin-top: 2.5rem;
	}

	@media (max-width: 620px) {
		.gracias {
			padding: 2.5rem 0 3rem;
		}
		.cabeza {
			gap: 1.25rem;
		}
	}
</style>
