<script lang="ts">
	let { children } = $props();
</script>

{@render children()}

<style>
	:global(:root) {
		/* Indigo: el tinte del comercio textil. El fondo es tela cruda tenida. */
		--tinta: #0d1226;
		--tinta-alta: #141b34;
		--telar: #1d2547;
		--hilo: #2b3563;
		--hilo-claro: #c8d4f0;
		--crudo: #f2efe6;
		--oro: #e0a73e;

		--letra-titulo: 'Bricolage Grotesque', ui-sans-serif, system-ui, sans-serif;
		--letra: 'Instrument Sans', ui-sans-serif, system-ui, sans-serif;
		--letra-dato: 'IBM Plex Mono', ui-monospace, monospace;
	}

	:global(*),
	:global(*::before),
	:global(*::after) {
		box-sizing: border-box;
	}

	:global(html) {
		-webkit-text-size-adjust: 100%;
	}

	:global(body) {
		margin: 0;
		min-height: 100vh;
		overflow-x: hidden;
		background: var(--tinta);
		color: var(--crudo);
		font-family: var(--letra);
		font-size: 15px;
		line-height: 1.55;
		-webkit-font-smoothing: antialiased;
	}

	/* Chrome pinta de blanco los campos que autocompleta y rompe el diseno.
	   El box-shadow interior es el unico modo de forzar el fondo. */
	:global(input:-webkit-autofill),
	:global(input:-webkit-autofill:hover),
	:global(input:-webkit-autofill:focus) {
		-webkit-text-fill-color: var(--crudo);
		-webkit-box-shadow: 0 0 0 1000px var(--tinta) inset;
		caret-color: var(--crudo);
		transition: background-color 9999s ease-out;
	}

	/* El foco tiene que verse: se navega con teclado */
	:global(:focus-visible) {
		outline: 2px solid var(--oro);
		outline-offset: 3px;
		border-radius: 2px;
	}

	:global(::selection) {
		background: var(--oro);
		color: var(--tinta);
	}
</style>
