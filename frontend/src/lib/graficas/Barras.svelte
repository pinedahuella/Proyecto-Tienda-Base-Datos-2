<script lang="ts">
	/**
	 * Un ranking en barras: el puesto, el nombre (con enlace si lo tiene), la
	 * cifra a la derecha y la barra debajo, medida contra el primero.
	 *
	 * Con `antes` en las filas se compara contra el periodo anterior: la barra
	 * de atras, mas clara, es lo de antes y la de adelante lo de ahora, y al
	 * lado sale cuanto crecio. Las barras entran creciendo desde cero.
	 */
	interface Fila {
		id: string;
		nombre: string;
		valor: number;
		antes?: number | null;
		texto?: string;
		detalle?: string | null;
		enlace?: string | null;
	}

	let {
		filas,
		color = 'var(--g1)',
		unidad = '',
		compacta = false,
		columnas = 1,
		vacio = 'Todavia no hay nada que mostrar'
	}: {
		filas: Fila[];
		color?: string;
		unidad?: string;
		compacta?: boolean;
		/** En una tarjeta ancha, el ranking repartido en columnas. */
		columnas?: number;
		vacio?: string;
	} = $props();

	let tope = $derived(Math.max(1, ...filas.map((f) => Math.max(f.valor, f.antes ?? 0))));

	function ancho(v: number): number {
		return Math.max(0, Math.round((v / tope) * 1000) / 10);
	}

	/** "3 veces mas", "nuevo" o "bajo a la mitad", para la comparacion. */
	function cambio(f: Fila): { texto: string; sube: boolean } | null {
		if (f.antes == null) return null;
		if (f.antes === 0) return f.valor > 0 ? { texto: 'nuevo', sube: true } : null;
		const r = f.valor / f.antes;
		if (r >= 1.05) return { texto: r >= 10 ? `${Math.round(r)} veces mas` : `${r.toFixed(1)} veces mas`, sube: true };
		if (r <= 0.95) return { texto: `${Math.round((1 - r) * 100)} % menos`, sube: false };
		return { texto: 'igual', sube: true };
	}
</script>

{#if filas.length === 0}
	<p class="vacio">{vacio}</p>
{:else}
	<ol class="barras" class:compacta class:en-columnas={columnas > 1} style="--columnas: {columnas}">
		{#each filas as f, i (f.id)}
			{@const c = cambio(f)}
			<li style="--color: {color}; --retraso: {i * 45}ms">
				<div class="cabeza">
					<span class="puesto">{i + 1}</span>
					{#if f.enlace}
						<a class="nombre" href={f.enlace} title={f.nombre}>{f.nombre}</a>
					{:else}
						<span class="nombre" title={f.nombre}>{f.nombre}</span>
					{/if}
					{#if f.detalle}<span class="detalle">{f.detalle}</span>{/if}
					<span class="cifra">
						{f.texto ?? f.valor}
						{#if unidad}<small>{unidad}</small>{/if}
					</span>
					{#if c}
						<span class="cambio" class:baja={!c.sube}>{c.texto}</span>
					{/if}
				</div>
				<div class="pista" aria-hidden="true">
					{#if f.antes != null}
						<span class="antes" style="width: {ancho(f.antes)}%"></span>
					{/if}
					<span class="ahora" style="width: {ancho(f.valor)}%"></span>
				</div>
			</li>
		{/each}
	</ol>
{/if}

<style>
	.barras {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	.barras.compacta {
		gap: 10px;
	}

	.barras.en-columnas {
		display: grid;
		grid-template-columns: repeat(var(--columnas), minmax(0, 1fr));
		gap: 16px 40px;
	}

	@media (max-width: 760px) {
		.barras.en-columnas {
			grid-template-columns: 1fr;
		}
	}

	.cabeza {
		display: flex;
		align-items: baseline;
		gap: var(--e2);
		min-width: 0;
		margin-bottom: 6px;
	}

	.puesto {
		flex-shrink: 0;
		width: 20px;
		height: 20px;
		display: inline-grid;
		place-items: center;
		font-size: var(--f-xs);
		font-weight: 600;
		color: var(--color);
		background: var(--panel);
		border-radius: 50%;
	}

	.nombre {
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		font-size: var(--f-ms);
		color: var(--tinta);
		text-decoration: none;
	}

	a.nombre:hover {
		color: var(--indigo);
		text-decoration: underline;
	}

	.detalle {
		flex-shrink: 0;
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.cifra {
		margin-left: auto;
		flex-shrink: 0;
		font-size: var(--f-ms);
		font-weight: 600;
		color: var(--tinta);
		font-variant-numeric: tabular-nums;
	}

	.cifra small {
		font-size: var(--f-xs);
		font-weight: 400;
		color: var(--gris);
	}

	.cambio {
		flex-shrink: 0;
		padding: 1px 8px;
		font-size: var(--f-xs);
		color: var(--descuento-tinta);
		background: var(--descuento-fondo);
		border-radius: 999px;
	}

	.cambio.baja {
		color: var(--rojo);
		background: var(--rojo-cl);
	}

	.pista {
		position: relative;
		height: 8px;
		background: var(--panel);
		border-radius: 999px;
		overflow: hidden;
	}

	.compacta .pista {
		height: 6px;
	}

	.pista span {
		position: absolute;
		inset: 0 auto 0 0;
		border-radius: 999px;
		animation: crece 0.7s ease-out both;
		animation-delay: var(--retraso);
	}

	.ahora {
		background: linear-gradient(90deg, color-mix(in srgb, var(--color) 70%, transparent), var(--color));
	}

	.antes {
		background: color-mix(in srgb, var(--color) 28%, transparent);
	}

	@keyframes crece {
		from {
			width: 0;
		}
	}

	.vacio {
		padding: 14px 16px;
		font-size: var(--f-ms);
		color: var(--gris);
		background: var(--panel);
		border-radius: var(--r);
	}
</style>
