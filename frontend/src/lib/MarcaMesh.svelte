<script lang="ts">
	/**
	 * Logotipo de Mesh.
	 *
	 * El simbolo es un tejido de tres por tres: la urdimbre corre entera y la
	 * trama se corta en los cruces donde pasa por debajo. Esos cortes en
	 * damero son lo que lo hace leerse como tela y no como una rejilla.
	 */
	let { href = '/', tamano = 30 }: { href?: string; tamano?: number } = $props();
</script>

<a class="marca" {href} aria-label="Mesh, inicio">
	<svg
		width={tamano}
		height={tamano}
		viewBox="0 0 32 32"
		fill="none"
		stroke="currentColor"
		stroke-width="2.6"
		stroke-linecap="round"
		aria-hidden="true"
	>
		<!-- urdimbre: los tres hilos verticales, enteros -->
		<path d="M9 4 V28" />
		<path d="M16 4 V28" />
		<path d="M23 4 V28" />

		<!-- trama: tres hilos horizontales, cortados donde pasan por debajo -->
		<path d="M4 9 H6 M12 9 H20 M26 9 H28" />
		<path d="M4 16 H13 M19 16 H28" />
		<path d="M4 23 H6 M12 23 H20 M26 23 H28" />
	</svg>
	<span class="nombre">Mesh</span>
</a>

<style>
	.marca {
		display: inline-flex;
		align-items: center;
		gap: var(--e2);
		text-decoration: none;
		flex-shrink: 0;
		color: var(--indigo);
	}

	.nombre {
		font-size: var(--f-xl);
		font-weight: 600;
		letter-spacing: -0.02em;
		color: var(--tinta);
	}
</style>
