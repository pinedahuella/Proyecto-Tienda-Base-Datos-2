<script lang="ts">
	import { onMount } from 'svelte';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import Autocompletar from '$lib/Autocompletar.svelte';
	import { pedir } from '$lib/api';

	/**
	 * El catalogo. Es la pagina de inicio y es publica: GET /productos no pide
	 * la cookie de sesion, asi que se puede navegar sin cuenta.
	 *
	 * Todo el filtrado lo hace el backend. Aqui no se filtra en memoria: si se
	 * hiciera, un filtro solo alcanzaria a los productos ya descargados y
	 * mentiria en cuanto haya mas de una tanda.
	 *
	 * Los filtros son exactamente los que expone GET /productos. El contrato
	 * esta en backend/elementos Generales/endpoints-productos.md:
	 *
	 *   fijos      nombre (parcial, sin distinguir mayusculas), id_categoria,
	 *              precio_min, precio_max (van sobre precio_desde, el mas
	 *              barato al que se ofrece), precio_tienda_min/max,
	 *              estado_variante, stock_min/max, stock_tienda_min/max
	 *   dinamicos  cualquier OTRO nombre de parametro es el nombre de una
	 *              caracteristica, y su prefijo decide el operador:
	 *                (sin prefijo)  igualdad exacta
	 *                min_           mayor o igual
	 *                max_           menor o igual
	 *                contiene_      contiene, sin distinguir mayusculas
	 *
	 * Un filtro dinamico se busca en las CUATRO ubicaciones posibles a la vez
	 * (caracteristicas del catalogo y personalizadas, del producto y de cada
	 * una de sus variantes), asi que aqui no hace falta saber donde vive cada
	 * caracteristica: basta con mandar su nombre.
	 */

	type TipoDato = 'texto' | 'entero' | 'decimal' | 'booleano' | 'lista';

	interface Definicion {
		nombre: string;
		unidad: string | null;
		tipo_dato: TipoDato;
	}

	interface CategoriaBreve {
		id_categoria: number;
		nombre: string;
		categoria_padre: string;
	}

	interface CategoriaCompleta extends CategoriaBreve {
		caracteristicas: Definicion[];
		caracteristicas_variante: Definicion[];
	}

	interface Caracteristica {
		nombre: string;
		valor: string | number | boolean | string[];
		unidad: string | null;
	}

	/** Como llega numeric(12,2) de Postgres a traves de Mongo. */
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
	}

	interface Producto {
		_id: number;
		nombre: string;
		descripcion: string | null;
		estado: string;
		categoria: { id_categoria: number; nombre: string; categoria_padre: string | null };
		variantes: Variante[];
		caracteristicas_adicionales?: Caracteristica[];
		caracteristicas_personalizadas?: Caracteristica[];

		/**
		 * Los cinco calculados. El producto ya NO tiene vendedor ni precio ni
		 * stock propios: son de cada oferta, y las ofertas viven en PostgreSQL.
		 * Estos cinco son lo unico que viaja al documento, y son justo lo que
		 * la tarjeta necesita para pintarse sin pedir nada mas.
		 *
		 * precio_tienda es el que se ENSENA (regla del profesor: el primero
		 * siempre es el de la pagina) y precio_desde el mas barato al que
		 * alguien lo ofrece. Cuando el segundo es menor, la tarjeta dice los
		 * dos: si solo dijera el de la tienda, estaria escondiendo que se
		 * puede pagar menos.
		 */
		precio_tienda: Decimal | null;
		precio_desde: Decimal | null;
		/** Unidades de la tienda, sumadas sobre todas sus variantes. */
		stock_tienda: number;
		/** Unidades entre TODOS los vendedores activos. Es el que dice si hay o no. */
		stock_total: number;
		/** Cuantos vendedores distintos lo tienen activo. */
		total_ofertas: number;
	}

	interface Tanda {
		productos: Producto[];
		siguiente_cursor: number | null;
	}

	/**
	 * Lo que devuelve GET /productos/paginacion: el mismo documento de producto
	 * y EXACTAMENTE los mismos filtros que GET /productos, solo que en vez de un
	 * cursor trae en que pagina estas y cuantas hay.
	 *
	 * Es la ruta que resuelve el catalogo con el marco de agregacion de Mongo:
	 * un $facet saca la tanda y el conteo de la misma foto del filtro, en vez de
	 * dos consultas que podrian ver estados distintos.
	 *
	 * total_paginas es 0 cuando el filtro no encuentra nada, no 1. Comprobado
	 * contra la ruta: ?nombre=zzzzzz devuelve total_productos 0 y total_paginas
	 * 0. Por eso los extremos se comparan contra totalPaginas y no se supone que
	 * siempre haya al menos una pagina.
	 */
	interface TandaPaginada {
		productos: Producto[];
		pagina: number;
		limite: number;
		total_productos: number;
		total_paginas: number;
	}

	/**
	 * Los nombres que GET /productos se reserva para sus filtros fijos: es la
	 * misma lista CLAVES_RESERVADAS de productos.service.ts.
	 *
	 * Hace falta tenerla aqui por las caracteristicas personalizadas, que las
	 * escribe quien publica el producto y podrian llamarse "estado" o
	 * "nombre". Si una asi se mandara tal cual, el backend la tomaria por el
	 * filtro fijo del mismo nombre y buscaria otra cosa sin dar ningun error.
	 */
	const CLAVES_RESERVADAS = new Set([
		'limite',
		'despues_de',
		'pagina',
		'nombre',
		'estado',
		'id_categoria',
		'precio_min',
		'precio_max',
		'precio_tienda_min',
		'precio_tienda_max',
		'estado_variante',
		'stock_min',
		'stock_max',
		'stock_tienda_min',
		'stock_tienda_max'
	]);

	/** Igual al varchar(100) de caracteristica.nombre, que es lo que valida el backend. */
	const LARGO_MAXIMO_NOMBRE = 100;

	const POR_TANDA = 12;

	type Operador = 'igual' | 'contiene' | 'rango';

	/** Un filtro de caracteristica ya agregado a la busqueda. */
	interface FiltroCarac {
		/** Solo para la clave del #each: dos filtros pueden compartir nombre. */
		id: number;
		nombre: string;
		unidad: string | null;
		/** null cuando es personalizada: no esta en la paleta y no se sabe su tipo. */
		tipo: TipoDato | null;
		operador: Operador;
		valor: string;
		desde: string;
		hasta: string;
	}

	/**
	 * Que operadores tiene sentido ofrecer para cada tipo_dato. El primero es
	 * el que se propone por defecto.
	 *
	 * min_ y max_ solo se ofrecen sobre lo numerico. El backend los deja pasar
	 * contra cualquier tipo a proposito -- no necesita conocer el tipo_dato --
	 * pero sobre texto Mongo compara lexicograficamente y el resultado no
	 * significa nada para quien busca: comprobado contra el catalogo real,
	 * min_Marca=A devuelve 47 de los 51 productos. Eso no es un fallo del
	 * backend; es justo la razon por la que GET /categorias/:id trae el
	 * tipo_dato de cada caracteristica.
	 */
	function operadoresDe(tipo: TipoDato | null): Operador[] {
		if (tipo === 'entero' || tipo === 'decimal') return ['rango', 'igual'];
		if (tipo === 'booleano') return ['igual'];
		if (tipo === 'texto') return ['contiene', 'igual'];
		if (tipo === 'lista') return ['igual', 'contiene'];
		// Personalizada: no se sabe su tipo, asi que se ofrecen los tres.
		return ['igual', 'contiene', 'rango'];
	}

	/**
	 * Los rotulos dicen lo que hace el operador, no como se llama. "es igual a"
	 * a secas parece lo mas natural del mundo y despues no encuentra nada
	 * porque el catalogo guarda "Azul" y la persona escribio "azul".
	 */
	const ROTULO_OPERADOR: Record<Operador, string> = {
		igual: 'es exactamente',
		contiene: 'contiene',
		rango: 'entre'
	};

	/**
	 * Lo que hay en un campo, siempre como texto listo para la URL.
	 *
	 * Hace falta porque un <input type="number"> con bind:value NO guarda
	 * texto: guarda un numero, y undefined cuando el campo esta vacio.
	 * Llamarle .trim() a eso revienta con "is not a function", y como pasa
	 * dentro de buscar(), la excepcion se lleva la peticion entera: la
	 * pantalla se queda en "Buscando..." para siempre, sin un solo error a la
	 * vista. Estaba pasando con precio_min y precio_max desde antes de los
	 * filtros nuevos.
	 */
	function texto(valor: unknown): string {
		return valor == null ? '' : String(valor).trim();
	}

	/** Lo que guarda un campo bindeado: texto, o numero si el control es numerico. */
	type Campo = string | number | undefined;

	/**
	 * Los query params que produce un filtro. Uno solo, salvo el rango, que
	 * son los dos que el backend combina en "entre": min_X y max_X.
	 */
	function paramsDe(f: FiltroCarac): [string, string][] {
		const n = f.nombre;
		if (!n) return [];

		if (f.operador === 'contiene') {
			return f.valor ? [['contiene_' + n, f.valor]] : [];
		}
		if (f.operador === 'igual') {
			return f.valor ? [[n, f.valor]] : [];
		}

		const salida: [string, string][] = [];
		if (f.desde) salida.push(['min_' + n, f.desde]);
		if (f.hasta) salida.push(['max_' + n, f.hasta]);
		return salida;
	}

	/** Como se lee el filtro en su etiqueta. */
	function describir(f: FiltroCarac): string {
		const u = f.unidad ? ' ' + f.unidad : '';
		if (f.operador === 'contiene') return `${f.nombre} contiene "${f.valor}"`;
		if (f.operador === 'igual') {
			if (f.tipo === 'booleano') return `${f.nombre}: ${f.valor === 'true' ? 'si' : 'no'}`;
			return `${f.nombre}: ${f.valor}${u}`;
		}
		if (f.desde && f.hasta) return `${f.nombre}: entre ${f.desde} y ${f.hasta}${u}`;
		if (f.desde) return `${f.nombre}: desde ${f.desde}${u}`;
		return `${f.nombre}: hasta ${f.hasta}${u}`;
	}

	// ---------- estado ----------

	let productos = $state<Producto[]>([]);
	let cursor = $state<number | null>(null);
	/**
	 * Nace en true, no en false.
	 *
	 * Los productos se piden en onMount, asi que entre el primer pintado y esa
	 * llamada no hay ninguno todavia. Con `false`, ese hueco caia en la rama de
	 * "no hay nada" y la pagina abria diciendo "Ningun producto coincide con lo
	 * que buscaste" y un contador en 0, antes de haber preguntado siquiera. No
	 * saber todavia no es lo mismo que no haber encontrado nada.
	 */
	let cargando = $state(true);
	let trayendoMas = $state(false);
	let error = $state('');
	let primeraVez = $state(true);

	/**
	 * Si lo ultimo que fallo fue traer la SIGUIENTE tanda, no la busqueda.
	 *
	 * Los dos fallos se ven igual en pantalla (el mismo parrafo rojo) pero no se
	 * reintentan igual: volver a empezar despues de un "Ver mas" que no llego
	 * tiraria las tandas que ya estaban acumuladas y devolveria a la persona a
	 * las primeras 12, que es perder trabajo por un fallo de red.
	 */
	let falloAlTraerMas = $state(false);

	/**
	 * Las dos formas de recorrer el catalogo. El backend expone las dos con los
	 * mismos filtros: GET /productos pagina por cursor (una tanda encima de la
	 * anterior) y GET /productos/paginacion por numero de pagina, que permite
	 * saltar directo a cambio de contar el total.
	 *
	 * Nace en 'scroll' porque es lo que habia antes: cambiar el modo por defecto
	 * cambiaria la pagina de inicio de todo el mundo sin que nadie lo pidiera.
	 */
	type Modo = 'scroll' | 'paginas';
	let modo = $state<Modo>('scroll');

	// Lo que trae GET /productos/paginacion. Solo significan algo en modo
	// paginas; en scroll se quedan como estaban y no se pintan.
	let pagina = $state(1);
	let totalPaginas = $state(0);
	let totalProductos = $state(0);

	/** Lo escrito en "Ir a la pagina". Puede ser numero: el control es numerico. */
	let saltoA = $state<Campo>('');
	let avisoSalto = $state('');

	let categorias = $state<CategoriaBreve[]>([]);
	let paleta = $state<CategoriaCompleta | null>(null);
	let cargandoPaleta = $state(false);

	// Los filtros fijos
	let nombre = $state('');
	let idCategoria = $state('');
	let precioMin = $state<Campo>('');
	let precioMax = $state<Campo>('');
	let soloVariantesActivas = $state(false);

	/**
	 * El filtro de stock. Los tres primeros casos son los que la gente pide de
	 * verdad, y cada uno es un solo valor de stock_min o stock_max; "rango"
	 * abre los dos campos para lo demas.
	 */
	type Disponibilidad = 'cualquiera' | 'con-stock' | 'agotados' | 'rango';
	let disponibilidad = $state<Disponibilidad>('cualquiera');
	let stockMin = $state<Campo>('');
	let stockMax = $state<Campo>('');

	// Los filtros de caracteristica ya agregados
	let filtros = $state<FiltroCarac[]>([]);
	let secuencia = 0;

	// La fila de "agregar un filtro"
	let nuevoNombre = $state('');
	/** El operador que la persona eligio a mano. null = el que toque por su tipo. */
	let operadorElegido = $state<Operador | null>(null);
	let nuevoValor = $state<Campo>('');
	let nuevoDesde = $state<Campo>('');
	let nuevoHasta = $state<Campo>('');
	let errorFiltro = $state('');

	/**
	 * Las caracteristicas que ofrece la categoria elegida, en una sola lista.
	 *
	 * Se juntan las del producto y las de la variante a proposito: el backend
	 * busca un filtro dinamico en las cuatro ubicaciones a la vez, asi que
	 * separarlas aqui daria a entender una diferencia que la consulta no hace.
	 * Se quitan los nombres repetidos porque unas cuantas (Largo, Ancho, Alto,
	 * Potencia, Voltaje) estan en las dos listas.
	 */
	let definiciones = $derived.by(() => {
		const mapa = new Map<string, Definicion>();
		for (const d of paleta?.caracteristicas ?? []) mapa.set(d.nombre, d);
		for (const d of paleta?.caracteristicas_variante ?? []) {
			if (!mapa.has(d.nombre)) mapa.set(d.nombre, d);
		}
		return mapa;
	});

	let nombresOfrecidos = $derived([...definiciones.keys()].sort((a, b) => a.localeCompare(b)));

	/** Lo que come el buscador de categorias. El valor es el id, que es lo que viaja. */
	let opcionesCategoria = $derived(
		categorias.map((c) => ({ texto: c.nombre, valor: String(c.id_categoria) }))
	);

	/** Lo que come el buscador de caracteristicas: el nombre, con su unidad a la vista. */
	let opcionesCaracteristica = $derived(
		nombresOfrecidos.map((n) => {
			const u = definiciones.get(n)?.unidad;
			return { texto: u ? `${n} (${u})` : n, valor: n };
		})
	);

	/** El tipo de lo que se esta agregando; null si es personalizada. */
	let nuevoTipo = $derived(nuevoNombre === '' ? null : (definiciones.get(nuevoNombre)?.tipo_dato ?? null));

	let nuevosOperadores = $derived(operadoresDe(nuevoTipo));

	/**
	 * El operador de la fila. Se deriva del tipo en vez de asignarse a mano al
	 * cambiar de caracteristica: asi no depende de si la caja se actualizo antes
	 * o despues del manejador, y si el elegido no aplica al tipo nuevo (venias de
	 * un numero con "entre" y pasas a un texto) cae solo al que si aplica.
	 */
	let nuevoOperador = $derived(
		operadorElegido && nuevosOperadores.includes(operadorElegido)
			? operadorElegido
			: nuevosOperadores[0]
	);

	/** Al elegir otra caracteristica se vuelve al operador que le toca por su tipo. */
	function alElegirCaracteristica() {
		operadorElegido = null;
		nuevoValor = '';
		nuevoDesde = '';
		nuevoHasta = '';
		errorFiltro = '';
	}

	// ---------- las llamadas ----------

	/**
	 * Los filtros puestos, ya como query params. Se arma solo con lo que este
	 * puesto y NO incluye como se pagina: eso lo pone cada modo encima.
	 *
	 * Esta separado justo por eso. Los dos modos filtran con los mismos
	 * parametros (el backend usa el mismo construirFiltro para las dos rutas),
	 * asi que si cada uno armara los suyos se irian separando en cuanto alguien
	 * agregue un filtro y lo ponga solo en uno.
	 *
	 * URLSearchParams codifica los espacios como "+", que es una de las dos
	 * formas que acepta la ruta ("Memoria+RAM" o "Memoria%20RAM"). Comprobado
	 * contra el backend: las dos devuelven lo mismo.
	 */
	function paramsFiltros(): URLSearchParams {
		const p = new URLSearchParams();
		p.set('limite', String(POR_TANDA));

		if (texto(nombre)) p.set('nombre', texto(nombre));
		if (idCategoria) p.set('id_categoria', idCategoria);
		// precio_min/precio_max van sobre precio_desde, el mas barato al que se
		// ofrece. La tarjeta ensena el de la tienda, pero quien pone un tope
		// quiere lo que puede pagar: si la tienda pide Q4100 y otro vendedor lo
		// tiene en Q3856, buscar "hasta Q4000" tiene que encontrarlo.
		if (texto(precioMin)) p.set('precio_min', texto(precioMin));
		if (texto(precioMax)) p.set('precio_max', texto(precioMax));
		// estado_variante y el rango de precio describen la MISMA variante: el
		// backend los mete en un solo $elemMatch. Marcar la casilla con un
		// rango puesto pide "una variante activa Y que cueste eso", no dos
		// variantes distintas que cumplan una cosa cada una.
		if (soloVariantesActivas) p.set('estado_variante', 'activa');

		// stock_min y stock_max son la excepcion a lo de "la misma variante":
		// van sobre stock_total, que es la suma de TODAS las variantes del
		// producto. Por eso no entran en el $elemMatch de arriba.
		if (disponibilidad === 'con-stock') {
			p.set('stock_min', '1');
		} else if (disponibilidad === 'agotados') {
			p.set('stock_max', '0');
		} else if (disponibilidad === 'rango') {
			if (texto(stockMin)) p.set('stock_min', texto(stockMin));
			if (texto(stockMax)) p.set('stock_max', texto(stockMax));
		}

		for (const f of filtros) {
			for (const [clave, valor] of paramsDe(f)) p.set(clave, valor);
		}

		return p;
	}

	/** La URL del modo scroll: los filtros mas el cursor. */
	function consulta(despuesDe: number | null): string {
		const p = paramsFiltros();
		if (despuesDe !== null) p.set('despues_de', String(despuesDe));
		return `/productos?${p.toString()}`;
	}

	/** La URL del modo paginas: los MISMOS filtros mas el numero de pagina. */
	function consultaPagina(numero: number): string {
		const p = paramsFiltros();
		p.set('pagina', String(numero));
		return `/productos/paginacion?${p.toString()}`;
	}

	/**
	 * Lo que llama cualquier cambio de filtro, en los dos modos. Reparte aqui
	 * para que ningun manejador de filtro tenga que saber cual esta puesto.
	 *
	 * En paginas se vuelve SIEMPRE a la 1: el filtro nuevo cambia cuantas
	 * paginas hay, y quedarse en la 7 de algo que ahora tiene 2 deja la pantalla
	 * vacia sin ninguna explicacion.
	 */
	function buscar(): Promise<void> {
		return modo === 'paginas' ? buscarPagina(1) : buscarCursor();
	}

	/** Vuelve a empezar: cambio un filtro, la lista anterior ya no vale. */
	async function buscarCursor() {
		cargando = true;
		error = '';
		falloAlTraerMas = false;
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
		falloAlTraerMas = false;
		const r = await pedir<Tanda>(consulta(cursor));
		if (r.ok && r.payload) {
			productos = [...productos, ...r.payload.productos];
			cursor = r.payload.siguiente_cursor;
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
			falloAlTraerMas = true;
		}
		trayendoMas = false;
	}

	/**
	 * Una pagina concreta. REEMPLAZA la lista, no la acumula: en este modo lo
	 * que se ve es la pagina, no todo lo que se ha recorrido.
	 *
	 * La lista anterior se deja en pantalla mientras carga y solo se vacia si
	 * falla. Vaciarla antes pintaria "Ningun producto coincide" en el hueco
	 * entre pedir y recibir, que es decir que no hay nada cuando todavia no se
	 * sabe.
	 */
	async function buscarPagina(numero: number) {
		cargando = true;
		error = '';
		avisoSalto = '';
		falloAlTraerMas = false;
		const r = await pedir<TandaPaginada>(consultaPagina(numero));
		if (r.ok && r.payload) {
			productos = r.payload.productos;
			// La pagina se toma de la respuesta y no de `numero`: el backend es
			// quien decide cual sirvio, y asi la cuenta de abajo dice lo que se
			// esta viendo de verdad.
			pagina = r.payload.pagina;
			totalPaginas = r.payload.total_paginas;
			totalProductos = r.payload.total_productos;
			saltoA = r.payload.pagina;
		} else {
			productos = [];
			totalPaginas = 0;
			totalProductos = 0;
			// Se guarda la pedida, no la anterior: es la que tiene que reintentar.
			pagina = numero;
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
		// El cursor es del otro modo. Dejarlo con valor pintaria "Ver mas
		// productos" debajo de una pagina, y esa tanda no seria la siguiente
		// pagina sino la continuacion de otro recorrido.
		cursor = null;
		cargando = false;
		primeraVez = false;
	}

	/**
	 * Ir a una pagina, si existe. Los extremos ya vienen deshabilitados en el
	 * markup; esto es el segundo cierre, por si se llama desde otro sitio.
	 */
	function irA(numero: number) {
		if (cargando) return;
		if (numero < 1 || numero > totalPaginas) return;
		buscarPagina(numero);
	}

	/**
	 * El salto a mano. Va en un <form> para que Enter dentro de la caja valga
	 * igual que el boton; sin prevenir el envio el navegador recarga la pagina y
	 * se pierden todos los filtros puestos.
	 */
	function saltar(evento: SubmitEvent) {
		evento.preventDefault();
		avisoSalto = '';
		const numero = Number(texto(saltoA));
		if (!Number.isInteger(numero) || numero < 1 || numero > totalPaginas) {
			avisoSalto =
				totalPaginas > 0
					? `Escribe un numero de pagina entre 1 y ${totalPaginas}.`
					: 'Todavia no hay paginas que recorrer.';
			return;
		}
		buscarPagina(numero);
	}

	/**
	 * Cambiar de forma de recorrer. Se vuelve a preguntar en vez de reaprovechar
	 * lo que hay en pantalla: la lista del scroll puede llevar cuatro tandas
	 * acumuladas, y eso no es "la pagina 1" de nada.
	 */
	function cambiarModo(nuevo: Modo) {
		if (modo === nuevo) return;
		modo = nuevo;
		avisoSalto = '';
		if (nuevo === 'paginas') buscarPagina(1);
		else buscarCursor();
	}

	/**
	 * Un fallo no borra los filtros: reintentar vuelve a pedir exactamente lo
	 * mismo que fallo, y solo eso.
	 *
	 * El error se limpia aqui y no dentro de verMas() (que no lo toca) porque si
	 * no, un "Ver mas" que si llega a la segunda deja el parrafo rojo puesto
	 * debajo de una lista que ya se completo.
	 */
	function reintentar() {
		error = '';
		if (falloAlTraerMas) verMas();
		else if (modo === 'paginas') buscarPagina(pagina);
		else buscarCursor();
	}

	/** El selector de categoria sale de GET /categorias, que es publica. */
	async function cargarCategorias() {
		const r = await pedir<CategoriaBreve[]>('/categorias');
		if (r.ok && r.payload) categorias = r.payload;
	}

	/**
	 * La paleta de la categoria elegida: GET /categorias/:id trae que
	 * caracteristicas ofrece, con su tipo_dato y su unidad. De ahi sale el
	 * desplegable de filtros y el control que le toca a cada una.
	 */
	async function cargarPaleta() {
		if (!idCategoria) {
			paleta = null;
			nuevoNombre = '';
			return;
		}
		cargandoPaleta = true;
		const r = await pedir<CategoriaCompleta>(`/categorias/${idCategoria}`);
		paleta = r.ok && r.payload ? r.payload : null;
		cargandoPaleta = false;
		// Lo que este escrito en el buscador de caracteristicas se deja: sigue
		// siendo un filtro valido aunque la categoria nueva no lo ofrezca, y
		// borrarselo a la persona sin avisar es peor que dejarlo.
	}

	/**
	 * El id llega como parametro y se asigna aqui, aunque `valor` ya este
	 * bindeado: asi no depende de si la propiedad bindeada se propago antes o
	 * despues de la llamada. Asignar dos veces el mismo valor no cuesta nada;
	 * cargar la paleta de la categoria anterior si.
	 */
	async function alCambiarCategoria(id: string) {
		idCategoria = id;
		await Promise.all([cargarPaleta(), buscar()]);
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

	// ---------- agregar y quitar filtros de caracteristica ----------

	function agregarFiltro() {
		errorFiltro = '';
		const nombreCarac = texto(nuevoNombre);

		if (!nombreCarac) {
			errorFiltro = 'Elige una caracteristica.';
			return;
		}
		// Las mismas dos reglas que valida el backend, para no mandar algo que
		// ya se sabe que va a contestar 400.
		if (nombreCarac.length > LARGO_MAXIMO_NOMBRE) {
			errorFiltro = `El nombre no puede pasar de ${LARGO_MAXIMO_NOMBRE} caracteres.`;
			return;
		}
		if (CLAVES_RESERVADAS.has(nombreCarac)) {
			errorFiltro = `"${nombreCarac}" es el nombre de un filtro fijo de la API y no se puede usar como caracteristica.`;
			return;
		}

		const definicion = definiciones.get(nombreCarac) ?? null;
		const filtro: FiltroCarac = {
			id: ++secuencia,
			nombre: nombreCarac,
			unidad: definicion?.unidad ?? null,
			tipo: definicion?.tipo_dato ?? null,
			operador: nuevoOperador,
			valor: texto(nuevoValor),
			desde: texto(nuevoDesde),
			hasta: texto(nuevoHasta)
		};

		if (paramsDe(filtro).length === 0) {
			errorFiltro = 'Escribe el valor que quieres buscar.';
			return;
		}

		// Un mismo nombre con el mismo operador se pisaria en la URL
		// (URLSearchParams.set), asi que aqui se reemplaza en vez de duplicar.
		filtros = [
			...filtros.filter((f) => !(f.nombre === filtro.nombre && f.operador === filtro.operador)),
			filtro
		];

		nuevoValor = '';
		nuevoDesde = '';
		nuevoHasta = '';
		buscar();
	}

	function quitarFiltro(id: number) {
		filtros = filtros.filter((f) => f.id !== id);
		buscar();
	}

	/**
	 * Los filtros de igualdad sobre algo que es texto. Son los unicos que pueden
	 * fallar por una mayuscula: "es exactamente" compara el valor entero tal
	 * cual, asi que "azul" no encuentra "Azul". Cuando la busqueda sale vacia y
	 * hay alguno puesto, se ofrece pasarlos a "contiene", que el backend resuelve
	 * con una expresion regular sin distinguir mayusculas.
	 */
	let exactosDeTexto = $derived(
		filtros.filter(
			(f) =>
				f.operador === 'igual' &&
				f.tipo !== 'booleano' &&
				f.tipo !== 'entero' &&
				f.tipo !== 'decimal'
		)
	);

	function aflojarExactos() {
		const aCambiar = new Set(exactosDeTexto.map((f) => f.id));
		filtros = filtros.map((f) =>
			aCambiar.has(f.id) ? { ...f, operador: 'contiene' as Operador } : f
		);
		buscar();
	}

	function limpiar() {
		nombre = '';
		idCategoria = '';
		precioMin = '';
		precioMax = '';
		soloVariantesActivas = false;
		disponibilidad = 'cualquiera';
		stockMin = '';
		stockMax = '';
		filtros = [];
		paleta = null;
		nuevoNombre = '';
		operadorElegido = null;
		nuevoValor = '';
		nuevoDesde = '';
		nuevoHasta = '';
		errorFiltro = '';
		buscar();
	}

	let hayFiltro = $derived(
		Boolean(
			texto(nombre) ||
				idCategoria ||
				texto(precioMin) ||
				texto(precioMax) ||
				soloVariantesActivas ||
				disponibilidad !== 'cualquiera' ||
				filtros.length > 0
		)
	);

	onMount(() => {
		cargarCategorias();
		buscar();
	});

	// ---------- lo que se ensena de cada producto ----------

	/**
	 * El dinero llega como Decimal128 de Mongo, no como numero: viaja en
	 * { $numberDecimal: "4100.00" }. Se guarda asi a proposito, porque el
	 * numero de JavaScript es punto flotante y pierde centavos.
	 */
	function aNumero(precio: Decimal | null | undefined): number {
		if (precio == null) return 0;
		if (typeof precio === 'number') return precio;
		if (typeof precio === 'string') return Number(precio);
		return Number(precio.$numberDecimal ?? 0);
	}

	function quetzales(n: number): string {
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}

	/**
	 * El precio que va en la tarjeta: el de la tienda. Es la regla del
	 * profesor, el primero siempre es el de la pagina.
	 *
	 * Ya no se calcula recorriendo las variantes. Desde el giro multi-vendedor
	 * el producto no tiene "un precio" que deducir: cada vendedor pone el
	 * suyo, y el documento trae el de la tienda ya resuelto.
	 */
	function precio(p: Producto): string {
		const n = aNumero(p.precio_tienda);
		return n > 0 ? quetzales(n) : 'Sin precio';
	}

	/**
	 * Lo que se puede pagar, cuando alguien lo tiene mas barato que la tienda.
	 * Devuelve null si el de la tienda ya es el mejor: en ese caso la tarjeta
	 * ensena un solo numero y no dos iguales.
	 *
	 * Existe porque esconderlo seria mentir por omision. La tarjeta dice
	 * Q4100 y el producto se puede comprar en Q3856; si el buscador lo
	 * devuelve por un tope de Q4000 (que lo hace, filtra por este) y la
	 * tarjeta solo dijera Q4100, el resultado pareceria un error.
	 */
	function precioDesde(p: Producto): string | null {
		const tienda = aNumero(p.precio_tienda);
		const desde = aNumero(p.precio_desde);
		if (desde <= 0) return null;
		if (tienda > 0 && desde >= tienda) return null;
		return quetzales(desde);
	}

	/**
	 * Que decir del stock. Siguen siendo tres casos, pero ahora salen de dos
	 * numeros de verdad en vez de deducirse contando variantes:
	 *
	 *   hay          stock_total > 0
	 *   sin-oferta   nadie lo vende todavia (total_ofertas === 0)
	 *   agotado      hay vendedores, pero ninguno tiene unidades
	 *
	 * Antes esto era peor. stock_total se sumaba de variantes[].stock, que era
	 * OPCIONAL, asi que "se vendio todo" y "nadie registro existencias" daban
	 * el mismo 0 y habia que ir a contar cuantas variantes traian el campo. De
	 * ahi salio el bug del `every()`: bastaba UNA variante en 0 para dar el
	 * producto entero por agotado, afirmando que se vendio lo que nunca se
	 * registro.
	 *
	 * Ahora los dos numeros vienen calculados del lado de la base y ninguno
	 * falta, asi que la pregunta se contesta mirando, no deduciendo.
	 */
	function estadoStock(p: Producto): 'hay' | 'sin-oferta' | 'agotado' {
		if (p.stock_total > 0) return 'hay';
		return p.total_ofertas === 0 ? 'sin-oferta' : 'agotado';
	}

	/**
	 * Los id de los productos cuya portada no cargo.
	 *
	 * Va en estado y no poniendo una clase desde el manejador: Svelte borra del
	 * bundle los selectores que no ve escritos en el markup, asi que una clase
	 * agregada por JS se queda sin CSS y en silencio.
	 */
	let rotas = $state<number[]>([]);

	function marcarRota(id: number) {
		if (!rotas.includes(id)) rotas = [...rotas, id];
	}

	function portada(p: Producto): string | null {
		for (const v of p.variantes) {
			if (v.imagenes && v.imagenes.length > 0) return v.imagenes[0];
		}
		return null;
	}

	/**
	 * Tres caracteristicas para la tarjeta. Se saltan los nombres repetidos:
	 * ensenar "Etiquetas" tres veces no dice nada.
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
			<div>
				<h1>El catalogo</h1>
				<p>
					{#if cargando}
						Buscando...
					{:else if error}
						&nbsp;
					{:else if modo === 'paginas'}
						<!-- Aqui la cuenta es la del catalogo entero, no la de lo que se ve:
						     el $facet de la ruta cuenta todo lo que pasa el filtro, y decir
						     "12 productos" estando en la pagina 3 de 9 seria mentir. -->
						{totalProductos}
						{totalProductos === 1 ? 'producto' : 'productos'}
						{hayFiltro
							? totalProductos === 1
								? 'que coincide'
								: 'que coinciden'
							: 'en la tienda'}{totalPaginas > 1 ? `, en ${totalPaginas} paginas` : ''}
					{:else}
						{productos.length}
						{productos.length === 1 ? 'producto' : 'productos'}
						{hayFiltro
							? productos.length === 1
								? 'que coincide'
								: 'que coinciden'
							: 'en la tienda'}{cursor !== null ? ' y hay mas' : ''}
					{/if}
				</p>
			</div>

			<!--
				El interruptor entre las dos formas de recorrer el catalogo. Las dos
				piden lo mismo al backend con los mismos filtros; lo unico que cambia
				es la ruta y como se pide la siguiente tanda.
			-->
			<div class="modos" role="group" aria-label="Forma de recorrer el catalogo">
				<button
					type="button"
					class:activo={modo === 'scroll'}
					aria-pressed={modo === 'scroll'}
					onclick={() => cambiarModo('scroll')}
				>
					Scroll
				</button>
				<button
					type="button"
					class:activo={modo === 'paginas'}
					aria-pressed={modo === 'paginas'}
					onclick={() => cambiarModo('paginas')}
				>
					Paginas
				</button>
			</div>
		</div>

		<!-- Los filtros. Cada cambio vuelve a preguntarle al backend -->
		<section class="filtros" aria-label="Filtros">
			<div class="fijos">
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

				<!--
					Igual que el de caracteristicas, pero aqui la categoria SI tiene
					que ser una de la lista: lo que viaja es id_categoria, un entero,
					y un nombre inventado no significa nada. Por eso sin permitirLibre:
					escribir algo que no esta y salirse del campo lo borra y avisa.
					Vaciar la caja es "todas", de ahi limpiarSiVacio.
				-->
				<div class="envoltura media">
					<Autocompletar
						id="f-cat"
						etiqueta="Categoria"
						opciones={opcionesCategoria}
						bind:valor={idCategoria}
						alElegir={alCambiarCategoria}
						marcador="Todas"
						mostrarAlEnfocar
						limpiarSiVacio
						compacto
					/>
				</div>

				<div class="campo corto">
					<label for="f-min">Precio desde</label>
					<input
						id="f-min"
						type="number"
						min="0"
						step="0.01"
						placeholder="0"
						bind:value={precioMin}
						oninput={alEscribir}
					/>
				</div>

				<div class="campo corto">
					<label for="f-max">hasta</label>
					<input
						id="f-max"
						type="number"
						min="0"
						step="0.01"
						placeholder="Sin tope"
						bind:value={precioMax}
						oninput={alEscribir}
					/>
				</div>

				<!--
					stock_min / stock_max. Los tres primeros casos son un solo valor
					cada uno, asi que no hace falta ensenar dos cajas para pedirlos.
				-->
				<div class="campo">
					<label for="f-disp">Disponibilidad</label>
					<select id="f-disp" bind:value={disponibilidad} onchange={buscar}>
						<option value="cualquiera">Cualquiera</option>
						<option value="con-stock">Con stock</option>
						<!-- El backend filtra por stock_total = 0, y ahi caen los dos
						     casos: el que se vendio todo y el que nunca registro
						     existencias. No hay filtro que los separe, asi que se
						     nombra por lo que de verdad devuelve. -->
						<option value="agotados">Sin unidades disponibles</option>
						<option value="rango">Rango exacto...</option>
					</select>
				</div>

				{#if disponibilidad === 'rango'}
					<div class="campo corto">
						<label for="f-stock-min">Stock desde</label>
						<input
							id="f-stock-min"
							type="number"
							min="0"
							step="1"
							placeholder="0"
							bind:value={stockMin}
							oninput={alEscribir}
						/>
					</div>
					<div class="campo corto">
						<label for="f-stock-max">hasta</label>
						<input
							id="f-stock-max"
							type="number"
							min="0"
							step="1"
							placeholder="Sin tope"
							bind:value={stockMax}
							oninput={alEscribir}
						/>
					</div>
				{/if}

				<label class="casilla" for="f-var">
					<input id="f-var" type="checkbox" bind:checked={soloVariantesActivas} onchange={buscar} />
					<span>Solo variantes activas</span>
				</label>

				{#if hayFiltro}
					<button type="button" class="limpiar" onclick={limpiar}>Quitar filtros</button>
				{/if}
			</div>

			<!--
				Los filtros de caracteristica. El desplegable sale de
				GET /categorias/:id, que trae el tipo_dato y la unidad de cada
				una; de ahi sale tambien que operadores tiene sentido ofrecer.
			-->
			<div class="dinamicos">
				<div class="fila-nuevo">
					<!--
						Buscador en vez de desplegable: una categoria ofrece hasta 46
						caracteristicas y recorrerlas a ojo no es forma de filtrar. Se
						escribe y se va acotando, o se enfoca y sale la lista para
						ojearla. Acepta un nombre que no este en la lista, que es como
						se filtra por una caracteristica personalizada: esas las
						escribio quien publico el producto y no hay lista que consultar.
					-->
					<div class="envoltura">
						<Autocompletar
							id="f-car"
							etiqueta="Caracteristica"
							opciones={opcionesCaracteristica}
							bind:valor={nuevoNombre}
							alElegir={alElegirCaracteristica}
							deshabilitado={cargandoPaleta}
							marcador={idCategoria
								? 'Escribe o elige de la lista'
								: 'Elige una categoria, o escribe una'}
							permitirLibre
							mostrarAlEnfocar
							compacto
						/>
					</div>

					{#if nuevoNombre}
						{#if nuevosOperadores.length > 1}
							<div class="campo">
								<label for="f-op">Operador</label>
								<select
									id="f-op"
									value={nuevoOperador}
									onchange={(e) => (operadorElegido = e.currentTarget.value as Operador)}
								>
									{#each nuevosOperadores as op (op)}
										<option value={op}>{ROTULO_OPERADOR[op]}</option>
									{/each}
								</select>
							</div>
						{/if}

						{#if nuevoTipo === 'booleano'}
							<div class="campo">
								<label for="f-bool">Valor</label>
								<select id="f-bool" bind:value={nuevoValor}>
									<option value="">Elige</option>
									<option value="true">Si</option>
									<option value="false">No</option>
								</select>
							</div>
						{:else if nuevoOperador === 'rango'}
							<div class="campo corto">
								<label for="f-desde">Desde</label>
								<input
									id="f-desde"
									type="number"
									step={nuevoTipo === 'entero' ? '1' : 'any'}
									bind:value={nuevoDesde}
								/>
							</div>
							<div class="campo corto">
								<label for="f-hasta">Hasta</label>
								<input
									id="f-hasta"
									type="number"
									step={nuevoTipo === 'entero' ? '1' : 'any'}
									bind:value={nuevoHasta}
								/>
							</div>
						{:else}
							<div class="campo ancho">
								<label for="f-val">Valor</label>
								<input
									id="f-val"
									type={nuevoTipo === 'entero' || nuevoTipo === 'decimal' ? 'number' : 'text'}
									step={nuevoTipo === 'entero' ? '1' : 'any'}
									placeholder={nuevoTipo === 'lista' ? 'Uno de los de la lista' : ''}
									bind:value={nuevoValor}
								/>
							</div>
						{/if}

						<button type="button" class="agregar" onclick={agregarFiltro}>Agregar</button>
					{/if}
				</div>

				{#if errorFiltro}
					<p class="aviso">{errorFiltro}</p>
				{/if}

				{#if filtros.length > 0}
					<ul class="etiquetas">
						{#each filtros as f (f.id)}
							<li>
								<span>{describir(f)}</span>
								<button
									type="button"
									onclick={() => quitarFiltro(f.id)}
									aria-label={'Quitar el filtro ' + f.nombre}
								>
									&times;
								</button>
							</li>
						{/each}
					</ul>
				{/if}
			</div>
		</section>

		{#if error}
			<p class="error">
				{error}
				<button type="button" class="enlace" onclick={reintentar}>Reintentar</button>
			</p>
		{/if}

		<!--
			"Todavia no se sabe" no se pinta igual que "no hay nada". Mientras se
			espera una respuesta y no hay lista que ensenar, esto dice que se esta
			buscando; el mensaje de "ningun producto coincide" solo aparece cuando ya
			contesto el backend.
		-->
		{#if cargando && productos.length === 0}
			<p class="vacio">{primeraVez ? 'Cargando el catalogo...' : 'Buscando productos...'}</p>
		{:else if productos.length === 0 && !error}
			<p class="vacio">
				Ningun producto coincide con lo que buscaste.
				{#if hayFiltro}<button type="button" class="enlace" onclick={limpiar}>
						Quitar los filtros
					</button>{/if}
			</p>

			<!--
				La causa mas comun de una busqueda vacia: "es exactamente" compara el
				valor entero y distingue mayusculas, y el catalogo guarda "Azul". En
				vez de dejar a la persona adivinando, se le dice y se le ofrece el
				operador que si lo encuentra.
			-->
			{#if exactosDeTexto.length > 0}
				<p class="pista">
					<strong>es exactamente</strong> busca el valor completo y distingue mayusculas: “azul”
					no encuentra “Azul”.
					<button type="button" class="enlace" onclick={aflojarExactos}>
						Probar con “contiene”
					</button>
				</p>
			{/if}
		{/if}

		<div class="rejilla">
			{#each productos as p (p._id)}
				<article class="tarjeta">
					<a class="cara" href="/producto/{p._id}">
						<div class="foto">
							<!-- Una portada que no carga se trata igual que no tenerla.
							     Las urls son de fuera (Wikimedia), y cuando una se cae el
							     navegador deja su icono de imagen rota con el texto alt al
							     lado: se ve peor que el hueco limpio de "Sin imagen", y
							     ademas parece un fallo de la pagina y no del enlace. -->
							{#if portada(p) && !rotas.includes(p._id)}
								<img
									src={portada(p)}
									alt={p.nombre}
									loading="lazy"
									onerror={() => marcarRota(p._id)}
								/>
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

							<!-- El segundo precio solo aparece cuando alguien lo tiene mas
							     barato que la tienda. Si no, no se pintan dos numeros
							     iguales. -->
							{#if precioDesde(p)}
								<p class="desde">
									desde <strong>{precioDesde(p)}</strong> con otro vendedor
								</p>
							{/if}

							{#if p.total_ofertas > 1}
								<p class="ofertas">{p.total_ofertas} vendedores lo tienen</p>
							{/if}

							<!-- stock_total viene siempre, no hay que pedirlo con nada.
							     Pero 0 no siempre quiere decir "agotado": ver estadoStock(). -->
							{#if p.stock_total !== undefined}
								{@const estado = estadoStock(p)}
								<span
									class="stock"
									class:agotado={estado === 'agotado'}
									class:sin-dato={estado === 'sin-oferta'}
								>
									{#if estado === 'hay'}
										{p.stock_total} en existencia
									{:else if estado === 'sin-oferta'}
										Nadie lo vende todavia
									{:else}
										Agotado
									{/if}
								</span>
							{/if}
						</div>
					</a>
				</article>
			{/each}
		</div>

		{#if modo === 'scroll' && cursor !== null && productos.length > 0}
			<div class="mas">
				<button type="button" onclick={verMas} disabled={trayendoMas}>
					{trayendoMas ? 'Trayendo...' : 'Ver mas productos'}
				</button>
			</div>
		{/if}

		<!--
			La barra de paginas. Solo con total_paginas > 0: cuando el filtro no
			encuentra nada no hay ninguna pagina que recorrer, y ensenar "Pagina 1
			de 0" con las dos flechas muertas no dice nada que el mensaje de vacio
			no diga ya.
		-->
		{#if modo === 'paginas' && totalPaginas > 0}
			<nav class="paginacion" aria-label="Paginas del catalogo">
				<button
					type="button"
					onclick={() => irA(pagina - 1)}
					disabled={cargando || pagina <= 1}
				>
					Anterior
				</button>

				<span class="cuenta" aria-live="polite">Pagina {pagina} de {totalPaginas}</span>

				<button
					type="button"
					onclick={() => irA(pagina + 1)}
					disabled={cargando || pagina >= totalPaginas}
				>
					Siguiente
				</button>

				<!-- El salto directo es lo unico que el modo cursor no puede hacer:
				     la ruta de paginacion no necesita haber pedido las anteriores. -->
				<form class="salto" onsubmit={saltar}>
					<label for="p-salto">Ir a la pagina</label>
					<input
						id="p-salto"
						type="number"
						min="1"
						max={totalPaginas}
						step="1"
						bind:value={saltoA}
					/>
					<button type="submit" disabled={cargando}>Ir</button>
				</form>
			</nav>

			{#if avisoSalto}
				<p class="aviso-salto">{avisoSalto}</p>
			{/if}
		{/if}
	</div>
</main>

<Pie />

<style>
	main {
		padding: 2.5rem 0 4rem;
	}

	.intro {
		display: flex;
		flex-wrap: wrap;
		align-items: flex-end;
		justify-content: space-between;
		gap: 1rem;
		margin-bottom: 1.75rem;
	}

	.intro p {
		color: var(--gris);
		margin-top: 0.35rem;
	}

	/* Un interruptor de dos, no dos botones sueltos: el borde compartido dice
	   que son la misma decision y que solo uno puede estar puesto. */
	.modos {
		display: flex;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		overflow: hidden;
	}

	.modos button {
		padding: 7px 16px;
		font-family: inherit;
		font-size: 0.88rem;
		color: var(--gris);
		background: var(--blanco);
		border: none;
		cursor: pointer;
		transition:
			color var(--t),
			background var(--t);
	}

	.modos button + button {
		border-left: 1px solid var(--linea);
	}

	.modos button:hover:not(.activo) {
		color: var(--indigo);
		background: var(--indigo-cl);
	}

	.modos button.activo {
		color: var(--blanco);
		background: var(--indigo);
	}

	/* ---------- filtros ---------- */

	.filtros {
		padding: 1.1rem;
		margin-bottom: 2rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.fijos,
	.fila-nuevo {
		display: flex;
		flex-wrap: wrap;
		align-items: flex-end;
		gap: 0.9rem;
	}

	.dinamicos {
		margin-top: 1.1rem;
		padding-top: 1.1rem;
		border-top: 1px solid var(--linea);
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
		min-width: 150px;
	}

	.campo.ancho {
		flex: 1 1 200px;
	}

	.campo.corto {
		min-width: 110px;
		max-width: 130px;
	}

	/* El buscador de caracteristicas se trae su propio label y su propia caja,
	   asi que aqui solo se le da el sitio que ocupa en la fila. */
	.envoltura {
		display: flex;
		flex-direction: column;
		flex: 1 1 240px;
		min-width: 200px;
	}

	.envoltura.media {
		flex: 0 1 190px;
		min-width: 150px;
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

	.filtros input:disabled,
	.filtros select:disabled {
		background: var(--panel);
		color: var(--gris-2);
	}

	.casilla {
		display: flex;
		align-items: center;
		gap: 0.45rem;
		padding-bottom: 10px;
		font-size: 0.92rem;
		color: var(--texto);
		cursor: pointer;
	}

	.casilla input {
		width: auto;
		accent-color: var(--indigo);
	}

	.limpiar,
	.agregar {
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
			color var(--t),
			background var(--t);
	}

	.limpiar:hover {
		border-color: var(--indigo);
		color: var(--indigo);
		background: var(--indigo-cl);
	}

	.agregar {
		color: var(--blanco);
		background: var(--indigo);
		border-color: var(--indigo);
	}

	.agregar:hover {
		color: var(--blanco);
		background: var(--indigo-os);
		border-color: var(--indigo-os);
	}

	.aviso {
		margin-top: 0.7rem;
		font-size: 0.88rem;
		color: var(--rojo);
	}

	.pista {
		margin-top: -1.5rem;
		padding-bottom: 2.5rem;
		text-align: center;
		font-size: 0.92rem;
		color: var(--gris);
	}

	.pista strong {
		font-weight: 500;
		color: var(--texto);
	}

	.etiquetas {
		list-style: none;
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
		margin-top: 0.9rem;
	}

	.etiquetas li {
		display: flex;
		align-items: center;
		gap: 0.4rem;
		padding: 5px 6px 5px 11px;
		font-size: 0.86rem;
		color: var(--indigo);
		background: var(--indigo-cl);
		border-radius: 999px;
	}

	.etiquetas button {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 19px;
		height: 19px;
		font-family: inherit;
		font-size: 1rem;
		line-height: 1;
		color: var(--indigo);
		background: none;
		border: none;
		border-radius: 999px;
		cursor: pointer;
	}

	.etiquetas button:hover {
		background: var(--blanco);
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
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
		transition: border-color var(--t);
	}

	.tarjeta:hover {
		border-color: var(--indigo);
	}

	.cara {
		display: flex;
		flex-direction: column;
		flex: 1;
		color: inherit;
		text-decoration: none;
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

	.stock {
		margin-top: 0.3rem;
		font-size: 0.8rem;
		color: var(--gris);
	}

	.stock.agotado {
		color: var(--rojo);
	}

	/* "Sin existencias registradas" no es una alarma como "Agotado": es un dato
	   que falta. Por eso va en gris y no en rojo. */
	.stock.sin-dato {
		color: var(--gris-2);
		font-style: italic;
	}

	.desde {
		margin: 0;
		padding: 0 1rem 2px;
		font-size: 0.8rem;
		color: var(--gris);
	}

	.desde strong {
		font-weight: 500;
		color: var(--indigo);
	}

	.ofertas {
		margin: 0;
		padding: 0 1rem 4px;
		font-size: 0.75rem;
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

	/* ---------- la barra de paginas ---------- */

	.paginacion {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: center;
		gap: 0.7rem;
		margin-top: 2.25rem;
	}

	/* Solo los hijos directos: los del formulario de salto tienen lo suyo. */
	.paginacion > button {
		padding: 9px 18px;
		font-family: inherit;
		font-size: 0.92rem;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t),
			background var(--t);
	}

	.paginacion > button:hover:not(:disabled) {
		color: var(--indigo);
		background: var(--indigo-cl);
		border-color: var(--indigo);
	}

	/* En los extremos el boton se queda, apagado: quitarlo moveria los demas de
	   sitio en cada pagina y habria que volver a buscar donde quedo el otro. */
	.paginacion > button:disabled {
		color: var(--gris-2);
		background: var(--panel);
		cursor: default;
	}

	.cuenta {
		min-width: 125px;
		text-align: center;
		font-size: 0.94rem;
		color: var(--texto);
	}

	.salto {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		margin-left: 0.6rem;
		padding-left: 1.1rem;
		border-left: 1px solid var(--linea);
	}

	.salto label {
		font-size: 0.86rem;
		color: var(--gris);
	}

	.salto input {
		width: 74px;
		padding: 8px 10px;
		font-family: inherit;
		font-size: 0.92rem;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		transition: border-color var(--t);
	}

	.salto input:focus {
		outline: none;
		border-color: var(--indigo);
	}

	.salto button {
		padding: 8px 15px;
		font-family: inherit;
		font-size: 0.9rem;
		color: var(--blanco);
		background: var(--indigo);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			background var(--t),
			border-color var(--t);
	}

	.salto button:hover:not(:disabled) {
		background: var(--indigo-os);
		border-color: var(--indigo-os);
	}

	.salto button:disabled {
		opacity: 0.6;
		cursor: default;
	}

	.aviso-salto {
		margin-top: 0.6rem;
		text-align: center;
		font-size: 0.86rem;
		color: var(--rojo);
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
		/* En una fila propia, la raya vertical y el sangrado separan de nada. */
		.salto {
			margin-left: 0;
			padding-left: 0;
			border-left: none;
		}
	}
</style>
