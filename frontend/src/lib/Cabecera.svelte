<script lang="ts">
	import MarcaMesh from './MarcaMesh.svelte';
	import BotonTema from './BotonTema.svelte';

	/**
	 * Cabecera del sitio. Se queda pegada arriba al bajar.
	 *
	 * Lleva el logotipo, que siempre vuelve al catalogo. Cuando hay sesion
	 * aparecen el correo y el boton de salir; cuando no la hay, el enlace para
	 * entrar. No hay menu porque todavia no existen mas paginas.
	 */
	let {
		sesion = null,
		alSalir
	}: { sesion?: string | null; alSalir?: () => void } = $props();
</script>

<header>
	<div class="env barra">
		<MarcaMesh href="/" />

		<div class="cuenta">
			{#if sesion}
				<span class="correo">{sesion}</span>
				<button type="button" class="salir" onclick={alSalir}>Salir</button>
			{:else}
				<a class="salir" href="/entrar">Iniciar sesion</a>
			{/if}
			<BotonTema />
		</div>
	</div>
</header>

<style>
	header {
		position: sticky;
		top: 0;
		z-index: 90;
		background: var(--blanco);
		border-bottom: 1px solid var(--linea);
	}

	.barra {
		display: flex;
		align-items: center;
		gap: 1.5rem;
		height: 68px;
	}

	.cuenta {
		margin-left: auto;
		display: flex;
		align-items: center;
		gap: 1rem;
	}

	.correo {
		font-size: 0.92rem;
		color: var(--gris);
	}

	.salir {
		display: inline-block;
		text-decoration: none;
		padding: 8px 16px;
		font-family: inherit;
		font-size: 0.95rem;
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.salir:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	/* En telefono se esconde el correo: no cabe junto al logo y los botones */
	@media (max-width: 620px) {
		.correo {
			display: none;
		}
		.barra {
			height: 60px;
			gap: 0.75rem;
		}
		.cuenta {
			gap: 0.6rem;
		}
		.salir {
			padding: 7px 12px;
			font-size: 0.9rem;
		}
	}
</style>
