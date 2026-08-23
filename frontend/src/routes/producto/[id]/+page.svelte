<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import { pedir } from '$lib/api';

	/**
	 * La ficha de un producto: la foto arriba y debajo todo lo que la base
	 * guarda de el.
	 *
	 * No hay ruta publica para un producto suelto: /vendedor/productos/:id pide
	 * sesion de vendedor. Se usa el cursor de GET /productos, que si es publico:
	 * "despues_de" trae los que tienen _id MAYOR al que se le pase, asi que
	 * pedir despues_de = id - 1 con limite = 1 devuelve justo este producto.
	 * El dia que exista GET /productos/:id, se cambia esta llamada y ya.
	 */

	interface Caracteristica {
		nombre: string;
		valor: string | number | boolean | string[];
		unidad: string | null;
	}

	interface Variante {
		id_producto_variante: number;
		nombre_variante: string;
		precio: { $numberDecimal: string } | string | number;
		descripcion: string | null;
		estado: string;
		imagenes: string[];
		caracteristicas_adicionales?: Caracteristica[];
		caracteristicas_personalizadas?: Caracteristica[];
	}

	interface Producto {
		_id: number;
		nombre: string;
		descripcion: string | null;
		fecha_creacion: string;
		estado: string;
		vendedor: { id_usuario: number; usuario: string; nombre: string; apellido: string };
		categoria: { id_categoria: number; nombre: string; categoria_padre: string | null };
		variantes: Variante[];
		caracteristicas_adicionales?: Caracteristica[];
		caracteristicas_personalizadas?: Caracteristica[];
	}

	let id = $derived(Number(page.params.id));
	let producto = $state<Producto | null>(null);
	let cargando = $state(true);
	let error = $state('');

	/** Cual de las fotos se ve en grande. Es el indice dentro de galeria(). */
	let elegida = $state(0);

	async function traer() {
		cargando = true;
		error = '';
		producto = null;
		elegida = 0;

		if (!Number.isInteger(id) || id < 1) {
			error = 'Ese no es un numero de producto valido';
			cargando = false;
			return;
		}

		const r = await pedir<{ productos: Producto[] }>(`/productos?limite=1&despues_de=${id - 1}`);

		if (!r.ok || !r.payload) {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		} else {
			const encontrado = r.payload.productos[0];
			// El cursor trae el SIGUIENTE que exista, no necesariamente este: si el
			// producto no existe, o esta inactivo o en borrador (que el catalogo
			// publico nunca devuelve), lo que llega es otro.
			if (encontrado && encontrado._id === id) {
				producto = encontrado;
			} else {
				error = 'Ese producto no esta en el catalogo publico';
			}
		}
		cargando = false;
	}

	onMount(traer);

	function aNumero(precio: Variante['precio']): number {
		if (typeof precio === 'number') return precio;
		if (typeof precio === 'string') return Number(precio);
		return Number(precio?.$numberDecimal ?? 0);
	}

	function quetzales(n: number): string {
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}

	function fecha(iso: string): string {
		return new Date(iso).toLocaleDateString('es-GT', {
			year: 'numeric',
			month: 'long',
			day: 'numeric'
		});
	}

	/** Todas las fotos del producto, sin repetir: una misma foto puede estar en
	 *  varias variantes y no tiene sentido ensenarla dos veces. */
	function galeria(p: Producto): string[] {
		const vistas: string[] = [];
		for (const v of p.variantes) {
			for (const url of v.imagenes ?? []) {
				if (!vistas.includes(url)) vistas.push(url);
			}
		}
		return vistas;
	}

	/** El rango de precio del producto, que es el de sus variantes. */
	function rango(p: Producto): string {
		const precios = p.variantes.map((v) => aNumero(v.precio)).filter((n) => n > 0);
		if (precios.length === 0) return 'Sin precio';
		const min = Math.min(...precios);
		const max = Math.max(...precios);
		return min === max ? quetzales(min) : `${quetzales(min)} - ${quetzales(max)}`;
	}

	/**
	 * Las caracteristicas agrupadas por nombre. Una de tipo lista viene en
	 * varias entradas con el mismo nombre y hay que ensenarla como una sola
	 * fila con sus valores juntos, no como cinco filas repetidas.
	 */
	function agrupadas(lista: Caracteristica[] | undefined) {
		const orden: string[] = [];
		const porNombre = new Map<string, { valores: string[]; unidad: string | null }>();

		for (const c of lista ?? []) {
			// El valor puede ser un array: una caracteristica de tipo lista viene
			// en UNA entrada con todos sus valores adentro.
			const texto = Array.isArray(c.valor) ? c.valor.join(', ') : String(c.valor);
			if (!porNombre.has(c.nombre)) {
				orden.push(c.nombre);
				porNombre.set(c.nombre, { valores: [], unidad: c.unidad });
			}
			porNombre.get(c.nombre)!.valores.push(texto);
		}

		return orden.map((nombre) => {
			const d = porNombre.get(nombre)!;
			return {
				nombre,
				valor: d.valores.join(', ') + (d.unidad ? ' ' + d.unidad : '')
			};
		});
	}

	let fotos = $derived(producto ? galeria(producto) : []);
	let deProducto = $derived(agrupadas(producto?.caracteristicas_adicionales));
	let propias = $derived(agrupadas(producto?.caracteristicas_personalizadas));
