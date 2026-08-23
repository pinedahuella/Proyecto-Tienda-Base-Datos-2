<script lang="ts">
	import { onMount } from 'svelte';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import { pedir } from '$lib/api';

	/**
	 * El catalogo. Es la pagina de inicio y es publica: GET /productos no pide
	 * la cookie de sesion, asi que se puede navegar sin cuenta.
	 *
	 * Todo el filtrado lo hace el backend. Aqui no se filtra en memoria: si se
	 * hiciera, un filtro solo alcanzaria a los productos ya descargados y
	 * mentiria en cuanto haya mas de una tanda.
	 */

	interface Variante {
		id_producto_variante: number;
		nombre_variante: string;
		precio: { $numberDecimal: string } | string | number;
		descripcion: string | null;
		estado: string;
		imagenes: string[];
		caracteristicas_adicionales?: Caracteristica[];
	}

	interface Caracteristica {
		nombre: string;
		valor: string | number | boolean | string[];
		unidad: string | null;
	}

	interface Producto {
		_id: number;
		nombre: string;
		descripcion: string | null;
		estado: string;
		vendedor: { id_usuario: number; usuario: string; nombre: string; apellido: string };
		categoria: { id_categoria: number; nombre: string; categoria_padre: string | null };
		variantes: Variante[];
		caracteristicas_adicionales?: Caracteristica[];
	}

	interface Tanda {
		productos: Producto[];
		siguiente_cursor: number | null;
	}

	/**
	 * Las categorias van escritas aqui a proposito, por ahora. La unica ruta que
	 * las lista es /vendedor/categorias, que pide sesion de vendedor, y esta
	 * pagina es publica. Cuando exista una ruta publica de categorias, esta
	 * lista se cambia por esa llamada y no hay que tocar nada mas.
	 */
	const CATEGORIAS = [
		{ id: 20, nombre: 'Accesorios de computadora' },
		{ id: 16, nombre: 'Audifonos' },
		{ id: 12, nombre: 'Botas' },
		{ id: 3, nombre: 'Camisas' },
		{ id: 25, nombre: 'Ciclismo' },
		{ id: 7, nombre: 'Cocina' },
		{ id: 5, nombre: 'Computadoras' },
		{ id: 22, nombre: 'Electrodomesticos de cocina' },
		{ id: 24, nombre: 'Fitness' },
		{ id: 28, nombre: 'Futbol' },
		{ id: 21, nombre: 'Iluminacion' },
		{ id: 27, nombre: 'Libros de texto' },
		{ id: 29, nombre: 'Literatura' },
		{ id: 19, nombre: 'Monitores' },
		{ id: 10, nombre: 'Pantalones' },
		{ id: 13, nombre: 'Sandalias' },
		{ id: 18, nombre: 'Telefonos' },
		{ id: 14, nombre: 'Tenis' },
		{ id: 9, nombre: 'Vestidos' }
	];

	/** Nombres de caracteristica para el desplegable del filtro dinamico. */
	const CARACTERISTICAS = [
		'Marca',
		'Modelo',
		'Pais de origen',
		'Tipo de producto',
		'Procesador',
		'Memoria RAM',
		'Talla',
		'Color',
		'Material',
		'Contenido del paquete'
	];

	const POR_TANDA = 12;

	let productos = $state<Producto[]>([]);
	let cursor = $state<number | null>(null);
	let cargando = $state(false);
	let trayendoMas = $state(false);
	let error = $state('');
	let primeraVez = $state(true);

	// Los filtros
	let nombre = $state('');
	let idCategoria = $state('');
	let precioMin = $state('');
	let precioMax = $state('');
	let caracNombre = $state('');
	let caracValor = $state('');

	/** La URL que se le pide al backend. Se arma sola con lo que este puesto. */
	function consulta(despuesDe: number | null): string {
		const p = new URLSearchParams();
		p.set('limite', String(POR_TANDA));
		if (despuesDe !== null) p.set('despues_de', String(despuesDe));
		if (nombre.trim()) p.set('nombre', nombre.trim());
		if (idCategoria) p.set('id_categoria', idCategoria);
		if (precioMin.trim()) p.set('precio_min', precioMin.trim());
		if (precioMax.trim()) p.set('precio_max', precioMax.trim());
		// El filtro dinamico: el NOMBRE de la caracteristica es el nombre del
		// parametro. Por eso hace falta que los dos campos vengan llenos.
		if (caracNombre.trim() && caracValor.trim()) {
			p.set(caracNombre.trim(), caracValor.trim());
		}
		return `/productos?${p.toString()}`;
	}

	/** Vuelve a empezar: cambio un filtro, la lista anterior ya no vale. */
	async function buscar() {
		cargando = true;
		error = '';
		const r = await pedir<Tanda>(consulta(null));
		if (r.ok && r.payload) {
			productos = r.payload.productos;
			cursor = r.payload.siguiente_cursor;
		} else {
			productos = [];
			cursor = null;
			// estado 0 quiere decir que la peticion ni salio: el backend esta apagado
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
		cargando = false;
		primeraVez = false;
	}

	/** La siguiente tanda, sin perder lo que ya se mostro. */
	async function verMas() {
		if (cursor === null || trayendoMas) return;
		trayendoMas = true;
		const r = await pedir<Tanda>(consulta(cursor));
		if (r.ok && r.payload) {
			productos = [...productos, ...r.payload.productos];
			cursor = r.payload.siguiente_cursor;
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
		trayendoMas = false;
	}

	/**
	 * Al escribir no se busca en cada tecla: se espera a que la persona pare.
	 * Sin esto, "laptop" son seis consultas y las respuestas pueden llegar
	 * desordenadas, dejando en pantalla el resultado de "lapt".
	 */
	let temporizador: ReturnType<typeof setTimeout> | undefined;
	function alEscribir() {
		clearTimeout(temporizador);
		temporizador = setTimeout(buscar, 350);
	}

	function limpiar() {
		nombre = '';
		idCategoria = '';
		precioMin = '';
		precioMax = '';
		caracNombre = '';
		caracValor = '';
		buscar();
	}

	let hayFiltro = $derived(
		Boolean(
			nombre.trim() ||
				idCategoria ||
				precioMin.trim() ||
				precioMax.trim() ||
				(caracNombre.trim() && caracValor.trim())
		)
	);

	onMount(buscar);

	// ---------- lo que se ensena de cada producto ----------

	/** El precio llega como Decimal128 de Mongo, no como numero. */
	function aNumero(precio: Variante['precio']): number {
		if (typeof precio === 'number') return precio;
		if (typeof precio === 'string') return Number(precio);
		return Number(precio?.$numberDecimal ?? 0);
	}

	function quetzales(n: number): string {
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}

	/**
	 * Un producto no tiene un precio: tiene el de cada variante. Se ensena el
	 * rango, y un solo numero cuando todas cuestan lo mismo.
	 */
	function precio(p: Producto): string {
		const precios = p.variantes.map((v) => aNumero(v.precio)).filter((n) => n > 0);
		if (precios.length === 0) return 'Sin precio';
		const min = Math.min(...precios);
		const max = Math.max(...precios);
		return min === max ? quetzales(min) : `${quetzales(min)} - ${quetzales(max)}`;
	}

	function portada(p: Producto): string | null {
		for (const v of p.variantes) {
			if (v.imagenes && v.imagenes.length > 0) return v.imagenes[0];
		}
		return null;
	}

	/**
	 * Tres caracteristicas para la tarjeta. Se saltan las de tipo lista
	 * repetidas: ensenar "Etiquetas" tres veces no dice nada.
	 */
	function resumen(p: Producto): Caracteristica[] {
		const vistas = new Set<string>();
		const salida: Caracteristica[] = [];
		for (const c of p.caracteristicas_adicionales ?? []) {
			if (vistas.has(c.nombre)) continue;
			vistas.add(c.nombre);
			salida.push(c);
			if (salida.length === 3) break;
		}
		return salida;
	}

	function conUnidad(c: Caracteristica): string {
		// Una caracteristica de tipo lista trae su valor como array
		const texto = Array.isArray(c.valor) ? c.valor.join(', ') : String(c.valor);
		return c.unidad ? `${texto} ${c.unidad}` : texto;
	}
</script>

<svelte:head>
	<title>Mesh</title>
</svelte:head>

<Cabecera />

<main>
	<div class="env">
		<div class="intro">
			<h1>El catalogo</h1>
			<p>
				{#if cargando}
					Buscando...
				{:else if error}
					&nbsp;
				{:else}
					{productos.length}
					{productos.length === 1 ? 'producto' : 'productos'}
					{hayFiltro ? 'que coinciden' : 'en la tienda'}{cursor !== null ? ' y hay mas' : ''}
				{/if}
			</p>
		</div>

		<!-- Los filtros. Cada cambio vuelve a preguntarle al backend -->
		<section class="filtros" aria-label="Filtros">
			<div class="campo ancho">
				<label for="f-nombre">Buscar</label>
				<input
					id="f-nombre"
					type="text"
					placeholder="Nombre del producto"
					bind:value={nombre}
					oninput={alEscribir}
				/>
			</div>

			<div class="campo">
				<label for="f-cat">Categoria</label>
				<select id="f-cat" bind:value={idCategoria} onchange={buscar}>
					<option value="">Todas</option>
					{#each CATEGORIAS as c (c.id)}
						<option value={String(c.id)}>{c.nombre}</option>
					{/each}
				</select>
			</div>

			<div class="campo corto">
				<label for="f-min">Precio desde</label>
				<input id="f-min" type="number" min="0" step="0.01" placeholder="0" bind:value={precioMin} oninput={alEscribir} />
			</div>

			<div class="campo corto">
				<label for="f-max">hasta</label>
				<input id="f-max" type="number" min="0" step="0.01" placeholder="Sin tope" bind:value={precioMax} oninput={alEscribir} />
			</div>

			<div class="campo">
				<label for="f-car">Caracteristica</label>
				<select id="f-car" bind:value={caracNombre} onchange={buscar}>
					<option value="">Cualquiera</option>
					{#each CARACTERISTICAS as c (c)}
						<option value={c}>{c}</option>
					{/each}
				</select>
			</div>

			<div class="campo">
				<label for="f-val">que valga</label>
				<input
					id="f-val"
					type="text"
					placeholder="Tecno Sur, 16, Negro..."
					bind:value={caracValor}
					oninput={alEscribir}
					disabled={!caracNombre}
				/>
			</div>

			{#if hayFiltro}
				<button type="button" class="limpiar" onclick={limpiar}>Quitar filtros</button>
			{/if}
		</section>

		{#if error}
			<p class="error">{error}</p>
		{/if}

		{#if cargando && primeraVez}
			<p class="vacio">Cargando el catalogo...</p>
		{:else if productos.length === 0 && !error}
			<p class="vacio">
				Ningun producto coincide con lo que buscaste.
				{#if hayFiltro}<button type="button" class="enlace" onclick={limpiar}>Quitar los filtros</button>{/if}
			</p>
		{/if}

		<div class="rejilla">
			{#each productos as p (p._id)}
				<a class="tarjeta" href="/producto/{p._id}">
					<div class="foto">
						{#if portada(p)}
							<img src={portada(p)} alt={p.nombre} loading="lazy" />
						{:else}
							<span class="sin-foto">Sin imagen</span>
						{/if}
					</div>

					<div class="cuerpo">
						<span class="categoria">{p.categoria.nombre}</span>
						<h2>{p.nombre}</h2>
						<p class="desc">{p.descripcion ?? ''}</p>

						{#if resumen(p).length > 0}
							<ul class="rasgos">
								{#each resumen(p) as c (c.nombre)}
									<li><span>{c.nombre}</span> {conUnidad(c)}</li>
								{/each}
							</ul>
						{/if}

						<div class="pie-tarjeta">
							<strong class="precio">{precio(p)}</strong>
							<span class="variantes">
								{p.variantes.length}
								{p.variantes.length === 1 ? 'variante' : 'variantes'}
							</span>
						</div>
					</div>
				</a>
			{/each}
		</div>

		{#if cursor !== null && productos.length > 0}
			<div class="mas">
				<button type="button" onclick={verMas} disabled={trayendoMas}>
					{trayendoMas ? 'Trayendo...' : 'Ver mas productos'}
				</button>
			</div>
		{/if}
	</div>
</main>

<Pie />

<style>
	main {
		padding: 2.5rem 0 4rem;
	}

	.intro {
		margin-bottom: 1.75rem;
	}

	.intro p {
		color: var(--gris);
		margin-top: 0.35rem;
	}

	/* ---------- filtros ---------- */

	.filtros {
		display: flex;
		flex-wrap: wrap;
		align-items: flex-end;
		gap: 0.9rem;
		padding: 1.1rem;
		margin-bottom: 2rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
		min-width: 150px;
	}

	.campo.ancho {
		flex: 1 1 220px;
	}

	.campo.corto {
		min-width: 110px;
		max-width: 130px;
	}

	.campo label {
		font-size: 0.82rem;
		color: var(--gris);
	}

	.filtros input,
	.filtros select {
		width: 100%;
		padding: 9px 11px;
		font-family: inherit;
		font-size: 0.95rem;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		transition: border-color var(--t);
	}

	.filtros input:focus,
	.filtros select:focus {
		outline: none;
		border-color: var(--indigo);
	}

	.filtros input:disabled {
		background: var(--panel);
		color: var(--gris-2);
	}

	.limpiar {
		border-radius: 999px;
		padding: 9px 18px;
		font-family: inherit;
		font-size: 0.92rem;
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.limpiar:hover {
		border-color: var(--indigo);
		color: var(--indigo);
		background: var(--indigo-cl);
	}

	/* ---------- la rejilla ---------- */

	.rejilla {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
		gap: 1.25rem;
	}

	.tarjeta {
		display: flex;
		flex-direction: column;
		color: inherit;
		text-decoration: none;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
		transition: border-color var(--t);
	}

	.tarjeta:hover {
		border-color: var(--indigo);
	}

	.foto {
		display: flex;
		align-items: center;
		justify-content: center;
		aspect-ratio: 4 / 3;
		background: var(--panel);
		border-bottom: 1px solid var(--linea);
	}

	.foto img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.sin-foto {
		font-size: 0.85rem;
		color: var(--gris-2);
	}

	.cuerpo {
		display: flex;
		flex-direction: column;
		flex: 1;
		gap: 0.45rem;
		padding: 1rem;
	}

	.categoria {
		font-size: 0.78rem;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--indigo);
	}

	.cuerpo h2 {
		font-size: 1.05rem;
		line-height: 1.35;
	}

	.desc {
		font-size: 0.9rem;
		color: var(--gris);
		/* Dos lineas y corta: si no, una descripcion larga descuadra la rejilla */
		display: -webkit-box;
		-webkit-line-clamp: 2;
		line-clamp: 2;
		-webkit-box-orient: vertical;
		overflow: hidden;
	}

	.rasgos {
		list-style: none;
		display: flex;
		flex-wrap: wrap;
		gap: 0.35rem;
		margin-top: 0.15rem;
	}

	.rasgos li {
		padding: 3px 8px;
		font-size: 0.78rem;
		color: var(--texto);
		background: var(--panel);
		border-radius: var(--r);
	}

	.rasgos span {
		color: var(--gris-2);
	}

	.pie-tarjeta {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 0.5rem;
		margin-top: auto;
		padding-top: 0.6rem;
	}

	.precio {
		font-size: 1.02rem;
		font-weight: 500;
		color: var(--tinta);
	}

	.variantes {
		font-size: 0.82rem;
		color: var(--gris);
	}

	/* ---------- estados ---------- */

	.vacio,
	.error {
		padding: 2.5rem 0;
		text-align: center;
		color: var(--gris);
	}

	.error {
		color: var(--rojo);
	}

	.enlace {
		font-family: inherit;
		font-size: inherit;
		color: var(--indigo);
		background: none;
		border: none;
		padding: 0;
		cursor: pointer;
		text-decoration: underline;
	}

	.mas {
		display: flex;
		justify-content: center;
		margin-top: 2.25rem;
	}

	.mas button {
		border-radius: 999px;
		padding: 11px 28px;
		font-family: inherit;
		font-size: 0.98rem;
		color: var(--blanco);
		background: var(--indigo);
		border: none;
		border-radius: var(--r);
		cursor: pointer;
		transition: background var(--t);
	}

	.mas button:hover:not(:disabled) {
		background: var(--indigo-os);
	}

	.mas button:disabled {
		opacity: 0.6;
		cursor: default;
	}

	@media (max-width: 620px) {
		.campo.corto {
			max-width: none;
			flex: 1 1 120px;
		}
		.rejilla {
			grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
			gap: 0.9rem;
		}
	}
</style>
