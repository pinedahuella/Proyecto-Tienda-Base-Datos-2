<script lang="ts">
	/**
	 * La foto de un resultado del buscador. Llega en el mismo documento de
	 * Elasticsearch que el nombre y el precio (desde el 2026-10-23), asi que la
	 * tarjeta sale entera de una sola consulta.
	 *
	 * Sin foto, o si el enlace no carga, queda el cuadro vacio del mismo tamano:
	 * una lista donde unas filas tienen foto y otras no, sin el hueco, deja los
	 * nombres desalineados.
	 *
	 *   mini    el cuadrito de las listas (por defecto 56 px de lado)
	 *   ancha   arriba de una tarjeta, a todo lo ancho
	 */
	let {
		src,
		tipo = 'mini',
		tam = 56
	}: { src: string | null | undefined; tipo?: 'mini' | 'ancha'; tam?: number } = $props();

	let rota = $state(false);
</script>

<span class="foto {tipo}" style="--tam: {tam}px" aria-hidden="true">
	{#if src && !rota}
		<img {src} alt="" loading="lazy" onerror={() => (rota = true)} />
	{/if}
</span>

<style>
	.foto {
		display: block;
		flex: none;
		overflow: hidden;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.mini {
		width: var(--tam);
		height: var(--tam);
	}

	.ancha {
		width: 100%;
		aspect-ratio: 4 / 3;
	}

	img {
		display: block;
		width: 100%;
		height: 100%;
		object-fit: cover;
	}
</style>