</script>

<svelte:head>
	<title>{producto ? producto.nombre + ' · Mesh' : 'Producto · Mesh'}</title>
</svelte:head>

<Cabecera />

<main>
	<div class="env">
		<a class="volver" href="/">
			<span class="flecha" aria-hidden="true">&#8592;</span>
			Volver al catalogo
		</a>

		{#if cargando}
			<p class="aviso">Cargando...</p>
		{:else if error}
			<p class="aviso malo">{error}</p>
		{:else if producto}
			<!-- Arriba la foto; toda la informacion va debajo -->
			<div class="arriba">
				<div class="galeria">
					<div class="grande">
						{#if fotos.length > 0}
							<img src={fotos[elegida]} alt={producto.nombre} />
						{:else}
							<span class="sin-foto">Este producto no tiene fotos</span>
						{/if}
					</div>

					{#if fotos.length > 1}
						<div class="tiras">
							{#each fotos as url, i (url)}
								<button
									type="button"
									class="tira"
									class:activa={i === elegida}
									onclick={() => (elegida = i)}
									aria-label={'Ver foto ' + (i + 1)}
								>
									<img src={url} alt="" />
								</button>
							{/each}
						</div>
					{/if}
				</div>

				<div class="resumen">
					<span class="ruta">
						{#if producto.categoria.categoria_padre}
							{producto.categoria.categoria_padre} ·
						{/if}
						{producto.categoria.nombre}
					</span>
					<h1>{producto.nombre}</h1>
					<p class="precio">{rango(producto)}</p>
					<p class="desc">{producto.descripcion ?? ''}</p>

					<dl class="datos">
						<div>
							<dt>Vendedor</dt>
							<dd>{producto.vendedor.nombre} {producto.vendedor.apellido}</dd>
						</div>
						<div><dt>Publicado</dt><dd>{fecha(producto.fecha_creacion)}</dd></div>
						<div>
							<dt>Variantes</dt>
							<dd>{producto.variantes.length}</dd>
						</div>
					</dl>
				</div>
			</div>

			{#if deProducto.length > 0}
				<section>
					<h2>Detalles</h2>
					<dl class="ficha">
						{#each deProducto as c (c.nombre)}
							<div><dt>{c.nombre}</dt><dd>{c.valor}</dd></div>
						{/each}
					</dl>
				</section>
			{/if}

			{#if propias.length > 0}
				<section>
					<h2>Otros datos del vendedor</h2>
					<dl class="ficha">
						{#each propias as c (c.nombre)}
							<div><dt>{c.nombre}</dt><dd>{c.valor}</dd></div>
						{/each}
					</dl>
				</section>
			{/if}

			<section>
				<h2>Presentaciones</h2>
				{#each producto.variantes as v (v.id_producto_variante)}
					<article class="variante">
						<div class="cabeza-variante">
							<div>
								<h3>{v.nombre_variante}</h3>
								<p class="desc">{v.descripcion ?? ''}</p>
							</div>
							<strong class="precio-v">{quetzales(aNumero(v.precio))}</strong>
						</div>

						{#if agrupadas(v.caracteristicas_adicionales).length > 0}
							<dl class="ficha compacta">
								{#each agrupadas(v.caracteristicas_adicionales) as c (c.nombre)}
									<div><dt>{c.nombre}</dt><dd>{c.valor}</dd></div>
								{/each}
							</dl>
						{/if}
					</article>
				{/each}
			</section>
		{/if}
	</div>
</main>

<Pie />

<style>
	main {
		padding: 2rem 0 4rem;
	}

	/* Un boton de verdad, no un enlace suelto: se ve que se puede pulsar y no
	   se pierde encima del fondo de la pagina. */
	.volver {
		display: inline-flex;
		align-items: center;
		gap: 0.5rem;
		padding: 8px 16px 8px 13px;
		margin-bottom: 1.5rem;
		font-size: 0.92rem;
		color: var(--texto);
		text-decoration: none;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: 999px;
		transition:
			border-color var(--t),
			color var(--t),
			background var(--t);
	}

	.volver:hover {
		color: var(--indigo);
		border-color: var(--indigo);
		background: var(--indigo-cl);
	}

	.flecha {
		display: inline-block;
		font-size: 1.05rem;
		line-height: 1;
		transition: transform var(--t);
	}

	/* La flecha se corre un poco hacia atras: dice a donde lleva */
	.volver:hover .flecha {
		transform: translateX(-3px);
	}

	/* Quien navega con teclado tiene que ver donde esta parado */
	.volver:focus-visible {
		outline: 2px solid var(--indigo);
		outline-offset: 2px;
	}

	/* ---------- la foto arriba, lo demas debajo ---------- */

	.arriba {
		display: grid;
		grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
		gap: 2rem;
		padding: 1.5rem;
		margin-bottom: 2.5rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	/* El resumen va pegado arriba, no centrado: si la foto es alta, el nombre
	   del producto se iria hasta la mitad de la pagina. */
	.resumen {
		align-self: start;
	}

	.grande {
		display: flex;
		align-items: center;
		justify-content: center;
		aspect-ratio: 4 / 3;
		background: var(--panel);
		border-radius: var(--r);
		overflow: hidden;
	}

	.grande img {
		width: 100%;
		height: 100%;
		object-fit: contain;
	}

	.sin-foto {
		color: var(--gris-2);
		font-size: 0.9rem;
	}

	.tiras {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
		margin-top: 0.6rem;
	}

	.tira {
		width: 68px;
		height: 52px;
		padding: 0;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		overflow: hidden;
		cursor: pointer;
		transition: border-color var(--t);
	}

	.tira.activa,
	.tira:hover {
		border-color: var(--indigo);
	}

	.tira img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.ruta {
		font-size: 0.8rem;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--indigo);
	}

	.resumen h1 {
		margin-top: 0.3rem;
		font-size: clamp(1.6rem, 2.6vw, 2.1rem);
	}

	.precio {
		margin-top: 0.7rem;
		font-size: 1.4rem;
		color: var(--tinta);
	}

	.desc {
		margin-top: 0.7rem;
		color: var(--gris);
	}

	.datos {
		display: flex;
		flex-wrap: wrap;
		gap: 1.75rem;
		margin-top: 1.5rem;
		padding-top: 1.1rem;
		border-top: 1px solid var(--linea);
	}

	.datos dt {
		font-size: 0.76rem;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--gris-2);
	}

	.datos dd {
		font-size: 0.96rem;
		color: var(--tinta);
	}

	/* ---------- ficha de caracteristicas ---------- */

	section {
		margin-bottom: 2.5rem;
	}

	h2 {
		font-size: 1.3rem;
		margin-bottom: 0.9rem;
	}

	h3 {
		font-size: 1.02rem;
	}

	.ficha {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
		gap: 0;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
	}

	.ficha > div {
		display: flex;
		gap: 0.75rem;
		padding: 10px 14px;
		border-bottom: 1px solid var(--linea);
	}

	.ficha dt {
		flex: 0 0 45%;
		font-size: 0.88rem;
		color: var(--gris);
	}

	.ficha dd {
		font-size: 0.92rem;
		color: var(--tinta);
	}

	.variante {
		padding: 1.1rem;
		margin-bottom: 1rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.cabeza-variante {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: 1rem;
		margin-bottom: 0.8rem;
	}

	.precio-v {
		font-size: 1.05rem;
		color: var(--tinta);
		white-space: nowrap;
	}

	.compacta {
		border-radius: var(--r);
		background: var(--off);
	}

	.aviso {
		padding: 1.5rem 0;
		color: var(--gris);
	}

	.malo {
		color: var(--rojo);
	}

	@media (max-width: 820px) {
		.arriba {
			grid-template-columns: 1fr;
			gap: 1.5rem;
		}
	}
</style>
