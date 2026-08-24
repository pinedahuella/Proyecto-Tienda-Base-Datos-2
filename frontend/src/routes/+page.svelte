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
	 *              id_vendedor, precio_min, precio_max, estado_variante
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

	interface Variante {
		id_producto_variante: number;
		nombre_variante: string;
		precio: { $numberDecimal: string } | string | number;
		descripcion: string | null;
		estado: string;
		imagenes: string[];
		stock?: number;
		caracteristicas_adicionales?: Caracteristica[];
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
		caracteristicas_personalizadas?: Caracteristica[];
		/**
		 * La suma de variantes[].stock. No se guarda en Mongo: la calcula el
		 * backend al responder, y por eso viene siempre, sin pedirla. Una
		 * variante sin stock cuenta como 0.
		 */
		stock_total?: number;
	}

	interface Tanda {
		productos: Producto[];
		siguiente_cursor: number | null;
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
		'id_vendedor',
		'precio_min',
		'precio_max',
		'estado_variante',
		'stock_min',
		'stock_max'
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
	let cargando = $state(false);
	let trayendoMas = $state(false);
	let error = $state('');
	let primeraVez = $state(true);

	let categorias = $state<CategoriaBreve[]>([]);
	let paleta = $state<CategoriaCompleta | null>(null);
	let cargandoPaleta = $state(false);

	// Los filtros fijos
	let nombre = $state('');
	let idCategoria = $state('');
	let precioMin = $state<Campo>('');
	let precioMax = $state<Campo>('');
	let soloVariantesActivas = $state(false);
	let idVendedor = $state('');
	let vendedorRotulo = $state('');

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
	 * La URL que se le pide al backend. Se arma sola con lo que este puesto.
	 *
	 * URLSearchParams codifica los espacios como "+", que es una de las dos
	 * formas que acepta la ruta ("Memoria+RAM" o "Memoria%20RAM"). Comprobado
	 * contra el backend: las dos devuelven lo mismo.
	 */
	function consulta(despuesDe: number | null): string {
		const p = new URLSearchParams();
		p.set('limite', String(POR_TANDA));
		if (despuesDe !== null) p.set('despues_de', String(despuesDe));

		if (texto(nombre)) p.set('nombre', texto(nombre));
		if (idCategoria) p.set('id_categoria', idCategoria);
		if (idVendedor) p.set('id_vendedor', idVendedor);
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

	function filtrarPorVendedor(p: Producto) {
		idVendedor = String(p.vendedor.id_usuario);
		vendedorRotulo = p.vendedor.usuario;
		buscar();
	}

	function quitarVendedor() {
		idVendedor = '';
		vendedorRotulo = '';
		buscar();
	}

	function limpiar() {
		nombre = '';
		idCategoria = '';
		precioMin = '';
		precioMax = '';
		soloVariantesActivas = false;
		idVendedor = '';
		vendedorRotulo = '';
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
				idVendedor ||
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

	/**
	 * Que decir del stock de un producto. Son TRES casos, no dos, y
	 * stock_total no los separa: el backend suma las variantes contando como 0
	 * las que no traen el campo `stock`, asi que "se vendio todo" y "nadie le
	 * ha registrado existencias" dan el mismo 0.
	 *
	 *   hay          stock_total > 0
	 *   sin-dato     NINGUNA variante trae el campo: nadie registro nada
	 *   agotado      todas lo traen y suman 0: de verdad no queda ninguna
	 *   ninguno      mixto: unas registradas en 0 y otras sin registrar
	 *
	 * El cuarto caso es el que se colaba: con un `every()` bastaba UNA variante
	 * registrada en 0 para que el producto entero se diera por inventariado y
	 * saliera "Agotado" en rojo, afirmando que se vendio lo que nunca se
	 * registro. Se nombra por lo que consta y ya.
	 */
	function estadoStock(p: Producto): 'hay' | 'sin-dato' | 'agotado' | 'ninguno' {
		if ((p.stock_total ?? 0) > 0) return 'hay';
		const registradas = p.variantes.filter((v) => v.stock !== undefined).length;
		if (registradas === 0) return 'sin-dato';
		if (registradas === p.variantes.length) return 'agotado';
		return 'ninguno';
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
			<h1>El catalogo</h1>
			<p>
				{#if cargando}
					Buscando...
				{:else if error}
					&nbsp;
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

				{#if filtros.length > 0 || idVendedor}
					<ul class="etiquetas">
						{#if idVendedor}
							<li>
								<span>Vendedor: {vendedorRotulo}</span>
								<button
									type="button"
									onclick={quitarVendedor}
									aria-label="Quitar el filtro de vendedor"
								>
									&times;
								</button>
							</li>
						{/if}
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
			<p class="error">{error}</p>
		{/if}

		{#if cargando && primeraVez}
			<p class="vacio">Cargando el catalogo...</p>
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

							<!-- stock_total viene siempre, no hay que pedirlo con nada.
							     Pero 0 no siempre quiere decir "agotado": ver estadoStock(). -->
							{#if p.stock_total !== undefined}
								{@const estado = estadoStock(p)}
								<span
									class="stock"
									class:agotado={estado === 'agotado' || estado === 'ninguno'}
									class:sin-dato={estado === 'sin-dato'}
								>
									{#if estado === 'hay'}
										{p.stock_total} en existencia
									{:else if estado === 'sin-dato'}
										Sin existencias registradas
									{:else if estado === 'agotado'}
										Agotado
									{:else}
										Sin unidades disponibles
									{/if}
								</span>
							{/if}
						</div>
					</a>

					<!-- Va fuera del enlace: un boton dentro de un <a> no es HTML valido -->
					<button type="button" class="vendedor" onclick={() => filtrarPorVendedor(p)}>
						Ver todo de {p.vendedor.usuario}
					</button>
				</article>
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

	.vendedor {
		width: 100%;
		padding: 8px 1rem;
		font-family: inherit;
		font-size: 0.8rem;
		text-align: left;
		color: var(--gris);
		background: var(--off);
		border: none;
		border-top: 1px solid var(--linea);
		cursor: pointer;
		transition:
			color var(--t),
			background var(--t);
	}

	.vendedor:hover {
		color: var(--indigo);
		background: var(--indigo-cl);
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
