<script lang="ts">
	import { leerTema, aplicarTema, type Tema } from './tema';

	/** Cambia entre el tema claro y el oscuro. */

	let tema = $state<Tema>('claro');

	$effect(() => {
		tema = leerTema();
	});

	function cambiar() {
		tema = tema === 'claro' ? 'oscuro' : 'claro';
		aplicarTema(tema);
	}
</script>

<button
	type="button"
	onclick={cambiar}
	aria-label={tema === 'claro' ? 'Cambiar a tema oscuro' : 'Cambiar a tema claro'}
	title={tema === 'claro' ? 'Tema oscuro' : 'Tema claro'}
>
	{#if tema === 'claro'}
		<!-- luna -->
		<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true">
			<path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5Z" stroke-linejoin="round" />
		</svg>
	{:else}
		<!-- sol -->
		<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true">
			<circle cx="12" cy="12" r="4.2" />
			<path
				d="M12 2.4v2.2M12 19.4v2.2M2.4 12h2.2M19.4 12h2.2M5.2 5.2l1.6 1.6M17.2 17.2l1.6 1.6M18.8 5.2l-1.6 1.6M6.8 17.2l-1.6 1.6"
				stroke-linecap="round"
			/>
		</svg>
	{/if}
</button>

<style>
	button {
		width: 38px;
		height: 38px;
		display: grid;
		place-items: center;
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		color: var(--tinta);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	button:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	svg {
		width: 19px;
		height: 19px;
	}
</style>
