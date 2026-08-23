<script lang="ts">
	import { onMount } from 'svelte';
	import { pedir, conJson, type RespuestaApi } from './api';

	/**
	 * El panel del vendedor: sus productos, publicar uno nuevo, editarlo y ver
	 * como estaba en una fecha.
	 *
	 * Las cuatro rutas que usa (todas piden sesion de vendedor):
	 *   GET   /vendedor/categorias        las categorias donde SI se puede publicar
	 *   GET   /vendedor/categorias/:id    que caracteristicas ofrece esa categoria
	 *   GET   /vendedor/productos         los propios, en cualquier estado
	 *   POST  /vendedor/productos         crear
	 *   PATCH /vendedor/productos/:id     editar
	 *   GET   /vendedor/productos/:id/historial?fecha=  como estaba ese dia
	 *
	 * El formulario no tiene campos fijos: los pinta la categoria. Cada
	 * caracteristica trae su tipo_dato y de ahi sale el control (texto, numero,
	 * si/no, lista) y la validacion que hara el backend.
	 */

	let { alExpirarSesion }: { alExpirarSesion?: () => void } = $props();

	// ---------------------------------------------------------------- tipos
	interface CategoriaBreve {
		id_categoria: number;
		nombre: string;
		categoria_padre: string | null;
	}

	interface DefinicionCaracteristica {
		nombre: string;
		unidad: string | null;
		tipo_dato: 'texto' | 'entero' | 'decimal' | 'booleano' | 'lista';
	}

	interface CategoriaCompleta extends CategoriaBreve {
		caracteristicas: DefinicionCaracteristica[];
		caracteristicas_variante: DefinicionCaracteristica[];
	}

	interface CaracteristicaGuardada {
		nombre: string;
		valor: string | number | boolean | string[];
		unidad?: string | null;
	}

	interface VarianteGuardada {
		id_producto_variante?: number;
		nombre_variante: string;
		precio: { $numberDecimal: string } | string | number;
		descripcion: string | null;
		estado?: string;
		imagenes?: string[];
		caracteristicas_adicionales?: CaracteristicaGuardada[];
		caracteristicas_personalizadas?: CaracteristicaGuardada[];
	}

	interface ProductoGuardado {
		_id: number;
		nombre: string;
		descripcion: string | null;
		estado: string;
		fecha_creacion: string;
		categoria: { id_categoria: number; nombre: string; categoria_padre: string | null };
		variantes: VarianteGuardada[];
		caracteristicas_adicionales?: CaracteristicaGuardada[];
		caracteristicas_personalizadas?: CaracteristicaGuardada[];
	}

	/** Lo que el formulario tiene en pantalla: todo texto, hasta que se envia. */
	interface VarianteEnForma {
		nombre_variante: string;
		precio: string;
		descripcion: string;
		imagenes: string;
		valores: Record<string, unknown>;
		propias: { nombre: string; valor: string }[];
	}

	type Vista = 'lista' | 'forma' | 'historial';

	// ---------------------------------------------------------------- estado
	let vista = $state<Vista>('lista');
	let mios = $state<ProductoGuardado[]>([]);
	let categorias = $state<CategoriaBreve[]>([]);
	let cargando = $state(true);
	let error = $state('');
	let aviso = $state('');

	// el formulario
	let editando = $state<number | null>(null);
	let idCategoria = $state('');
	let paleta = $state<CategoriaCompleta | null>(null);
	let cargandoPaleta = $state(false);
	let nombre = $state('');
	let descripcion = $state('');
	let estado = $state('borrador');
	let valores = $state<Record<string, unknown>>({});
	let propias = $state<{ nombre: string; valor: string }[]>([]);
	let variantes = $state<VarianteEnForma[]>([varianteVacia()]);
	let guardando = $state(false);
	let errorForma = $state('');

	// el historial
	let productoHistorial = $state<ProductoGuardado | null>(null);
	let fechaHistorial = $state('');
	let reconstruido = $state<ProductoGuardado | null>(null);
	let errorHistorial = $state('');
	let buscandoHistorial = $state(false);

	function varianteVacia(): VarianteEnForma {
		return {
			nombre_variante: '',
			precio: '',
			descripcion: '',
			imagenes: '',
			valores: {},
			propias: []
		};
	}

	// ---------------------------------------------------------------- cargar
	/** true si la sesion se acabo. Se avisa al panel para que saque a la persona. */
	function expiro(r: RespuestaApi<unknown>): boolean {
		if (r.estado === 401) {
			alExpirarSesion?.();
			return true;
		}
		return false;
	}

	async function cargar() {
		cargando = true;
		error = '';

		const [rProductos, rCategorias] = await Promise.all([
			pedir<ProductoGuardado[]>('/vendedor/productos'),
			pedir<CategoriaBreve[]>('/vendedor/categorias')
		]);

		if (expiro(rProductos) || expiro(rCategorias)) return;

		if (rProductos.ok && rProductos.payload) {
			mios = rProductos.payload;
		} else {
			error = rProductos.estado === 0 ? 'No se pudo conectar con el servidor' : rProductos.mensaje;
		}
		if (rCategorias.ok && rCategorias.payload) {
			categorias = rCategorias.payload;
		}
		cargando = false;
	}

	// Al montar y nada mas: con $effect se repetia sola.
	onMount(cargar);

	/** Al elegir categoria se pide su menu de caracteristicas: son los campos. */
	async function traerPaleta(id: string, conservarValores = false) {
		paleta = null;
		if (!id) return;
		cargandoPaleta = true;
		const r = await pedir<CategoriaCompleta>(`/vendedor/categorias/${id}`);
		if (expiro(r)) return;
		if (r.ok && r.payload) {
			paleta = r.payload;
			if (!conservarValores) {
				valores = {};
				variantes = variantes.map((v) => ({ ...v, valores: {} }));
			}
		} else if (r.estado === 404 && conservarValores) {
			// Pasa con los productos que quedaron colgados de una categoria raiz:
			// el backend no deja publicar ahi, asi que no devuelve su menu de
			// caracteristicas. El 404 pelado no explica nada, y hay que decir
			// que se puede hacer.
			idCategoria = '';
			errorForma =
				'Este producto esta en una categoria raiz, y ahi no se puede publicar. ' +
				'Elegi una subcategoria arriba para poder editarlo.';
		} else {
			errorForma = r.mensaje;
		}
		cargandoPaleta = false;
	}

	// ---------------------------------------------------------------- abrir el formulario
	function nuevo() {
		editando = null;
		idCategoria = '';
		paleta = null;
		nombre = '';
		descripcion = '';
		estado = 'borrador';
		valores = {};
		propias = [];
		variantes = [varianteVacia()];
		errorForma = '';
		aviso = '';
		vista = 'forma';
	}

	/** Pasa lo guardado a texto, que es lo que el formulario maneja. */
	function aTexto(valor: CaracteristicaGuardada['valor']): string {
		if (Array.isArray(valor)) return valor.join('\n');
		if (typeof valor === 'boolean') return valor ? 'true' : 'false';
		return String(valor);
	}

	/** Varias entradas con el mismo nombre son una lista: se juntan. */
	function aMapa(lista: CaracteristicaGuardada[] | undefined): Record<string, unknown> {
		const mapa: Record<string, string> = {};
		for (const c of lista ?? []) {
			const texto = aTexto(c.valor);
			mapa[c.nombre] = mapa[c.nombre] ? mapa[c.nombre] + '\n' + texto : texto;
		}
		return mapa;
	}

	function precioTexto(precio: VarianteGuardada['precio']): string {
		if (typeof precio === 'number') return precio.toFixed(2);
		if (typeof precio === 'string') return precio;
		return precio?.$numberDecimal ?? '';
	}

	async function editar(p: ProductoGuardado) {
		editando = p._id;
		idCategoria = String(p.categoria.id_categoria);
		nombre = p.nombre;
		descripcion = p.descripcion ?? '';
		estado = p.estado;
		valores = aMapa(p.caracteristicas_adicionales);
		propias = (p.caracteristicas_personalizadas ?? []).map((c) => ({
			nombre: c.nombre,
			valor: aTexto(c.valor)
		}));
		variantes = p.variantes.map((v) => ({
			nombre_variante: v.nombre_variante,
			precio: precioTexto(v.precio),
			descripcion: v.descripcion ?? '',
			imagenes: (v.imagenes ?? []).join('\n'),
			valores: aMapa(v.caracteristicas_adicionales),
			propias: (v.caracteristicas_personalizadas ?? []).map((c) => ({
				nombre: c.nombre,
				valor: aTexto(c.valor)
			}))
		}));
		errorForma = '';
		aviso = '';
		vista = 'forma';
		await traerPaleta(idCategoria, true);
	}

	// ---------------------------------------------------------------- armar el envio
	/**
	 * Convierte lo escrito al tipo que el backend espera. Devuelve undefined
	 * cuando el campo se dejo vacio: una caracteristica sin valor no se manda,
	 * no se manda vacia.
	 */
	function convertir(def: DefinicionCaracteristica, crudo: unknown) {
		// Ojo: no siempre llega texto. En un <input type="number">, bind:value
		// guarda un NUMERO, asi que llamarle .trim() revienta. Se normaliza a
		// texto antes de mirar nada.
		const texto = String(crudo ?? '').trim();
		if (texto === '') return undefined;

		if (def.tipo_dato === 'entero' || def.tipo_dato === 'decimal') {
			const n = Number(texto);
			if (Number.isNaN(n)) throw new Error(`"${def.nombre}" tiene que ser un numero`);
			if (def.tipo_dato === 'entero' && !Number.isInteger(n)) {
				throw new Error(`"${def.nombre}" tiene que ser un numero entero`);
			}
			return n;
		}
		if (def.tipo_dato === 'booleano') return texto === 'true';
		if (def.tipo_dato === 'lista') {
			const partes = texto
				.split('\n')
				.map((x) => x.trim())
				.filter((x) => x !== '');
			return partes.length > 0 ? partes : undefined;
		}
		return texto;
	}

	function caracteristicasDe(defs: DefinicionCaracteristica[], mapa: Record<string, unknown>) {
		const salida: { nombre: string; valor: unknown }[] = [];
		for (const def of defs) {
			const valor = convertir(def, mapa[def.nombre] ?? '');
			if (valor !== undefined) salida.push({ nombre: def.nombre, valor });
		}
		return salida;
	}

	/** Las personalizadas van sueltas: texto, numero o si/no, nunca una lista. */
	function propiasDe(lista: { nombre: string; valor: string }[]) {
		const salida: { nombre: string; valor: string | number | boolean }[] = [];
		for (const c of lista) {
			const n = String(c.nombre ?? '').trim();
			const v = String(c.valor ?? '').trim();
			if (n === '' || v === '') continue;
			if (v === 'true' || v === 'false') salida.push({ nombre: n, valor: v === 'true' });
			else if (/^-?\d+(\.\d+)?$/.test(v)) salida.push({ nombre: n, valor: Number(v) });
			else salida.push({ nombre: n, valor: v });
		}
		return salida;
	}

	function cuerpoDelFormulario() {
		if (!paleta) throw new Error('Elegi una categoria');

		const variantesEnvio = variantes.map((v) => {
			const cuerpo: Record<string, unknown> = {
				nombre_variante: v.nombre_variante.trim(),
				precio: v.precio.trim(),
				descripcion: v.descripcion.trim(),
				imagenes: v.imagenes
					.split('\n')
					.map((x) => x.trim())
					.filter((x) => x !== '')
			};
			const suyas = caracteristicasDe(paleta!.caracteristicas_variante, v.valores);
			if (suyas.length > 0) cuerpo.caracteristicas_adicionales = suyas;
			const libres = propiasDe(v.propias);
			if (libres.length > 0) cuerpo.caracteristicas_personalizadas = libres;
			return cuerpo;
		});

		return {
			id_categoria: Number(idCategoria),
			nombre: nombre.trim(),
			descripcion: descripcion.trim() === '' ? null : descripcion.trim(),
			caracteristicas_adicionales: caracteristicasDe(paleta.caracteristicas, valores),
			caracteristicas_personalizadas: propiasDe(propias),
			variantes: variantesEnvio
		};
	}

	async function guardar() {
		errorForma = '';
		let cuerpo: ReturnType<typeof cuerpoDelFormulario>;
		try {
			cuerpo = cuerpoDelFormulario();
		} catch (fallo) {
			errorForma = (fallo as Error).message;
			return;
		}

		// Lo minimo que el backend exige, comprobado aqui para no ir y volver
		if (!cuerpo.id_categoria) return (errorForma = 'Elegi una categoria');
		if (!cuerpo.nombre) return (errorForma = 'El nombre del producto es obligatorio');
		if (cuerpo.variantes.length === 0) return (errorForma = 'Agrega al menos una variante');
		for (const v of cuerpo.variantes) {
			if (!v.nombre_variante) return (errorForma = 'Cada variante necesita un nombre');
			if (!v.descripcion) return (errorForma = 'Cada variante necesita una descripcion');
			if (!/^\d+(\.\d{1,2})?$/.test(String(v.precio)) || Number(v.precio) <= 0) {
				return (errorForma = 'El precio debe ser un numero mayor a 0, con hasta 2 decimales');
			}
		}

		guardando = true;
		const r =
			editando === null
				? await pedir<ProductoGuardado>('/vendedor/productos', conJson('POST', cuerpo))
				: await pedir<ProductoGuardado>(
						`/vendedor/productos/${editando}`,
						conJson('PATCH', { ...cuerpo, estado })
					);
		guardando = false;

		if (expiro(r)) return;
		if (r.ok) {
			aviso = editando === null ? 'Producto creado' : 'Producto actualizado';
			vista = 'lista';
			await cargar();
		} else {
			errorForma = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	/** Publicar o retirar sin abrir el formulario entero. */
	async function cambiarEstado(p: ProductoGuardado, nuevoEstado: string) {
		aviso = '';
		error = '';
		const r = await pedir<ProductoGuardado>(
			`/vendedor/productos/${p._id}`,
			conJson('PATCH', { estado: nuevoEstado })
		);
		if (expiro(r)) return;
		if (r.ok) {
			aviso = `"${p.nombre}" ahora esta en ${nuevoEstado}`;
			await cargar();
		} else {
			error = r.mensaje;
		}
	}

	// ---------------------------------------------------------------- historial
	function abrirHistorial(p: ProductoGuardado) {
		productoHistorial = p;
		reconstruido = null;
		errorHistorial = '';
		fechaHistorial = new Date().toISOString().slice(0, 10);
		vista = 'historial';
	}

	async function reconstruir() {
		if (!productoHistorial) return;
		buscandoHistorial = true;
		errorHistorial = '';
		reconstruido = null;
		const r = await pedir<ProductoGuardado>(
			`/vendedor/productos/${productoHistorial._id}/historial?fecha=${fechaHistorial}`
		);
		buscandoHistorial = false;
		if (expiro(r)) return;
		if (r.ok && r.payload) reconstruido = r.payload;
		else errorHistorial = r.mensaje;
	}

	// ---------------------------------------------------------------- ayudas de pantalla
	function quetzales(v: VarianteGuardada['precio']): string {
		const n = Number(typeof v === 'object' ? v?.$numberDecimal : v);
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2 });
	}

	function rango(p: ProductoGuardado): string {
		const ns = p.variantes.map((v) => Number(typeof v.precio === 'object' ? v.precio?.$numberDecimal : v.precio));
		if (ns.length === 0) return '—';
		const min = Math.min(...ns);
		const max = Math.max(...ns);
		return min === max ? quetzales(min) : `${quetzales(min)} - ${quetzales(max)}`;
	}

	function fecha(iso: string): string {
		return new Date(iso).toLocaleDateString('es-GT', { day: 'numeric', month: 'short', year: 'numeric' });
	}

	let defsProducto = $derived(paleta?.caracteristicas ?? []);
	let defsVariante = $derived(paleta?.caracteristicas_variante ?? []);
