<script lang="ts">
	import { onMount } from 'svelte';
	import { pedir } from './api';

	/**
	 * "Se compran juntos": GET /productos/combos (Jose David, 2026-10-16).
	 *
	 * Los grupos de 2 y 3 productos que mas se compran en el MISMO pedido, en
	 * toda la tienda. Es un conteo global, asi que sale de ClickHouse: un worker
	 * lo cuenta cada 30 min y deja el JSON en Redis, y la ruta solo lee Redis.
	 * La version "con este producto suelen llevar" es otra cosa y sale del
	 * grafo (tambien-compraron, en la ficha).
	 *
	 * Se pide sola al montarse y no se monta si no hay combos: con pedidos de un
	 * solo producto no sale ninguno, y un estante vacio con titulo se lee como
	 * un fallo.
	 */

	interface ProductoCombo {
		_id: number;
		nombre: string;
		imagen?: string | null;
		precio_tienda?: unknown;
		precio_desde?: unknown;
		hay_descuento?: boolean;
	}

	interface Combo {
		pedidos: number;
		productos: ProductoCombo[];
	}

	let combos = $state<Combo[]>([]);
	let rotas = $state<number[]>([]);

	onMount(async () => {
		const r = await pedir<Combo[]>('/productos/combos');
		combos =
			r.ok && Array.isArray(r.payload)
				? r.payload.filter((c) => c && Array.isArray(c.productos) && c.productos.length >= 2)
				: [];
	});

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

	/** El de la tienda si lo tiene, si no el mas barato. Igual que los demas estantes. */
	function precio(p: ProductoCombo): number {
		const tienda = aNumero(p.precio_tienda);
		return tienda > 0 ? tienda : aNumero(p.precio_desde);
	}

	function quetzales(n: number): string {
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}

	function clave(c: Combo): string {
		return c.productos.map((p) => p._id).join('-');
	}
</script>

{#if combos.length > 0}
	<section class="combos" aria-labelledby="t-combos">
		<h2 id="t-combos">Se compran juntos</h2>
		<ul>
			{#each combos as c (clave(c))}
				<li>
					<div class="fotos">
						{#each c.productos as p (p._id)}
							<a href="/producto/{p._id}?origen=catalogo" title={p.nombre}>
								{#if p.imagen && !rotas.includes(p._id)}
									<img
										src={p.imagen}
										alt={p.nombre}
										loading="lazy"
										onerror={() => (rotas = [...rotas, p._id])}
									/>
								{:else}
									<span class="sin-foto">Sin imagen</span>
								{/if}
							</a>
						{/each}
					</div>
					<p class="nombres">
						{#each c.productos as p, i (p._id)}
							{#if i > 0}<span class="mas"> + </span>{/if}
							<a href="/producto/{p._id}?origen=catalogo">{p.nombre}</a>
						{/each}
					</p>
					<p class="pie">
						<strong>{quetzales(c.productos.reduce((t, p) => t + precio(p), 0))}</strong>
						<span>juntos en {c.pedidos} pedidos</span>
					</p>
				</li>
			{/each}
		</ul>
	</section>
{/if}

<style>
	.combos {
		margin-bottom: 28px;
	}

	.combos h2 {
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
		flex: 0 0 260px;
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 10px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		scroll-snap-align: start;
	}

	.fotos {
		display: flex;
		gap: 6px;
	}

	.fotos a {
		flex: 1;
		display: grid;
		place-items: center;
		aspect-ratio: 1;
		overflow: hidden;
		background: var(--panel);
		border-radius: var(--r);
	}

	.fotos img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.sin-foto {
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.nombres {
		font-size: var(--f-sm);
		line-height: 1.3;
		overflow-wrap: anywhere;
	}

	.nombres a {
		color: inherit;
		text-decoration: none;
	}

	.nombres a:hover {
		color: var(--indigo);
	}

	.mas {
		color: var(--gris);
	}

	.pie {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 8px;
		margin-top: auto;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.pie strong {
		font-size: var(--f-base);
		color: var(--tinta);
	}
</style>
