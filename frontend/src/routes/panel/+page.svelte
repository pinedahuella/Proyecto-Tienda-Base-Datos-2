<script lang="ts">
	import { goto } from '$app/navigation';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import { leerSesion, cerrarSesion, nombreDesdeCorreo } from '$lib/sesion';

	let correo = $state<string | null>(null);

	$effect(() => {
		const guardado = leerSesion();
		if (!guardado) {
			goto('/');
			return;
		}
		correo = guardado;
	});

	let nombre = $derived(correo ? nombreDesdeCorreo(correo) : '');

	function salir() {
		cerrarSesion();
		goto('/');
	}

	const resumen = [
		{ rotulo: 'Pedidos', cifra: '0', nota: 'Aun no hay pedidos.' },
		{ rotulo: 'Productos', cifra: '0', nota: 'Todavia no has publicado nada.' },
		{ rotulo: 'Inventario', cifra: '0', nota: 'Sin movimientos registrados.' }
	];
</script>

<svelte:head>
	<title>Mesh · Panel</title>
</svelte:head>

<Cabecera sesion={correo} alSalir={salir} />

{#if correo}
	<main>
		<div class="env">
			<div class="saludo">
				<h1>Hola, {nombre}</h1>
				<p>Tu tienda esta lista. Publica tu primer producto para que aparezca en el catalogo.</p>
			</div>

			<div class="resumen">
				{#each resumen as tarjeta}
					<article>
						<h3>{tarjeta.rotulo}</h3>
						<p class="cifra">{tarjeta.cifra}</p>
						<p class="nota">{tarjeta.nota}</p>
					</article>
				{/each}
			</div>

			<section class="invitacion">
				<h2>Tu tienda esta vacia por ahora</h2>
				<p>
					Cuando publiques tu primer producto, los pedidos y los movimientos de inventario
					empiezan a aparecer aqui.
				</p>
			</section>
		</div>
	</main>
{/if}

<Pie />

<style>
	main {
		padding-top: 48px;
		min-height: 50vh;
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

	.resumen {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
		gap: 20px;
		margin-bottom: 28px;
	}

	.resumen article {
		padding: 22px 24px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.resumen h3 {
		font-size: 0.95rem;
		font-weight: 500;
		color: var(--gris);
		margin-bottom: 10px;
	}

	.cifra {
		font-size: 2.4rem;
		line-height: 1;
		color: var(--tinta);
		margin-bottom: 8px;
	}

	.nota {
		font-size: 0.92rem;
		color: var(--gris-2);
	}

	.invitacion {
		padding: 30px 32px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.invitacion h2 {
		font-size: 1.3rem;
		margin-bottom: 6px;
	}

	.invitacion p {
		max-width: 560px;
		color: var(--texto);
	}

	@media (max-width: 620px) {
		main {
			padding-top: 32px;
		}
		.saludo {
			margin-bottom: 26px;
		}
		.resumen {
			gap: 14px;
			margin-bottom: 20px;
		}
		.resumen article {
			padding: 18px 20px;
		}
		.cifra {
			font-size: 2rem;
		}
		.invitacion {
			padding: 24px 20px;
		}
	}
</style>