</script>

<section class="panel">
	<div class="titulo">
		<div>
			<h2>Mis productos</h2>
			<p class="sub">
				{#if vista === 'lista'}
					{mios.length}
					{mios.length === 1 ? 'producto publicado o en borrador' : 'productos publicados o en borrador'}
				{:else if vista === 'forma'}
					{editando === null ? 'Publicar un producto nuevo' : 'Editando el producto ' + editando}
				{:else}
					Como estaba en una fecha
				{/if}
			</p>
		</div>

		{#if vista === 'lista'}
			<button type="button" class="principal" onclick={nuevo}>Publicar producto</button>
		{:else}
			<button type="button" class="secundario" onclick={() => ((vista = 'lista'), (aviso = '')) }>
				Volver a la lista
			</button>
		{/if}
	</div>

	{#if aviso}
		<p class="ok" role="status">{aviso}</p>
	{/if}
	{#if error}
		<p class="malo" role="alert">{error}</p>
	{/if}

	<!-- ══════════════════════════════ LISTA ══════════════════════════════ -->
	{#if vista === 'lista'}
		{#if cargando}
			<p class="quieto">Cargando tus productos...</p>
		{:else if mios.length === 0}
			<p class="quieto">Todavia no has publicado nada. Empeza con el boton de arriba.</p>
		{:else}
			<div class="tabla">
				{#each mios as p (p._id)}
					<article class="fila">
						<div class="datos">
							<span class="chip {p.estado}">{p.estado}</span>
							<h3>{p.nombre}</h3>
							<p class="menor">
								{p.categoria.nombre} · {p.variantes.length}
								{p.variantes.length === 1 ? 'variante' : 'variantes'} · {rango(p)} · {fecha(p.fecha_creacion)}
							</p>
						</div>

						<div class="acciones">
							{#if p.estado !== 'activo'}
								<button type="button" onclick={() => cambiarEstado(p, 'activo')}>Publicar</button>
							{:else}
								<button type="button" onclick={() => cambiarEstado(p, 'inactivo')}>Retirar</button>
							{/if}
							<button type="button" onclick={() => editar(p)}>Editar</button>
							<button type="button" onclick={() => abrirHistorial(p)}>Historial</button>
						</div>
					</article>
				{/each}
			</div>
		{/if}

		<!-- ══════════════════════════════ FORMULARIO ══════════════════════ -->
	{:else if vista === 'forma'}
		<div class="forma">
			<div class="bloque">
				<h3>Lo basico</h3>

				<div class="campo">
					<label for="v-cat">Categoria</label>
					<select
						id="v-cat"
						bind:value={idCategoria}
						onchange={() => traerPaleta(idCategoria)}
					>
						<option value="">Elegi una...</option>
						{#each categorias as c (c.id_categoria)}
							<option value={String(c.id_categoria)}>
								{c.categoria_padre ? c.categoria_padre + ' > ' : ''}{c.nombre}
							</option>
						{/each}
					</select>
					<small>Los campos de abajo dependen de esto: cada categoria pregunta lo suyo.</small>
				</div>

				<div class="campo">
					<label for="v-nom">Nombre del producto</label>
					<input id="v-nom" type="text" maxlength="200" bind:value={nombre} />
				</div>

				<div class="campo">
					<label for="v-desc">Descripcion</label>
					<textarea id="v-desc" rows="2" bind:value={descripcion}></textarea>
				</div>

				{#if editando !== null}
					<div class="campo">
						<label for="v-estado">Estado</label>
						<select id="v-estado" bind:value={estado}>
							<option value="borrador">borrador (no se ve en la tienda)</option>
							<option value="activo">activo (visible)</option>
							<option value="inactivo">inactivo (retirado)</option>
						</select>
					</div>
				{:else}
					<p class="menor">Nace en borrador. Se publica desde la lista o editandolo.</p>
				{/if}
			</div>

			{#if cargandoPaleta}
				<p class="quieto">Cargando lo que pide esta categoria...</p>
			{:else if paleta}
				<div class="bloque">
					<h3>Caracteristicas del producto</h3>
					<p class="menor">
						{defsProducto.length} que ofrece {paleta.nombre}. Llena solo las que apliquen: las vacias
						no se guardan.
					</p>

					<div at-rejilla class="rejilla">
						{#each defsProducto as def (def.nombre)}
							<div class="campo">
								<label for={'p-' + def.nombre}>
									{def.nombre}
									{#if def.unidad}<span class="unidad">({def.unidad})</span>{/if}
								</label>

								{#if def.tipo_dato === 'booleano'}
									<select id={'p-' + def.nombre} bind:value={valores[def.nombre]}>
										<option value="">Sin responder</option>
										<option value="true">Si</option>
										<option value="false">No</option>
									</select>
								{:else if def.tipo_dato === 'lista'}
									<textarea
										id={'p-' + def.nombre}
										rows="2"
										placeholder="Uno por linea"
										bind:value={valores[def.nombre]}
									></textarea>
								{:else if def.tipo_dato === 'entero' || def.tipo_dato === 'decimal'}
									<input
										id={'p-' + def.nombre}
										type="number"
										step={def.tipo_dato === 'entero' ? '1' : 'any'}
										bind:value={valores[def.nombre]}
									/>
								{:else}
									<input id={'p-' + def.nombre} type="text" bind:value={valores[def.nombre]} />
								{/if}
							</div>
						{/each}
					</div>
				</div>

				<div class="bloque">
					<h3>Caracteristicas propias</h3>
					<p class="menor">
						Las que no estan en el catalogo. Nombre y un valor suelto, nunca una lista. No se puede
						filtrar por ellas en la tienda.
					</p>

					{#each propias as _, i (i)}
						<div class="par">
							<input type="text" placeholder="Nombre" bind:value={propias[i].nombre} />
							<input type="text" placeholder="Valor" bind:value={propias[i].valor} />
							<button type="button" class="quitar" onclick={() => (propias = propias.filter((_, j) => j !== i))}>
								Quitar
							</button>
						</div>
					{/each}
					<button type="button" class="secundario" onclick={() => (propias = [...propias, { nombre: '', valor: '' }])}>
						Agregar una
					</button>
				</div>

				<div class="bloque">
					<h3>Variantes</h3>
					<p class="menor">
						Lo que de verdad se compra: una talla, un color, una capacidad. El precio vive aqui, por
						eso hace falta al menos una.
					</p>

					{#each variantes as _, i (i)}
						<div class="variante">
							<div class="cabeza">
								<strong>Variante {i + 1}</strong>
								{#if variantes.length > 1}
									<button
										type="button"
										class="quitar"
										onclick={() => (variantes = variantes.filter((_, j) => j !== i))}
									>
										Quitar
									</button>
								{/if}
							</div>

							<div class="rejilla">
								<div class="campo">
									<label for={'vn-' + i}>Nombre</label>
									<input id={'vn-' + i} type="text" bind:value={variantes[i].nombre_variante} />
								</div>
								<div class="campo">
									<label for={'vp-' + i}>Precio (Q)</label>
									<input id={'vp-' + i} type="text" placeholder="169.00" bind:value={variantes[i].precio} />
								</div>
								<div class="campo ancho">
									<label for={'vd-' + i}>Descripcion</label>
									<input id={'vd-' + i} type="text" bind:value={variantes[i].descripcion} />
								</div>
								<div class="campo ancho">
									<label for={'vi-' + i}>Imagenes</label>
									<textarea id={'vi-' + i} rows="2" placeholder="Una URL por linea" bind:value={variantes[i].imagenes}
									></textarea>
								</div>
							</div>

							{#if defsVariante.length > 0}
								<p class="menor sep">Lo que distingue a esta variante</p>
								<div class="rejilla">
									{#each defsVariante as def (def.nombre)}
										<div class="campo">
											<label for={'vc-' + i + '-' + def.nombre}>
												{def.nombre}
												{#if def.unidad}<span class="unidad">({def.unidad})</span>{/if}
											</label>

											{#if def.tipo_dato === 'booleano'}
												<select id={'vc-' + i + '-' + def.nombre} bind:value={variantes[i].valores[def.nombre]}>
													<option value="">Sin responder</option>
													<option value="true">Si</option>
													<option value="false">No</option>
												</select>
											{:else if def.tipo_dato === 'lista'}
												<textarea
													id={'vc-' + i + '-' + def.nombre}
													rows="2"
													placeholder="Uno por linea"
													bind:value={variantes[i].valores[def.nombre]}
												></textarea>
											{:else if def.tipo_dato === 'entero' || def.tipo_dato === 'decimal'}
												<input
													id={'vc-' + i + '-' + def.nombre}
													type="number"
													step={def.tipo_dato === 'entero' ? '1' : 'any'}
													bind:value={variantes[i].valores[def.nombre]}
												/>
											{:else}
												<input
													id={'vc-' + i + '-' + def.nombre}
													type="text"
													bind:value={variantes[i].valores[def.nombre]}
												/>
											{/if}
										</div>
									{/each}
								</div>
							{/if}
						</div>
					{/each}

					<button type="button" class="secundario" onclick={() => (variantes = [...variantes, varianteVacia()])}>
						Agregar otra variante
					</button>
				</div>

				{#if errorForma}
					<p class="malo" role="alert">{errorForma}</p>
				{/if}

				<div class="final">
					<button type="button" class="principal" onclick={guardar} disabled={guardando}>
						{guardando ? 'Guardando...' : editando === null ? 'Crear producto' : 'Guardar cambios'}
					</button>
					<button type="button" class="secundario" onclick={() => (vista = 'lista')}>Cancelar</button>
				</div>
			{:else}
				<p class="quieto">Elegi una categoria para ver que hay que llenar.</p>
			{/if}
		</div>

		<!-- ══════════════════════════════ HISTORIAL ══════════════════════ -->
	{:else if vista === 'historial' && productoHistorial}
		<div class="bloque">
			<h3>{productoHistorial.nombre}</h3>
			<p class="menor">
				Se reconstruye juntando el evento de creacion y las modificaciones anteriores a la fecha que
				elijas. Las caracteristicas no tienen historial: se ven las de hoy.
			</p>

			<div class="par">
				<input type="date" bind:value={fechaHistorial} />
				<button type="button" class="principal" onclick={reconstruir} disabled={buscandoHistorial}>
					{buscandoHistorial ? 'Buscando...' : 'Ver como estaba'}
				</button>
			</div>

			{#if errorHistorial}
				<p class="malo" role="alert">{errorHistorial}</p>
			{/if}

			{#if reconstruido}
				<div class="resultado">
					<p><strong>{reconstruido.nombre}</strong></p>
					<p class="menor">{reconstruido.descripcion ?? ''}</p>
					<p class="menor">Estado ese dia: {reconstruido.estado ?? '—'}</p>
					<ul>
						{#each reconstruido.variantes ?? [] as v (v.id_producto_variante)}
							<li>{v.nombre_variante} — {quetzales(v.precio)}</li>
						{/each}
					</ul>
				</div>
			{/if}
		</div>
	{/if}
</section>

<style>
	.panel {
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

	.unidad {
		color: var(--gris-2);
	}

	/* ---------- lista ---------- */

	.tabla {
		display: flex;
		flex-direction: column;
		gap: 0.75rem;
	}

	.fila {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		padding: 1rem 1.1rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.fila h3 {
		margin: 0.2rem 0 0.15rem;
		font-size: 1.02rem;
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

	.acciones {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
	}

	/* ---------- formulario ---------- */

	.bloque {
		padding: 1.25rem;
		margin-bottom: 1.25rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.rejilla {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(230px, 1fr));
		gap: 0.9rem;
		margin-top: 0.9rem;
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
		margin-bottom: 0.9rem;
	}

	.campo.ancho {
		grid-column: 1 / -1;
	}

	.rejilla .campo {
		margin-bottom: 0;
	}

	label {
		font-size: 0.85rem;
		color: var(--gris);
	}

	small {
		font-size: 0.82rem;
		color: var(--gris-2);
	}

	input,
	select,
	textarea {
		width: 100%;
		padding: 9px 11px;
		font-family: inherit;
		font-size: 0.95rem;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		resize: vertical;
		transition: border-color var(--t);
	}

	input:focus,
	select:focus,
	textarea:focus {
		outline: none;
		border-color: var(--indigo);
	}

	.par {
		display: flex;
		gap: 0.6rem;
		margin-bottom: 0.6rem;
	}

	.variante {
		padding: 1rem;
		margin-bottom: 1rem;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.cabeza {
		display: flex;
		align-items: center;
		justify-content: space-between;
	}

	.final {
		display: flex;
		gap: 0.75rem;
		margin-top: 0.5rem;
	}

	/* ---------- botones ---------- */

	button {
		padding: 9px 18px;
		font-family: inherit;
		font-size: 0.92rem;
		border-radius: 999px;
		cursor: pointer;
		transition:
			border-color var(--t),
			background var(--t),
			color var(--t);
	}

	.principal {
		color: var(--blanco);
		background: var(--indigo);
		border: 1px solid var(--indigo);
	}

	.principal:hover:not(:disabled) {
		background: var(--indigo-os);
	}

	.principal:disabled {
		opacity: 0.6;
		cursor: default;
	}

	.secundario,
	.acciones button {
		color: var(--texto);
		background: var(--blanco);
		border: 1px solid var(--linea);
	}

	.secundario:hover,
	.acciones button:hover {
		color: var(--indigo);
		border-color: var(--indigo);
		background: var(--indigo-cl);
	}

	.quitar {
		padding: 6px 12px;
		font-size: 0.85rem;
		color: var(--rojo);
		background: none;
		border: 1px solid var(--linea);
	}

	.quitar:hover {
		border-color: var(--rojo);
	}

	/* ---------- avisos ---------- */

	.quieto {
		padding: 2rem 0;
		color: var(--gris);
	}

	.ok {
		padding: 10px 14px;
		margin-bottom: 1rem;
		color: var(--indigo);
		background: var(--indigo-cl);
		border-radius: var(--r);
	}

	.malo {
		padding: 10px 14px;
		margin: 0.75rem 0;
		color: var(--rojo);
		background: var(--blanco);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	.resultado {
		margin-top: 1rem;
		padding: 1rem;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.resultado ul {
		margin: 0.5rem 0 0 1.1rem;
		font-size: 0.92rem;
	}

	@media (max-width: 620px) {
		.fila {
			flex-direction: column;
			align-items: flex-start;
		}
		.titulo {
			flex-direction: column;
			align-items: flex-start;
		}
	}
</style>
