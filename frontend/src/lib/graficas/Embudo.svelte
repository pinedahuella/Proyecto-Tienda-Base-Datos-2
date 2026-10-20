<script lang="ts">
	/**
	 * Un embudo: cada etapa es una barra entera con su borde, y el color la llena
	 * desde la izquierda en la parte que le toca contra la primera. Asi se ve
	 * cuanto llena aunque sea poco (Meme, 2026-10-20: sin el borde el texto
	 * parecia flotar). El numero y el nombre van arriba de la barra, y a la
	 * derecha cuantos de cada cien pasaron desde la etapa anterior. Una etapa
	 * sin dato (null) sale vacia con su aviso y no corta las demas.
	 */
	interface Etapa {
		nombre: string;
		valor: number | null;
		color?: string;
	}
	let { etapas }: { etapas: Etapa[] } = $props();

	const COLORES = ['var(--g1)', 'var(--g5)', 'var(--g3)', 'var(--g4)'];
	let tope = $derived(Math.max(1, ...etapas.map((e) => e.valor ?? 0)));

	/** Cuantos de cada cien de la etapa anterior con dato. */
	function paso(i: number): string | null {
		const actual = etapas[i].valor;
		const antes = etapas
			.slice(0, i)
			.reverse()
			.find((e) => e.valor != null)?.valor;
		if (actual == null || antes == null || antes === 0) return null;
		const pct = (actual / antes) * 100;
		return pct > 100
			? `${(actual / antes).toFixed(1)} veces el paso anterior`
			: `${pct.toFixed(pct < 10 ? 1 : 0)} de cada 100 del paso anterior`;
	}
</script>

<ol class="embudo">
	{#each etapas as e, i (e.nombre)}
		<li>
			<div class="rotulos">
				<span><strong>{e.valor == null ? 'Sin dato' : e.valor.toLocaleString('es-GT')}</strong> {e.nombre}</span>
				{#if i > 0 && paso(i)}<span class="paso">{paso(i)}</span>{/if}
			</div>
			<div class="pista" role="presentation">
				{#if e.valor != null && e.valor > 0}
					<span
						class="relleno"
						style="width: {Math.max(1.5, (e.valor / tope) * 100)}%; background: {e.color ?? COLORES[i % COLORES.length]}"
					></span>
				{/if}
			</div>
		</li>
	{/each}
</ol>

<style>
	.embudo {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	li {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	.rotulos {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		align-items: baseline;
		gap: 4px 12px;
		font-size: var(--f-sm);
		color: var(--texto);
	}

	.rotulos strong {
		font-size: var(--f-base);
		color: var(--tinta);
	}

	.paso {
		font-size: var(--f-xs);
		color: var(--gris);
	}

	/* La barra entera, con borde oscuro: lo vacio tambien se ve. */
	.pista {
		height: 18px;
		padding: 2px;
		border: 1px solid var(--tinta);
		border-radius: 5px;
		background: var(--blanco);
	}

	.relleno {
		display: block;
		height: 100%;
		border-radius: 3px;
		transition: width 0.5s ease;
	}
</style>
