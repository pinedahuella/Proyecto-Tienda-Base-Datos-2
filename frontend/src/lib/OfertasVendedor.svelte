<script lang="ts">
	import { onMount } from 'svelte';
	import { pedir, conJson, type RespuestaApi } from './api';

	/**
	 * Las ofertas del vendedor: verlas, editarlas y publicar una nueva.
	 *
	 * Esta pantalla reemplaza a la de inventario. En el modelo multi-vendedor
	 * el producto no es de nadie y ya no tiene precio ni stock: quien vende,
	 * a como y con cuantas unidades es una fila de `oferta`, en PostgreSQL.
	 * Las rutas viejas (`/vendedor/productos/:id/inventario`) leian la tabla
	 * `inventario`, que se borro del esquema.
	 *
	 * Las cuatro rutas que usa:
	 *   GET   /vendedor/ofertas                    las mias, en cualquier estado
	 *   GET   /vendedor/ofertas/producto/:id       un producto con sus variantes
	 *   POST  /vendedor/ofertas                    publicar
	 *   PATCH /vendedor/ofertas/:id                precio, estado y/o ajuste de stock
	 *
	 * Y una del catalogo publico, `GET /productos?nombre=`, para buscar sobre
	 * que variante publicar.
	 */

	let { alExpirarSesion }: { alExpirarSesion?: () => void } = $props();

	// ---------------------------------------------------------------- tipos
	type EstadoOferta = 'activa' | 'pausada' | 'retirada';

	/**
	 * Un precio, como llega. De PostgreSQL viene como texto y de Mongo como
	 * Decimal128; ver quetzales(), que es quien traduce las dos formas.
	 */
	type Precio = string | number | { $numberDecimal: string } | null;

	interface Oferta {
		/**
		 * Texto, no numero: es un `bigint` de PostgreSQL y el driver `pg` lo
		 * entrega como string para no perder precision. Es intencional en toda
		 * la API (ver models/direccion.ts). No pasarlo por Number(): con
		 * convertirlo aqui se pierde justo la precision que el driver cuida.
		 */
		id_oferta: string;
		/** Estos dos SI son numeros: son los `_id` de Mongo. */
		id_producto: number;
		id_producto_variante: number;
		nombre_producto: string;
		nombre_variante: string;
		imagen: string | null;
		/** Tambien texto, por lo mismo: es un decimal de PostgreSQL. */
		precio: string;
		stock: number;
		estado: EstadoOferta;
		fecha_creacion: string;
		fecha_actualizacion: string;
	}

	/** Lo que trae cada variante en GET /vendedor/ofertas/producto/:id */
	interface VarianteDelCatalogo {
		id_producto_variante: number;
		nombre_variante: string;
		imagenes?: string[];
		estado: string;
		precio_tienda: Precio;
		precio_desde: Precio;
		stock_total: number;
		total_ofertas: number;
		/**
		 * La oferta que YA tengo sobre esta variante, o null.
		 *
		 * Es lo que evita el 409: `oferta` tiene
		 * UNIQUE (id_usuario, id_producto_mongo, id_producto_variante_mongo),
		 * asi que un vendedor tiene una sola oferta por variante. En vez de
		 * dejar publicar y que el backend la rechace, la variante ya tomada se
		 * ensena deshabilitada y con lo que ya tiene.
		 */
		mi_oferta: {
			id_oferta: string;
			precio: string;
			stock: number;
			estado: EstadoOferta;
		} | null;
	}

	interface ProductoDelCatalogo {
		_id: number;
		nombre: string;
		descripcion: string | null;
		estado: string;
		categoria: { id_categoria: number; nombre: string; categoria_padre: string | null };
		variantes: VarianteDelCatalogo[];
	}

	/** Lo minimo que hace falta de un resultado de busqueda. */
	interface ProductoEnBusqueda {
		_id: number;
		nombre: string;
		categoria?: { nombre: string };
	}

	interface ProductosPaginados {
		productos: ProductoEnBusqueda[];
		siguiente_cursor: number | null;
	}

	type Vista = 'lista' | 'publicar';

	const ESTADOS: EstadoOferta[] = ['activa', 'pausada', 'retirada'];

	// ---------------------------------------------------------------- estado
	let vista = $state<Vista>('lista');
	let ofertas = $state<Oferta[]>([]);
	let cargando = $state(true);
	let error = $state('');
	let aviso = $state('');

	/** 'todas' o uno de los tres estados. La ruta trae los tres, el filtro es local. */
	let filtro = $state<'todas' | EstadoOferta>('todas');

	// la edicion de una fila
	let editando = $state<string | null>(null);
	let precioNuevo = $state('');
	let estadoNuevo = $state<EstadoOferta>('activa');
	let ajusteStock = $state('');
	let guardando = $state(false);
	let errorFila = $state('');

	// publicar
	let busqueda = $state('');
	let buscando = $state(false);
	let resultados = $state<ProductoEnBusqueda[]>([]);
	let buscoAlgunaVez = $state(false);
	let productoElegido = $state<ProductoDelCatalogo | null>(null);
	let cargandoProducto = $state(false);
	let varianteElegida = $state<number | null>(null);
	let precioNuevaOferta = $state('');
	let stockInicial = $state('');
	let publicando = $state(false);
	let errorPublicar = $state('');

	// ---------------------------------------------------------------- helpers
	/** true si la sesion se acabo. Se avisa al panel para que saque a la persona. */
	function expiro(r: RespuestaApi<unknown>): boolean {
		if (r.estado === 401) {
			alExpirarSesion?.();
			return true;
		}
		return false;
	}

	/**
	 * Un precio puede llegar de dos formas distintas en la MISMA respuesta, y
	 * hay que aguantar las dos:
	 *
	 *   "13803.00"                 lo que sale de PostgreSQL (oferta.precio,
	 *                              mi_oferta.precio): el driver `pg` entrega
	 *                              los decimales como texto.
	 *   { $numberDecimal: "..." }  lo que sale de Mongo (precio_tienda,
	 *                              precio_desde): son Decimal128, y asi los
	 *                              serializa el driver.
	 *
	 * Con solo la primera, los campos calculados del catalogo se pintaban
	 * "Q[object Object]": Number() de un objeto da NaN y el texto crudo era el
	 * objeto. Se vio en las variantes al publicar.
	 */
	function quetzales(precio: Precio): string {
		if (precio == null) return '-';
		const texto =
			typeof precio === 'object' && '$numberDecimal' in precio
				? precio.$numberDecimal
				: String(precio);
		const n = Number(texto);
		if (Number.isNaN(n)) return texto;
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}

	/**
	 * El mismo formato que valida el backend: numero > 0 con hasta 2 decimales.
	 * Se comprueba aqui tambien para no gastar una peticion en un 400 seguro.
	 */
	const FORMATO_PRECIO = /^\d+(\.\d{1,2})?$/;

	function precioValido(texto: string): boolean {
		const limpio = texto.trim();
		return FORMATO_PRECIO.test(limpio) && Number(limpio) > 0;
	}

	let listaFiltrada = $derived(
		filtro === 'todas' ? ofertas : ofertas.filter((o) => o.estado === filtro)
	);

	/** Cuantas hay de cada estado, para las pestanas. */
	let conteos = $derived({
		todas: ofertas.length,
		activa: ofertas.filter((o) => o.estado === 'activa').length,
		pausada: ofertas.filter((o) => o.estado === 'pausada').length,
		retirada: ofertas.filter((o) => o.estado === 'retirada').length
	});

	// ---------------------------------------------------------------- cargar
	async function cargar() {
		cargando = true;
		error = '';

		const r = await pedir<Oferta[]>('/vendedor/ofertas');
		if (expiro(r)) return;

		if (r.ok && r.payload) {
			ofertas = r.payload;
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
		cargando = false;
	}

	onMount(cargar);

	/**
	 * Mete la oferta que devolvio el backend en la lista, en su sitio.
	 *
	 * Se usa la que contesta el servidor y no la que se mando: el stock que
	 * queda despues de un ajuste lo calcula `reponer_stock()`, y la fecha de
	 * actualizacion la pone un trigger. Recalcularlos aqui seria adivinar.
	 */
	function guardarEnLista(o: Oferta) {
		const i = ofertas.findIndex((x) => x.id_oferta === o.id_oferta);
		if (i === -1) {
			ofertas = [o, ...ofertas];
		} else {
			ofertas[i] = o;
			ofertas = ofertas;
		}
	}

	// ---------------------------------------------------------------- editar
	function abrirEdicion(o: Oferta) {
		editando = o.id_oferta;
		precioNuevo = o.precio;
		estadoNuevo = o.estado;
		ajusteStock = '';
		errorFila = '';
		aviso = '';
	}

	function cerrarEdicion() {
		editando = null;
		errorFila = '';
	}

	/**
	 * A cuanto quedaria el stock con el ajuste escrito.
	 *
	 * Se ensena mientras se escribe porque el campo NO es el stock nuevo: es un
	 * delta con signo. Sin este renglon es facil escribir "18" queriendo dejar
	 * 18 unidades y terminar con 33. Es la trampa de esta pantalla.
	 */
	function stockResultante(o: Oferta): number | null {
		const texto = ajusteStock.trim();
		if (texto === '') return null;
		const n = Number(texto);
		if (!Number.isInteger(n) || n === 0) return null;
		return o.stock + n;
	}

	async function guardarFila(o: Oferta) {
		errorFila = '';

		const cuerpo: { precio?: string; estado?: string; ajuste_stock?: number } = {};

		const precio = precioNuevo.trim();
		if (precio !== '' && precio !== o.precio) {
			if (!precioValido(precio)) {
				errorFila = 'El precio tiene que ser un numero mayor a 0, con hasta 2 decimales';
				return;
			}
			cuerpo.precio = precio;
		}

		if (estadoNuevo !== o.estado) {
			cuerpo.estado = estadoNuevo;
		}

		const ajuste = ajusteStock.trim();
		if (ajuste !== '') {
			const n = Number(ajuste);
			if (!Number.isInteger(n) || n === 0) {
				errorFila = 'El ajuste tiene que ser un numero entero distinto de 0';
				return;
			}
			// El backend lo rechazaria con un 409 de reponer_stock(), pero
			// decirlo aqui ahorra la vuelta y explica mejor: el numero que
			// falta es el que la persona ya tiene en pantalla.
			if (o.stock + n < 0) {
				errorFila = `No se puede: la oferta tiene ${o.stock} y el ajuste la dejaria en ${o.stock + n}`;
				return;
			}
			cuerpo.ajuste_stock = n;
		}

		// La ruta exige al menos un campo. Sin esto, guardar sin cambiar nada
		// gastaria una peticion para recibir un 400 que ya se sabia.
		if (Object.keys(cuerpo).length === 0) {
			errorFila = 'No cambiaste nada';
			return;
		}

		guardando = true;
		const r = await pedir<Oferta>(`/vendedor/ofertas/${o.id_oferta}`, conJson('PATCH', cuerpo));
		guardando = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			guardarEnLista(r.payload);
			editando = null;
			aviso = `"${r.payload.nombre_producto} - ${r.payload.nombre_variante}" actualizada`;
		} else {
			errorFila = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	/**
	 * Pausar o reactivar sin abrir el formulario: es el cambio mas frecuente y
	 * no necesita escribir nada.
	 */
	async function cambiarEstado(o: Oferta, estado: EstadoOferta) {
		aviso = '';
		error = '';
		guardando = true;
		const r = await pedir<Oferta>(`/vendedor/ofertas/${o.id_oferta}`, conJson('PATCH', { estado }));
		guardando = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			guardarEnLista(r.payload);
			aviso = `"${r.payload.nombre_producto} - ${r.payload.nombre_variante}" quedo ${estado}`;
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	// ---------------------------------------------------------------- publicar
	function abrirPublicar() {
		vista = 'publicar';
		busqueda = '';
		resultados = [];
		buscoAlgunaVez = false;
		productoElegido = null;
		varianteElegida = null;
		precioNuevaOferta = '';
		stockInicial = '';
		errorPublicar = '';
		aviso = '';
	}

	async function buscar(evento?: Event) {
		evento?.preventDefault();
		const texto = busqueda.trim();
		if (texto === '') return;

		buscando = true;
		errorPublicar = '';
		productoElegido = null;
		varianteElegida = null;

		const r = await pedir<ProductosPaginados>(
			`/productos?nombre=${encodeURIComponent(texto)}&limite=10`
		);
		buscando = false;
		buscoAlgunaVez = true;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			resultados = r.payload.productos ?? [];
		} else {
			resultados = [];
			errorPublicar = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	async function elegirProducto(id: number) {
		cargandoProducto = true;
		errorPublicar = '';
		varianteElegida = null;

		const r = await pedir<ProductoDelCatalogo>(`/vendedor/ofertas/producto/${id}`);
		cargandoProducto = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			productoElegido = r.payload;
		} else {
			productoElegido = null;
			errorPublicar = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	async function publicar() {
		errorPublicar = '';

		if (productoElegido == null || varianteElegida == null) {
			errorPublicar = 'Elegi una variante';
			return;
		}

		const precio = precioNuevaOferta.trim();
		if (!precioValido(precio)) {
			errorPublicar = 'El precio tiene que ser un numero mayor a 0, con hasta 2 decimales';
			return;
		}

		const cuerpo: {
			id_producto: number;
			id_producto_variante: number;
			precio: string;
			stock_inicial?: number;
		} = {
			id_producto: productoElegido._id,
			id_producto_variante: varianteElegida,
			precio
		};

		const stock = stockInicial.trim();
		if (stock !== '') {
			const n = Number(stock);
			if (!Number.isInteger(n) || n < 0) {
				errorPublicar = 'El stock inicial tiene que ser un numero entero mayor o igual a 0';
				return;
			}
			cuerpo.stock_inicial = n;
		}

		publicando = true;
		const r = await pedir<Oferta>('/vendedor/ofertas', conJson('POST', cuerpo));
		publicando = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			guardarEnLista(r.payload);
			aviso = `Publicaste "${r.payload.nombre_producto} - ${r.payload.nombre_variante}" a ${quetzales(r.payload.precio)}`;
			vista = 'lista';
			filtro = 'todas';
		} else {
			errorPublicar = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	/** La variante ya tomada no se puede elegir: seria un 409 seguro. */
	function seleccionable(v: VarianteDelCatalogo): boolean {
		return v.mi_oferta == null;
	}

	/**
	 * Los id de las ofertas cuya portada no cargo. Ver el comentario del <img>.
	 *
	 * Va como arreglo reasignado y no como Set mutado: un Set normal no es
	 * reactivo en Svelte 5, asi que agregarle un id no volveria a pintar nada.
	 */
	let rotas = $state<string[]>([]);

	function marcarRota(id: string) {
		if (!rotas.includes(id)) rotas = [...rotas, id];
	}
</script>

<section class="ofertas">
	<div class="titulo">
		<div>
			<h2>{vista === 'lista' ? 'Mis ofertas' : 'Publicar una oferta'}</h2>
			<p class="sub">
				{#if vista === 'lista'}
					Lo que vendes, a que precio y con cuantas unidades. El producto es del catalogo
					compartido; la oferta es tuya.
				{:else}
					Busca una variante que ya este en el catalogo y ponle tu precio. Crear el producto
					mismo es solo de la tienda.
				{/if}
			</p>
		</div>

		{#if vista === 'lista'}
			<button type="button" class="principal" onclick={abrirPublicar}>Publicar una oferta</button>
		{:else}
			<button type="button" onclick={() => (vista = 'lista')}>Volver a mis ofertas</button>
		{/if}
	</div>

	{#if aviso}
		<p class="hecho" role="status">{aviso}</p>
	{/if}

	{#if vista === 'lista'}
		{#if cargando}
			<p class="quieto">Cargando tus ofertas...</p>
		{:else if error}
			<p class="malo" role="alert">{error}</p>
			<button type="button" class="enlace" onclick={cargar}>Reintentar</button>
		{:else if ofertas.length === 0}
			<p class="quieto">
				Todavia no tienes ofertas. Publica una sobre cualquier variante del catalogo.
			</p>
		{:else}
			<div class="pestanas">
				{#each ['todas', ...ESTADOS] as const as e}
					<button
						type="button"
						class="pestana"
						class:elegida={filtro === e}
						onclick={() => (filtro = e)}
					>
						{e === 'todas' ? 'Todas' : e[0].toUpperCase() + e.slice(1) + 's'}
						<span class="cuenta">{conteos[e]}</span>
					</button>
				{/each}
			</div>

			{#if listaFiltrada.length === 0}
				<p class="quieto">Ninguna oferta {filtro}.</p>
			{:else}
				<div class="tabla">
					{#each listaFiltrada as o (o.id_oferta)}
						<article class="fila">
							<!-- Las portadas son URL de fuera (el conjunto de datos usa
							     Wikimedia). Si una no carga, el navegador deja el icono de
							     imagen rota, que se ve peor que no poner nada: se cambia por
							     el hueco gris, igual que una variante sin foto.

							     El fallo se guarda en `rotas` y no con classList: Svelte borra
							     del bundle los selectores que no ve en el markup, asi que una
							     clase puesta desde JS se queda sin CSS y en silencio. -->
							{#if o.imagen && !rotas.includes(o.id_oferta)}
								<img
									class="mini"
									src={o.imagen}
									alt=""
									loading="lazy"
									onerror={() => marcarRota(o.id_oferta)}
								/>
							{:else}
								<div class="mini vacia" aria-hidden="true"></div>
							{/if}

							<div class="datos">
								<h3>{o.nombre_producto}</h3>
								<p class="menor">{o.nombre_variante}</p>
								<span
									class="chip"
									class:activo={o.estado === 'activa'}
									class:inactivo={o.estado === 'retirada'}>{o.estado}</span
								>
							</div>

							<div class="numeros">
								<strong class="precio">{quetzales(o.precio)}</strong>
								<span class="menor">{o.stock} unidades</span>
							</div>

							<div class="acciones">
								{#if o.estado === 'activa'}
									<button type="button" onclick={() => cambiarEstado(o, 'pausada')} disabled={guardando}>
										Pausar
									</button>
								{:else}
									<button type="button" onclick={() => cambiarEstado(o, 'activa')} disabled={guardando}>
										Activar
									</button>
								{/if}
								<button
									type="button"
									class="principal"
									onclick={() => (editando === o.id_oferta ? cerrarEdicion() : abrirEdicion(o))}
								>
									{editando === o.id_oferta ? 'Cerrar' : 'Editar'}
								</button>
							</div>

							{#if editando === o.id_oferta}
								<div class="edicion">
									<div class="campos">
										<label>
											Precio
											<input type="text" inputmode="decimal" bind:value={precioNuevo} placeholder={o.precio} />
										</label>

										<label>
											Estado
											<select bind:value={estadoNuevo}>
												{#each ESTADOS as e}
													<option value={e}>{e}</option>
												{/each}
											</select>
										</label>

										<label>
											Ajuste de existencias
											<input type="text" inputmode="numeric" bind:value={ajusteStock} placeholder="+5 o -2" />
										</label>
									</div>

									<!-- El campo del stock es un DELTA, no el total. Sin decirlo, "18"
									     se lee como "dejalo en 18" y termina sumando 18 a lo que habia. -->
									<p class="menor nota">
										El ajuste se suma o se resta a lo que ya hay, no lo reemplaza: escribe
										<code>+5</code> para reponer y <code>-2</code> para corregir a la baja. Cada
										ajuste queda escrito en el kardex.
										{#if stockResultante(o) !== null}
											<!-- Un resultante negativo se pinta como lo que es: un
											     ajuste que no se va a poder guardar. Con el mismo
											     color que uno valido, "15 → -84" se leia como un
											     resultado normal. -->
											<strong class="resultante" class:imposible={stockResultante(o)! < 0}>
												{o.stock} → {stockResultante(o)} unidades
												{#if stockResultante(o)! < 0}· no se puede bajar de 0{/if}
											</strong>
										{/if}
									</p>

									{#if errorFila}
										<p class="malo" role="alert">{errorFila}</p>
									{/if}

									<div class="acciones">
										<button
											type="button"
											class="principal"
											onclick={() => guardarFila(o)}
											disabled={guardando}
										>
											{guardando ? 'Guardando...' : 'Guardar cambios'}
										</button>
										<button type="button" onclick={cerrarEdicion} disabled={guardando}>Cancelar</button>
									</div>
								</div>
							{/if}
						</article>
					{/each}
				</div>
			{/if}
		{/if}
	{:else}
		<!-- ------------------------------------------------------ publicar -->
		<form class="buscador" onsubmit={buscar}>
			<label class="ancho">
				Busca el producto
				<input type="search" bind:value={busqueda} placeholder="Laptop, camisa, audifonos..." />
			</label>
			<button type="submit" class="principal" disabled={buscando || busqueda.trim() === ''}>
				{buscando ? 'Buscando...' : 'Buscar'}
			</button>
		</form>

		{#if errorPublicar && productoElegido == null}
			<p class="malo" role="alert">{errorPublicar}</p>
		{/if}

		{#if buscando}
			<p class="quieto">Buscando en el catalogo...</p>
		{:else if buscoAlgunaVez && resultados.length === 0 && !errorPublicar}
			<p class="quieto">Ningun producto se llama asi. Prueba con otra palabra.</p>
		{:else if resultados.length > 0}
			<div class="resultados">
				{#each resultados as p (p._id)}
					<button
						type="button"
						class="resultado"
						class:elegido={productoElegido?._id === p._id}
						onclick={() => elegirProducto(p._id)}
					>
						<span class="nombre">{p.nombre}</span>
						{#if p.categoria?.nombre}
							<span class="menor">{p.categoria.nombre}</span>
						{/if}
					</button>
				{/each}
			</div>
		{/if}

		{#if cargandoProducto}
			<p class="quieto">Cargando las variantes...</p>
		{:else if productoElegido}
			<div class="variantes">
				<h3>{productoElegido.nombre}</h3>
				<p class="sub">Elige la variante sobre la que quieres publicar.</p>

				{#each productoElegido.variantes as v (v.id_producto_variante)}
					{@const tomada = !seleccionable(v)}
					<label class="variante" class:tomada class:elegida={varianteElegida === v.id_producto_variante}>
						<input
							type="radio"
							name="variante"
							value={v.id_producto_variante}
							disabled={tomada}
							bind:group={varianteElegida}
						/>
						<span class="datos">
							<strong>{v.nombre_variante}</strong>
							<span class="menor">
								{#if v.total_ofertas > 0}
									{v.total_ofertas}
									{v.total_ofertas === 1 ? 'vendedor la ofrece' : 'vendedores la ofrecen'}
									{#if v.precio_desde}· desde {quetzales(v.precio_desde)}{/if}
								{:else}
									Nadie la ofrece todavia
								{/if}
							</span>
						</span>

						<!-- No se puede tener dos ofertas sobre la misma variante
						     (el UNIQUE de `oferta`), asi que en vez de dejar
						     intentarlo y devolver un 409, se dice que ya es tuya. -->
						{#if tomada && v.mi_oferta}
							<span class="chip">ya la ofreces · {quetzales(v.mi_oferta.precio)}</span>
						{/if}
					</label>
				{/each}

				{#if varianteElegida !== null}
					<div class="campos sep">
						<label>
							Tu precio
							<input
								type="text"
								inputmode="decimal"
								bind:value={precioNuevaOferta}
								placeholder="3950.00"
							/>
						</label>
						<label>
							Unidades iniciales
							<input type="text" inputmode="numeric" bind:value={stockInicial} placeholder="0" />
						</label>
					</div>

					<p class="menor nota">
						La oferta nace activa. Las unidades iniciales entran como una reposicion en el
						kardex, no sueltas: por eso cada unidad tiene de donde salir.
					</p>

					{#if errorPublicar}
						<p class="malo" role="alert">{errorPublicar}</p>
					{/if}

					<div class="acciones">
						<button type="button" class="principal" onclick={publicar} disabled={publicando}>
							{publicando ? 'Publicando...' : 'Publicar la oferta'}
						</button>
						<button type="button" onclick={() => (vista = 'lista')} disabled={publicando}>
							Cancelar
						</button>
					</div>
				{/if}
			</div>
		{/if}
	{/if}
</section>

<style>
	.ofertas {
		margin-top: 2rem;
	}

	.titulo {
		display: flex;
		align-items: flex-end;
		justify-content: space-between;
		gap: 1rem;
		margin-bottom: 1.25rem;
	}

	h2 {
		font-size: 1.5rem;
	}

	h3 {
		font-size: 1.08rem;
		margin-bottom: 0.5rem;
	}

	.sub,
	.menor {
		font-size: 0.9rem;
		color: var(--gris);
	}

	.sep {
		margin-top: 0.9rem;
	}

	.quieto {
		color: var(--gris);
		padding: 1.5rem 0;
	}

	.malo {
		color: var(--rojo);
		margin: 0.5rem 0;
	}

	.hecho {
		color: var(--indigo);
		background: var(--indigo-cl);
		padding: 0.6rem 0.9rem;
		border-radius: var(--r2);
		margin-bottom: 1rem;
	}

	/* ---------- pestanas por estado ---------- */

	.pestanas {
		display: flex;
		flex-wrap: wrap;
		gap: 0.4rem;
		margin-bottom: 1rem;
	}

	.pestana {
		display: inline-flex;
		align-items: center;
		gap: 0.4rem;
		padding: 0.35rem 0.85rem;
		font-size: 0.9rem;
		background: transparent;
		border: 1px solid var(--linea);
		border-radius: 999px;
	}

	.pestana.elegida {
		background: var(--indigo-cl);
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.cuenta {
		font-size: 0.78rem;
		color: var(--gris);
	}

	.pestana.elegida .cuenta {
		color: var(--indigo);
	}

	/* ---------- la lista ---------- */

	.tabla {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	.fila {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 1rem;
		padding: 1rem 1.1rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.mini {
		width: 48px;
		height: 48px;
		object-fit: cover;
		border-radius: var(--r2);
		background: var(--panel);
	}

	.mini.vacia {
		background: var(--panel);
	}

	/* Que el nombre ocupe el hueco sobrante, para que el precio no quede
	   flotando a medio camino de su boton. */
	.fila .datos {
		flex: 1;
		min-width: 0;
	}

	.fila h3 {
		margin: 0 0 0.15rem;
		font-size: 1.02rem;
	}

	.numeros {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 0.15rem;
	}

	.precio {
		font-size: 1.05rem;
	}

	.chip {
		display: inline-block;
		padding: 2px 10px;
		font-size: 0.75rem;
		letter-spacing: 0.03em;
		text-transform: uppercase;
		border-radius: 999px;
		background: var(--panel);
		color: var(--gris);
	}

	.chip.activo {
		background: var(--indigo-cl);
		color: var(--indigo);
	}

	.chip.inactivo {
		background: var(--panel);
		color: var(--rojo);
	}

	.acciones {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}

	/* ---------- editar una fila ---------- */

	/* Ocupa el ancho entero de la fila: se abre debajo, no al lado. */
	.edicion {
		flex-basis: 100%;
		border-top: 1px solid var(--linea);
		padding-top: 0.9rem;
	}

	.campos {
		display: flex;
		flex-wrap: wrap;
		gap: 0.75rem;
	}

	.campos label,
	.ancho {
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
		font-size: 0.9rem;
		color: var(--gris);
	}

	.campos input,
	.campos select {
		min-width: 9rem;
	}

	.nota {
		margin: 0.7rem 0;
	}

	.nota code {
		background: var(--panel);
		padding: 0 4px;
		border-radius: 4px;
	}

	.resultante {
		display: block;
		margin-top: 0.3rem;
		color: var(--indigo);
	}

	.resultante.imposible {
		color: var(--rojo);
	}

	/* ---------- publicar ---------- */

	.buscador {
		display: flex;
		align-items: flex-end;
		gap: 0.75rem;
		margin-bottom: 1rem;
	}

	.buscador .ancho {
		flex: 1;
	}

	.resultados {
		display: flex;
		flex-direction: column;
		gap: 0.4rem;
		margin-bottom: 1.25rem;
	}

	.resultado {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 1rem;
		padding: 0.7rem 0.9rem;
		text-align: left;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.resultado.elegido {
		border-color: var(--indigo);
		background: var(--indigo-cl);
	}

	.variantes {
		padding: 1.1rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.variante {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		padding: 0.65rem 0.2rem;
		border-bottom: 1px solid var(--linea);
	}

	.variante .datos {
		display: flex;
		flex-direction: column;
		flex: 1;
		min-width: 0;
	}

	.variante.elegida {
		color: var(--indigo);
	}

	/* La ya ofertada se ensena, apagada: saber que ya es tuya es informacion,
	   esconderla haria pensar que la variante no existe. */
	.variante.tomada {
		opacity: 0.55;
	}
</style>
