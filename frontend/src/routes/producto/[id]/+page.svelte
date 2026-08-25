<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import { page } from '$app/state';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import { pedir } from '$lib/api';
	import {
		agregarLinea,
		crearPedido,
		guardarPedidoAbierto,
		leerPedidoAbierto,
		olvidarPedidoAbierto,
		pedidoCaduco,
		traerPedido
	} from '$lib/pedido';

	/**
	 * La ficha de un producto: la foto arriba y debajo todo lo que la base
	 * guarda de el.
	 *
	 * Sale de GET /productos/:id, que es publico y devuelve 404 tanto si el
	 * producto no existe como si esta en borrador o inactivo (el backend no
	 * confirma por esta via que un producto oculto exista).
	 *
	 * Antes esto daba un rodeo con el cursor de GET /productos, porque un
	 * comentario aqui decia que la ruta por id no existia. Si existe, y el
	 * rodeo tenia dos costuras: dependia del orden por defecto del listado, y
	 * cuando el cursor devolvia OTRO producto no habia forma de saber si este
	 * no existe o solo esta oculto.
	 */

	interface Caracteristica {
		nombre: string;
		valor: string | number | boolean | string[];
		unidad: string | null;
	}

	/** Como llega numeric(12,2) de Postgres: en un objeto, no como numero. */
	type Decimal = { $numberDecimal: string } | string | number;

	interface Variante {
		id_producto_variante: number;
		nombre_variante: string;
		descripcion: string | null;
		estado: string;
		imagenes: string[];
		/** El precio de la tienda para esta variante. null si la tienda no la oferta. */
		precio_tienda: Decimal | null;
		/** El mas barato al que se ofrece, de cualquier vendedor. */
		precio_desde: Decimal | null;
		stock_tienda: number;
		stock_total: number;
		total_ofertas: number;
		caracteristicas_adicionales?: Caracteristica[];
		caracteristicas_personalizadas?: Caracteristica[];
	}

	/**
	 * Una oferta de verdad: quien vende esta variante, a como y con cuantas.
	 *
	 * NO viene del documento del producto. Las ofertas viven en PostgreSQL y
	 * el backend las trae con una consulta aparte al pedir la ficha, porque
	 * precio y stock cambian en cada venta y una copia en la base documental
	 * se desfasaria. En el listado del catalogo no estan: alli solo van los
	 * numeros agregados.
	 */
	interface Oferta {
		id_oferta: string;
		id_producto_variante_mongo: string;
		vendedor: { id_usuario: string; usuario: string; nombre: string; apellido: string | null };
		/** La oferta de la cuenta de la tienda: es la que se ensena por defecto. */
		es_tienda: boolean;
		precio: string;
		stock: number;
	}

	interface Producto {
		_id: number;
		nombre: string;
		descripcion: string | null;
		fecha_creacion: string;
		estado: string;
		categoria: { id_categoria: number; nombre: string; categoria_padre: string | null };
		variantes: Variante[];
		caracteristicas_adicionales?: Caracteristica[];
		caracteristicas_personalizadas?: Caracteristica[];
		/** El precio de la tienda, que es el que se ensena. */
		precio_tienda: Decimal | null;
		/** El mas barato al que se ofrece, de cualquier vendedor. */
		precio_desde: Decimal | null;
		stock_tienda: number;
		stock_total: number;
		total_ofertas: number;
		/** Las ofertas de verdad, que solo trae esta ruta y no el listado. */
		ofertas: Oferta[];
	}

	let id = $derived(Number(page.params.id));
	let producto = $state<Producto | null>(null);
	let cargando = $state(true);
	let error = $state('');

	/** Cual de las fotos se ve en grande. Es el indice dentro de galeria(). */
	let elegida = $state(0);

	async function traer(cual: number) {
		cargando = true;
		error = '';
		producto = null;
		elegida = 0;

		if (!Number.isInteger(cual) || cual < 1) {
			error = 'Ese no es un numero de producto valido';
			cargando = false;
			return;
		}

		const r = await pedir<Producto>(`/productos/${cual}`);

		if (r.ok && r.payload) {
			producto = r.payload;
		} else if (r.estado === 404) {
			error = 'Ese producto no esta en el catalogo publico';
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
		cargando = false;
	}

	/**
	 * Se recarga cuando cambia el id, no solo al montar.
	 *
	 * SvelteKit reusa el mismo componente al ir de /producto/1 a /producto/2:
	 * con `onMount` la pantalla se quedaba con el producto anterior mientras la
	 * URL decia otro. Y no era solo un dato viejo: alPedido() manda el `id` de
	 * la URL (ya el nuevo) junto con el id de una variante del producto viejo,
	 * asi que el pedido recibiria un par que no existe.
	 *
	 * Va con `untrack` porque traer() escribe `producto`, `cargando` y `error`,
	 * y sin el, el efecto se dispararia a si mismo en bucle: es la misma
	 * mordida documentada en docs/frontend.md ("cargar los datos con $effect se
	 * repite solo"). La UNICA dependencia que se registra es `id`.
	 */
	$effect(() => {
		const cual = id;
		untrack(() => {
			cantidades = {};
			avisoPedido = '';
			errorPedido = '';
			varianteDelAviso = 0;
			traer(cual);
		});
	});

	function aNumero(precio: Decimal | null | undefined): number {
		if (precio == null) return 0;
		if (typeof precio === 'number') return precio;
		if (typeof precio === 'string') return Number(precio);
		return Number(precio.$numberDecimal ?? 0);
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

	/**
	 * El precio del encabezado: el de la tienda, que es el que se ensena.
	 * Regla del profesor, el primero siempre es el de la pagina.
	 */
	function rango(p: Producto): string {
		const n = aNumero(p.precio_tienda);
		return n > 0 ? quetzales(n) : 'Sin precio';
	}

	/** Lo que se puede pagar, si alguien lo tiene mas barato que la tienda. */
	function desde(p: Producto): string | null {
		const t = aNumero(p.precio_tienda);
		const d = aNumero(p.precio_desde);
		if (d <= 0 || (t > 0 && d >= t)) return null;
		return quetzales(d);
	}

	/** Las ofertas de una variante, de la mas barata a la mas cara. */
	function ofertasDe(v: Variante): Oferta[] {
		return (producto?.ofertas ?? []).filter(
			(o) => Number(o.id_producto_variante_mongo) === v.id_producto_variante
		);
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

	/**
	 * Que decir del stock. Tres casos, y ahora salen de dos numeros de verdad
	 * en vez de deducirse contando variantes:
	 *
	 *   hay          stock_total > 0
	 *   sin-oferta   nadie lo vende todavia
	 *   agotado      hay vendedores, pero ninguno tiene unidades
	 *
	 * Antes stock_total se sumaba de variantes[].stock, que era OPCIONAL, y
	 * "se vendio todo" daba el mismo 0 que "nadie registro nada". Mismo
	 * criterio que el catalogo (routes/+page.svelte).
	 */
	let estadoStock = $derived.by((): 'hay' | 'sin-oferta' | 'agotado' => {
		if (producto == null) return 'sin-oferta';
		if (producto.stock_total > 0) return 'hay';
		return producto.total_ofertas === 0 ? 'sin-oferta' : 'agotado';
	});

	// ------------------------------------------------------------- al pedido
	/**
	 * Agregar una presentacion al pedido abierto, con las rutas de
	 * /comprador/pedidos (ver $lib/pedido.ts).
	 *
	 * Si todavia no hay pedido abierto se abre uno aqui mismo, con la primera
	 * direccion del usuario: obligar a ir al panel a abrirlo y volver seria
	 * perder la ficha que se estaba mirando. Sin ninguna direccion no se puede,
	 * y se dice donde se crea.
	 */
	let haySesion = $state(false);
	let cantidades = $state<Record<number, number | string | undefined>>({});
	/** El id de la variante que se esta agregando ahora mismo; 0 = ninguna. */
	let agregando = $state(0);
	let avisoPedido = $state('');
	let errorPedido = $state('');
	/**
	 * De que presentacion habla el aviso. Sin esto el mensaje salia arriba de
	 * todas, a varios cientos de pixeles del boton que se pulso: en un producto
	 * con tres presentaciones no habia forma de saber a cual contestaba.
	 */
	let varianteDelAviso = $state(0);

	async function mirarSesion() {
		const r = await pedir<unknown>('/usuario/yo');
		haySesion = r.ok;
	}

	onMount(mirarSesion);

	/** El pedido abierto, abriendo uno si hace falta. null si no se pudo. */
	async function pedidoAbierto(): Promise<string | null> {
		const guardado = leerPedidoAbierto();
		if (guardado) return guardado;

		const rDirecciones = await pedir<{ id_direccion: string }[]>('/direccion-usuario');

		// "No pude preguntar" y "no tienes ninguna" son cosas distintas, y
		// mandar a agregar una direccion cuando lo que se cayo fue el servidor
		// manda a la persona a arreglar algo que no esta roto.
		if (rDirecciones.estado === 401) {
			haySesion = false;
			errorPedido = 'Se acabo tu sesion. Vuelve a entrar para seguir.';
			return null;
		}
		if (!rDirecciones.ok || !rDirecciones.payload) {
			errorPedido =
				rDirecciones.estado === 0
					? 'No se pudo conectar con el servidor'
					: rDirecciones.mensaje;
			return null;
		}
		if (rDirecciones.payload.length === 0) {
			errorPedido =
				'Para abrir un pedido hace falta una direccion de entrega. Agrega una en tu panel.';
			return null;
		}

		const rPedido = await crearPedido(rDirecciones.payload[0].id_direccion);
		if (!rPedido.ok || !rPedido.payload) {
			errorPedido = rPedido.estado === 0 ? 'No se pudo conectar con el servidor' : rPedido.mensaje;
			return null;
		}

		guardarPedidoAbierto(rPedido.payload.id_pedido);
		return rPedido.payload.id_pedido;
	}

	/**
	 * Se agrega una OFERTA, no una variante: la misma presentacion la pueden
	 * vender varias personas a precios distintos, asi que hay que decir a
	 * cual se le compra. El backend saca el producto, la variante, el nombre
	 * y el precio de la propia oferta.
	 */
	async function alPedido(v: Variante, o: Oferta) {
		avisoPedido = '';
		errorPedido = '';
		varianteDelAviso = v.id_producto_variante;

		const escrito = cantidades[Number(o.id_oferta)];
		// El campo esta vacio casi siempre: agregar de a uno es lo normal.
		const cantidad = escrito == null || String(escrito).trim() === '' ? 1 : Number(escrito);
		if (!Number.isInteger(cantidad) || cantidad <= 0) {
			errorPedido = 'La cantidad debe ser un numero entero mayor a 0';
			return;
		}

		agregando = v.id_producto_variante;
		const idPedido = await pedidoAbierto();
		if (idPedido == null) {
			agregando = 0;
			return;
		}

		const r = await agregarLinea(idPedido, {
			id_oferta: Number(o.id_oferta),
			cantidad
		});
		agregando = 0;

		if (r.ok && r.payload) {
			avisoPedido =
				`"${v.nombre_variante}" de ${o.vendedor.usuario} queda en ${r.payload.cantidad} ` +
				`en tu pedido (le quedan ${r.payload.stock_disponible}). Se ve en tu panel.`;
			cantidades[Number(o.id_oferta)] = '';
		} else if (r.estado === 401) {
			haySesion = false;
			errorPedido = 'Se acabo tu sesion. Vuelve a entrar para seguir.';
		} else if (r.estado === 404) {
			// OJO: este 404 tiene TRES motivos posibles y solo uno de ellos es
			// del pedido (el otro es que el producto este oculto, y el otro que
			// la variante no sea de este producto). Olvidar el pedido a la
			// primera de cambio seria tirar el unico hilo que lo une a este
			// navegador -- no hay ruta para volver a encontrarlo -- por un fallo
			// que ni siquiera era suyo. Asi que primero se pregunta.
			const rPedido = await traerPedido(idPedido);
			if (pedidoCaduco(rPedido)) {
				olvidarPedidoAbierto();
				errorPedido = 'Ese pedido ya no existe. Prueba otra vez y se abre uno nuevo.';
			} else {
				errorPedido = r.mensaje;
			}
		} else {
			// El 409 trae el motivo real del backend ("no hay suficiente stock",
			// "No hay inventario para la variante N del producto M"): se cita.
			errorPedido = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
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
					{#if desde(producto)}
						<p class="desde-p">
							desde <strong>{desde(producto)}</strong> con otro vendedor
						</p>
					{/if}
					{#if producto.total_ofertas > 1}
						<p class="desde-p">{producto.total_ofertas} vendedores lo tienen</p>
					{/if}
					<p class="desc">{producto.descripcion ?? ''}</p>

					<!-- Las existencias, que es lo primero que se pregunta -->
					<div
						class="existencias"
						class:agotado={estadoStock === 'agotado'}
						class:sin-dato={estadoStock === 'sin-oferta'}
					>
						{#if estadoStock === 'sin-oferta'}
							<strong>Sin vendedores</strong>
							<span>Nadie ofrece este producto todavia</span>
						{:else if estadoStock === 'agotado'}
							<strong>Agotado</strong>
							<span>Hay vendedores, pero ninguno tiene unidades</span>
						{:else}
							<strong>{producto.stock_total}</strong>
							<span>
								{producto.stock_total === 1 ? 'unidad disponible' : 'unidades disponibles'}
								{#if producto.variantes.length > 1}
									entre sus {producto.variantes.length} presentaciones
								{/if}
							</span>
						{/if}
					</div>

					<dl class="datos">
						<div>
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
					<h2>Otros datos</h2>
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
					<!-- Las ofertas de esta presentacion, de la mas barata a la mas
					     cara. Un {@const} tiene que ser hijo directo del bloque. -->
					{@const ofertas = ofertasDe(v)}
					<article class="variante">
						<div class="cabeza-variante">
							<div>
								<h3>{v.nombre_variante}</h3>
								<p class="desc">{v.descripcion ?? ''}</p>
							</div>
						<div class="lado-variante">
								<!-- El resumen de la presentacion. El detalle por vendedor va
								     abajo, en la lista de ofertas. -->
								{#if aNumero(v.precio_tienda) > 0}
									<strong class="precio-v">{quetzales(aNumero(v.precio_tienda))}</strong>
								{:else if aNumero(v.precio_desde) > 0}
									<strong class="precio-v">{quetzales(aNumero(v.precio_desde))}</strong>
								{/if}
								{#if v.total_ofertas === 0}
									<span class="stock-v sin-dato">Sin vendedores</span>
								{:else if v.stock_total === 0}
									<span class="stock-v agotado">Agotada</span>
								{:else}
									<span class="stock-v">
										{v.stock_total}
										{v.stock_total === 1 ? 'unidad' : 'unidades'}
									</span>
								{/if}
							</div>
						</div>

						{#if agrupadas(v.caracteristicas_adicionales).length > 0}
							<dl class="ficha compacta">
								{#each agrupadas(v.caracteristicas_adicionales) as c (c.nombre)}
									<div><dt>{c.nombre}</dt><dd>{c.valor}</dd></div>
								{/each}
							</dl>
						{/if}

						<!-- Una fila por OFERTA: la misma presentacion la pueden vender
						     varias personas a precios distintos, y hay que poder elegir a
						     cual comprarle. Las trae GET /productos/:id desde PostgreSQL,
						     no del documento: precio y stock cambian en cada venta. -->
						{#if ofertas.length === 0}
							<p class="nota">Nadie vende esta presentacion todavia.</p>
						{:else}
							<ul class="ofertas">
								{#each ofertas as o (o.id_oferta)}
									<li class:tienda={o.es_tienda}>
										<div class="quien">
											<strong>{o.vendedor.nombre} {o.vendedor.apellido ?? ''}</strong>
											{#if o.es_tienda}<span class="sello">la tienda</span>{/if}
											<span class="usuario">{o.vendedor.usuario}</span>
										</div>

										<div class="cuanto">
											<strong class="precio-v">{quetzales(Number(o.precio))}</strong>
											{#if o.stock === 0}
												<span class="stock-v agotado">Agotada</span>
											{:else}
												<span class="stock-v">{o.stock} {o.stock === 1 ? 'unidad' : 'unidades'}</span>
											{/if}
										</div>

										{#if haySesion}
											<div class="al-pedido">
												<label class="oculto" for={'cant-' + o.id_oferta}>
													Cantidad de {v.nombre_variante} de {o.vendedor.usuario}
												</label>
												<input
													id={'cant-' + o.id_oferta}
													type="number"
													min="1"
													step="1"
													bind:value={cantidades[Number(o.id_oferta)]}
													placeholder="1"
													disabled={o.stock === 0}
												/>
												<button
													type="button"
													onclick={() => alPedido(v, o)}
													disabled={agregando !== 0 || o.stock === 0}
												>
													{agregando === v.id_producto_variante ? 'Agregando...' : 'Agregar'}
												</button>
											</div>
										{/if}
									</li>
								{/each}
							</ul>

							{#if !haySesion}
								<p class="nota">
									<a href="/entrar">Inicia sesion</a> para agregar al pedido.
								</p>
							{/if}

							<!-- La respuesta va pegada a la presentacion que la produjo. -->
							{#if varianteDelAviso === v.id_producto_variante && avisoPedido}
								<p class="aviso-pedido ok" role="status">{avisoPedido}</p>
							{/if}
							{#if varianteDelAviso === v.id_producto_variante && errorPedido}
								<p class="aviso-pedido malo" role="alert">{errorPedido}</p>
							{/if}
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

	/* ---------- las existencias ---------- */

	.existencias {
		display: flex;
		align-items: baseline;
		flex-wrap: wrap;
		gap: 0.5rem;
		margin-top: 1.25rem;
		padding: 0.9rem 1.1rem;
		background: var(--indigo-cl);
		border-radius: var(--r2);
	}

	.existencias strong {
		font-size: 1.9rem;
		font-weight: 500;
		line-height: 1;
		color: var(--indigo);
	}

	.existencias span {
		font-size: 0.95rem;
		color: var(--texto);
	}

	.existencias.agotado {
		background: var(--panel);
	}

	.existencias.agotado strong {
		font-size: 1.4rem;
		color: var(--rojo);
	}

	.existencias.sin-dato {
		background: var(--panel);
	}

	.existencias.sin-dato strong {
		font-size: 1.4rem;
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

	.lado-variante {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 0.25rem;
	}

	.precio-v {
		font-size: 1.05rem;
		color: var(--tinta);
		white-space: nowrap;
	}

	.stock-v {
		font-size: 0.85rem;
		color: var(--indigo);
		white-space: nowrap;
	}

	.stock-v.agotado {
		color: var(--rojo);
	}

	.stock-v.sin-dato {
		color: var(--gris-2);
	}

	/* ---------- agregar al pedido ---------- */

	/* ---------- las ofertas de una presentacion ---------- */

	.ofertas {
		margin: 10px 0 0;
		padding: 0;
		list-style: none;
		display: grid;
		gap: 6px;
	}

	.ofertas li {
		display: grid;
		grid-template-columns: 1fr auto;
		align-items: center;
		gap: 4px 1rem;
		padding: 10px 12px;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: 6px;
	}

	/* La de la tienda se marca, porque es la que se ensena en el catalogo */
	.ofertas li.tienda {
		background: var(--indigo-cl);
		border-color: var(--indigo);
	}

	.quien {
		display: flex;
		align-items: baseline;
		flex-wrap: wrap;
		gap: 6px;
		font-size: 0.9rem;
	}

	.quien .usuario {
		font-size: 0.8rem;
		color: var(--gris);
	}

	.sello {
		padding: 1px 7px;
		font-size: 0.7rem;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--blanco);
		background: var(--indigo);
		border-radius: 999px;
	}

	.cuanto {
		display: flex;
		align-items: baseline;
		gap: 10px;
		white-space: nowrap;
	}

	/* El formulario de comprar ocupa las dos columnas, debajo */
	.ofertas .al-pedido {
		grid-column: 1 / -1;
		margin-top: 4px;
	}

	@media (max-width: 560px) {
		.ofertas li {
			grid-template-columns: 1fr;
		}
	}

	.al-pedido {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.5rem;
		margin-top: 0.9rem;
		padding-top: 0.8rem;
		border-top: 1px solid var(--linea);
	}

	.al-pedido input {
		width: 5.5rem;
		padding: 0.45rem 0.6rem;
		background: var(--off);
		color: var(--tinta);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		font: inherit;
	}

	.al-pedido button {
		padding: 0.45rem 0.9rem;
		background: var(--indigo);
		color: var(--blanco);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
		font: inherit;
		font-size: 0.88rem;
		cursor: pointer;
	}

	.al-pedido button:disabled {
		opacity: 0.55;
		cursor: default;
	}

	.nota {
		flex: 1 1 14rem;
		font-size: 0.8rem;
		color: var(--gris);
	}

	/* La etiqueta existe para quien navega con lector de pantalla; en la
	   pantalla el campo ya se entiende por el boton que tiene al lado. */
	.oculto {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		overflow: hidden;
		clip: rect(0, 0, 0, 0);
		white-space: nowrap;
		border: 0;
	}

	.aviso-pedido {
		flex: 1 1 100%;
		padding: 0.6rem 0.8rem;
		margin-top: 0.2rem;
		border-radius: var(--r);
		font-size: 0.88rem;
	}

	.aviso-pedido.ok {
		background: var(--indigo-cl);
		color: var(--indigo-os);
	}

	.aviso-pedido.malo {
		background: var(--panel);
		color: var(--rojo);
		border: 1px solid var(--rojo);
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
