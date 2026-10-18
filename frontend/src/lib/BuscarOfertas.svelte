<script lang="ts">
	import { mensajeUtil, pedir } from './api';

	/**
	 * El buscador de ofertas: GET /vendedor/ofertas/buscar (Jose David,
	 * 2026-10-17, plan pendiente/evento-oferta.md).
	 *
	 * Busca por texto difuso (tolera errores de tecleo y no distingue tildes)
	 * sobre el nombre del producto, el de la variante y el del vendedor, en el
	 * indice mesh_ofertas de Elasticsearch. Lo mantiene el worker
	 * EventoOfertaSyncService desde la cola evento_oferta de PostgreSQL, asi que
	 * un cambio de precio o de stock tarda unos 5 s en verse aqui. Editar una
	 * oferta sigue siendo la lista de abajo, contra PostgreSQL.
	 *
	 * El `resumen` sale de agregaciones de Elasticsearch sobre TODO lo que
	 * cumple la busqueda, no solo sobre la pagina.
	 *
	 * Quien ve que lo decide el backend: un vendedor solo las suyas; la tienda y
	 * el admin pueden pedir `alcance=todas`. Por eso el selector solo sale con
	 * `administraLaTienda`.
	 */
	let {
		alExpirarSesion,
		administraLaTienda = false
	}: { alExpirarSesion: () => void; administraLaTienda?: boolean } = $props();

	interface OfertaEncontrada {
		id_oferta: string;
		id_producto: string;
		id_producto_variante: string;
		nombre_producto: string;
		nombre_variante: string;
		estado_variante: string;
		vendedor: { id_usuario: string; usuario: string; nombre: string; estado: string };
		precio: string;
		porcentaje_descuento: string | null;
		precio_final: string;
		stock: number;
		estado: string;
	}

	interface Resultado {
		ofertas: OfertaEncontrada[];
		pagina: number;
		limite: number;
		total_ofertas: number;
		total_paginas: number;
		resumen: {
			por_estado: Record<string, number>;
			con_descuento: number;
			agotadas: number;
			precio_final: { minimo: string | null; maximo: string | null; promedio: string | null };
			por_vendedor?: { id_vendedor: string; usuario: string; ofertas: number }[];
		};
	}

	const LIMITE = 10;

	let q = $state('');
	let todas = $state(false);
	let stock = $state('');
	let conDescuento = $state('');
	let orden = $state('');
	let pagina = $state(1);

	let resultado = $state<Resultado | null>(null);
	let cargando = $state(false);
	let error = $state('');
	let vigente = 0;

	async function buscar(p = 1) {
		const mia = ++vigente;
		pagina = p;
		cargando = true;
		error = '';

		const params = new URLSearchParams();
		if (q.trim()) params.set('q', q.trim().slice(0, 100));
		if (administraLaTienda && todas) params.set('alcance', 'todas');
		if (stock) params.set('stock', stock);
		if (conDescuento) params.set('con_descuento', conDescuento);
		if (orden) params.set('orden', orden);
		params.set('pagina', String(p));
		params.set('limite', String(LIMITE));

		const r = await pedir<Resultado>(`/vendedor/ofertas/buscar?${params}`);
		if (mia !== vigente) return;
		cargando = false;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}
		if (!r.ok || !r.payload) {
			error = mensajeUtil(r);
			resultado = null;
			return;
		}
		resultado = r.payload;
	}

	function alEnviar(e: SubmitEvent) {
		e.preventDefault();
		void buscar(1);
	}

	function quetzales(valor: string | null): string {
		const n = Number(valor ?? 0);
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}

	function resumenEstados(r: Resultado): string {
		return Object.entries(r.resumen.por_estado ?? {})
			.map(([estado, n]) => `${n} ${estado}`)
			.join(', ');
	}
</script>

