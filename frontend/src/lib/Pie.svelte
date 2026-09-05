<script lang="ts">
	import MarcaMesh from './MarcaMesh.svelte';

	/**
	 * Pie del sitio.
	 *
	 * Solo el logotipo, el lema y la linea legal. Sin columnas de enlaces:
	 * esas paginas todavia no existen.
	 */
	const anio = 2026;
</script>

<footer>
	<div class="env fila">
		<div class="izquierda">
			<MarcaMesh tamano={26} />
			<p class="lema">Cada tienda, un hilo distinto.</p>
		</div>
		<p class="legal">&copy; {anio} Mesh · Proyecto academico, Universidad del Istmo</p>
	</div>
</footer>

<style>
	footer {
		margin-top: 72px;
		background: var(--off);
		border-top: 1px solid var(--linea);
	}

	.fila {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e5);
		flex-wrap: wrap;
		padding-top: 30px;
		padding-bottom: 30px;
	}

	.izquierda {
		display: flex;
		align-items: center;
		gap: var(--e4);
		flex-wrap: wrap;
	}

	.lema {
		font-size: var(--f-md);
		color: var(--gris);
	}

	.legal {
		font-size: var(--f-ms);
		color: var(--gris-2);
	}

	@media (max-width: 620px) {
		footer {
			margin-top: 48px;
		}
		.fila {
			align-items: flex-start;
			gap: var(--e4);
			padding-top: 24px;
			padding-bottom: 24px;
		}
		.izquierda {
			gap: var(--e3);
		}
		.lema,
		.legal {
			font-size: var(--f-sm);
		}
	}
</style>
