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
		gap: 28px;
		flex-wrap: wrap;
		padding-top: 30px;
		padding-bottom: 30px;
	}

	.izquierda {
		display: flex;
		align-items: center;
		gap: 20px;
		flex-wrap: wrap;
	}

	.lema {
		font-size: 1rem;
		color: var(--gris);
	}

	.legal {
		font-size: 0.88rem;
		color: var(--gris-2);
	}

	@media (max-width: 620px) {
		footer {
			margin-top: 48px;
		}
		.fila {
			align-items: flex-start;
			gap: 16px;
			padding-top: 24px;
			padding-bottom: 24px;
		}
		.izquierda {
			gap: 12px;
		}
		.lema,
		.legal {
			font-size: 0.85rem;
		}
	}
</style>
