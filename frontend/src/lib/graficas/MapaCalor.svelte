<script lang="ts">
	/**
	 * El mapa de calor de la semana: un renglon por dia (lunes primero) y una
	 * columna por hora. Cada celda dice cuantos hubo y su color va en cinco
	 * escalones, del vacio al pico, como el panel de metricas de la aerolinea.
	 * Al pasar el mouse por una celda se lee el detalle.
	 */
	interface Celda {
		/** 1 lunes ... 7 domingo. */
		dia: number;
		hora: number;
		valor: number;
		detalle?: string;
	}
	let {
		celdas,
		unidad = ['pedido', 'pedidos'],
		vacio = 'Nada en este periodo'
	}: {
		celdas: Celda[];
		unidad?: [string, string];
		vacio?: string;
	} = $props();

	const DIAS = ['Lunes', 'Martes', 'Miercoles', 'Jueves', 'Viernes', 'Sabado', 'Domingo'];
	const HORAS = Array.from({ length: 24 }, (_, h) => h);
	const NIVELES = ['Sin nada', 'Bajo', 'Medio', 'Alto', 'Pico'];

	let porClave = $derived(new Map(celdas.map((c) => [`${c.dia}-${c.hora}`, c])));
	let pico = $derived(Math.max(0, ...celdas.map((c) => c.valor)));
	let elegida = $state<Celda | null>(null);

	/** El escalon de 0 a 4. */
	function nivel(v: number): number {
		if (v <= 0 || pico === 0) return 0;
		const t = v / pico;
		return t < 0.25 ? 1 : t < 0.5 ? 2 : t < 0.8 ? 3 : 4;
	}
	const palabra = (n: number) => (n === 1 ? unidad[0] : unidad[1]);

	/** Las tres horas con mas, para decirlas con palabras debajo. */
	let mejores = $derived([...celdas].filter((c) => c.valor > 0).sort((a, b) => b.valor - a.valor).slice(0, 3));
</script>

{#if pico === 0}
	<p class="vacio">{vacio}</p>
{:else}
	<div class="mapa" role="table" aria-label="Por dia de la semana y hora">
		<div class="fila cabeza" role="row">
			<span class="dia" role="columnheader"></span>
			{#each HORAS as h (h)}
				<span class="hora" role="columnheader">{h % 3 === 0 ? `${h}h` : ''}</span>
			{/each}
		</div>
		{#each DIAS as nombre, i (nombre)}
			<div class="fila" role="row">
				<span class="dia" role="rowheader">{nombre.slice(0, 3)}</span>
				{#each HORAS as h (h)}
					{@const c = porClave.get(`${i + 1}-${h}`)}
					{@const v = c?.valor ?? 0}
					<button
						type="button"
						class="celda n{nivel(v)}"
						class:elegida={elegida === c && c != null}
						role="cell"
						title="{nombre} a las {h}:00, {v} {palabra(v)}{c?.detalle ? `, ${c.detalle}` : ''}"
						aria-label="{nombre} a las {h}:00, {v} {palabra(v)}"
						onmouseenter={() => (elegida = c ?? null)}
						onfocus={() => (elegida = c ?? null)}
						onclick={() => (elegida = c ?? null)}
					>
						{#if v > 0}<span>{v}</span>{/if}
					</button>
				{/each}
			</div>
		{/each}
	</div>
	<div class="pie">
		<div class="leyenda">
			{#each NIVELES as n, i (n)}
				<span><i class="celda n{i}"></i>{n}</span>
			{/each}
		</div>
		<p class="lectura" aria-live="polite">
			{#if elegida}
				{DIAS[elegida.dia - 1]} a las {elegida.hora}:00, {elegida.valor} {palabra(elegida.valor)}{elegida.detalle
					? `, ${elegida.detalle}`
					: ''}
			{:else if mejores.length > 0}
				Lo mas fuerte es el {DIAS[mejores[0].dia - 1].toLowerCase()} a las {mejores[0].hora}:00{mejores[1]
					? `, despues el ${DIAS[mejores[1].dia - 1].toLowerCase()} a las ${mejores[1].hora}:00`
					: ''}
			{/if}
		</p>
	</div>
{/if}

<style>
	.mapa {
		display: flex;
		flex-direction: column;
		gap: 3px;
		overflow-x: auto;
		padding-bottom: 4px;
	}

	.fila {
		display: grid;
		grid-template-columns: 38px repeat(24, minmax(22px, 1fr));
		gap: 3px;
		min-width: 620px;
	}

	.dia,
	.hora {
		font-size: var(--f-xs);
		color: var(--gris);
		align-self: center;
	}

	.hora {
		text-align: left;
	}

	.celda {
		height: 28px;
		padding: 0;
		display: grid;
		place-items: center;
		font: inherit;
		font-size: 10px;
		font-weight: 600;
		border: 1px solid transparent;
		border-radius: 4px;
		cursor: default;
	}

	.celda:focus-visible,
	.celda.elegida {
		border-color: var(--tinta);
		outline: none;
	}

	/* Cinco escalones del mismo tono, con el texto que se lee encima. */
	.n0 {
		background: color-mix(in srgb, var(--linea) 60%, transparent);
	}
	.n1 {
		background: #fde9b8;
		color: #5a4310;
	}
	.n2 {
		background: #f6c35a;
		color: #4a3508;
	}
	.n3 {
		background: #d98a1c;
		color: #fff;
	}
	.n4 {
		background: #9c4a0c;
		color: #fff;
	}

	.pie {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		align-items: center;
		gap: 8px 20px;
		margin-top: 12px;
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
		display: inline-block;
		width: 14px;
		height: 14px;
	}

	.lectura {
		margin: 0;
		font-size: var(--f-sm);
		color: var(--texto);
	}

	.vacio {
		margin: 0;
		padding: 28px 0;
		text-align: center;
		color: var(--gris);
	}
</style>
