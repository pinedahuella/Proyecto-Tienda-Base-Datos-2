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

	/**
	 * `modo` decide para quien es este panel, y son los dos unicos usos:
	 *
	 *   'catalogo'  la tienda o un admin administrando el catalogo compartido:
	 *               la lista paginada, el alta, la edicion y el historial.
	 *   'propuesta' un vendedor normal proponiendo un producto: SOLO el
	 *               formulario, que se manda a otra ruta y nace `en_revision`.
	 *
	 * Va como modo y no como componente aparte porque el formulario es el MISMO:
	 * los cuatro campos fijos, las variantes y las dos tandas de caracteristicas
	 * que pinta la categoria. Duplicarlo eran setecientas lineas que se irian
	 * separando con el primer cambio que alguien hiciera en una sola de las dos.
	 */
	let {
		alExpirarSesion,
		modo = 'catalogo'
	}: { alExpirarSesion?: () => void; modo?: 'catalogo' | 'propuesta' } = $props();

	let proponiendo = $derived(modo === 'propuesta');

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

	/** Un precio como llega: de Mongo viene envuelto en Decimal128. */
	type Precio = { $numberDecimal: string } | string | number | null | undefined;

	interface VarianteGuardada {
		id_producto_variante?: number;
		nombre_variante: string;
		/**
		 * Una variante NO tiene un precio: tiene tantos como vendedores, y
		 * cada uno vive en su fila de `oferta`, en PostgreSQL.
		 *
		 * Lo que el documento guarda son dos numeros CALCULADOS: el de la
		 * tienda (el que se ensena en el catalogo) y el mas barato de
		 * cualquier vendedor. Los dos pueden ser null: una variante recien
		 * creada todavia no tiene ninguna oferta encima.
		 *
		 * Antes aqui se declaraba `precio` a secas, que es como se llamaba
		 * antes del modelo multi-vendedor. Ese campo ya no llega en NINGUN
		 * producto -- medido: 0 de 102 -- asi que `Number(v.precio)` daba
		 * NaN y la lista entera salia con "QNaN - QNaN" donde va el precio.
		 */
		precio_tienda?: Precio;
		precio_desde?: Precio;
		descripcion: string | null;
		estado?: string;
		imagenes?: string[];
		/**
		 * Existencias, tambien calculadas: las de la tienda y las de todos
		 * los vendedores activos sumadas. Como los precios, pueden faltar.
		 *
		 * (Antes aqui se declaraba `stock` a secas, con una nota sobre una
		 * `PROYECCION_SIN_STOCK` del backend que ya no existe.)
		 */
		stock_tienda?: number;
		stock_total?: number;
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
		/**
		 * El id que YA tenia esta variante, cuando se esta editando.
		 *
		 * Mandarlo no es un detalle: es lo que le dice al backend "esta es la
		 * misma variante, editada". Sin el, el backend le asigna un id nuevo,
		 * y las ofertas de PostgreSQL -- que apuntan a la variante por
		 * `id_producto_variante_mongo` -- se quedan apuntando a un id que ya
		 * no existe en el documento. Undefined solo en las de verdad nuevas.
		 */
		id_producto_variante?: number;
		nombre_variante: string;
		descripcion: string;
		imagenes: string;
		valores: Record<string, unknown>;
		propias: { nombre: string; valor: string }[];
	}

	type Vista = 'lista' | 'forma' | 'historial';

	// ---------------------------------------------------------------- estado
	// Arranca en 'lista' y el modo la corrige en onMount. Es `$state` y no
	// `$derived` porque la vista cambia navegando dentro del panel: si siguiera a
	// la prop, no se podria salir de ella.
	let vista = $state<Vista>('lista');
	let mios = $state<ProductoGuardado[]>([]);

	// ------------------------------------------------- la paginacion
	/**
	 * Se pagina en el SERVIDOR, con `GET /vendedor/productos/paginado`.
	 *
	 * Esa ruta la agrego el backend a proposito para este panel, y es la unica
	 * que sirve: `GET /vendedor/productos` trae los tres estados pero entero
	 * (191 KB, 789 ms medido), y la publica `GET /productos/paginacion` si
	 * pagina pero fuerza `estado: 'activo'` como lista blanca, asi que dejaria
	 * fuera justo los borradores que este panel existe para administrar.
	 *
	 * Medido con la ruta nueva: 32 KB y 234 ms la primera pagina de 20, contra
	 * 191 KB y 789 ms de traerlo todo. Y el filtro por nombre tambien viaja,
	 * asi que buscar mira los 105 y no solo lo que estuviera descargado.
	 */
	const POR_PAGINA = 20;

	let pagina = $state(1);
	let totalProductos = $state(0);
	let totalPaginas = $state(0);
	let busqueda = $state('');

	/** Lo que hay escrito en la caja y todavia no se ha pedido. */
	let temporizadorBusqueda: ReturnType<typeof setTimeout> | null = null;

	function alBuscar() {
		if (temporizadorBusqueda) clearTimeout(temporizadorBusqueda);
		// 300 ms: lo mismo que el buscador de ofertas, y la ruta contesta en
		// 40-70 ms con filtro, asi que no hace falta esperar mas.
		temporizadorBusqueda = setTimeout(() => void irAPagina(1), 300);
	}

	async function irAPagina(n: number) {
		pagina = n;
		await cargar();
	}
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

	/** Lo que devuelve GET /productos/ofertas/:id/historial?fecha= */
	interface OfertaEnFecha {
		id_oferta: string;
		/** numeric(12,2) de PostgreSQL: llega como texto. */
		precio: string;
		stock: number;
	}

	/** Lo minimo de GET /vendedor/ofertas/producto/:id: de ahi sale el id_oferta. */
	interface VarianteConOferta {
		id_producto_variante: number;
		mi_oferta: { id_oferta: string } | null;
	}

	/**
	 * El precio y el stock de la oferta de la tienda ese dia, por variante.
	 * Vacio mientras no se hayan podido resolver.
	 */
	let ofertaEnFecha = $state<Record<number, OfertaEnFecha>>({});
	let errorHistorial = $state('');
	let buscandoHistorial = $state(false);

	function varianteVacia(): VarianteEnForma {
		return {
			nombre_variante: '',
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

	interface PaginaDeProductos {
		productos: ProductoGuardado[];
		pagina: number;
		limite: number;
		total_productos: number;
		total_paginas: number;
	}

	/**
	 * Solo las categorias, para el modo propuesta.
	 *
	 * `cargar()` las pide junto con la lista paginada, y esa lista devuelve 404 a
	 * un vendedor normal. Aqui se pide lo unico que el formulario necesita.
	 */
	async function cargarCategorias() {
		if (categorias.length > 0) return;

		const r = await pedir<CategoriaBreve[]>('/vendedor/categorias');
		if (expiro(r)) return;

		if (r.ok && r.payload) {
			categorias = r.payload;
		} else {
			// Por el mismo motivo que en cambiarEstado: guardar un producto que
			// paso a `en_revision` en otra pestana devuelve el mismo texto con
			// la ruta y el verbo HTTP dentro.
			errorForma =
				r.estado === 0
					? 'No se pudo conectar con el servidor'
					: mensajeParaPersona(r.mensaje);
		}
	}

	async function cargar() {
		cargando = true;
		error = '';

		const partes = [`pagina=${pagina}`, `limite=${POR_PAGINA}`];
		const texto = busqueda.trim();
		if (texto !== '') partes.push(`nombre=${encodeURIComponent(texto)}`);

		// Las categorias solo la primera vez: son 17 y no cambian entre
		// paginas. Pedirlas en cada salto seria gastar por gusto.
		const pedirCategorias = categorias.length === 0;

		const [rProductos, rCategorias] = await Promise.all([
			pedir<PaginaDeProductos>(`/vendedor/productos/paginado?${partes.join('&')}`),
			pedirCategorias
				? pedir<CategoriaBreve[]>('/vendedor/categorias')
				: Promise.resolve(null)
		]);

		if (expiro(rProductos) || (rCategorias != null && expiro(rCategorias))) {
			cargando = false;
			return;
		}

		if (rProductos.ok && rProductos.payload) {
			mios = rProductos.payload.productos ?? [];
			totalProductos = rProductos.payload.total_productos;
			totalPaginas = rProductos.payload.total_paginas;
			pagina = rProductos.payload.pagina;
		} else {
			error = rProductos.estado === 0 ? 'No se pudo conectar con el servidor' : rProductos.mensaje;
		}
		if (rCategorias?.ok && rCategorias.payload) {
			categorias = rCategorias.payload;
		}
		cargando = false;
	}

	// Al montar y nada mas: con $effect se repetia sola.
	// Solo la tienda carga la lista. Un vendedor normal recibiria el 404
	// deliberado de `/vendedor/productos` y el panel abriria con ese error.
	onMount(() => {
		// Proponiendo no hay lista que ver: `GET /vendedor/productos` responde 404
		// a un vendedor normal a proposito, asi que se entra directo al formulario
		// y no se pide nada que vaya a fallar.
		if (proponiendo) {
			// El formulario no puede pintarse sin las categorias: son el primer
			// campo y de ellas cuelgan las caracteristicas. `cargar()` las traia
			// de paso, asi que aqui hay que pedirlas aparte.
			nuevo();
			cargarCategorias();
		} else {
			cargar();
		}
	});

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
			// Se conserva el id, o el backend la trata como una variante nueva y
			// las ofertas quedan apuntando a un id que ya no existe. Ver el
			// comentario de VarianteEnForma.
			id_producto_variante: v.id_producto_variante,
			nombre_variante: v.nombre_variante,
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
	 * Lo que hay en un campo, siempre como texto listo para comparar y convertir.
	 *
	 * Hace falta porque en un `<input type="number">` bind:value guarda un
	 * NUMERO, no texto: llamarle .trim() directo revienta con "is not a
	 * function" dentro del manejador del boton, y el clic se queda sin hacer
	 * nada y sin un solo aviso en pantalla. Paso de verdad al probarlo.
	 */
	function texto(valor: unknown): string {
		return valor == null ? '' : String(valor).trim();
	}

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
			// Sin precio ni stock_inicial: `VarianteCreacionPeticion` no los
			// tiene y el servicio del backend no los lee. Se mandaban igual y
			// se descartaban en silencio, pero el formulario NO dejaba enviar
			// sin escribir un precio -- pedia un dato que no se guardaba en
			// ninguna parte.
			const cuerpo: Record<string, unknown> = {
				nombre_variante: v.nombre_variante.trim(),
				descripcion: v.descripcion.trim(),
				imagenes: v.imagenes
					.split('\n')
					.map((x) => x.trim())
					.filter((x) => x !== '')
			};

			// Si ya existia, se manda su id para que siga siendo LA MISMA
			// variante y las ofertas que le apuntan sigan valiendo.
			if (v.id_producto_variante != null) {
				cuerpo.id_producto_variante = v.id_producto_variante;
			}

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
		}

		guardando = true;
		// El cuerpo es el mismo; lo unico que cambia es a donde va. Proponiendo
		// nunca se edita: una propuesta se corrige reenviandola, no editandola.
		const r = proponiendo
			? await pedir<ProductoGuardado>('/vendedor/productos/propuestas', conJson('POST', cuerpo))
			: editando === null
				? await pedir<ProductoGuardado>('/vendedor/productos', conJson('POST', cuerpo))
				: await pedir<ProductoGuardado>(
						`/vendedor/productos/${editando}`,
						conJson('PATCH', { ...cuerpo, estado })
					);
		guardando = false;

		if (expiro(r)) return;
		if (r.ok) {
			// Un producto nace SIN ninguna oferta: publicarlo lo pone en el
			// catalogo, pero todavia no lo vende nadie ni tiene precio. Se
			// dice, porque si no la fila nueva aparece con "sin ofertas" y
			// parece que algo fallo.
			//
			// Aqui habia un aviso sobre variantes "sin existencias" y un boton
			// para llevarlas a la pantalla de inventario. Esa pantalla y sus
			// cinco rutas ya no existen: el stock se maneja por la oferta.
			const creado = r.payload;

			if (proponiendo) {
				// Proponiendo NO se vuelve a la lista ni se recarga: la lista es
				// `/vendedor/productos`, que a un vendedor normal le contesta 404 a
				// proposito, y ese 404 salia pintado como error justo debajo del
				// aviso de exito. Se queda en el formulario, limpio para la
				// siguiente.
				const texto =
					`"${creado?.nombre ?? 'El producto'}" quedo enviado a revision. ` +
					`Cuando la tienda lo apruebe vas a poder ofertarlo, y mientras tanto ` +
					`lo seguis en "Mis propuestas al catalogo".`;
				// `nuevo()` limpia el formulario Y el aviso, asi que el mensaje se
				// pone DESPUES: al reves se borraba solo y parecia que no habia
				// pasado nada.
				nuevo();
				aviso = texto;
				return;
			}

			aviso =
				editando === null
					? `Producto creado con el id ${creado?._id ?? ''}. Todavia no tiene ofertas: ` +
						`ponle precio y existencias desde "Mis ofertas".`
					: 'Producto actualizado';
			vista = 'lista';
			await cargar();
		} else {
			// Por el mismo motivo que en cambiarEstado: guardar un producto que
			// paso a `en_revision` en otra pestana devuelve el mismo texto con
			// la ruta y el verbo HTTP dentro.
			errorForma =
				r.estado === 0
					? 'No se pudo conectar con el servidor'
					: mensajeParaPersona(r.mensaje);
		}
	}

	/** Publicar o retirar sin abrir el formulario entero. */
	/**
	 * Los dos estados del flujo de propuesta.
	 *
	 * Se resuelven aprobando o rechazando la propuesta, no editando el
	 * producto: `PATCH /vendedor/productos/:id` los rechaza a proposito.
	 */
	const ESTADOS_EN_PROPUESTA = ['en_revision', 'rechazado'];

	function enPropuesta(p: ProductoGuardado): boolean {
		return ESTADOS_EN_PROPUESTA.includes(p.estado);
	}

	/**
	 * Traduce el mensaje del backend cuando habla en lenguaje de API.
	 *
	 * Es una red por debajo, no el arreglo: el arreglo es no ofrecer el boton
	 * (ver la fila del listado). Pero el mismo rechazo puede llegar por otro
	 * camino -- dos pestanas abiertas y la propuesta resuelta en la otra -- y
	 * un mensaje que dice "usa PATCH /vendedor/productos/:id/revision" delante
	 * de quien administra el catalogo no es un error suyo que pueda corregir:
	 * es una nota para quien programa.
	 *
	 * Se compara por el texto porque el backend contesta 409 para varias cosas
	 * distintas y no manda un codigo propio; si algun dia lo manda, esto se
	 * cambia por ese codigo.
	 */
	function mensajeParaPersona(texto: string): string {
		if (texto.includes('flujo de propuesta')) {
			return 'Este producto todavia es una propuesta. Se resuelve en "Productos por revisar", con Aprobar o Rechazar.';
		}
		return texto;
	}

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
			error = mensajeParaPersona(r.mensaje);
			// Si el rechazo fue por el flujo de propuesta, la lista que se tiene
			// en pantalla ya no es la de verdad: se recarga para que el boton
			// que no debia estar ahi desaparezca solo.
			if (r.mensaje.includes('flujo de propuesta')) await cargar();
		}
	}

	// ---------------------------------------------------------------- historial
	function abrirHistorial(p: ProductoGuardado) {
		productoHistorial = p;
		reconstruido = null;
		aviso = '';
		errorHistorial = '';
		fechaHistorial = new Date().toISOString().slice(0, 10);
		vista = 'historial';
	}

	async function reconstruir() {
		if (!productoHistorial) return;
		buscandoHistorial = true;
		errorHistorial = '';
		reconstruido = null;
		ofertaEnFecha = {};

		const r = await pedir<ProductoGuardado>(
			`/vendedor/productos/${productoHistorial._id}/historial?fecha=${fechaHistorial}`
		);
		buscandoHistorial = false;
		if (expiro(r)) return;

		if (r.ok && r.payload) {
			reconstruido = r.payload;
			// El producto reconstruido no trae precio ni existencias, y no puede:
			// los eventos del catalogo no los guardan porque son de la oferta.
			// Se piden aparte, del otro lado.
			void reconstruirOfertas(productoHistorial._id);
		} else {
			errorHistorial = r.mensaje;
		}
	}

	/**
	 * El precio y las existencias que tenia CADA presentacion ese dia.
	 *
	 * Es lo que completa la consulta que pide la entrega: "el estado de un
	 * producto en un punto anterior del tiempo (precio, descripcion y
	 * disponibilidad)". La descripcion y la categoria salen de los eventos de
	 * MongoDB; el precio y el stock no pueden salir de ahi, porque al volverse
	 * multi-vendedor dejaron de ser del producto -- hay uno por vendedor, y su
	 * historia vive en `precio_historial` y `stock_movimiento`, en PostgreSQL.
	 *
	 * Dos pasos, con las rutas que ya existen:
	 *   1. GET /vendedor/ofertas/producto/:id   da el id_oferta de cada variante
	 *   2. GET /productos/ofertas/:idOferta/historial?fecha=   precio y stock de ese dia
	 *
	 * Una peticion por variante. Son dos o tres por producto y pesan 1 KB, asi
	 * que no vale la pena complicarlo; si un producto tuviera veinte, aqui es
	 * donde habria que agruparlas.
	 *
	 * Si algo de esto falla no se pinta ningun error rojo: la reconstruccion
	 * del producto -- que es lo que se vino a ver -- ya esta en pantalla, y
	 * tumbarla por no poder adornarla con el precio seria peor. Cada renglon
	 * que no se pudo resolver simplemente no ensena precio.
	 */
	async function reconstruirOfertas(idProducto: number) {
		const rOfertas = await pedir<{ variantes: VarianteConOferta[] }>(
			`/vendedor/ofertas/producto/${idProducto}`
		);
		if (!rOfertas.ok || !rOfertas.payload) return;

		const conOferta = rOfertas.payload.variantes.filter((v) => v.mi_oferta != null);

		const resueltas = await Promise.all(
			conOferta.map(async (v) => {
				const r = await pedir<OfertaEnFecha>(
					`/productos/ofertas/${v.mi_oferta!.id_oferta}/historial?fecha=${fechaHistorial}`
				);
				return r.ok && r.payload
					? ([v.id_producto_variante, r.payload] as const)
					: null;
			})
		);

		const mapa: Record<number, OfertaEnFecha> = {};
		for (const par of resueltas) {
			if (par) mapa[par[0]] = par[1];
		}
		ofertaEnFecha = mapa;
	}

	// ---------------------------------------------------------------- ayudas de pantalla
	/**
	 * Un precio a numero, o null si no hay.
	 *
	 * Devolver null y no NaN es lo importante: NaN se cuela por las
	 * operaciones sin quejarse y termina impreso como "QNaN", que es
	 * exactamente lo que pasaba antes en las 102 filas de la lista.
	 */
	function numero(v: Precio): number | null {
		if (v == null) return null;
		const n = Number(typeof v === 'object' ? v.$numberDecimal : v);
		return Number.isFinite(n) ? n : null;
	}

	function quetzales(v: Precio): string {
		const n = numero(v);
		if (n === null) return '—';
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2 });
	}

	/**
	 * El rango de precios de un producto, tomando de cada variante el de la
	 * tienda y, si esa variante no la vende la tienda, el mas barato que
	 * haya.
	 *
	 * Un producto recien creado no tiene ninguna oferta todavia, asi que no
	 * tiene precio: se dice, en vez de inventar un cero.
	 */
	function rango(p: ProductoGuardado): string {
		const ns = p.variantes
			.map((v) => numero(v.precio_tienda) ?? numero(v.precio_desde))
			.filter((n): n is number => n !== null);
		if (ns.length === 0) return 'sin ofertas';
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
			<!-- "El catalogo", no "Mis productos": el producto es compartido y no
			     es de nadie. Esta pantalla es la administracion del catalogo
			     entero, y por eso solo la abre la cuenta de la tienda. -->
			<h2>{proponiendo ? 'Proponer un producto' : 'El catalogo'}</h2>
			<p class="sub">
				{#if proponiendo}
					El catalogo es compartido: si lo que vendes no esta, propone la entrada y la tienda
					la revisa. Una vez aprobada, cualquiera puede ofertarla, tambien vos.
				{:else if vista === 'lista' && (cargando || error)}
					<!-- Ni "0 productos" ni ningun otro numero mientras no se sepa:
					     con la lista sin cargar, "0 productos en el catalogo" es una
					     afirmacion falsa puesta al lado del error que dice que no se
					     pudo cargar. Las dos frases se contradecian en pantalla. -->
					El catalogo compartido
				{:else if vista === 'lista' && busqueda.trim() !== ''}
					<!-- Con un filtro puesto, `totalProductos` es el de la BUSQUEDA.
					     Decir "0 productos en el catalogo" teniendo 105 era mentir
					     dos veces: ni son 0 ni es el catalogo lo que se conto. -->
					{totalProductos}
					{totalProductos === 1 ? 'producto encontrado' : 'productos encontrados'}
				{:else if vista === 'lista'}
					{totalProductos}
					{totalProductos === 1 ? 'producto en el catalogo' : 'productos en el catalogo'}
				{:else if vista === 'forma'}
					{editando === null ? 'Publicar un producto nuevo' : 'Editando el producto ' + editando}
				{:else}
					Como estaba en una fecha
				{/if}
			</p>
		</div>

		{#if proponiendo}
			<!-- Proponiendo no hay lista a la que volver: el formulario ES la
			     pantalla. Se ofrece empezar de nuevo, que es lo unico que hace
			     falta despues de mandar una. -->
			<button type="button" class="secundario" onclick={() => (nuevo(), (aviso = ''))}>
				Empezar otra
			</button>
		{:else if vista === 'lista'}
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
		<button type="button" class="enlace" onclick={cargar}>Reintentar</button>
	{/if}

	<!-- ══════════════════════════════ LISTA ══════════════════════════════ -->
	{#if vista === 'lista'}
		{#if cargando}
			<p class="quieto">Cargando el catalogo...</p>
		{:else if error}
			<!-- Nada mas. El error ya esta arriba, con su boton de reintentar.
			     Antes aqui caia igualmente "Todavia no has publicado nada", asi
			     que la pantalla decia a la vez que fallo la carga y que el
			     catalogo esta vacio -- y lo segundo no se sabe. -->
		{:else}
			<!--
				El buscador va FUERA de la comprobacion de lista vacia.

				Antes estaba dentro del {:else}, asi que una busqueda sin
				resultados se llevaba por delante la propia caja de busqueda:
				la pantalla decia "El catalogo esta vacio, publica el primer
				producto" -- tres mentiras seguidas, porque hay 105, no esta
				vacio, y no habia ni como borrar lo escrito para volver.

				Se esconde solo cuando de verdad no hay nada QUE buscar: catalogo
				vacio y sin texto escrito.
			-->
			{#if mios.length > 0 || busqueda.trim() !== ''}
				<label class="buscar">
					<span class="visualmente-oculto">Buscar en el catalogo</span>
					<input
						type="search"
						bind:value={busqueda}
						oninput={alBuscar}
						autocomplete="off"
						placeholder="Buscar por nombre"
					/>
				</label>
			{/if}

			{#if mios.length === 0 && busqueda.trim() !== ''}
				<p class="quieto">
					Ningun producto del catalogo se llama <strong>"{busqueda.trim()}"</strong>.
					<button
						type="button"
						class="enlace"
						onclick={() => {
							busqueda = '';
							void irAPagina(1);
						}}
					>
						Ver todos otra vez
					</button>
				</p>
			{:else if mios.length === 0}
				<p class="quieto">
					El catalogo esta vacio. Publica el primer producto con el boton de arriba.
				</p>
			{/if}

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

						<!--
							Un producto del flujo de propuesta NO se publica ni se edita
							por aqui: el backend rechaza `PATCH /vendedor/productos/:id`
							para `en_revision` y `rechazado`, porque esos se resuelven
							aprobando o rechazando la propuesta.

							Antes la fila le ofrecia "Publicar" igual -- la condicion era
							solo `estado !== 'activo'` -- y al pulsarlo salia en rojo el
							mensaje del backend, que nombra la ruta y el verbo HTTP. A
							quien administra el catalogo eso no le dice nada y ademas le
							hace creer que algo se rompio, cuando lo unico que pasa es
							que el boton estaba de mas.
						-->
						<div class="acciones">
							{#if enPropuesta(p)}
								<span class="menor nota-propuesta">
									Se resuelve en <strong>Productos por revisar</strong>, con Aprobar o
									Rechazar.
								</span>
								<button type="button" onclick={() => abrirHistorial(p)}>Historial</button>
							{:else}
								{#if p.estado !== 'activo'}
									<button type="button" onclick={() => cambiarEstado(p, 'activo')}>
										Publicar
									</button>
								{:else}
									<button type="button" onclick={() => cambiarEstado(p, 'inactivo')}>
										Retirar
									</button>
								{/if}
								<button type="button" onclick={() => editar(p)}>Editar</button>
								<button type="button" onclick={() => abrirHistorial(p)}>Historial</button>
							{/if}
						</div>
					</article>
				{/each}
			</div>

			{#if totalPaginas > 1}
				<!--
					Paginacion por NUMERO de pagina, no por cursor: es lo que
					devuelve la ruta (`pagina`, `total_paginas`) y aqui tiene
					sentido, porque en un panel de administracion uno quiere poder
					volver a "la pagina 3" y no solo seguir bajando.
				-->
				<nav class="paginacion" aria-label="Paginas del catalogo">
					<button
						type="button"
						onclick={() => irAPagina(pagina - 1)}
						disabled={pagina <= 1 || cargando}
					>
						Anterior
					</button>

					<span class="cuantas">
						Pagina {pagina} de {totalPaginas}
						<span class="menor">
							({totalProductos}
							{totalProductos === 1 ? 'producto' : 'productos'}{busqueda.trim() !== ''
								? ' con ese nombre'
								: ''})
						</span>
					</span>

					<button
						type="button"
						onclick={() => irAPagina(pagina + 1)}
						disabled={pagina >= totalPaginas || cargando}
					>
						Siguiente
					</button>
				</nav>
			{:else if totalProductos > 0}
				<p class="quieto centrado">
					{totalProductos}
					{totalProductos === 1 ? 'producto' : 'productos'}{busqueda.trim() !== ''
						? ' con ese nombre'
						: ''}.
				</p>
			{/if}
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

				{#if proponiendo}
					<!-- El vendedor no elige el estado: una propuesta nace `en_revision`
					     y quien la mueve de ahi es la tienda. -->
					<p class="menor">
						Se envia a revision de la tienda. Hasta que la aprueben no se ve en el catalogo.
					</p>
				{:else if editando !== null}
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

					<div class="rejilla">
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

							<!--
								Ni precio ni existencias.

								Aqui habia un campo "Precio (Q)" obligatorio y uno de
								"Existencias iniciales", los dos escritos contra la API de
								antes del modelo multi-vendedor. El backend ya no los lee:
								`VarianteCreacionPeticion` no los tiene, y el servicio nunca
								los toca. El de precio ademas BLOQUEABA el formulario --
								pedia un numero mayor a 0 para dejar publicar, y ese numero
								se descartaba en el servidor.

								Los dos son de la OFERTA, no del catalogo: una variante no
								tiene un precio, tiene uno por cada vendedor que la ofrece.
							-->
							<p class="menor sep">
								El precio y las existencias no se ponen aqui: son de la oferta, no del
								catalogo. Cuando el producto exista, ponle los tuyos desde
								<strong>Mis ofertas</strong>.
							</p>

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
						{guardando
							? 'Guardando...'
							: proponiendo
								? 'Enviar a revision'
								: editando === null
									? 'Crear producto'
									: 'Guardar cambios'}
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
				elijas. Reconstruye <strong>nombre, descripcion, categoria y variantes</strong>: son los
				campos que guardan los eventos del catalogo.
			</p>
			<p class="menor">
				El <strong>precio</strong> y las <strong>existencias</strong> no salen de esos eventos:
				al volverse multi-vendedor un producto dejo de tener un precio -- tiene uno por
				vendedor. Se piden aparte, a <code>precio_historial</code> y a
				<code>stock_movimiento</code> de PostgreSQL, y son los de la oferta de la tienda. Las
				caracteristicas no llevan historial: se ven las de hoy.
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
					{#if reconstruido.categoria?.nombre}
						<p class="menor">
							Categoria ese dia:
							<strong>
								{#if reconstruido.categoria.categoria_padre}{reconstruido.categoria
										.categoria_padre} &rsaquo;
								{/if}{reconstruido.categoria.nombre}
							</strong>
						</p>
					{/if}
					<ul class="presentaciones">
						<!--
							El nombre sale del evento del catalogo; el precio y las
							existencias, de PostgreSQL (ver reconstruirOfertas).

							Aqui iba `quetzales(v.precio)` sobre un campo que NUNCA
							llega en ninguno de los 105 productos, asi que cada renglon
							salia como "QNaN". Ahora o hay dato de verdad, o se dice que
							no lo hay.
						-->
						{#each reconstruido.variantes ?? [] as v (v.id_producto_variante)}
							<!-- `id_producto_variante` es opcional en el tipo (una variante
							     nueva del formulario todavia no lo tiene), asi que se
							     comprueba antes de usarlo como clave. -->
							{@const enFecha =
								v.id_producto_variante != null ? ofertaEnFecha[v.id_producto_variante] : undefined}
							<li>
								<span>{v.nombre_variante}</span>
								{#if enFecha}
									<span class="dato">
										{quetzales(enFecha.precio)} · {enFecha.stock}
										{enFecha.stock === 1 ? 'unidad' : 'unidades'}
									</span>
								{:else}
									<span class="dato vacio">sin oferta de la tienda ese dia</span>
								{/if}
							</li>
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
		gap: var(--e4);
		margin-bottom: 1.25rem;
	}

	h2 {
		font-size: var(--f-xl);
	}

	h3 {
		font-size: var(--f-md);
		margin-bottom: 0.5rem;
	}

	.sub,
	.menor {
		font-size: var(--f-ms);
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
		gap: var(--e3);
	}

	.fila {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		padding: 1rem 1.1rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.fila h3 {
		margin: 0.2rem 0 0.15rem;
		font-size: var(--f-md);
	}

	/* Que el nombre ocupe el hueco sobrante. Sin esto el numero de existencias
	   quedaba flotando en medio de la fila, a medio camino de su boton. */
	.fila .datos {
		flex: 1;
		min-width: 0;
	}

	.chip {
		display: inline-block;
		padding: 2px 10px;
		font-size: var(--f-xs);
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
		gap: var(--e2);
	}

	/* Ocupa el lugar de los botones que no van, para que la fila no quede
	   vacia y parezca que a ese producto no se le puede hacer nada. */
	.nota-propuesta {
		align-self: center;
		max-width: 18rem;
		text-align: right;
	}

	.chip.inactivo {
		background: var(--panel);
		color: var(--rojo);
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
		gap: var(--e4);
		margin-top: 0.9rem;
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		margin-bottom: 0.9rem;
	}

	.campo.ancho {
		grid-column: 1 / -1;
	}

	.rejilla .campo {
		margin-bottom: 0;
	}

	label {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	small {
		font-size: var(--f-sm);
		color: var(--gris-2);
	}

	input,
	select,
	textarea {
		width: 100%;
		padding: 9px 11px;
		font-family: inherit;
		font-size: var(--f-base);
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
		gap: var(--e2);
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
		gap: var(--e3);
		margin-top: 0.5rem;
	}

	/* ---------- botones ---------- */

	button {
		padding: 9px 18px;
		font-family: inherit;
		font-size: var(--f-base);
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
		font-size: var(--f-sm);
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

	/* ---------- el buscador y el recorte de la lista ---------- */
	.buscar {
		display: block;
		max-width: 24rem;
		margin-bottom: 1rem;
	}

	.buscar input {
		width: 100%;
	}

	/* Se oculta a la vista pero no al lector de pantalla: el campo necesita
	   nombre y el marcador de posicion ya lo dice visualmente. */
	.visualmente-oculto {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		overflow: hidden;
		clip-path: inset(50%);
		white-space: nowrap;
	}

	.paginacion {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-wrap: wrap;
		gap: var(--e4);
		margin-top: 1.25rem;
	}

	.cuantas {
		color: var(--tinta);
		text-align: center;
	}

	.cuantas .menor {
		display: block;
		color: var(--gris);
	}

	.centrado {
		margin-top: 1.25rem;
		text-align: center;
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
		font-size: var(--f-base);
	}

	/* Las presentaciones con su precio y sus existencias de ese dia. Sin
	   vinetas y en dos columnas: el nombre a la izquierda y el dato a la
	   derecha, que es como se lee una tabla de precios. */
	.resultado ul.presentaciones {
		list-style: none;
		margin-left: 0;
		border-top: 1px solid var(--linea);
	}

	.presentaciones li {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: var(--e4);
		padding: 0.45rem 0;
		border-bottom: 1px solid var(--linea);
	}

	.presentaciones .dato {
		flex-shrink: 0;
		color: var(--tinta);
		white-space: nowrap;
	}

	/* "Sin oferta ese dia" es un dato, no un fallo: se dice apagado, no en
	   rojo. Que la tienda no vendiera algo en marzo es informacion correcta. */
	.presentaciones .dato.vacio {
		color: var(--gris);
		font-size: var(--f-sm);
	}

	@media (max-width: 620px) {
		.presentaciones li {
			flex-direction: column;
			gap: var(--e1);
		}
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
