<script lang="ts">
	/**
	 * Una serie en el tiempo: linea con su area debajo, la cuadricula con la
	 * escala a la izquierda y las fechas abajo. Al pasar el mouse (o el dedo)
	 * marca el punto mas cercano y dice su valor. SVG a mano, como Dona y Barras.
	 *
	 * `texto` escribe un valor como se lee (el dinero con Q); `fecha` escribe
	 * el rotulo de cada punto.
	 */
	interface Punto {
		rotulo: string;
		valor: number;
		/** Lo que se lee al pasar el mouse, si no es solo el valor. */
		detalle?: string;
	}
	let {
		puntos,
		color = 'var(--g1)',
		texto = (v: number) => v.toLocaleString('es-GT'),
		alto = 220,
		vacio = 'Nada en este periodo'
	}: {
		puntos: Punto[];
		color?: string;
		texto?: (v: number) => string;
		alto?: number;
		vacio?: string;
	} = $props();

	const ANCHO = 760;
	const IZQ = 64;
	const ABAJO = 26;
	const ARRIBA = 12;

	let marcado = $state<number | null>(null);

	let tope = $derived.by(() => {
		const max = Math.max(0, ...puntos.map((p) => p.valor));
		if (max === 0) return 1;
		// Un tope redondo: 1, 2 o 5 por una potencia de 10.
		const potencia = 10 ** Math.floor(Math.log10(max));
		const paso = [1, 2, 5, 10].find((m) => m * potencia >= max) ?? 10;
		return paso * potencia;
	});
	let paso = $derived(puntos.length > 1 ? (ANCHO - IZQ - 8) / (puntos.length - 1) : 0);
	const x = (i: number) => IZQ + i * paso;
	const y = (v: number) => ARRIBA + (alto - ARRIBA - ABAJO) * (1 - v / tope);

	let camino = $derived(puntos.map((p, i) => `${i === 0 ? 'M' : 'L'}${x(i).toFixed(1)},${y(p.valor).toFixed(1)}`).join(' '));
	let area = $derived(
		puntos.length === 0 ? '' : `${camino} L${x(puntos.length - 1).toFixed(1)},${y(0)} L${x(0).toFixed(1)},${y(0)} Z`
	);
	/** Cada cuantos puntos se escribe la fecha, para que no se encimen. */
	let cadaCuanto = $derived(Math.max(1, Math.ceil(puntos.length / 9)));
	const id = `linea-${Math.random().toString(36).slice(2, 8)}`;

	function alMover(e: PointerEvent) {
		const svg = e.currentTarget as SVGSVGElement;
		const caja = svg.getBoundingClientRect();
		const enSvg = ((e.clientX - caja.left) / caja.width) * ANCHO;
		if (puntos.length === 0) return;
		const i = paso === 0 ? 0 : Math.round((enSvg - IZQ) / paso);
		marcado = Math.max(0, Math.min(puntos.length - 1, i));
	}
</script>

{#if puntos.length === 0 || puntos.every((p) => p.valor === 0)}
	<p class="vacio">{vacio}</p>
{:else}
	<div class="linea">
		<svg
			viewBox="0 0 {ANCHO} {alto}"
			role="img"
			aria-label="Grafica en el tiempo"
			onpointermove={alMover}
			onpointerleave={() => (marcado = null)}
		>
			<defs>
				<linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
					<stop offset="0%" stop-color={color} stop-opacity="0.28" />
					<stop offset="100%" stop-color={color} stop-opacity="0.02" />
				</linearGradient>
			</defs>
			{#each [0, 0.25, 0.5, 0.75, 1] as parte (parte)}
				<line class="guia" x1={IZQ} x2={ANCHO - 4} y1={y(tope * parte)} y2={y(tope * parte)} />
				<text class="escala" x={IZQ - 8} y={y(tope * parte) + 4} text-anchor="end">{texto(tope * parte)}</text>
			{/each}
			<path d={area} fill="url(#{id})" />
			<path d={camino} fill="none" stroke={color} stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round" />
			{#each puntos as p, i (i)}
				{#if i % cadaCuanto === 0}
					<text class="fecha" x={x(i)} y={alto - 6} text-anchor="middle">{p.rotulo}</text>
				{/if}
			{/each}
			{#if marcado !== null}
				{@const p = puntos[marcado]}
				<line class="cursor" x1={x(marcado)} x2={x(marcado)} y1={ARRIBA} y2={y(0)} />
				<circle cx={x(marcado)} cy={y(p.valor)} r="4.5" fill={color} stroke="var(--blanco)" stroke-width="2" />
			{/if}
		</svg>
		{#if marcado !== null}
			{@const p = puntos[marcado]}
			<div
				class="lectura"
				style="left: {(x(marcado) / ANCHO) * 100}%"
				class:a-la-izquierda={x(marcado) > ANCHO * 0.7}
			>
				<span class="cuando">{p.rotulo}</span>
				<strong>{texto(p.valor)}</strong>
				{#if p.detalle}<span class="mas">{p.detalle}</span>{/if}
			</div>
		{/if}
	</div>
{/if}

<style>
	.linea {
		position: relative;
	}

	svg {
		display: block;
		width: 100%;
		height: auto;
		touch-action: pan-y;
	}

	.guia {
		stroke: var(--linea);
		stroke-width: 1;
	}

	.escala,
	.fecha {
		font-size: 11px;
		fill: var(--gris);
	}

	.cursor {
		stroke: var(--gris-2);
		stroke-width: 1;
		stroke-dasharray: 3 3;
	}

	.lectura {
		position: absolute;
		top: 4px;
		transform: translateX(10px);
		display: flex;
		flex-direction: column;
		gap: 1px;
		padding: 6px 10px;
		font-size: var(--f-sm);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		box-shadow: var(--sombra);
		pointer-events: none;
		white-space: nowrap;
	}

	.lectura.a-la-izquierda {
		transform: translateX(calc(-100% - 10px));
	}

	.cuando,
	.mas {
		color: var(--gris);
		font-size: var(--f-xs);
	}

	.vacio {
		margin: 0;
		padding: 28px 0;
		text-align: center;
		color: var(--gris);
	}
</style>
