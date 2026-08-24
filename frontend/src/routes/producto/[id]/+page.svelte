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

	interface Variante {
		id_producto_variante: number;
		nombre_variante: string;
		precio: { $numberDecimal: string } | string | number;
		descripcion: string | null;
		estado: string;
		imagenes: string[];
		/**
		 * Unidades de ESTA variante. Opcional: una variante publicada desde el
		 * panel del vendedor sin `stock_inicial` no trae el campo, que no es lo
		 * mismo que traerlo en 0.
		 */
		stock?: number;
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
		/** La suma de variantes[].stock. La calcula el backend al responder. */
		stock_total?: number;
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

	/**
	 * Que decir del stock. Son CUATRO casos, no dos, y stock_total no los
	 * separa: el backend suma contando como 0 las variantes que no traen el
	 * campo `stock`, asi que "se vendio todo" y "nadie registro nada" dan el
	 * mismo 0.
	 *
	 *   hay          stock_total > 0
	 *   sin-dato     NINGUNA presentacion trae el campo
	 *   agotado      todas lo traen y suman 0
	 *   ninguno      mixto: unas en 0 y otras sin registrar
	 *
	 * El mixto es el que se colaba: bastaba UNA presentacion registrada en 0
	 * para dar el producto entero por inventariado y decir "Agotado", que es
	 * afirmar que se vendio lo que nunca se registro. Mismo criterio que el
	 * catalogo (routes/+page.svelte).
	 */
	let estadoStock = $derived.by((): 'hay' | 'sin-dato' | 'agotado' | 'ninguno' => {
		if (producto == null) return 'sin-dato';
		if ((producto.stock_total ?? 0) > 0) return 'hay';
		const registradas = producto.variantes.filter((v) => v.stock !== undefined).length;
		if (registradas === 0) return 'sin-dato';
		if (registradas === producto.variantes.length) return 'agotado';
		return 'ninguno';
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

	async function alPedido(v: Variante) {
		avisoPedido = '';
		errorPedido = '';
		varianteDelAviso = v.id_producto_variante;

		const escrito = cantidades[v.id_producto_variante];
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
			id_producto: id,
			id_producto_variante: v.id_producto_variante,
			cantidad
		});
		agregando = 0;

		if (r.ok && r.payload) {
			avisoPedido =
				`"${v.nombre_variante}" queda en ${r.payload.cantidad} en tu pedido ` +
				`(hay ${r.payload.stock_disponible} en existencia). Se ve en tu panel.`;
			cantidades[v.id_producto_variante] = '';
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
					<p class="desc">{producto.descripcion ?? ''}</p>

					<!-- Las existencias, que es lo primero que se pregunta -->
					<div
						class="existencias"
						class:agotado={estadoStock === 'agotado' || estadoStock === 'ninguno'}
						class:sin-dato={estadoStock === 'sin-dato'}
					>
						{#if estadoStock === 'sin-dato'}
							<strong>Sin registrar</strong>
							<span>Este producto todavia no tiene existencias cargadas</span>
						{:else if estadoStock === 'agotado'}
							<strong>Agotado</strong>
							<span>Ninguna presentacion tiene unidades</span>
						{:else if estadoStock === 'ninguno'}
							<strong>Sin unidades</strong>
							<span>
								Unas presentaciones estan agotadas y a otras nadie les ha registrado
								existencias
							</span>
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
							<div class="lado-variante">
								<strong class="precio-v">{quetzales(aNumero(v.precio))}</strong>
								{#if v.stock === undefined}
									<span class="stock-v sin-dato">Sin registrar</span>
								{:else if v.stock === 0}
									<span class="stock-v agotado">Agotada</span>
								{:else}
									<span class="stock-v">
										{v.stock}
										{v.stock === 1 ? 'unidad' : 'unidades'}
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

						<!-- Solo con sesion: /comprador/pedidos la exige (no el rol). Sin
						     ella se ensena el enlace en vez de un boton que daria 401. -->
						{#if haySesion}
							<div class="al-pedido">
								<label class="oculto" for={'cant-' + v.id_producto_variante}>
									Cantidad de {v.nombre_variante}
								</label>
								<input
									id={'cant-' + v.id_producto_variante}
									type="number"
									min="1"
									step="1"
									bind:value={cantidades[v.id_producto_variante]}
									placeholder="1"
								/>
								<button
									type="button"
									onclick={() => alPedido(v)}
									disabled={agregando !== 0}
								>
									{agregando === v.id_producto_variante ? 'Agregando...' : 'Agregar al pedido'}
								</button>
								{#if v.stock === undefined}
									<span class="nota">
										Esta presentacion todavia no tiene existencias registradas; el pedido la
										va a rechazar hasta que su vendedor se las cree.
									</span>
								{/if}

								<!-- La respuesta va pegada al boton que la produjo, no arriba de todo. -->
								{#if varianteDelAviso === v.id_producto_variante && avisoPedido}
									<p class="aviso-pedido ok" role="status">{avisoPedido}</p>
								{/if}
								{#if varianteDelAviso === v.id_producto_variante && errorPedido}
									<p class="aviso-pedido malo" role="alert">{errorPedido}</p>
								{/if}
							</div>
						{:else}
							<p class="nota">
								<a href="/entrar">Inicia sesion</a> para agregarla a un pedido.
							</p>
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
