<script lang="ts">
	/**
	 * Una cifra grande con su nombre, para la franja de arriba de un reporte.
	 * Con `parte` (de 0 a 1) lleva debajo una barrita de cuanto es del total,
	 * y `tono` la pinta: `bien` en verde, `ojo` en rojo. La caja no lleva
	 * linea de color arriba (Meme, 2026-10-20).
	 */
	let {
		rotulo,
		valor,
		nota = '',
		tono = 'normal',
		parte = null
	}: {
		rotulo: string;
		valor: string;
		nota?: string;
		tono?: 'normal' | 'bien' | 'ojo';
		parte?: number | null;
	} = $props();
</script>

<div class="cifra {tono}">
	<span class="rotulo">{rotulo}</span>
	<span class="valor">{valor}</span>
	{#if parte !== null}
		<span class="barrita" aria-hidden="true"><span style="width: {Math.min(100, Math.max(0, parte * 100))}%"></span></span>
	{/if}
	{#if nota}<span class="nota">{nota}</span>{/if}
</div>

<style>
	.cifra {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 18px 20px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
	}

	.rotulo {
		font-size: var(--f-xs);
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--gris);
	}

	.valor {
		font-size: var(--f-2xl);
		font-weight: 600;
		color: var(--tinta);
		font-variant-numeric: tabular-nums;
		line-height: 1.1;
	}

	.nota {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.barrita {
		height: 5px;
		background: var(--blanco);
		border-radius: 999px;
		overflow: hidden;
	}

	.barrita span {
		display: block;
		height: 100%;
		background: var(--g1);
		border-radius: 999px;
	}

	.bien .barrita span {
		background: var(--g3);
	}

	.ojo .barrita span {
		background: var(--g4);
	}
</style>
