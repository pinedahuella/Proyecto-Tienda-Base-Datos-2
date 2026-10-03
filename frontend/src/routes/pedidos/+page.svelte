<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import MisPedidos from '$lib/MisPedidos.svelte';
	import { cerrarSesion, SesionIndeterminada, verificarSesion } from '$lib/sesion';
	import { carrito } from '$lib/estadoCarrito.svelte';

	/**
	 * Mis pedidos: todo lo que se ha comprado. La compra sale del carrito, asi
	 * que ya no hay un pedido abierto que llenar aqui.
	 *
	 * Pagina propia, y no una seccion mas del panel. Antes vivian los dos
	 * dentro de /panel, debajo del perfil y de las direcciones: comprar y
	 * administrar la cuenta son cosas distintas, y meterlas en la misma pagina
	 * obligaba a bajar por los datos personales para llegar a lo que uno venia
	 * a ver. El panel se queda con la cuenta; esto es lo que se compro.
	 *
	 * Pide sesion, como todo /comprador/*. No exige rol: comprar no es
	 * privilegio de nadie, y un vendedor o un admin compran igual.
	 */

	let cargando = $state(true);
	let error = $state('');

	onMount(async () => {
		try {
			const sesion = await verificarSesion();
			if (!sesion) {
				await goto('/entrar');
				return;
			}
		} catch (fallo) {
			// No se pudo averiguar (503, o el backend apagado). No se saca a
			// nadie: el token puede estar bien y ser el servidor el del problema.
			error = fallo instanceof SesionIndeterminada ? fallo.message : 'No se pudo cargar tus pedidos';
		}
		cargando = false;
	});

	/** La sesion se acabo de verdad: a entrar de nuevo. */
	function expiro() {
		cerrarSesion();
		carrito.olvidar();
		goto('/entrar');
	}
</script>

<svelte:head>
	<title>Mis pedidos · Mesh</title>
</svelte:head>

<Cabecera />

<main>
	<div class="env">
		{#if cargando}
			<p class="cargando">Cargando tus pedidos...</p>
		{:else if error}
			<div class="aviso" role="alert">
				<p>{error}</p>
				<a href="/pedidos">Reintentar</a>
			</div>
		{:else}
			<div class="saludo">
				<h1>Mis pedidos</h1>
				<p>Todo lo que has comprado.</p>
			</div>

			<div class="bloque">
				<MisPedidos alExpirarSesion={expiro} />
			</div>
		{/if}
	</div>
</main>

<Pie />

<style>
	main {
		padding-top: 48px;
		min-height: 50vh;
	}

	.cargando {
		color: var(--gris);
		padding: 3rem 0;
	}

	.aviso {
		padding: 1.1rem 1.25rem;
		background: var(--panel);
		border: 1px solid var(--rojo);
		border-radius: var(--r2);
		color: var(--rojo);
	}

	.aviso a {
		color: var(--indigo);
	}

	.saludo {
		max-width: 560px;
		margin-bottom: 36px;
	}

	.saludo h1 {
		margin-bottom: 10px;
	}

	.saludo p {
		color: var(--gris);
	}

	/* Cada seccion en su tarjeta, separadas. Antes iban una pegada a la otra
	   sobre el fondo, y el pedido abierto y el historial se leian como un solo
	   bloque largo. */
	.bloque {
		margin-bottom: 28px;
		padding: 26px 28px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	/* Los componentes traen su propio margen de arriba, pensado para cuando
	   iban sueltos en el panel. Dentro de la tarjeta sobra. */
	.bloque :global(section) {
		margin-top: 0;
	}

	@media (max-width: 620px) {
		.bloque {
			padding: 20px 16px;
		}
	}
</style>
