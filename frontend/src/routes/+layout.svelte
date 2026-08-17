<script lang="ts">
	import Trama from '$lib/Trama.svelte';

	let { children } = $props();
</script>

<!-- La trama va fija detras de todo: es el fondo de la marca -->
<Trama />

<!-- Columna: cabecera, contenido que crece, y pie siempre hasta abajo -->
<div class="sitio">
	{@render children()}
</div>

<style>
	/* ══════════════════════════════════════════════════════════
	   MESH

	   Fondo claro con la trama azul de la marca, tinta calida (no
	   negro puro), titulares grandes en peso ligero, cuerpo de 16px.
	   El indigo es el tinte del comercio textil desde hace siglos, y
	   Mesh es un tejido: de ahi sale toda la paleta.
	   ══════════════════════════════════════════════════════════ */

	:global(:root) {
		--tinta: #16181f;
		--texto: #3a3e49;
		/* Los grises estan medidos contra el fondo, no elegidos a ojo: con los
		   anteriores el texto secundario quedaba en 2.7 de contraste y se perdia.
		   El minimo legible es 4.5. */
		--gris: #545965;
		--gris-2: #676c78;
		--linea: #e3e1dc;
		--panel: #f5f3ef;
		--off: #faf9f6;
		--blanco: #ffffff;

		--indigo: #2f3a8f;
		--indigo-os: #242d72;
		--indigo-cl: #e8ebf7;

		--rojo: #b3352c;

		/* La trama va apenas por encima del fondo. Si se sube mas, los hilos
		   cruzan por detras de las letras y el texto se vuelve dificil de leer. */
		--hilo: #e6eaf6;

		--ancho: 1185px;
		--r: 6px;
		--r2: 10px;
		--t: 0.18s ease;
	}

	/* Tema oscuro. Los nombres significan lo mismo: --tinta es siempre el texto
	   principal y --blanco la superficie de las tarjetas. Asi ningun componente
	   necesita saber en que tema esta. */
	:global(html[data-tema='oscuro']) {
		--tinta: #edeff7;
		--texto: #bcc2d2;
		--gris: #a6adc0;
		--gris-2: #949bb0;
		--linea: #262c45;
		--panel: #161b31;
		--off: #0f1428;
		--blanco: #141a33;

		--indigo: #8a9ae4;
		--indigo-os: #a3b0ec;
		--indigo-cl: #1c2447;

		--rojo: #e08b81;

		--hilo: #191f3a;
	}

	:global(*),
	:global(*::before),
	:global(*::after) {
		box-sizing: border-box;
		margin: 0;
		padding: 0;
	}

	:global(body) {
		font-family:
			'Segoe UI', system-ui, -apple-system, Roboto, 'Helvetica Neue', Arial, sans-serif;
		font-size: 16px;
		line-height: 1.5;
		color: var(--texto);
		background: var(--off);
		-webkit-font-smoothing: antialiased;
		/* La trama es fija y mide 100% del ancho: sin esto, cuando aparece la
		   barra de desplazamiento vertical se cuela un desplazamiento lateral. */
		overflow-x: hidden;
	}

	/* El pie queda hasta abajo aunque la pagina tenga poco contenido */
	.sitio {
		position: relative;
		z-index: 1;
		display: flex;
		flex-direction: column;
		min-height: 100vh;
	}

	:global(.sitio > main) {
		flex: 1;
	}

	/* Titulares grandes en peso 400: eso es lo que da el aire */
	:global(h1),
	:global(h2),
	:global(h3),
	:global(h4) {
		font-weight: 400;
		color: var(--tinta);
		letter-spacing: 0;
	}
	:global(h1) {
		font-size: clamp(2rem, 3.4vw, 2.75rem);
		line-height: 1.15;
	}
	:global(h2) {
		font-size: clamp(1.4rem, 2.2vw, 1.85rem);
		line-height: 1.2;
	}
	:global(h3) {
		font-size: 1.15rem;
		line-height: 1.4;
		font-weight: 500;
	}

	:global(a) {
		color: inherit;
	}

	:global(img),
	:global(svg) {
		max-width: 100%;
		display: block;
	}

	:global(:focus-visible) {
		outline: 2px solid var(--indigo);
		outline-offset: 3px;
	}

	/* Contenedor unico de todo el sitio */
	:global(.env) {
		width: 100%;
		max-width: var(--ancho);
		margin: 0 auto;
		padding: 0 24px;
	}

	@media (max-width: 620px) {
		:global(.env) {
			padding: 0 16px;
		}
	}

	/* Chrome pinta de blanco los campos que autocompleta; se fija el color del
	   texto para que no cambie de tono. */
	:global(input:-webkit-autofill) {
		-webkit-text-fill-color: var(--tinta);
		-webkit-box-shadow: 0 0 0 1000px var(--blanco) inset;
	}
</style>
