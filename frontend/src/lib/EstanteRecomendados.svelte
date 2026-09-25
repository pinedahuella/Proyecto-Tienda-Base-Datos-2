<script lang="ts" module>
	/**
	 * Lo poco que el estante lee del documento de Mongo que traen las rutas de
	 * recomendaciones. Las tres (R1, R2 y R3) mandan el producto COMPLETO de la
	 * coleccion `productos`, o `null` si ya no tiene documento.
	 */
	export interface ProductoRecomendado {
		_id: number;
		nombre: string;
		categoria?: { nombre: string } | null;
		precio_tienda?: unknown;
		precio_desde?: unknown;
		hay_descuento?: boolean;
		stock_total?: number;
		variantes?: { imagenes?: string[] }[];
	}

	/** Una tarjeta del estante: el producto y, si hace falta, una linea chica debajo. */
	export interface Recomendado {
		producto: ProductoRecomendado;
		nota?: string;
	}
</script>

<script lang="ts">
	/**
	 * Un estante horizontal de tarjetas chicas, para las recomendaciones que
	 * salen de ClickHouse (docs/fraude-entrega3/03-consultas-clickhouse.md):
	 *
	 *   R1  GET /productos/vistos-recientemente   portada, "Viste hace poco"
	 *   R2  GET /productos/:id/tambien-vieron     ficha, "Tambien vieron"
	 *   R3  GET /productos/para-ti                portada con sesion, "Para ti"
	 *
	 * Solo pinta. Quien lo usa pide la ruta, quita los `producto: null` y le
	 * pasa la lista; si queda vacia no se monta, porque un estante vacio con
	 * titulo se lee como un fallo.
	 *
	 * Las tarjetas del catalogo de la portada viven en +page.svelte con estilos
	 * de esa pagina, que Svelte no deja reusar desde aqui. Esta es mas chica a
	 * proposito: una recomendacion acompana, no compite con el catalogo.
	 */
	let {
		titulo,
		items,
		id
	}: {
		titulo: string;
		items: Recomendado[];
		/** Para el aria-labelledby, unico en la pagina. */
		id: string;
	} = $props();

	let rotas = $state<number[]>([]);

	/** El precio llega como { $numberDecimal } de Mongo, como texto o como numero. */
	function aNumero(precio: unknown): number {
		if (precio == null) return 0;
		if (typeof precio === 'number') return precio;
		if (typeof precio === 'string') return Number(precio);
		if (typeof precio === 'object' && '$numberDecimal' in (precio as object)) {
			return Number((precio as { $numberDecimal: string }).$numberDecimal);
		}
		return 0;
	}

	function quetzales(n: number): string {
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}

	/** El de la tienda si lo tiene, si no el mas barato de cualquiera. Igual que la portada. */
	function precio(p: ProductoRecomendado): string {
		const tienda = aNumero(p.precio_tienda);
		if (tienda > 0) return quetzales(tienda);
		const desde = aNumero(p.precio_desde);
		return desde > 0 ? quetzales(desde) : 'Sin precio';
	}

	function portada(p: ProductoRecomendado): string | null {
		return p.variantes?.find((v) => v.imagenes?.length)?.imagenes?.[0] ?? null;
	}
</script>

{#if items.length > 0}
	<section class="estante-rec" aria-labelledby={id}>
		<h2 {id}>{titulo}</h2>
		<ul>
			{#each items as it (it.producto._id)}
				{@const p = it.producto}
				<li>
					<a href="/producto/{p._id}?origen=catalogo">
						<div class="foto">
							{#if p.hay_descuento}
								<span class="marca">Con descuento</span>
							{/if}
							{#if portada(p) && !rotas.includes(p._id)}
								<img
									src={portada(p)}
									alt={p.nombre}
									loading="lazy"
									onerror={() => (rotas = [...rotas, p._id])}
								/>
							{:else}
								<span class="sin-foto">Sin imagen</span>
							{/if}
						</div>
						<span class="nombre">{p.nombre}</span>
						<strong class="precio">{precio(p)}</strong>
						{#if it.nota}
							<span class="nota">{it.nota}</span>
						{/if}
					</a>
				</li>
			{/each}
		</ul>
	</section>
{/if}

<style>
	.estante-rec {
		margin-bottom: 28px;
	}

	.estante-rec h2 {
		font-size: var(--f-lg, 1.15rem);
		margin-bottom: 12px;
	}

	/* Se desliza de lado dentro de su caja y nunca empuja el ancho de la pagina. */
	ul {
		list-style: none;
		display: flex;
		gap: 14px;
		padding: 0 0 8px;
		margin: 0;
		overflow-x: auto;
		scroll-snap-type: x proximity;
	}

	li {
		flex: 0 0 168px;
		scroll-snap-align: start;
	}

	a {
		display: flex;
		flex-direction: column;
		gap: 4px;
		height: 100%;
		padding: 10px;
		color: inherit;
		text-decoration: none;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		transition: border-color var(--t);
	}

	a:hover {
		border-color: var(--indigo);
	}

	.foto {
		position: relative;
		display: grid;
		place-items: center;
		aspect-ratio: 1;
		margin-bottom: 4px;
		overflow: hidden;
		background: var(--panel);
		border-radius: var(--r);
	}

	.foto img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.sin-foto {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.marca {
		position: absolute;
		top: 6px;
		left: 6px;
		padding: 2px 8px;
		font-size: var(--f-xs);
		color: #fff;
		background: var(--indigo);
		border-radius: 999px;
	}

	.nombre {
		font-size: var(--f-sm);
		line-height: 1.3;
		overflow-wrap: anywhere;
	}

	.precio {
		margin-top: auto;
		font-size: var(--f-base);
	}

	.nota {
		font-size: var(--f-xs);
		color: var(--gris);
	}
</style>
