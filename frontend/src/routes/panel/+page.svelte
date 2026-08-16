<script lang="ts">
	import { goto } from '$app/navigation';
	import Telar from '$lib/Telar.svelte';
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
	let inicial = $derived(nombre ? nombre.charAt(0) : '');

	function salir() {
		cerrarSesion();
		goto('/');
	}

	const secciones = [
		{ rotulo: 'Pedidos', vacio: 'Aun no hay pedidos.' },
		{ rotulo: 'Productos', vacio: 'Todavia no has publicado nada.' },
		{ rotulo: 'Inventario', vacio: 'Sin movimientos registrados.' }
	];
</script>

<svelte:head>
	<title>Mesh · Panel</title>
</svelte:head>

<Telar densidad={44} />

{#if correo}
	<div class="lienzo">
		<header>
			<a class="marca" href="/panel">
				Mesh<span class="punto"></span>
			</a>

			<div class="cuenta">
				<span class="ficha" aria-hidden="true">{inicial}</span>
				<span class="correo">{correo}</span>
				<button type="button" onclick={salir}>Salir</button>
			</div>
		</header>

		<main>
			<div class="saludo">
				<p class="antetitulo">Tu tienda</p>
				<h1>Hola, {nombre}</h1>
				<p class="entrada">
					Tu tienda esta lista. Publica tu primer producto para que aparezca en el catalogo.
				</p>
			</div>

			<div class="rejilla">
				{#each secciones as seccion}
					<article>
						<h2>{seccion.rotulo}</h2>
						<p class="cifra">0</p>
						<p class="vacio">{seccion.vacio}</p>
					</article>
				{/each}
			</div>

			<section class="invitacion">
				<div>
					<h2>Empieza por un producto</h2>
					<p>
						Ponle nombre, precio y una foto. Cuando lo publiques, tus pedidos y tu inventario
						empiezan a llenarse solos.
					</p>
				</div>
				<button type="button" class="publicar">Publicar producto</button>
			</section>
		</main>
	</div>
{/if}

<style>
	.lienzo {
		position: relative;
		z-index: 1;
		min-height: 100vh;
		display: flex;
		flex-direction: column;
	}

	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 20px;
		padding: 18px 30px;
		border-bottom: 1px solid var(--telar);
		background: rgba(13, 18, 38, 0.86);
		backdrop-filter: blur(8px);
	}

	.marca {
		font-family: var(--letra-titulo);
		font-weight: 700;
		font-size: 19px;
		letter-spacing: -0.03em;
		color: var(--crudo);
		text-decoration: none;
		display: inline-flex;
		align-items: baseline;
		gap: 4px;
	}

	.punto {
		width: 5px;
		height: 5px;
		border-radius: 50%;
		background: var(--oro);
	}

	.cuenta {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	.ficha {
		width: 27px;
		height: 27px;
		display: grid;
		place-items: center;
		border-radius: 50%;
		background: var(--oro);
		color: var(--tinta);
		font-family: var(--letra-titulo);
		font-weight: 700;
		font-size: 13px;
	}

	.correo {
		font-family: var(--letra-dato);
		font-size: 11.5px;
		color: #8e9ac4;
	}

	.cuenta button {
		background: none;
		border: 1px solid var(--telar);
		border-radius: 3px;
		padding: 6px 12px;
		font-family: var(--letra-dato);
		font-size: 10px;
		letter-spacing: 0.16em;
		text-transform: uppercase;
		color: #8e9ac4;
		cursor: pointer;
		transition:
			color 0.16s ease,
			border-color 0.16s ease;
	}

	.cuenta button:hover {
		color: var(--oro);
		border-color: var(--oro);
	}

	main {
		flex: 1;
		width: 100%;
		max-width: 960px;
		margin: 0 auto;
		padding: 58px 30px 70px;
	}

	.saludo {
		max-width: 520px;
		margin-bottom: 44px;
		animation: subir 0.7s 0.9s both cubic-bezier(0.2, 0.7, 0.3, 1);
	}

	.antetitulo {
		margin: 0 0 10px;
		font-family: var(--letra-dato);
		font-size: 10px;
		letter-spacing: 0.24em;
		text-transform: uppercase;
		color: #6f7cad;
	}

	h1 {
		margin: 0 0 12px;
		font-family: var(--letra-titulo);
		font-weight: 600;
		font-size: clamp(32px, 6vw, 44px);
		line-height: 1.04;
		letter-spacing: -0.04em;
		color: var(--crudo);
	}

	.entrada {
		margin: 0;
		color: #97a3ca;
		font-size: 15px;
	}

	.rejilla {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
		gap: 1px;
		background: var(--telar);
		border: 1px solid var(--telar);
		margin-bottom: 30px;
		animation: subir 0.7s 1.02s both cubic-bezier(0.2, 0.7, 0.3, 1);
	}

	.rejilla article {
		padding: 24px 22px 22px;
		background: var(--tinta-alta);
	}

	.rejilla h2 {
		margin: 0 0 14px;
		font-family: var(--letra-dato);
		font-size: 10px;
		font-weight: 500;
		letter-spacing: 0.2em;
		text-transform: uppercase;
		color: #8e9ac4;
	}

	.cifra {
		margin: 0 0 6px;
		font-family: var(--letra-titulo);
		font-weight: 500;
		font-size: 42px;
		line-height: 1;
		letter-spacing: -0.045em;
		color: #3d4a80;
	}

	.vacio {
		margin: 0;
		font-size: 13px;
		color: #6f7cad;
	}

	.invitacion {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 28px;
		flex-wrap: wrap;
		padding: 26px 26px 26px 28px;
		background: var(--tinta-alta);
		border: 1px solid var(--telar);
		position: relative;
		animation: subir 0.7s 1.14s both cubic-bezier(0.2, 0.7, 0.3, 1);
	}

	/* El hilo dorado otra vez, esta vez como remate lateral */
	.invitacion::before {
		content: '';
		position: absolute;
		left: -1px;
		top: 26px;
		bottom: 26px;
		width: 2px;
		background: var(--oro);
	}

	.invitacion h2 {
		margin: 0 0 6px;
		font-family: var(--letra-titulo);
		font-weight: 600;
		font-size: 19px;
		letter-spacing: -0.02em;
		color: var(--crudo);
	}

	.invitacion p {
		margin: 0;
		max-width: 460px;
		font-size: 14px;
		color: #97a3ca;
	}

	.publicar {
		padding: 12px 20px;
		font-family: var(--letra);
		font-size: 14px;
		font-weight: 600;
		color: var(--tinta);
		background: var(--oro);
		border: none;
		border-radius: 3px;
		cursor: pointer;
		white-space: nowrap;
		transition:
			transform 0.16s cubic-bezier(0.2, 0.7, 0.3, 1),
			background 0.16s ease;
	}

	.publicar:hover {
		background: #f0bc57;
		transform: translateY(-1px);
	}

	@keyframes subir {
		from {
			opacity: 0;
			transform: translateY(14px);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	@media (max-width: 620px) {
		header {
			padding: 14px 18px;
		}
		.correo {
			display: none;
		}
		main {
			padding: 40px 18px 54px;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.saludo,
		.rejilla,
		.invitacion {
			animation: none;
		}
		.publicar:hover {
			transform: none;
		}
	}
</style>
