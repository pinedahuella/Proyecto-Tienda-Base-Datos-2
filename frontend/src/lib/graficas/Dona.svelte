<script lang="ts">
	/**
	 * Una dona con su leyenda: como se reparte un total entre pocas partes
	 * (los pedidos por estado, los pagos por metodo). SVG a mano, sin
	 * libreria: cada parte es el mismo circulo con un trazo que mide su
	 * porcentaje (pathLength 100), corrido donde termina la anterior.
	 *
	 * `texto` es como se escribe el valor en la leyenda (el dinero llega ya
	 * formateado); si no viene, se escribe el numero. Pasar el mouse por una
	 * parte o por su fila de la leyenda resalta las dos.
	 */
	interface Parte {
		nombre: string;
		valor: number;
		texto?: string;
		color?: string;
	}

	let {
		partes,
		centro = null,
		tamano = 168,
		vacio = 'Todavia no hay datos'
	}: {
		partes: Parte[];
		centro?: { cifra: string; rotulo: string } | null;
		tamano?: number;
		vacio?: string;
	} = $props();

	const COLORES = ['var(--g1)', 'var(--g2)', 'var(--g3)', 'var(--g4)', 'var(--g5)', 'var(--g6)'];

	let resaltada = $state<number | null>(null);

	let total = $derived(partes.reduce((s, p) => s + (p.valor > 0 ? p.valor : 0), 0));

	/** Cada parte con su color, su porcentaje y donde empieza. */
	let trozos = $derived.by(() => {
		let inicio = 0;
		return partes.map((p, i) => {
			const pct = total > 0 ? (Math.max(p.valor, 0) / total) * 100 : 0;
			const t = { ...p, i, color: p.color ?? COLORES[i % COLORES.length], pct, inicio };
			inicio += pct;
			return t;
		});
	});

	function porcentaje(pct: number): string {
		if (pct === 0) return '0 %';
		if (pct < 1) return 'menos de 1 %';
		return `${Math.round(pct)} %`;
	}
</script>

<div class="dona">
	<div class="circulo" style="width: {tamano}px; height: {tamano}px">
		<svg viewBox="0 0 100 100" role="img" aria-label={partes.map((p) => `${p.nombre} ${p.texto ?? p.valor}`).join(', ')}>
			<circle class="pista" cx="50" cy="50" r="40" pathLength="100" />
			{#each trozos as t (t.i)}
				{#if t.pct > 0}
					<circle
						class="parte"
						class:apagada={resaltada !== null && resaltada !== t.i}
						cx="50"
						cy="50"
						r="40"
						pathLength="100"
						stroke={t.color}
						stroke-dasharray="{Math.max(t.pct - (trozos.filter((x) => x.pct > 0).length > 1 ? 0.8 : 0), 0.4)} {100}"
						stroke-dashoffset={-t.inicio}
						role="presentation"
						onmouseenter={() => (resaltada = t.i)}
						onmouseleave={() => (resaltada = null)}
					>
						<title>{t.nombre}: {t.texto ?? t.valor} ({porcentaje(t.pct)})</title>
					</circle>
				{/if}
			{/each}
		</svg>
		<div class="centro">
			{#if total === 0}
				<span class="rotulo">{vacio}</span>
			{:else if resaltada !== null}
				<span class="cifra">{porcentaje(trozos[resaltada].pct)}</span>
				<span class="rotulo">{trozos[resaltada].nombre}</span>
			{:else if centro}
				<span class="cifra" class:larga={centro.cifra.length > 7} class:muy-larga={centro.cifra.length > 11}>{centro.cifra}</span>
				<span class="rotulo">{centro.rotulo}</span>
			{/if}
		</div>
	</div>

	<ul class="leyenda">
		{#each trozos as t (t.i)}
			<li
				class:apagada={resaltada !== null && resaltada !== t.i}
				class:cero={t.valor <= 0}
				onmouseenter={() => (resaltada = t.pct > 0 ? t.i : null)}
				onmouseleave={() => (resaltada = null)}
			>
				<span class="punto" style="background: {t.color}"></span>
				<span class="nombre">{t.nombre}</span>
				<span class="valor">{t.texto ?? t.valor}</span>
				<span class="pct">{porcentaje(t.pct)}</span>
			</li>
		{/each}
	</ul>
</div>

<style>
	.dona {
		display: flex;
		align-items: center;
		gap: var(--e5);
		flex-wrap: wrap;
	}

	.circulo {
		position: relative;
		flex-shrink: 0;
	}

	svg {
		width: 100%;
		height: 100%;
		transform: rotate(-90deg);
		overflow: visible;
	}

	circle {
		fill: none;
		stroke-width: 13;
	}

	.pista {
		stroke: var(--panel);
	}

	.parte {
		transition:
			opacity var(--t),
			stroke-width var(--t);
		cursor: default;
		animation: entra 0.7s ease-out both;
	}

	.parte:hover {
		stroke-width: 15;
	}

	.apagada {
		opacity: 0.35;
	}

	@keyframes entra {
		from {
			stroke-dasharray: 0 100;
		}
	}

	.centro {
		position: absolute;
		inset: 22%;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		text-align: center;
		pointer-events: none;
	}

	.cifra {
		font-size: var(--f-lg);
		font-weight: 600;
		color: var(--tinta);
		font-variant-numeric: tabular-nums;
		line-height: 1.15;
	}

	/* Una cifra larga (dinero) se achica para quedarse dentro del anillo. */
	.cifra.larga {
		font-size: var(--f-base);
	}

	.cifra.muy-larga {
		font-size: var(--f-sm);
	}

	.rotulo {
		font-size: var(--f-xs);
		color: var(--gris);
		line-height: 1.2;
	}

	.leyenda {
		list-style: none;
		flex: 1;
		min-width: 190px;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.leyenda li {
		display: grid;
		grid-template-columns: 10px 1fr auto auto;
		align-items: center;
		gap: var(--e2);
		padding: 5px 8px;
		font-size: var(--f-ms);
		border-radius: var(--r);
		transition:
			opacity var(--t),
			background var(--t);
	}

	.leyenda li:hover {
		background: var(--panel);
	}

	.leyenda li.cero {
		color: var(--gris-2);
	}

	.punto {
		width: 10px;
		height: 10px;
		border-radius: 50%;
	}

	.nombre {
		color: var(--tinta);
	}

	.cero .nombre {
		color: var(--gris-2);
	}

	.valor {
		font-weight: 500;
		color: var(--tinta);
		font-variant-numeric: tabular-nums;
		text-align: right;
	}

	.pct {
		min-width: 44px;
		font-size: var(--f-sm);
		color: var(--gris);
		text-align: right;
		font-variant-numeric: tabular-nums;
	}
</style>