<section class="buscar-ofertas">
	<h2>Buscar ofertas</h2>
	<p class="intro">Encuentra una oferta por el nombre del producto, la variante o el vendedor.</p>

	<form onsubmit={alEnviar}>
		<input type="search" placeholder="Por ejemplo laptop 16 gb" maxlength="100" bind:value={q} />
		<select bind:value={stock} aria-label="Existencias">
			<option value="">Con y sin stock</option>
			<option value="con_stock">Con stock</option>
			<option value="agotadas">Agotadas</option>
		</select>
		<select bind:value={conDescuento} aria-label="Descuento">
			<option value="">Con y sin descuento</option>
			<option value="true">Con descuento</option>
			<option value="false">Sin descuento</option>
		</select>
		<select bind:value={orden} aria-label="Orden">
			<option value="">Mas parecidas primero</option>
			<option value="precio_asc">Precio, de menor a mayor</option>
			<option value="precio_desc">Precio, de mayor a menor</option>
			<option value="stock_asc">Menos stock primero</option>
			<option value="recientes">Mas nuevas primero</option>
		</select>
		{#if administraLaTienda}
			<label class="todas">
				<input type="checkbox" bind:checked={todas} />
				De todos los vendedores
			</label>
		{/if}
		<button type="submit" class="principal" disabled={cargando}>
			{cargando ? 'Buscando...' : 'Buscar'}
		</button>
	</form>

	{#if error}
		<p class="malo" role="alert">{error}</p>
	{:else if resultado}
		{#if resultado.total_ofertas === 0}
			<p class="gris">No hay ofertas que coincidan.</p>
		{:else}
			<p class="resumen">
				{resultado.total_ofertas}
				{resultado.total_ofertas === 1 ? 'oferta' : 'ofertas'} ({resumenEstados(resultado)}).
				{resultado.resumen.con_descuento} con descuento, {resultado.resumen.agotadas} agotadas.
				Precio final de {quetzales(resultado.resumen.precio_final.minimo)} a
				{quetzales(resultado.resumen.precio_final.maximo)}.
			</p>
			<div class="rodillo">
				<table>
					<thead>
						<tr>
							<th scope="col">Producto</th>
							<th scope="col">Vendedor</th>
							<th scope="col">Precio final</th>
							<th scope="col">Stock</th>
							<th scope="col">Estado</th>
						</tr>
					</thead>
					<tbody>
						{#each resultado.ofertas as o (o.id_oferta)}
							<tr>
								<td>
									<a href="/producto/{o.id_producto}">{o.nombre_producto}</a>
									<span class="gris">{o.nombre_variante}</span>
								</td>
								<td>{o.vendedor.usuario}</td>
								<td>
									{quetzales(o.precio_final)}
									{#if o.porcentaje_descuento && Number(o.porcentaje_descuento) > 0}
										<span class="gris">-{Number(o.porcentaje_descuento)} %</span>
									{/if}
								</td>
								<td class:agotada={o.stock === 0}>{o.stock}</td>
								<td>{o.estado}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
			{#if resultado.total_paginas > 1}
				<nav class="paginas" aria-label="Paginas de ofertas">
					<button type="button" disabled={pagina <= 1 || cargando} onclick={() => buscar(pagina - 1)}>
						Anterior
					</button>
					<span>Pagina {resultado.pagina} de {resultado.total_paginas}</span>
					<button
						type="button"
						disabled={pagina >= resultado.total_paginas || cargando}
						onclick={() => buscar(pagina + 1)}
					>
						Siguiente
					</button>
				</nav>
			{/if}
		{/if}
	{/if}
</section>

<style>
	.buscar-ofertas {
		padding: 22px 26px;
		margin-bottom: 24px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	h2 {
		font-size: var(--f-lg);
		margin-bottom: 4px;
	}

	.intro,
	.gris {
		color: var(--gris);
	}

	form {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 8px;
		margin: 12px 0;
	}

	form input[type='search'] {
		flex: 1 1 16rem;
		min-width: 0;
	}

	.todas {
		display: flex;
		align-items: center;
		gap: 6px;
		font-size: var(--f-sm);
	}

	.principal {
		color: #fff;
		background: var(--indigo);
		border-color: var(--indigo);
	}

	.resumen {
		margin-bottom: 10px;
		font-size: var(--f-sm);
	}

	.rodillo {
		overflow-x: auto;
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: var(--f-sm);
	}

	th,
	td {
		padding: 6px 8px;
		text-align: left;
		border-bottom: 1px solid var(--linea);
		vertical-align: top;
	}

	td a {
		display: block;
		color: var(--tinta);
	}

	.agotada {
		color: var(--rojo);
	}

	.malo {
		color: var(--rojo);
	}

	.paginas {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 12px;
		margin-top: 12px;
	}

	@media (max-width: 620px) {
		.buscar-ofertas {
			padding: 18px 16px;
		}
	}
</style>
