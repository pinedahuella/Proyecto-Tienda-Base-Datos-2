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
		/**
		 * OJO: por aqui casi nunca llega.
		 *
		 * GET /vendedor/productos y GET /vendedor/productos/:id lo BORRAN a
		 * proposito con una proyeccion negativa
		 * (`PROYECCION_SIN_STOCK = { 'variantes.stock': 0 }`, en
		 * backend/src/services/vendedores/productos.service.ts:53). Solo el PATCH
		 * lo devuelve, porque relee el documento sin proyeccion.
		 *
		 * Asi que NO se puede usar su ausencia para deducir "esta variante no
		 * tiene inventario": aqui esta ausente siempre. Quien sabe eso de verdad
		 * son las rutas de inventario.
		 */
		stock?: number;
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
		 * misma variante, editada". Sin el, el backend le asigna un id nuevo, la
		 * variante pierde su `stock`, y la fila de `inventario` de PostgreSQL
		 * se queda apuntando a un id que ya no existe en el documento --
		 * inventario huerfano, y todas las rutas de inventario contestando 409
		 * para siempre. Undefined solo en las variantes de verdad nuevas.
		 */
		id_producto_variante?: number;
		nombre_variante: string;
		precio: string;
		descripcion: string;
		imagenes: string;
		/**
		 * Solo tiene sentido en una variante NUEVA (sin id). En una que ya
		 * existe, el backend lo ignora sin avisar si esa variante ya tiene
		 * inventario -- y desde aqui no hay forma de saber si lo tiene, porque
		 * la ruta que trae el producto borra `variantes[].stock`. Ofrecerlo ahi
		 * seria prometer algo que puede no pasar, asi que solo se ensena cuando
		 * la variante no tiene id.
		 *
		 * Va bindeado a un <input type="number">, asi que aqui NO siempre hay
		 * texto: hay un numero, o undefined con el campo vacio. Se lee con
		 * texto().
		 */
		stock_inicial: string | number | undefined;
		valores: Record<string, unknown>;
		propias: { nombre: string; valor: string }[];
	}

	/** Una fila de la tabla de inventario: el stock REAL, de PostgreSQL. */
	interface InventarioVariante {
		id_producto: number;
		id_producto_variante: number;
		stock: number;
	}

	interface MotivoAjuste {
		id_motivo_movimiento: number;
		motivo_nombre: string;
	}

	type Vista = 'lista' | 'forma' | 'historial' | 'inventario';

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
			stock_inicial: '',
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
			// Se conserva el id, o el backend la trata como una variante nueva y
			// le deja el inventario huerfano. Ver el comentario de VarianteEnForma.
			id_producto_variante: v.id_producto_variante,
			nombre_variante: v.nombre_variante,
			precio: precioTexto(v.precio),
			descripcion: v.descripcion ?? '',
			imagenes: (v.imagenes ?? []).join('\n'),
			stock_inicial: '',
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

			// Si ya existia, se manda su id para que siga siendo LA MISMA variante:
			// conserva el id y el stock, y su fila de inventario en PostgreSQL
			// sigue apuntando a algo que existe.
			if (v.id_producto_variante != null) {
				cuerpo.id_producto_variante = v.id_producto_variante;
			}

			// Solo en variantes nuevas: en una que ya existe el backend lo ignora
			// si ya tiene inventario, y desde aqui no se puede saber si lo tiene.
			if (v.id_producto_variante == null && texto(v.stock_inicial) !== '') {
				cuerpo.stock_inicial = Number(texto(v.stock_inicial));
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
			if (!/^\d+(\.\d{1,2})?$/.test(String(v.precio)) || Number(v.precio) <= 0) {
				return (errorForma = 'El precio debe ser un numero mayor a 0, con hasta 2 decimales');
			}
		}

		// Un stock_inicial invalido hace que el backend rechace TODA la operacion,
		// no solo esa variante: se comprueba aqui para no ir y volver.
		for (const v of variantes) {
			if (v.id_producto_variante == null && texto(v.stock_inicial) !== '') {
				const n = Number(texto(v.stock_inicial));
				if (!Number.isInteger(n) || n < 0) {
					return (errorForma = 'El stock inicial debe ser un numero entero mayor o igual a 0');
				}
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
			// Al crear, las variantes que se enviaron SIN stock_inicial nacen sin
			// inventario. Eso no da ningun error -- el producto se crea igual --
			// pero deja la pantalla de inventario en modo pendientes hasta que se
			// arregle, y el vendedor no tiene por que adivinar por que. Se le dice
			// aqui, con el id, y con el boton que lleva directo a arreglarlo.
			//
			// Ojo con la diferencia: stock_inicial 0 SI crea inventario (queda en
			// cero, que es un dato); dejar el campo vacio es no crearlo.
			const sinExistencias =
				editando === null
					? cuerpo.variantes.filter((v) => v.stock_inicial == null).length
					: 0;
			const creado = r.payload;

			if (editando === null && sinExistencias > 0 && creado) {
				productoRecienCreado = creado;
				aviso =
					`Producto creado con el id ${creado._id}, pero ${sinExistencias} de sus ` +
					`${cuerpo.variantes.length} ${cuerpo.variantes.length === 1 ? 'variante' : 'variantes'} ` +
					`${sinExistencias === 1 ? 'quedo' : 'quedaron'} sin existencias. ` +
					`Hasta que las tenga, su inventario no se puede consultar.`;
			} else {
				productoRecienCreado = null;
				aviso =
					editando === null
						? `Producto creado con el id ${creado?._id ?? ''}`.trim()
						: 'Producto actualizado';
			}
			vista = 'lista';
			await cargar();
		} else {
			errorForma = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	/**
	 * El producto que se acaba de crear dejando alguna variante sin
	 * existencias. Solo sirve para el boton de "Agregar existencias" que
	 * aparece junto al aviso; se limpia en cuanto se usa o se hace otra cosa.
	 */
	let productoRecienCreado = $state<ProductoGuardado | null>(null);

	/** Publicar o retirar sin abrir el formulario entero. */
	async function cambiarEstado(p: ProductoGuardado, nuevoEstado: string) {
		aviso = '';
		productoRecienCreado = null;
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
		const r = await pedir<ProductoGuardado>(
			`/vendedor/productos/${productoHistorial._id}/historial?fecha=${fechaHistorial}`
		);
		buscandoHistorial = false;
		if (expiro(r)) return;
		if (r.ok && r.payload) reconstruido = r.payload;
		else errorHistorial = r.mensaje;
	}

	// ---------------------------------------------------------------- inventario
	/**
	 * El inventario del vendedor. El stock REAL vive en PostgreSQL y solo lo dan
	 * las rutas de inventario; NO se puede sacar de los productos.
	 *
	 * Es tentador leerlo de `variantes[].stock` del documento, pero
	 * GET /vendedor/productos y GET /vendedor/productos/:id lo BORRAN con una
	 * proyeccion (`PROYECCION_SIN_STOCK`, productos.service.ts:53). Ahi ese campo
	 * esta ausente SIEMPRE, tenga o no tenga inventario la variante: deducir de
	 * su ausencia que "no tiene inventario" daria falso en el 100% de los casos.
	 *
	 * Y las rutas que si lo saben son TODO O NADA: con que a una sola variante le
	 * falte su fila, la peticion entera se cae con 409 y no devuelve ni las que si
	 * estan. El 409 ademas solo nombra a UNA, asi que tampoco se puede saber
	 * cuantas faltan de un vistazo.
	 *
	 * De ahi el reparto: los productos y sus variantes salen de `mios` (que nunca
	 * falla y es lo unico que da los nombres), y el stock se le superpone encima
	 * cuando la ruta de inventario contesta. Cuando contesta 409, la tabla se
	 * ensena igual pero sin numeros, diciendo que el stock no se puede consultar
	 * hasta que no falte ninguno, y con el boton de crearlo en cada fila.
	 */
	let inventarioReal = $state<InventarioVariante[]>([]);

	/**
	 * Que se sabe del inventario de cada producto. Son TRES estados y no dos, y
	 * confundirlos es mentir:
	 *
	 *  'ok'          se leyo su inventario; sus variantes tienen numero.
	 *  'incompleto'  contesto 409: a alguna de sus variantes le falta su fila.
	 *                Cual, lo dice el propio mensaje del 409 (ver
	 *                varianteSenalada); las que van despues de ella en el
	 *                documento quedan sin saberse.
	 *  'fallo'       no se pudo preguntar (503, red, lo que sea). Aqui no hay
	 *                nada que crear: el problema no es la falta de inventario.
	 */
	type EstadoInventario = 'ok' | 'incompleto' | 'fallo';
	let estadoPorProducto = $state<Record<number, EstadoInventario>>({});

	/**
	 * De cada producto que contesto 409, la variante que el mensaje nombro.
	 *
	 * No es un dato de adorno: es lo unico que convierte "a este producto le
	 * falta algo" en "a ESTA variante le falta". El backend recorre
	 * producto.variantes en el orden del documento y se detiene en la PRIMERA
	 * que no tiene fila de inventario (combinarConInventario, en
	 * backend/src/services/vendedores/inventario.service.ts). Asi que de un
	 * solo 409 se deducen tres cosas, y solo tres:
	 *
	 *   las variantes ANTERIORES a la nombrada  -> SI tienen inventario
	 *   la nombrada                             -> NO lo tiene
	 *   las POSTERIORES                         -> no se sabe todavia
	 *
	 * Lo que no se sabe se ensena como "por revisar", nunca como "sin
	 * inventario": afirmar lo segundo seria inventarse un hecho. Y se termina
	 * de saber solo: al crear la que falta, el siguiente 409 nombra a la
	 * siguiente, hasta que el producto contesta 200.
	 */
	let varianteSenalada = $state<Record<number, number>>({});

	/**
	 * De que variante habla un 409 de inventario. El texto lo arma el backend
	 * (inventario.service.ts) con esta forma:
	 *
	 *   El producto "X" (id 51), variante "Azul" (id 95), todavia no tiene inventario creado
	 *
	 * Se ancla al FINAL, no al nombre de la variante. Buscar
	 * `variante "..." (id N)` parece lo natural y esta roto: los nombres los
	 * escribe el vendedor y pueden llevar comillas. Con una variante llamada
	 * `Monitor 24"` el texto queda
	 *
	 *   ... variante "Monitor 24"" (id 135), todavia no tiene inventario creado
	 *
	 * y ahi `"[^"]*"` corta en la comilla de las pulgadas y no encaja nada. Peor
	 * todavia: si el nombre del PRODUCTO contiene la palabra variante seguida de
	 * un (id N), ese patron la encuentra primero y devuelve el numero
	 * equivocado, sin fallar. Anclado al final no hay ambiguedad: el ultimo
	 * "(id N)," antes de la coletilla es siempre el de la variante, escriba el
	 * vendedor lo que escriba.
	 *
	 * Si algun dia esa coletilla cambia, esto devuelve null y la pantalla cae al
	 * caso honesto: el producto queda marcado incompleto y todas sus variantes
	 * salen "por revisar". Se pierde precision, no se gana una mentira. Y de
	 * paso el ancla descarta el OTRO 409 de esta ruta ("Ya existe inventario
	 * para..."), que habla de una variante que no falta.
	 */
	function varianteDelMensaje(mensaje: string): number | null {
		const encontrado = /\(id\s+(\d+)\),\s*todavia no tiene inventario creado\s*$/.exec(
			mensaje ?? ''
		);
		return encontrado ? Number(encontrado[1]) : null;
	}
	let motivosAjuste = $state<MotivoAjuste[]>([]);
	let cargandoInventario = $state(false);
	let errorInventario = $state('');
	let avisoInventario = $state('');
	/** El producto cuyo inventario se mira. null = todos los del vendedor. */
	let inventarioDe = $state<ProductoGuardado | null>(null);

	/** La fila con su formulario abierto, como "producto-variante". */
	let filaAbierta = $state('');
	/**
	 * Los dos van bindeados a un <input type="number">, que NO guarda texto:
	 * guarda un numero, y undefined con el campo vacio. De ahi el tipo y de ahi
	 * texto(): llamarles .trim() revienta con "is not a function" dentro del
	 * manejador del boton, y el clic se queda sin hacer nada, sin un solo aviso
	 * en pantalla. Paso de verdad al probarlo.
	 */
	let stockInicialFila = $state<string | number | undefined>('');
	let cantidadFila = $state<string | number | undefined>('');
	let motivoFila = $state('');
	let guardandoFila = $state(false);
	/** El error de la fila abierta. Aparte del de la pantalla, para que se vea. */
	let errorFila = $state('');

	/** Lo que hay en un campo, siempre como texto listo para comparar y convertir. */
	function texto(valor: unknown): string {
		return valor == null ? '' : String(valor).trim();
	}

	/**
	 * Que le pasa a UNA variante, que no es lo mismo que que le pasa a su
	 * producto. Cuatro casos, y ninguno se puede confundir con otro:
	 *
	 *  'tiene'      tiene su fila de inventario. Con 'real' definido ademas se
	 *               sabe cuanto; sin el, se sabe que la tiene pero no el numero
	 *               (el 409 de su producto se llevo por delante la consulta).
	 *  'falta'      NO la tiene. Consta: es la variante que nombro el 409.
	 *  'porRevisar' va despues de la que falta, asi que el backend ni llego a
	 *               mirarla. Puede estar bien o no; todavia no se sabe.
	 *  'noSeSabe'   no se pudo preguntar por su producto (503, red). Aqui no
	 *               falta inventario: falta el servidor.
	 */
	type Situacion = 'tiene' | 'falta' | 'porRevisar' | 'noSeSabe';

	interface FilaInventario {
		clave: string;
		producto: ProductoGuardado;
		variante: VarianteGuardada;
		idVariante: number;
		/** El stock real. undefined si no se pudo consultar el de su producto. */
		real: number | undefined;
		/**
		 * Que se sabe de ESTA variante. Es lo unico que mira la pantalla: el
		 * estado del producto ya esta resumido aqui, y guardarlo tambien en la
		 * fila dejaria dos verdades que se pueden desalinear.
		 */
		situacion: Situacion;
	}

	let filasInventario = $derived.by(() => {
		const reales = new Map<string, number>();
		for (const i of inventarioReal) {
			reales.set(`${i.id_producto}-${i.id_producto_variante}`, i.stock);
		}

		const productos = inventarioDe ? mios.filter((p) => p._id === inventarioDe!._id) : mios;
		const filas: FilaInventario[] = [];

		for (const p of productos) {
			const estado = estadoPorProducto[p._id] ?? 'fallo';
			// La posicion de la variante que nombro el 409, dentro de este
			// producto. -1 si el producto no dio 409 o si no se pudo leer cual.
			const corte =
				estado === 'incompleto' && varianteSenalada[p._id] != null
					? p.variantes.findIndex(
							(v) => v.id_producto_variante === varianteSenalada[p._id]
						)
					: -1;

			p.variantes.forEach((v, i) => {
				const idVariante = v.id_producto_variante ?? 0;
				// DOS claves, y no es por gusto. La del {#each} lleva la POSICION,
				// asi que es unica pase lo que pase con el dato; la del stock es
				// producto-variante, que es como viene indexado el inventario.
				//
				// Juntarlas costaba la pantalla entera: el backend acepta un PATCH
				// con el mismo id_producto_variante repetido (construirVariantes lo
				// busca con .find() y no mira si ya salio), y dos variantes con el
				// mismo id daban la misma clave. Svelte lanza each_key_duplicate y
				// tumba el componente completo -- tambien en produccion, no solo en
				// desarrollo. Con la posicion dentro, el dato roto se ve en pantalla
				// en vez de hacerla desaparecer. Lo mismo con el `?? 0`: dos
				// variantes sin id chocaban igual.
				const clave = `${p._id}-${i}-${idVariante}`;
				const claveStock = `${p._id}-${idVariante}`;

				let situacion: Situacion;
				if (estado === 'ok') situacion = 'tiene';
				else if (estado === 'fallo') situacion = 'noSeSabe';
				else if (corte === -1) situacion = 'porRevisar';
				else if (i < corte) situacion = 'tiene';
				else if (i === corte) situacion = 'falta';
				else situacion = 'porRevisar';

				filas.push({
					clave,
					producto: p,
					variante: v,
					idVariante,
					real: reales.get(claveStock),
					situacion
				});
			});
		}
		return filas;
	});

	/**
	 * Las filas que de verdad piden algo: SOLO la que consta que no tiene nada.
	 *
	 * Las "por revisar" no entran. Van detras de la que falta, asi que el
	 * backend ni llego a mirarlas: pueden estar perfectas, y pedir que se
	 * arreglen es pedir que se arregle algo que a lo mejor no esta roto. Se
	 * resuelve solo, de una en una: al crear la que falta, el siguiente 409
	 * nombra a la siguiente, y cuando ya no queda ninguna el producto sale
	 * entero, con todas sus variantes.
	 *
	 * La excepcion es cuando NO se pudo saber cual falta (corte === -1, que
	 * deja todas en 'porRevisar'). Ahi si se ensenan todas: no hay forma de
	 * acotarlo, y esconderlas dejaria al vendedor sin nada que tocar.
	 */
	let filasPendientes = $derived.by(() => {
		const conFaltaConocida = new Set(
			filasInventario.filter((f) => f.situacion === 'falta').map((f) => f.producto._id)
		);
		return filasInventario.filter(
			(f) =>
				f.situacion === 'falta' ||
				(f.situacion === 'porRevisar' && !conFaltaConocida.has(f.producto._id))
		);
	});

	/** Los productos a los que les falta crear algun inventario. */
	let productosIncompletos = $derived(
		[...new Set(filasPendientes.map((f) => f.producto._id))].sort((a, b) => a - b)
	);

	/** true mientras haya algo que crear: la pantalla ensena solo eso. */
	let hayPendientes = $derived(filasPendientes.length > 0);

	/**
	 * Los productos cuyo inventario no se pudo consultar. Van aparte de los
	 * incompletos a proposito: aqui no falta inventario, falta el servidor, y
	 * la accion no es crear nada sino reintentar.
	 */
	let productosConFallo = $derived(
		[...new Set(filasInventario.filter((f) => f.situacion === 'noSeSabe').map((f) => f.producto._id))].sort(
			(a, b) => a - b
		)
	);

	/**
	 * El catalogo agrupado por producto, para el modo completo.
	 *
	 * `total` es null, no 0, cuando a alguna de sus variantes no se le pudo
	 * leer el stock. Sumar tratando lo desconocido como cero deja al producto
	 * anunciando "0 unidades", que es una afirmacion que nadie hizo: lo unico
	 * que consta es que no se pudo preguntar.
	 */
	interface GrupoInventario {
		producto: ProductoGuardado;
		filas: FilaInventario[];
		total: number | null;
	}

	let gruposInventario = $derived.by(() => {
		const grupos: GrupoInventario[] = [];
		for (const f of filasInventario) {
			let grupo = grupos.find((g) => g.producto._id === f.producto._id);
			if (!grupo) {
				grupo = { producto: f.producto, filas: [], total: 0 };
				grupos.push(grupo);
			}
			grupo.filas.push(f);
			if (f.real === undefined) grupo.total = null;
			else if (grupo.total !== null) grupo.total += f.real;
		}
		return grupos;
	});

	/**
	 * Cuantas unidades hay en total, de todo lo del vendedor. null si de alguna
	 * variante no se sabe: un total al que le faltan sumandos no es un total.
	 */
	let totalUnidades = $derived(
		filasInventario.some((f) => f.real === undefined)
			? null
			: filasInventario.reduce((suma, f) => suma + (f.real ?? 0), 0)
	);

	async function abrirInventario(p: ProductoGuardado | null) {
		inventarioDe = p;
		// Se marca ANTES de cambiar de vista. Si no, entre pintar la pantalla y
		// la primera respuesta del servidor no se sabe nada de ningun producto,
		// y "no se sabe" se pinta igual que "no falta nada": el catalogo entero
		// aparecia un instante, que es justo lo que esta pantalla no debe hacer.
		cargandoInventario = true;
		vista = 'inventario';
		// El aviso general es de la pantalla anterior ("PCgamer ahora esta en
		// inactivo"). Si no se limpia se queda arriba, encima del aviso de esta,
		// y se leen dos mensajes de exito para una sola accion.
		aviso = '';
		productoRecienCreado = null;
		avisoInventario = '';
		errorFila = '';
		filaAbierta = '';
		await cargarInventario();
	}

	async function cargarInventario() {
		cargandoInventario = true;
		errorInventario = '';
		// Lo que se sabia de la consulta anterior ya no vale: acaba de cambiar
		// algo. Si no se limpia, una variante recien arreglada se queda pintada
		// como "falta" hasta que el servidor conteste.
		varianteSenalada = {};

		// El de un producto suelto cuando se abrio desde su fila; el de todos si no.
		const ruta = inventarioDe
			? `/vendedor/productos/${inventarioDe._id}/inventario`
			: '/vendedor/productos/inventario';

		const [rInv, rMotivos] = await Promise.all([
			pedir<InventarioVariante[]>(ruta),
			pedir<MotivoAjuste[]>('/vendedor/productos/inventario/motivos-ajuste')
		]);

		// Se apaga la bandera antes de salir: ahora la pantalla entera cuelga de
		// ella, y dejarla encendida deja "Cargando el inventario..." para
		// siempre si la sesion se cae justo aqui.
		if (expiro(rInv) || expiro(rMotivos)) {
			cargandoInventario = false;
			return;
		}

		const enFoco = inventarioDe ? [inventarioDe] : mios;
		const marcarTodos = (e: EstadoInventario) => {
			const mapa: Record<number, EstadoInventario> = {};
			for (const p of enFoco) mapa[p._id] = e;
			estadoPorProducto = mapa;
		};

		if (rInv.ok && rInv.payload) {
			inventarioReal = rInv.payload;
			marcarTodos('ok');
		} else if (rInv.estado === 409) {
			// El 409 no es un fallo de la pantalla: es el backend diciendo que a
			// alguna variante le falta su inventario. Y como la ruta es todo o
			// nada, ese 409 se lleva por delante el stock de TODAS -- 55 buenas
			// desaparecen por una rota, y el mensaje solo nombra a una.
			//
			// Se vuelve a preguntar producto por producto: cada producto es su
			// propio todo-o-nada, asi que los sanos si devuelven sus numeros y el
			// hueco queda acotado a los pocos que de verdad estan rotos.
			errorInventario = rInv.mensaje;
			// Los numeros de una consulta anterior ya no valen: el servidor acaba
			// de decir que no puede darlos.
			inventarioReal = [];
			if (inventarioDe) {
				marcarTodos('incompleto');
				const senalada = varianteDelMensaje(rInv.mensaje);
				if (senalada != null) varianteSenalada = { [inventarioDe._id]: senalada };
			} else {
				await preguntarProductoPorProducto();
			}
		} else {
			// Ni 200 ni 409: no se pudo preguntar. Aqui no falta inventario, falta
			// el servidor -- y decir "sin inventario" seria inventarse un hecho.
			inventarioReal = [];
			marcarTodos('fallo');
			errorInventario = rInv.estado === 0 ? 'No se pudo conectar con el servidor' : rInv.mensaje;
		}

		if (rMotivos.ok && rMotivos.payload) motivosAjuste = rMotivos.payload;
		else motivosAjuste = [];

		cargandoInventario = false;
	}

	/**
	 * El rodeo cuando la ruta de todos dio 409: una peticion por producto, en
	 * paralelo. Cuesta N peticiones, pero solo pasa en el caso roto y una vez;
	 * a cambio, en vez de una pantalla sin un solo numero queda el inventario
	 * completo de los productos sanos y el hueco senalado donde de verdad esta.
	 */
	async function preguntarProductoPorProducto() {
		const respuestas = await Promise.all(
			mios.map((p) => pedir<InventarioVariante[]>(`/vendedor/productos/${p._id}/inventario`))
		);

		// Basta con que una haya caducado para que todas las demas no signifiquen
		// nada: se saca a la persona en vez de pintarle un catalogo sin stock.
		if (respuestas.some((r) => r.estado === 401)) {
			alExpirarSesion?.();
			return;
		}

		const juntos: InventarioVariante[] = [];
		const mapa: Record<number, EstadoInventario> = {};
		const senaladas: Record<number, number> = {};

		respuestas.forEach((r, i) => {
			const id = mios[i]._id;
			if (r.ok && r.payload) {
				juntos.push(...r.payload);
				mapa[id] = 'ok';
			} else if (r.estado === 409) {
				// 409 es "le falta inventario y se puede crear aqui", y ademas dice
				// cual: es la unica via para acotarlo a la variante exacta.
				mapa[id] = 'incompleto';
				const senalada = varianteDelMensaje(r.mensaje);
				if (senalada != null) senaladas[id] = senalada;
			} else {
				// Cualquier otra cosa (503, 500, la red) es "no se pudo preguntar",
				// que no se arregla creando nada. Antes las dos caian en el mismo
				// saco y un backend reiniciandose pintaba el catalogo entero como
				// sin stock.
				mapa[id] = 'fallo';
			}
		});

		inventarioReal = juntos;
		estadoPorProducto = mapa;
		varianteSenalada = senaladas;
	}

	function abrirFila(f: FilaInventario) {
		filaAbierta = filaAbierta === f.clave ? '' : f.clave;
		stockInicialFila = '';
		cantidadFila = '';
		motivoFila = motivosAjuste[0] ? String(motivosAjuste[0].id_motivo_movimiento) : '';
		avisoInventario = '';
		errorFila = '';
	}

	/** Crea la fila de inventario que le falta a una variante. */
	async function crearInventario(f: FilaInventario) {
		const escrito = texto(stockInicialFila);
		const n = Number(escrito);
		if (escrito === '' || !Number.isInteger(n) || n < 0) {
			errorFila = 'El stock inicial debe ser un numero entero mayor o igual a 0';
			return;
		}

		guardandoFila = true;
		errorFila = '';
		const r = await pedir<InventarioVariante>(
			`/vendedor/productos/${f.producto._id}/inventario`,
			conJson('POST', { id_producto_variante: f.idVariante, stock_inicial: n })
		);
		guardandoFila = false;
		if (expiro(r)) return;

		if (r.ok) {
			avisoInventario = `"${f.variante.nombre_variante}" queda con ${n} ${n === 1 ? 'unidad' : 'unidades'}`;
			filaAbierta = '';
			// La copia de Mongo tambien cambio, asi que hay que releer los
			// productos, y volver a preguntar el inventario para traer el numero.
			await cargar();
			await cargarInventario();
		} else if (r.estado === 409) {
			// Esta variante ya tenia inventario. Pasa con las que salen "por
			// revisar": el backend se detuvo antes de llegar a ellas, asi que
			// desde aqui no constaba si lo tenian. No es un fallo, es la
			// respuesta -- se acepta y se vuelve a preguntar, que ahora dira
			// cual es la siguiente que de verdad falta.
			avisoInventario = `"${f.variante.nombre_variante}" ya tenia existencias; no se toco nada`;
			filaAbierta = '';
			errorFila = '';
			await cargarInventario();
		} else {
			errorFila = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	/** Sube o baja el stock de una variante que YA tiene inventario. */
	async function ajustarInventario(f: FilaInventario) {
		const escrito = texto(cantidadFila);
		const n = Number(escrito);
		if (escrito === '' || !Number.isInteger(n) || n <= 0) {
			errorFila = 'La cantidad debe ser un numero entero mayor a 0';
			return;
		}
		if (!motivoFila) {
			errorFila = 'Elegi un motivo';
			return;
		}

		guardandoFila = true;
		errorFila = '';
		const r = await pedir<InventarioVariante>(
			`/vendedor/productos/${f.producto._id}/inventario`,
			conJson('PATCH', {
				id_producto_variante: f.idVariante,
				// El <select> devuelve texto y el backend exige number: sin este
				// Number() contesta 400 sin explicar por que.
				id_motivo_movimiento: Number(motivoFila),
				cantidad: n
			})
		);
		guardandoFila = false;
		if (expiro(r)) return;

		if (r.ok && r.payload) {
			avisoInventario = `"${f.variante.nombre_variante}" queda en ${r.payload.stock}`;
			filaAbierta = '';
			await cargar();
			await cargarInventario();
		} else {
			errorFila = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
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
				{:else if vista === 'inventario'}
					{inventarioDe ? 'Inventario de "' + inventarioDe.nombre + '"' : 'Inventario de todo lo tuyo'}
				{:else}
					Como estaba en una fecha
				{/if}
			</p>
		</div>

		{#if vista === 'lista'}
			<div class="acciones">
				<button type="button" class="secundario" onclick={() => abrirInventario(null)}>
					Inventario
				</button>
				<button type="button" class="principal" onclick={nuevo}>Publicar producto</button>
			</div>
		{:else}
			<button type="button" class="secundario" onclick={() => ((vista = 'lista'), (aviso = '')) }>
				Volver a la lista
			</button>
		{/if}
	</div>

	{#if aviso}
		<p class="ok" role="status">
			{aviso}
			{#if productoRecienCreado}
				<button
					type="button"
					class="enlace"
					onclick={() => abrirInventario(productoRecienCreado)}
				>
					Agregar existencias ahora
				</button>
			{/if}
		</p>
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
							<button type="button" onclick={() => abrirInventario(p)}>Inventario</button>
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

								<!--
									El stock inicial solo se puede poner cuando la variante todavia
									no tiene inventario. Si ya lo tiene, el backend ignora este
									campo a proposito: subir o bajar un stock que ya existe se hace
									en la pantalla de Inventario, que ademas deja el movimiento
									apuntado con su motivo.
								-->
								{#if variantes[i].id_producto_variante == null}
									<div class="campo">
										<label for={'vs-' + i}>Existencias iniciales</label>
										<input
											id={'vs-' + i}
											type="number"
											min="0"
											step="1"
											placeholder="Se puede dejar vacio"
											bind:value={variantes[i].stock_inicial}
										/>
										<small>
											<strong>Vacio y 0 no son lo mismo.</strong> Con un numero (0 incluido)
											la variante nace con su inventario creado, y 0 quiere decir "agotada".
											Vacio quiere decir que todavia no tiene inventario: hasta que se lo
											crees en la pantalla de Inventario, el stock de este producto no se
											puede consultar.
										</small>
									</div>
								{:else}
									<div class="campo">
										<span class="rotulo">Stock</span>
										<p class="fijo">Se lleva en Inventario</p>
										<small>
											Ahi se crea si le falta, y se sube o se baja con su motivo apuntado.
											Aqui no se toca.
										</small>
									</div>
								{/if}
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

		<!-- ══════════════════════════════ INVENTARIO ═════════════════════ -->
	{:else if vista === 'inventario'}
		<!-- Mientras se pregunta NO se pinta nada de la tabla, ni siquiera lo que
		     se sabia antes. Con el estado a medio saber, un producto del que
		     todavia no hay respuesta se ve igual que uno que esta bien, y el
		     catalogo completo asomaria por un instante. -->
		{#if cargandoInventario}
			<p class="quieto">Cargando el inventario...</p>
		{:else if filasInventario.length === 0}
			<p class="quieto">Todavia no tienes productos, asi que no hay inventario que llevar.</p>
		{:else}
			{#if avisoInventario}
				<p class="ok" role="status">{avisoInventario}</p>
			{/if}

			{#if hayPendientes}
				<!-- ── MODO PENDIENTES ─────────────────────────────────────────
				     Mientras falte una sola existencia por crear, el catalogo NO
				     se ensena: se ensena solo lo que hay que arreglar. Ensenar
				     los 27 productos sanos junto al roto es lo que hacia que no
				     se viera cual habia que tocar. -->
				<p class="aviso" role="alert">
					Falta agregar existencias en {productosIncompletos.length}
					{productosIncompletos.length === 1 ? 'producto' : 'productos'}:
					{productosIncompletos.map((id) => 'id ' + id).join(', ')}. El catalogo se
					muestra completo cuando ninguna variante quede sin existencias.
				</p>
				{#if productosConFallo.length > 0}
					<p class="aviso">
						De {productosConFallo.map((id) => 'id ' + id).join(', ')} no se pudo preguntar
						el inventario. Eso no es falta de existencias, es que el servidor no contesto.
						<button type="button" class="enlace" onclick={cargarInventario}>Reintentar</button>
					</p>
				{/if}

				<div class="tabla">
					{#each filasPendientes as f (f.clave)}
						{@render filaDeInventario(f)}
					{/each}
				</div>
			{:else}
				<!-- ── MODO CATALOGO ───────────────────────────────────────────
				     Ya nada falta: el catalogo entero, producto por producto,
				     con sus variantes y sus existencias reales. -->
				{#if errorInventario}
					<p class="malo" role="alert">
						{errorInventario}
						<button type="button" class="enlace" onclick={cargarInventario}>Reintentar</button>
					</p>
				{/if}

				<!-- El recuento de todo solo tiene sentido con varios productos. Con
				     uno solo dice exactamente lo mismo que su propio encabezado, dos
				     lineas seguidas. Sale solo con productosConFallo vacio, asi que
				     aqui totalUnidades nunca es null. -->
				{#if productosConFallo.length === 0 && gruposInventario.length > 1}
					<p class="menor recuento">
						{gruposInventario.length} productos ·
						{filasInventario.length}
						{filasInventario.length === 1 ? 'variante' : 'variantes'} ·
						{totalUnidades}
						{totalUnidades === 1 ? 'unidad' : 'unidades'} en total
					</p>
				{/if}

				{#each gruposInventario as g (g.producto._id)}
					<div class="grupo">
						<div class="cabeza-grupo">
							<h3>{g.producto.nombre}</h3>
							<p class="menor">
								producto {g.producto._id} · {g.producto.categoria.nombre} ·
								{g.filas.length}
								{g.filas.length === 1 ? 'variante' : 'variantes'} ·
								{#if g.total === null}
									<!-- Decir "0 unidades" de un producto que no se pudo
									     consultar es afirmar algo que nadie comprobo. -->
									<strong>sin consultar</strong>
								{:else}
									<strong>{g.total}</strong>
									{g.total === 1 ? 'unidad' : 'unidades'}
								{/if}
							</p>
						</div>
						<div class="tabla">
							{#each g.filas as f (f.clave)}
								{@render filaDeInventario(f)}
							{/each}
						</div>
					</div>
				{/each}
			{/if}
		{/if}
	{/if}
</section>

<!--
	Una fila de variante. Es la misma en los dos modos (pendientes y catalogo),
	asi que vive una sola vez: lo que cambia entre modos es QUE filas se pintan,
	no como se pinta cada una.
-->
{#snippet filaDeInventario(f: FilaInventario)}
	<article class="fila">
		<div class="datos">
			<h3>{f.variante.nombre_variante}</h3>
			<p class="menor">
				{f.producto.nombre} · producto {f.producto._id} · variante {f.idVariante}
			</p>
		</div>

		<div class="stock-celda">
			{#if f.real !== undefined}
				<strong class="grande">{f.real}</strong>
				<span class="menor">{f.real === 1 ? 'unidad' : 'unidades'}</span>
			{:else if f.situacion === 'falta'}
				<span class="chip inactivo">sin existencias</span>
			{:else if f.situacion === 'porRevisar'}
				<span class="chip">por revisar</span>
			{:else if f.situacion === 'tiene'}
				<!-- Consta que tiene inventario (va antes de la que fallo), pero el
				     409 se llevo por delante el numero. -->
				<span class="chip">ya tiene</span>
			{:else}
				<span class="chip">no disponible</span>
			{/if}
		</div>

		<div class="acciones">
			<!-- Con 'noSeSabe' no se ofrece crear nada: el problema no es que falte
			     inventario, es que no se pudo preguntar. -->
			{#if f.situacion !== 'noSeSabe'}
				<button type="button" onclick={() => abrirFila(f)}>
					{#if f.real === undefined}
						{filaAbierta === f.clave ? 'Cancelar' : 'Agregar existencias'}
					{:else}
						{filaAbierta === f.clave ? 'Cancelar' : 'Ajustar'}
					{/if}
				</button>
			{/if}
		</div>

		{#if filaAbierta === f.clave}
			<div class="formulario-fila">
				<!-- El error va aqui, pegado al control que lo produjo: arriba
				     lo tapaba el aviso del 409 y el clic parecia no hacer nada. -->
				{#if errorFila}
					<p class="malo" role="alert">{errorFila}</p>
				{/if}
				{#if f.real === undefined}
					<div class="par">
						<input
							type="number"
							min="0"
							step="1"
							placeholder="Cuantas unidades"
							bind:value={stockInicialFila}
						/>
						<button
							type="button"
							class="principal"
							onclick={() => crearInventario(f)}
							disabled={guardandoFila}
						>
							{guardandoFila ? 'Agregando...' : 'Agregar'}
						</button>
					</div>
					<small>
						Deja tambien el primer renglon en el libro de movimientos, con motivo
						"reposicion" — salvo que pongas 0, que no mueve nada pero si deja la variante
						con existencias en cero, que es distinto de no tenerlas.
						{#if f.situacion === 'porRevisar'}
							Esta variante podria tener inventario ya; si lo tiene, el servidor lo dira y
							no se toca nada.
						{/if}
					</small>
				{:else}
					<div class="par">
						<select bind:value={motivoFila}>
							{#each motivosAjuste as m (m.id_motivo_movimiento)}
								<option value={String(m.id_motivo_movimiento)}>{m.motivo_nombre}</option>
							{/each}
						</select>
						<input
							type="number"
							min="1"
							step="1"
							placeholder="Cuantas unidades"
							bind:value={cantidadFila}
						/>
						<button
							type="button"
							class="principal"
							onclick={() => ajustarInventario(f)}
							disabled={guardandoFila}
						>
							{guardandoFila ? 'Ajustando...' : 'Ajustar'}
						</button>
					</div>
					<small>
						Es una correccion manual y queda apuntada con su motivo. Nunca deja el
						stock en negativo.
					</small>
				{/if}
			</div>
		{/if}
	</article>
{/snippet}

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

	/* Que el nombre ocupe el hueco sobrante. Sin esto el numero de existencias
	   quedaba flotando en medio de la fila, a medio camino de su boton. */
	.fila .datos {
		flex: 1;
		min-width: 0;
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

	.chip.inactivo {
		background: var(--panel);
		color: var(--rojo);
	}

	/* ---------- inventario ---------- */

	/* La fila de inventario abre un formulario debajo, asi que tiene que poder
	   partirse en dos lineas. Las filas de producto solo tienen dos hijos y no
	   llegan a envolver, asi que esto no las cambia. */
	.fila {
		flex-wrap: wrap;
	}

	.stock-celda {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 0.15rem;
		min-width: 120px;
		/* Separacion propia del boton: con .datos ocupando el hueco sobrante,
		   el numero queda pegado a "Ajustar" y se leen como una sola cosa. */
		padding-right: 0.6rem;
		text-align: right;
	}

	.grande {
		font-size: 1.5rem;
		font-weight: 500;
		line-height: 1;
		color: var(--tinta);
	}

	.formulario-fila {
		flex-basis: 100%;
		padding-top: 0.9rem;
		margin-top: 0.2rem;
		border-top: 1px solid var(--linea);
	}

	.rotulo {
		font-size: 0.85rem;
		color: var(--gris);
	}

	.fijo {
		margin: 0.2rem 0 0;
		font-size: 1rem;
		color: var(--tinta);
	}

	/* El aviso de la pantalla de inventario es una linea de texto, no una
	   tarjeta: nada de recuadro con barra de color al lado. */
	.aviso {
		margin-bottom: 0.8rem;
		font-size: 0.88rem;
		color: var(--texto);
	}

	.recuento {
		margin-bottom: 1rem;
	}

	/* ---------- inventario agrupado por producto ---------- */

	/* En el modo catalogo las variantes se leen por producto, no como una lista
	   plana de 99 filas donde no se ve donde empieza una y termina la otra. */
	.grupo {
		margin-bottom: 1.6rem;
	}

	/* Una banda que rotula al grupo, con el mismo lenguaje de tarjeta que el
	   resto del panel (fondo, borde y radio), pero en --panel para que se lea
	   como encabezado y no compita con las filas, que van en --blanco.
	   Suelto sobre el fondo parecia texto que se quedo sin estilo. */
	.cabeza-grupo {
		padding: 0.7rem 1.1rem;
		margin-bottom: 0.5rem;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.cabeza-grupo h3 {
		margin-bottom: 0.1rem;
		font-size: 1.02rem;
		font-weight: 600;
		color: var(--tinta);
	}

	/* Un boton que se lee como enlace: va dentro de un parrafo de texto y una
	   caja gris ahi rompe la frase. */
	.enlace {
		padding: 0;
		border: 0;
		background: none;
		font: inherit;
		color: var(--indigo);
		text-decoration: underline;
		cursor: pointer;
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
