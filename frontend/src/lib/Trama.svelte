<script lang="ts">
	/**
	 * La trama: un tejido de ligamento tafetan, en SVG y repetido como patron.
	 *
	 * Cada hilo se corta en los cruces donde pasa por debajo. Ese damero de
	 * cortes es lo que lo hace verse tejido y no una rejilla de papel
	 * milimetrado. El azulejo mide 24 y los cortes no tocan sus bordes, asi que
	 * se repite sin costura.
	 *
	 * Va fija detras de todo el sitio: es el fondo de la marca.
	 */
</script>

<svg class="trama" aria-hidden="true">
	<defs>
		<pattern id="tejido" width="24" height="24" patternUnits="userSpaceOnUse">
			<g stroke="var(--hilo)" stroke-width="1" fill="none" stroke-linecap="round">
				<!-- urdimbre -->
				<path d="M6 0 V15 M6 21 V24" />
				<path d="M18 0 V3 M18 9 V24" />
				<!-- trama -->
				<path d="M0 6 H3 M9 6 H24" />
				<path d="M0 18 H15 M21 18 H24" />
			</g>
		</pattern>
	</defs>

	<rect width="100%" height="100%" fill="url(#tejido)" />
</svg>

<style>
	.trama {
		position: fixed;
		inset: 0;
		width: 100%;
		height: 100%;
		z-index: 0;
		pointer-events: none;
	}
</style>
