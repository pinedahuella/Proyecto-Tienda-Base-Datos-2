<script lang="ts">
	/**
	 * Barras verticales apiladas: una columna por grupo (un mes) y en cada una
	 * las partes (los metodos de pago) una encima de otra, con su leyenda. Al
	 * pasar el mouse por una columna se lee cuanto fue cada parte.
	 */
	interface Columna {
		rotulo: string;
		partes: { nombre: string; valor: number }[];
	}
	let {
		columnas,
		texto = (v: number) => v.toLocaleString('es-GT'),
		alto = 220,
		vacio = 'Nada en este periodo'
	}: {
		columnas: Columna[];
		texto?: (v: number) => string;
		alto?: number;
		vacio?: string;
	} = $props();

	const COLORES = ['var(--g1)', 'var(--g2)', 'var(--g3)', 'var(--g5)', 'var(--g6)', 'var(--g4)'];

	let nombres = $derived([...new Set(columnas.flatMap((c) => c.partes.map((p) => p.nombre)))]);
	const total = (c: Columna) => c.partes.reduce((s, p) => s + p.valor, 0);
	let tope = $derived(Math.max(1, ...columnas.map(total)));
	let elegida = $state<number | null>(null);
	const colorDe = (nombre: string) => COLORES[nombres.indexOf(nombre) % COLORES.length];
</script>

{#if columnas.length === 0 || tope <= 1}
	<p class="vacio">{vacio}</p>
{:else}
	<div class="apiladas" style="height: {alto}px">
		{#each columnas as c, i (c.rotulo)}
			<button
				type="button"
				class="columna"
				class:elegida={elegida === i}
				onmouseenter={() => (elegida = i)}
				onmouseleave={() => (elegida = null)}
				onfocus={() => (elegida = i)}
				onblur={() => (elegida = null)}
				aria-label="{c.rotulo}, {texto(total(c))}"
			>
				<span class="pila" style="height: {(total(c) / tope) * 100}%">
					{#each nombres as nombre (nombre)}
						{@const v = c.partes.find((p) => p.nombre === nombre)?.valor ?? 0}
						{#if v > 0}
							<span class="parte" style="flex: {v}; background: {colorDe(nombre)}"></span>
						{/if}
					{/each}
				</span>
				<span class="rotulo">{c.rotulo}</span>
			</button>
		{/each}
	</div>
	<div class="pie">
		<div class="leyenda">
			{#each nombres as nombre (nombre)}
				<span><i style="background: {colorDe(nombre)}"></i>{nombre}</span>
			{/each}
		</div>
		<p class="lectura" aria-live="polite">
			{#if elegida !== null}
				{@const c = columnas[elegida]}
				<strong>{c.rotulo}</strong>, {texto(total(c))} en total.
				{#each c.partes.filter((p) => p.valor > 0) as p (p.nombre)}
					<span class="detalle">{p.nombre} {texto(p.valor)}</span>
				{/each}
			{:else}
				Pasa el mouse por un mes para ver cada metodo
			{/if}
		</p>
	</div>
{/if}

<style>
	.apiladas {
		display: flex;
		align-items: stretch;
		gap: 6px;
		padding-bottom: 20px;
		border-bottom: 1px solid var(--linea);
	}

	.columna {
		position: relative;
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		justify-content: flex-end;
		align-items: center;
		padding: 0;
		background: none;
		border: none;
		cursor: default;
		font: inherit;
	}

	.pila {
		display: flex;
		flex-direction: column-reverse;
		width: min(46px, 70%);
		border-radius: 4px 4px 0 0;
		overflow: hidden;
		transition: opacity var(--t);
	}

	.apiladas:hover .columna:not(.elegida) .pila {
		opacity: 0.55;
	}

	.parte {
		display: block;
		min-height: 2px;
	}

	.rotulo {
		position: absolute;
		bottom: -19px;
		font-size: var(--f-xs);
		color: var(--gris);
		white-space: nowrap;
	}

	.pie {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		gap: 8px 20px;
		margin-top: 30px;
	}

	.leyenda {
		display: flex;
		flex-wrap: wrap;
		gap: 12px;
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.leyenda span {
		display: inline-flex;
		align-items: center;
		gap: 5px;
	}

	.leyenda i {
		width: 10px;
		height: 10px;
		border-radius: 2px;
	}

	.lectura {
		margin: 0;
		font-size: var(--f-sm);
		color: var(--texto);
	}

	.detalle {
		margin-left: 10px;
		color: var(--gris);
	}

	.vacio {
		margin: 0;
		padding: 28px 0;
		text-align: center;
		color: var(--gris);
	}
</style>
