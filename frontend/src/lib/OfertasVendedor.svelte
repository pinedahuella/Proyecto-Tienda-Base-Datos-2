<script lang="ts">
	import { onMount } from 'svelte';
	import { pedir, conJson, mensajeUtil, type RespuestaApi } from './api';
	import Autocompletar from './Autocompletar.svelte';
	import { textoConflictoDescuento, textoPorcentaje, tieneDescuento } from './descuento';

	/**
	 * Las ofertas del vendedor: verlas, editarlas y publicar una nueva.
	 *
	 * Esta pantalla reemplaza a la de inventario. En el modelo multi-vendedor
	 * el producto no es de nadie y ya no tiene precio ni stock: quien vende,
	 * a como y con cuantas unidades es una fila de `oferta`, en PostgreSQL.
	 * Las rutas viejas (`/vendedor/productos/:id/inventario`) leian la tabla
	 * `inventario`, que se borro del esquema.
	 *
	 * Las rutas que usa:
	 *   GET    /vendedor/ofertas                    las mias, en cualquier estado
	 *   GET    /vendedor/ofertas/producto/:id       un producto con sus variantes
	 *   POST   /vendedor/ofertas                    publicar
	 *   PATCH  /vendedor/ofertas/:id                precio, estado y/o ajuste de stock
	 *   POST   /vendedor/ofertas/:id/venta-limitada abrir la venta relampago
	 *   DELETE /vendedor/ofertas/:id/venta-limitada cerrarla
	 *   POST   /vendedor/ofertas/:id/descuento      poner un % de descuento
	 *   DELETE /vendedor/ofertas/:id/descuento      quitarlo
	 *
	 * Y una del catalogo publico, `GET /productos?nombre=`, para buscar sobre
	 * que variante publicar.
	 */

	let {
		alExpirarSesion,
		administraLaTienda = false
	}: {
		alExpirarSesion?: () => void;
		/**
		 * Si esta cuenta opera como la tienda: `tienda@mesh.com` o un admin.
		 *
		 * Los dos son el mismo caso desde el commit `bd12cd4`:
		 * `OfertasVendedorService.resolverIdEfectivo()` cambia el `id_usuario`
		 * del token por el de la tienda apenas entra una peticion de admin, asi
		 * que las cuatro rutas de `/vendedor/ofertas` le contestan exactamente
		 * lo mismo a los dos. Por eso hay un solo interruptor y no dos.
		 *
		 * Y por eso importa: la tienda oferta TODAS las variantes del catalogo,
		 * asi que `GET /vendedor/ofertas` le devuelve 202 filas -- y al admin
		 * le devolveria esas mismas 202. Un vendedor normal tiene ~90 y esa
		 * lista es su pantalla entera, asi que a el se le trae completa.
		 *
		 * A quien administra la tienda se le entra por el PRODUCTO: la lista
		 * sale del catalogo paginado y las ofertas de un producto se piden al
		 * abrirlo, con `GET /vendedor/ofertas/producto/:id`.
		 *
		 * Medido hoy, mediana de tres corridas en caliente:
		 *
		 *   GET /vendedor/ofertas              84 KB   254 ms   202 filas
		 *   GET /productos?limite=20           40 KB   188 ms    20 filas
		 *   GET /vendedor/ofertas/producto/68   2 KB    59 ms
		 *
		 * El argumento NO es el tiempo: 254 ms no es una tragedia, y decir lo
		 * contrario seria inventar. Son dos cosas: los BYTES de la primera
		 * pantalla (40 contra 84 KB, y 20 filas con imagen contra 202), y que
		 * el coste de la lista completa crece con el catalogo mientras el de
		 * una tanda no. Con 1000 productos la primera revienta y la segunda
		 * sigue costando lo mismo.
		 */
		administraLaTienda?: boolean;
	} = $props();

	// ---------------------------------------------------------------- tipos
	type EstadoOferta = 'pendiente' | 'activa' | 'pausada' | 'retirada' | 'rechazada';

	/**
	 * Un rechazo de la tienda. Son varios por oferta: si se corrige y se vuelve a
	 * rechazar, queda otra fila, y por eso se listan del mas nuevo al mas viejo.
	 */
	interface Rechazo {
		id_rechazo_oferta: string;
		razon_rechazo: string;
		fecha_rechazo: string;
	}

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
		/**
		 * Tambien texto, por lo mismo: es un decimal de PostgreSQL. Es el precio
		 * de LISTA: un descuento no lo toca. Lo que se cobra es `precio_final`.
		 */
		precio: string;
		/** El % de descuento vigente ("25.00"), o null si no tiene. */
		porcentaje_descuento: string | null;
		/**
		 * `precio` con el descuento aplicado, calculado por PostgreSQL. Sin
		 * descuento es igual a `precio`. Aqui no se recalcula nunca.
		 */
		precio_final: string;
		stock: number;
		estado: EstadoOferta;
		/**
		 * Cuando la tienda la aprobo. NULL = nunca. Es lo que decide si el
		 * vendedor puede activarla o pausarla el solo: sin ella el backend
		 * responde 409.
		 */
		fecha_aprobacion: string | null;
		/**
		 * Si esta oferta tiene su VENTA RELAMPAGO abierta
		 * (`oferta.es_inventario_limitado`, migracion 014).
		 *
		 * Mientras vale true su stock NO lo lleva PostgreSQL: lo lleva un
		 * contador atomico en Redis, y agregarla al carrito aparta unidades de
		 * verdad. Es lo unico que decide si el boton de la fila dice "Abrir
		 * venta relampago" o "Cerrar la venta", asi que sin este campo el panel
		 * no podria pintar ninguno de los dos.
		 */
		es_inventario_limitado: boolean;
		/**
		 * Las unidades que quedan AHORA, del contador de Redis. Solo trae numero
		 * con la venta relampago abierta; `null` en una oferta normal, en una
		 * cuya venta ya cerro, y cuando Redis no contesto.
		 *
		 * Mientras la venta esta abierta, `stock` de arriba **esta congelado** en
		 * el valor que tenia al abrirla. Los dos numeros son utiles y por eso se
		 * ensenan los dos: el vendedor quiere saber con cuantas abrio y cuantas
		 * le quedan.
		 */
		stock_disponible: number | null;
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
			/** Lo mismo que en `Oferta`. */
			porcentaje_descuento: string | null;
			precio_final: string;
			stock: number;
			estado: EstadoOferta;
			/**
			 * Cuando la tienda la aprobo. NULL = nunca.
			 *
			 * Esto FALTABA aqui, y no porque el backend no lo mandara: la ruta
			 * devuelve ocho campos en `mi_oferta` y este tipo declaraba cuatro.
			 * El dato llegaba y el tipo lo escondia.
			 *
			 * Lo que costo: el formulario de editar de ESTA vista no tenia como
			 * saber si la oferta estaba aprobada, asi que ofrecia los cinco
			 * estados a todo el mundo -- incluidos `pendiente` y `rechazada`,
			 * que el backend nunca acepta, y `activa`/`pausada` sobre una oferta
			 * sin aprobar, que da 409. Tres errores distintos, todos provocados
			 * por la pantalla.
			 *
			 * La leccion, que vale para el resto del archivo: un tipo que declara
			 * de menos no es "conservador", es una capacidad que se pierde en
			 * silencio. No hay error en ningun lado; simplemente el dato no
			 * existe para quien lo necesita.
			 */
			fecha_aprobacion: string | null;
			/**
			 * Lo mismo que en `Oferta`, y se declara aqui por la misma leccion
			 * de arriba: la ruta lo manda desde el 2026-09-03 y sin escribirlo
			 * el dato llegaria y el tipo lo esconderia.
			 *
			 * Importa mas de lo que parece: quien administra la TIENDA entra por
			 * esta vista y no por la lista, asi que la cuenta que mas ofertas
			 * tiene solo puede abrir una venta relampago desde aqui.
			 */
			es_inventario_limitado: boolean;
			/** Lo mismo que en `Oferta`: las unidades reales de Redis, o null. */
			stock_disponible: number | null;
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

	/**
	 * Lo minimo para editar una oferta: es lo unico que miran `guardarFila` y
	 * `stockResultante`.
	 *
	 * Existe para que las dos vistas compartan el MISMO codigo de edicion. En
	 * la lista se edita una `Oferta` completa; en el catalogo se edita el
	 * `mi_oferta` que viene embebido en la variante, que trae cuatro campos y
	 * no doce. Con este tipo las dos encajan y no hay dos validaciones que
	 * mantener sincronizadas.
	 */
	type OfertaEditable = Pick<Oferta, 'id_oferta' | 'precio' | 'stock' | 'estado'>;

	/**
	 * Lo minimo para abrir o cerrar una venta relampago, por lo mismo que
	 * `OfertaEditable`: las dos vistas tienen que compartir el codigo.
	 *
	 * Lleva `stock` porque el boton dice cuantas unidades se van a sembrar, y
	 * `estado` porque solo una oferta `activa` admite abrirla -- el backend
	 * contesta 409 con cualquier otro, y decirlo antes ahorra la vuelta.
	 */
	type OfertaRelampago = Pick<
		Oferta,
		'id_oferta' | 'stock' | 'estado' | 'es_inventario_limitado' | 'porcentaje_descuento'
	>;

	/**
	 * Lo minimo para poner o quitar un descuento, por lo mismo que las dos de
	 * arriba. Lleva `es_inventario_limitado` porque con la venta relampago
	 * abierta el backend no deja quitar el descuento (409), y se dice antes.
	 */
	type OfertaDescuento = Pick<
		Oferta,
		'id_oferta' | 'precio' | 'porcentaje_descuento' | 'precio_final' | 'es_inventario_limitado'
	>;

	/**
	 * 'lista'     todas mis ofertas de golpe. Un vendedor normal.
	 * 'catalogo'  el catalogo paginado, y las ofertas de un producto al abrirlo.
	 *             Es lo que ven la tienda y el admin.
	 * 'publicar'  buscar un producto para publicar una oferta nueva.
	 */
	type Vista = 'lista' | 'publicar' | 'catalogo' | 'revision';

	/**
	 * Una oferta esperando el visto bueno de la tienda, tal como la manda
	 * GET /vendedor/ofertas/pendientes. Trae el vendedor, que en la lista propia
	 * no hace falta: aqui son de otros.
	 */
	interface Pendiente {
		id_oferta: string;
		id_producto: number;
		id_producto_variante: number;
		nombre_producto: string;
		nombre_variante: string;
		imagen: string | null;
		/** De lista. Ver `Oferta`. */
		precio: string;
		porcentaje_descuento: string | null;
		precio_final: string;
		stock: number;
		fecha_creacion: string;
		vendedor: {
			id_usuario: string;
			usuario: string;
			nombre: string;
			apellido: string | null;
		};
	}

	/**
	 * Los cinco estados que una oferta PUEDE TENER. Sirven para las pestanas
	 * del filtro, que tienen que poder listar las cinco.
	 */
	const ESTADOS: EstadoOferta[] = ['pendiente', 'activa', 'pausada', 'retirada', 'rechazada'];

	/**
	 * Los tres estados que un vendedor PUEDE PEDIR al editar. No son los
	 * mismos, y confundirlos era un bug.
	 *
	 * `pendiente` y `rechazada` los pone el flujo de aprobacion, nunca el
	 * cliente: `pendiente` lo pone la creacion (o una edicion de una oferta sin
	 * aprobar) y `rechazada` lo pone la tienda. El backend los rechaza de plano
	 * -- es su `ESTADOS_OFERTA_VALIDOS`, en models/estado-oferta.ts.
	 *
	 * Lo que pasaba: el select de editar se llenaba con los CINCO. Elegir
	 * "pendiente" o "rechazada" mandaba un PATCH que volvia con
	 * "El estado debe ser uno de: activa, pausada, retirada" -- un error que
	 * la pantalla provoco sola, ofreciendo una opcion que sabia invalida.
	 * La regla: un control no ofrece lo que el servidor no acepta.
	 */
	const ESTADOS_EDITABLES: EstadoOferta[] = ['activa', 'pausada', 'retirada'];

	/**
	 * Que estados se le pueden ofrecer a ESTA oferta en el select de editar.
	 *
	 * Siempre entra el suyo actual, que significa "dejalo como esta": guardar
	 * sin tocarlo no manda el campo (ver guardarFila), asi que una oferta
	 * `pendiente` puede editarse el precio sin que su estado viaje.
	 *
	 * Y si nunca fue aprobada, la unica salida real es retirarla: `activa` y
	 * `pausada` devuelven 409 con "todavia no fue aprobada por la tienda".
	 * Ofrecerlas seria repetir el mismo error de antes con otro codigo.
	 */
	function estadosPosibles(o: { estado: EstadoOferta; fecha_aprobacion: string | null }) {
		const destinos = sinAprobar(o) ? (['retirada'] as EstadoOferta[]) : ESTADOS_EDITABLES;
		return [o.estado, ...destinos.filter((e) => e !== o.estado)];
	}

	/**
	 * Si la oferta todavia no paso por la tienda.
	 *
	 * Se mira `fecha_aprobacion` y no el estado, porque es exactamente lo que
	 * mira el backend (`nuncaAprobada`) para decidir si el vendedor puede
	 * activarla o pausarla el solo. Deducirlo del estado casi alcanzaba, pero
	 * `retirada` es ambigua -- se puede retirar una aprobada y tambien una que
	 * nunca se miro -- y ahi la deduccion se equivocaba en un sentido o en otro.
	 */
	function sinAprobar(o: { fecha_aprobacion: string | null }): boolean {
		return o.fecha_aprobacion == null;
	}

	/** Cuantos productos por tanda en la vista de catalogo. */
	const POR_TANDA = 20;

	// ---------------------------------------------------------------- estado
	let vista = $state<Vista>('lista');
	let ofertas = $state<Oferta[]>([]);
	let cargando = $state(true);
	let error = $state('');
	let aviso = $state('');

	/** 'todas' o uno de los cinco estados. Se filtra en el SERVIDOR (`estado=`) y por eso cambiarlo pide otra pagina. */
	let filtro = $state<'todas' | EstadoOferta>('todas');

	// ------------------------------------------------- el catalogo paginado
	/**
	 * La tanda de productos que se esta enseñando, y por donde seguir.
	 *
	 * Se pagina por CURSOR (`despues_de` = el ultimo `_id` de la tanda) y no
	 * por numero de pagina, que es el mismo modo "Scroll" del catalogo
	 * publico: aqui la lista solo crece hacia abajo y nunca se salta a una
	 * pagina suelta, asi que el cursor sobra de sobra y no se descuadra si
	 * alguien publica un producto entre dos tandas.
	 */
	let productosCatalogo = $state<ProductoEnBusqueda[]>([]);
	let cursor = $state<number | null>(null);
	let cargandoTanda = $state(false);
	let errorCatalogo = $state('');
	/** El producto abierto en la vista de catalogo. Su detalle va en `productoElegido`. */
	let abierto = $state<number | null>(null);
	/** Hay mas tandas por pedir. */
	let hayMas = $derived(cursor !== null);

	// ------------------------------------------------- los filtros del catalogo
	/**
	 * Se filtra en el SERVIDOR, no en memoria.
	 *
	 * Es la misma regla del catalogo publico: filtrar aqui solo alcanzaria a
	 * las tandas ya descargadas, asi que buscar "laptop" con 20 productos en
	 * pantalla diria "no hay ninguna" teniendo siete. `GET /productos` ya
	 * acepta `nombre` e `id_categoria`, asi que el filtro viaja en la misma
	 * peticion que la paginacion y el cursor se reinicia con cada cambio.
	 */
	let fNombre = $state('');
	let fCategoria = $state('');
	let fCategoriaTexto = $state('');
	let fCategoriaElegida = $state(false);

	interface CategoriaBreve {
		id_categoria: number;
		nombre: string;
		categoria_padre: string | null;
	}

	let categorias = $state<CategoriaBreve[]>([]);
	let opcionesCategoria = $derived(
		categorias.map((c) => ({
			texto: c.categoria_padre ? `${c.categoria_padre} > ${c.nombre}` : c.nombre,
			valor: String(c.id_categoria)
		}))
	);

	/** true si hay algun filtro puesto. */
	let hayFiltro = $derived(fNombre.trim() !== '' || fCategoria !== '');

	let temporizadorFiltro: ReturnType<typeof setTimeout> | null = null;

	/** Al escribir en el filtro de nombre se espera un poco y se vuelve a pedir. */
	function alFiltrarNombre() {
		if (temporizadorFiltro) clearTimeout(temporizadorFiltro);
		temporizadorFiltro = setTimeout(() => void cargarTanda(true), ESPERA_MS);
	}

	function alElegirCategoria(valor: string) {
		fCategoria = valor;
		void cargarTanda(true);
	}

	function limpiarFiltros() {
		if (temporizadorFiltro) {
			clearTimeout(temporizadorFiltro);
			temporizadorFiltro = null;
		}
		fNombre = '';
		fCategoria = '';
		fCategoriaTexto = '';
		fCategoriaElegida = false;
		void cargarTanda(true);
	}

	// la edicion de una fila
	let editando = $state<string | null>(null);

	/**
	 * Los rechazos de UNA oferta, la que se este mirando.
	 *
	 * Se guarda el id de la abierta y no un booleano por fila, igual que
	 * `editando`: asi solo puede haber una desplegada a la vez y volver a pulsar
	 * el mismo boton la cierra.
	 */
	let rechazosDe = $state<string | null>(null);
	let rechazos = $state<Rechazo[]>([]);
	let cargandoRechazos = $state(false);
	let errorRechazos = $state('');
	let precioNuevo = $state('');
	let estadoNuevo = $state<EstadoOferta>('activa');
	let ajusteStock = $state('');
	let guardando = $state(false);
	let errorFila = $state('');

	// ------------------------------------------------- la venta relampago
	/**
	 * El id de la oferta cuyo panel de venta relampago esta desplegado, o null.
	 *
	 * Uno solo, igual que `editando` y `rechazosDe`: dos paneles abiertos a la
	 * vez comparten `duracionRelampago` y quien escriba una duracion en uno la
	 * veria aparecer en el otro.
	 */
	let relampagoDe = $state<string | null>(null);
	/** Los segundos elegidos, como texto. Vacio quiere decir "sin vencimiento". */
	let duracionRelampago = $state('');
	let relampagoOcupado = $state(false);
	let errorRelampago = $state('');

	/** El id de la oferta con el panel de descuento abierto, o null. */
	let descuentoDe = $state<string | null>(null);
	/**
	 * El % escrito, como TEXTO. Un input number con bind:value guarda un
	 * numero (o null si se borra), y .trim() sobre eso revienta; con texto y
	 * `inputmode` el teclado del telefono sale igual de numerico.
	 */
	let porcentajeNuevo = $state('');
	/**
	 * Cuanto dura el descuento, en segundos y como texto. Vacio es "sin limite",
	 * que es como funcionaba antes del 2026-09-24. Con duracion, el backend le
	 * pone vencimiento a la clave `mesh:oferta:<id>:descuento` y su worker lo
	 * quita solo al vencer.
	 */
	let duracionDescuento = $state('');
	let descuentoOcupado = $state(false);
	let errorDescuento = $state('');

	/**
	 * Lo que se puede elegir en "Cuando cierra".
	 *
	 * Una lista cerrada y no una caja de segundos. El backend acepta cualquier
	 * entero de 0 a 604800, pero ofrecer eso en crudo tenia dos costes: nadie
	 * piensa en segundos, y el numero invitaba a confundir el plazo de la VENTA
	 * con el plazo del COMPRADOR (15 minutos, fijo). Alguien que queria "quince
	 * minutos de venta" escribia 900 y cerraba su propia venta en quince
	 * minutos.
	 *
	 * El tope de la lista es el tope del backend, asi que no hace falta validar
	 * el rango en ningun sitio: no hay forma de elegir algo fuera.
	 *
	 * El vacio va primero porque es lo que casi siempre se quiere: abrir la
	 * venta y cerrarla a mano cuando toque.
	 */
	const DURACIONES = [
		{ valor: '', texto: 'Sin limite, la cierro yo' },
		{ valor: '3600', texto: 'En 1 hora' },
		{ valor: '21600', texto: 'En 6 horas' },
		{ valor: '86400', texto: 'En 1 dia' },
		{ valor: '259200', texto: 'En 3 dias' },
		{ valor: '604800', texto: 'En 7 dias' }
	];

	/**
	 * Lo mismo para el descuento manual. Mismos plazos y mismo tope (el backend
	 * valida los dos con `validarDuracionVencimiento`, de 0 a 604800), solo
	 * cambia como se dice el vacio.
	 */
	const DURACIONES_DESCUENTO = DURACIONES.map((d) =>
		d.valor === '' ? { valor: '', texto: 'Sin limite, lo quito yo' } : d
	);

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
	/** Solo para ensenar: dia y hora en corto. Mismo formato que Direcciones. */
	function cuando(iso: string): string {
		return new Date(iso).toLocaleString('es-GT', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}

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

	/**
	 * El buscador de la lista de un vendedor normal.
	 *
	 * Se usan LAS DOS RUTAS de ofertas, cada una para lo que hace bien:
	 *
	 *   sin texto  GET /vendedor/ofertas/paginado  una pagina de 20, ya filtrada por
	 *              estado en el servidor, mas los seis totales de las pestanas
	 *   con texto  GET /vendedor/ofertas           TODAS, y se filtra aqui
	 *
	 * El servidor no busca por texto, y filtrar solo la pagina que hay en pantalla
	 * diria "ninguna oferta se llama asi" teniendo tres en otra pagina. Con texto
	 * se trae la lista completa una sola vez (la primera que se escribe algo) y se
	 * guarda en `completas`; al vaciar la caja se vuelve a las paginas. Quien no
	 * busca nunca descarga esa lista, que para la tienda pesa 1.2 MB.
	 */
	let busquedaLista = $state('');

	/** Sin tildes y en minusculas, para que "audifonos" encuentre "Audifonos". */
	function plano(texto: string): string {
		return texto
			.normalize('NFD')
			.replace(/[̀-ͯ]/g, '')
			.toLowerCase();
	}

	/** La lista completa, solo cuando se busca por texto. null = todavia no se ha pedido. */
	let completas = $state<Oferta[] | null>(null);
	let cargandoCompletas = $state(false);

	let hayBusqueda = $derived(busquedaLista.trim() !== '');

	/**
	 * Las ofertas que se estan viendo.
	 *
	 * Sin busqueda son las de la PAGINA que trajo el servidor, que ya viene
	 * filtrada por estado. Con busqueda son las de `completas`, filtradas aqui por
	 * estado y por texto.
	 */
	let listaFiltrada = $derived.by(() => {
		const texto = plano(busquedaLista.trim());
		if (texto === '') return ofertas;

		const base = completas ?? [];
		const porEstado = filtro === 'todas' ? base : base.filter((o) => o.estado === filtro);

		// Busca en el producto Y en la variante: quien tiene casi mil ofertas suele
		// acordarse de una por la talla o el color, no por el nombre completo.
		return porEstado.filter(
			(o) =>
				plano(o.nombre_producto).includes(texto) || plano(o.nombre_variante).includes(texto)
		);
	});

	/**
	 * Cuantas hay de cada estado, para las pestanas.
	 *
	 * Vienen del SERVIDOR, no se cuentan aqui: con una pagina en memoria se diria
	 * "Activas 8" teniendo 894. Cada numero es el `total_ofertas` de una peticion
	 * con `estado=` (ver cargarConteos), que cuenta todas las ofertas de la
	 * cuenta y no las de la pagina.
	 */
	let conteos = $state<Record<'todas' | EstadoOferta, number>>({
		todas: 0,
		pendiente: 0,
		activa: 0,
		pausada: 0,
		retirada: 0,
		rechazada: 0
	});

	// ---------------------------------------------------------------- cargar
	/** Ofertas por pagina de la lista. */
	const POR_PAGINA = 20;

	/** Lo que devuelve GET /vendedor/ofertas/paginado. */
	interface PaginaOfertas {
		ofertas: Oferta[];
		pagina: number;
		limite: number;
		total_ofertas: number;
		total_paginas: number;
	}

	let pagina = $state(1);
	let totalPaginas = $state(0);
	let cargandoPagina = $state(false);

	/**
	 * Si la lista ya se cargo al menos una vez. Para un vendedor normal es que si
	 * desde el primer momento; para la tienda solo si entra a la lista.
	 *
	 * Hace falta para no mentir al parchear: en la vista de catalogo la lista esta
	 * vacia A PROPOSITO, y meterle la fila recien tocada la dejaba con UN elemento.
	 */
	let listaCargada = $state(false);

	function urlPagina(numero: number, estado: 'todas' | EstadoOferta, limite = POR_PAGINA): string {
		const p = new URLSearchParams({ pagina: String(numero), limite: String(limite) });
		if (estado !== 'todas') p.set('estado', estado);
		return `/vendedor/ofertas/paginado?${p.toString()}`;
	}

	/**
	 * Los seis numeros de las pestanas: una peticion de UNA oferta por cada estado
	 * mas una sin filtro, y de cada una solo se lee `total_ofertas`. Van juntas.
	 * Es lo que el servidor ya calcula bien (cuenta todas las ofertas de la cuenta
	 * que cumplen el filtro, en una sola foto de la base), y asi no se descarga
	 * ninguna oferta para saber cuantas hay.
	 */
	async function cargarConteos(): Promise<void> {
		const pedidos: ('todas' | EstadoOferta)[] = ['todas', ...ESTADOS];
		const respuestas = await Promise.all(
			pedidos.map((e) => pedir<PaginaOfertas>(urlPagina(1, e, 1)))
		);

		if (respuestas.some((r) => expiro(r))) return;

		const mala = respuestas.find((r) => !r.ok || !r.payload);
		if (mala) {
			error = mensajeUtil(mala);
			return;
		}

		const nuevos = { ...conteos };
		pedidos.forEach((e, i) => {
			nuevos[e] = respuestas[i].payload.total_ofertas;
		});
		conteos = nuevos;
	}

	/** Una pagina de la lista, del estado que este elegido en las pestanas. */
	async function cargarPagina(numero: number): Promise<void> {
		cargandoPagina = true;
		error = '';

		const r = await pedir<PaginaOfertas>(urlPagina(numero, filtro));
		cargandoPagina = false;

		// Antes el `return` de expiro() se iba dejando `cargando` en true, y la
		// pantalla se quedaba con "Cargando tus ofertas..." pegado para siempre.
		if (expiro(r)) return;

		if (!r.ok || !r.payload) {
			error = mensajeUtil(r);
			return;
		}

		// Una pagina que quedo mas alla del final (se movieron ofertas de estado
		// mientras se miraba) devuelve [] con el total correcto: se va a la ultima.
		const p = r.payload;
		if (p.ofertas.length === 0 && p.total_paginas > 0 && numero > p.total_paginas) {
			return cargarPagina(p.total_paginas);
		}

		ofertas = p.ofertas;
		pagina = p.pagina;
		totalPaginas = p.total_paginas;
		listaCargada = true;
	}

	/** Entrar a la lista: los contadores y la primera pagina, en paralelo. */
	async function cargar() {
		cargando = true;
		error = '';
		completas = null; // una lista de una busqueda anterior puede estar vieja
		await Promise.all([cargarConteos(), cargarPagina(1)]);
		cargando = false;
	}

	/** Volver a preguntar sin perder el sitio: contadores y la pagina en la que se estaba. */
	async function refrescarLista() {
		completas = null;
		await Promise.all([cargarConteos(), cargarPagina(pagina)]);
		// Si se estaba buscando, la lista completa hay que traerla otra vez.
		if (busquedaLista.trim() !== '') void alBuscarEnLista();
	}

	function elegirFiltro(e: 'todas' | EstadoOferta) {
		if (filtro === e) return;
		filtro = e;
		// Buscando, el filtro se aplica en memoria a `completas`: no hay a donde ir.
		if (!hayBusqueda) void cargarPagina(1);
	}

	function irAPagina(numero: number) {
		if (cargandoPagina || numero < 1 || numero > totalPaginas) return;
		void cargarPagina(numero);
	}

	/**
	 * Al escribir en el buscador: la PRIMERA vez que hay texto se trae la lista
	 * completa (la ruta sin paginar), y de ahi en adelante se filtra en memoria.
	 * Ver la explicacion de `busquedaLista`.
	 */
	async function alBuscarEnLista() {
		if (busquedaLista.trim() === '' || completas !== null || cargandoCompletas) return;
		cargandoCompletas = true;
		const r = await pedir<Oferta[]>('/vendedor/ofertas');
		cargandoCompletas = false;
		if (expiro(r)) return;
		if (r.ok && r.payload) {
			completas = r.payload;
		} else {
			error = mensajeUtil(r);
		}
	}

	/**
	 * Una tanda del catalogo.
	 *
	 * `reiniciar` la pide desde el principio (al entrar, o al limpiar la
	 * busqueda); si no, sigue desde el cursor. Se usa `GET /productos`, que es
	 * publico y ya viene paginado -- no hace falta ninguna ruta nueva.
	 */
	async function cargarTanda(reiniciar = false) {
		if (cargandoTanda) return;
		if (!reiniciar && cursor === null && productosCatalogo.length > 0) return;

		cargandoTanda = true;
		errorCatalogo = '';

		// Al filtrar se empieza de cero: el cursor de la tanda anterior es de
		// otra busqueda y saltaria productos.
		if (reiniciar) cursor = null;

		const partes = [`limite=${POR_TANDA}`];
		if (!reiniciar && cursor !== null) partes.push(`despues_de=${cursor}`);
		if (fNombre.trim() !== '') partes.push(`nombre=${encodeURIComponent(fNombre.trim())}`);
		if (fCategoria !== '') partes.push(`id_categoria=${encodeURIComponent(fCategoria)}`);

		const r = await pedir<ProductosPaginados>(`/productos?${partes.join('&')}`);

		cargandoTanda = false;
		if (expiro(r)) return;

		if (r.ok && r.payload) {
			const tanda = r.payload.productos ?? [];
			productosCatalogo = reiniciar ? tanda : [...productosCatalogo, ...tanda];
			// El backend solo pone `siguiente_cursor` en null cuando la tanda
			// vino CORTA, asi que con un total multiplo de POR_TANDA el boton
			// "Ver mas" sobrevive a la ultima tanda y gasta un viaje que no
			// trae nada. Una tanda corta ya dice que se acabo.
			cursor = tanda.length < POR_TANDA ? null : r.payload.siguiente_cursor;
		} else {
			errorCatalogo = mensajeUtil(r);
		}
	}

	/** Abre o cierra un producto del catalogo. Sus ofertas se piden al abrirlo. */
	async function alternarProducto(id: number) {
		errorPublicar = '';
		if (abierto === id) {
			abierto = null;
			productoElegido = null;
			return;
		}
		abierto = id;
		varianteElegida = null;
		cerrarEdicion();
		await elegirProducto(id);
	}

	onMount(() => {
		// Quien administra la tienda no arranca con sus 202 ofertas encima:
		// entra por el catalogo, de 20 en 20.
		if (administraLaTienda) {
			vista = 'catalogo';
			cargando = false;
			void cargarTanda(true);
			// La paleta del filtro. Es la ruta de vendedor, que acepta vendedor
			// Y admin (@Roles(2, 3)); trae solo las categorias hoja, que son
			// las unicas donde de verdad cuelga un producto.
			void pedir<CategoriaBreve[]>('/vendedor/categorias').then((r) => {
				if (r.ok && r.payload) categorias = r.payload;
			});
			return;
		}
		void cargar();
	});

	/**
	 * Mete la oferta que devolvio el backend en la lista, en su sitio.
	 *
	 * Se usa la que contesta el servidor y no la que se mando: el stock que
	 * queda despues de un ajuste lo calcula `reponer_stock()`, y la fecha de
	 * actualizacion la pone un trigger. Recalcularlos aqui seria adivinar.
	 */
	function guardarEnLista(o: Oferta) {
		// En la vista de catalogo la lista no se ha cargado A PROPOSITO. Meterle la
		// fila recien tocada la dejaba con UN elemento y las pestanas pasaban a
		// decir "Todas 1" cuando en realidad hay cientos sin cargar. No es la
		// lista: es un hueco.
		if (!listaCargada) return;

		const iPagina = ofertas.findIndex((x) => x.id_oferta === o.id_oferta);
		const iCompletas = completas ? completas.findIndex((x) => x.id_oferta === o.id_oferta) : -1;
		const estadoAntes =
			iPagina !== -1
				? ofertas[iPagina].estado
				: iCompletas !== -1 && completas
					? completas[iCompletas].estado
					: null;

		if (iPagina !== -1) ofertas[iPagina] = o;
		if (completas) {
			if (iCompletas !== -1) completas[iCompletas] = o;
			else completas = [o, ...completas];
		}

		// Una oferta nueva, o que cambio de estado, mueve los contadores y puede
		// cambiar de pestana o de pagina. Eso no se recalcula aqui: se le vuelve a
		// preguntar al servidor, que es quien lo sabe.
		if (estadoAntes !== o.estado) void refrescarLista();
	}

	// ---------------------------------------------------------------- editar
	function abrirEdicion(o: OfertaEditable) {
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
	function stockResultante(o: OfertaEditable): number | null {
		const texto = ajusteStock.trim();
		if (texto === '') return null;
		const n = Number(texto);
		if (!Number.isInteger(n) || n === 0) return null;
		return o.stock + n;
	}

	async function guardarFila(o: OfertaEditable) {
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
			// Y si se estaba editando desde el catalogo, el producto abierto
			// tiene su propia copia de la oferta: sin esto se quedaria
			// enseñando el precio de antes hasta cerrar y volver a abrir.
			refrescarEnProductoAbierto(r.payload);
			editando = null;
			aviso = `"${r.payload.nombre_producto} - ${r.payload.nombre_variante}" actualizada`;
		} else {
			errorFila = mensajeUtil(r);
		}
	}

	/** Mete la oferta recien guardada en la variante del producto abierto. */
	function refrescarEnProductoAbierto(o: Oferta) {
		if (productoElegido == null || productoElegido._id !== o.id_producto) return;

		productoElegido = {
			...productoElegido,
			variantes: productoElegido.variantes.map((v) =>
				v.id_producto_variante === o.id_producto_variante
					? {
							...v,
							mi_oferta: {
								id_oferta: o.id_oferta,
								precio: o.precio,
								// Sin copiar estos dos, poner un descuento no se veia
								// en la tarjeta del catalogo hasta volver a abrirla.
								porcentaje_descuento: o.porcentaje_descuento,
								precio_final: o.precio_final,
								stock: o.stock,
								estado: o.estado,
								// Va tambien la fecha de aprobacion, y no es un extra:
								// es lo que decide que estados puede pedir el vendedor.
								// Sin copiarla, la oferta recien guardada volvia a la
								// tarjeta SIN ella, o sea indistinguible de una que
								// nunca se aprobo, y el select de al lado cambiaba de
								// opciones despues de guardar sin que nadie tocara nada.
								fecha_aprobacion: o.fecha_aprobacion,
								// Y por lo mismo va la marca de venta relampago. Sin
								// copiarla, editar el precio de una oferta con la venta
								// ABIERTA la devolvia a la tarjeta sin la marca, o sea
								// indistinguible de una cerrada: el boton pasaba a decir
								// "Abrir venta relampago" sobre una que ya estaba abierta,
								// y el unico aviso habria sido el 409 del backend.
								es_inventario_limitado: o.es_inventario_limitado,
								// Y con ella su numero real, por lo mismo. Sin copiarlo, editar
								// el precio durante una venta devolvia la oferta a la tarjeta
								// con `stock_disponible` sin definir, y la tarjeta volvia a
								// ensenar el `stock` congelado de PostgreSQL.
								stock_disponible: o.stock_disponible
							}
						}
					: v
			)
		};
	}

	/**
	 * Pausar o reactivar sin abrir el formulario: es el cambio mas frecuente y
	 * no necesita escribir nada.
	 */
	/**
	 * Trae los motivos por los que la tienda devolvio una oferta.
	 *
	 * Es GET, asi que va sin `conJson`: `conJson` solo arma el cuerpo de las que
	 * mandan JSON, y pasarselo a un GET no rompe pero sobra.
	 */
	async function verRechazos(idOferta: string) {
		if (rechazosDe === idOferta) {
			rechazosDe = null;
			return;
		}

		rechazosDe = idOferta;
		rechazos = [];
		errorRechazos = '';
		cargandoRechazos = true;

		const r = await pedir<Rechazo[]>(`/vendedor/ofertas/${idOferta}/rechazos`);
		cargandoRechazos = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			rechazos = r.payload;
		} else {
			errorRechazos = mensajeUtil(r);
		}
	}

	async function cambiarEstado(o: OfertaEditable, estado: EstadoOferta) {
		aviso = '';
		error = '';
		guardando = true;
		const r = await pedir<Oferta>(`/vendedor/ofertas/${o.id_oferta}`, conJson('PATCH', { estado }));
		guardando = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			guardarEnLista(r.payload);
			refrescarEnProductoAbierto(r.payload);
			aviso = `"${r.payload.nombre_producto} - ${r.payload.nombre_variante}" quedo ${estado}`;
		} else {
			const texto = mensajeUtil(r);
			// `error` solo se pinta en la vista 'lista', asi que un fallo desde
			// el catalogo no se veia en ninguna parte: el boton se quedaba
			// quieto y no pasaba nada. Y al reves, en 'lista' ese mismo `error`
			// se lleva por delante la tabla entera (es una rama {:else if}),
			// asi que un 409 de una fila borraba las 202. Cada vista usa el
			// suyo: `errorFila` sale JUNTO a la oferta y no tapa nada.
			if (vista === 'catalogo') errorFila = texto;
			else error = texto;
		}
	}

	// -------------------------------------------------------- venta relampago
	/**
	 * Abre o cierra el panel de la venta relampago de una fila.
	 *
	 * El panel existe para las dos direcciones y no solo para abrir: CERRAR una
	 * venta descarta las reservas que haya en curso, asi que tambien pide un
	 * paso mas antes del clic definitivo. Un boton pelado que le quita a
	 * alguien lo que ya habia apartado no da tiempo a arrepentirse.
	 */
	function alternarRelampago(o: OfertaRelampago) {
		errorRelampago = '';
		if (relampagoDe === o.id_oferta) {
			relampagoDe = null;
			return;
		}
		relampagoDe = o.id_oferta;
		descuentoDe = null;
		duracionRelampago = '';
		aviso = '';
	}

	/**
	 * Deja la marca de venta relampago donde la pantalla la esta mirando.
	 *
	 * Son DOS sitios y hay que tocar los dos, igual que hacen `guardarEnLista` y
	 * `refrescarEnProductoAbierto` juntos: la lista tiene su propia copia de la
	 * oferta y el producto abierto del catalogo tiene otra dentro de la
	 * variante. Escribir solo una deja la otra vista diciendo lo contrario.
	 *
	 * No se recarga desde el servidor porque no hace falta: las dos rutas
	 * cambian exactamente un booleano, y volver a pedir las 976 ofertas del
	 * vendedor para enterarse de eso seria pagar la lista entera por un bit.
	 */
	function marcarRelampago(idOferta: string, abierta: boolean, sembrado: number | null = null) {
		// Al ABRIR, las unidades reales son las que el backend dice que sembro
		// (`stock_sembrado`), que es el stock de ese instante. Al CERRAR vuelven
		// a ser null, que es lo que significa "aqui manda PostgreSQL otra vez".
		// Sin esto, la fila quedaba marcada como en venta pero con el numero
		// viejo hasta la siguiente recarga completa.
		const disponible = abierta ? sembrado : null;

		// La oferta puede estar en la pagina, en la lista completa de una busqueda,
		// o en las dos: se parchea donde este.
		for (const lista of [ofertas, completas ?? []]) {
			const i = lista.findIndex((x) => x.id_oferta === idOferta);
			if (i !== -1) {
				lista[i] = {
					...lista[i],
					es_inventario_limitado: abierta,
					stock_disponible: disponible
				};
			}
		}

		if (productoElegido == null) return;
		productoElegido = {
			...productoElegido,
			variantes: productoElegido.variantes.map((v) =>
				v.mi_oferta != null && v.mi_oferta.id_oferta === idOferta
					? {
							...v,
							mi_oferta: {
								...v.mi_oferta,
								es_inventario_limitado: abierta,
								stock_disponible: disponible
							}
						}
					: v
			)
		};
	}

	/**
	 * POST /vendedor/ofertas/:id/venta-limitada
	 *
	 * Siembra en Redis el stock que la oferta tiene AHORA en PostgreSQL y
	 * enciende `oferta.es_inventario_limitado`. A partir de ese momento agregar
	 * la oferta al carrito aparta unidades de verdad.
	 *
	 * El cuerpo va SIEMPRE, aunque sea `{}`. No es un detalle de estilo: un
	 * POST con `Content-Type: application/json` y cuerpo vacio lo rechaza
	 * Fastify antes de llegar a Nest, y ese 400 no viene con la forma
	 * `{ ok, mensaje, payload }` del resto de la API -- trae `message` en vez
	 * de `mensaje`, asi que `mensajeUtil` se queda sin texto y la caja de error
	 * saldria con la frase generica en vez de decir que paso.
	 */
	async function abrirRelampago(o: OfertaRelampago) {
		errorRelampago = '';

		// Se comprueba aqui y no solo alla porque el mensaje del backend nombra
		// el estado en el que esta, y el de aqui puede nombrar la salida.
		if (o.estado !== 'activa') {
			errorRelampago = `Solo se puede abrir sobre una oferta activa, y esta esta ${o.estado}. Activala primero.`;
			return;
		}

		// Con stock 0 el backend NO se queja: `sembrar` acepta un stock de cero
		// y contesta 201. Y ahi esta la trampa, que aparecio pulsando el boton
		// sobre una oferta agotada de la tienda.
		//
		// Lo que se siembra es una FOTO del stock en ese instante, y ya no se
		// vuelve a mirar PostgreSQL: si el vendedor abre con cero y despues
		// repone existencias por Editar, PostgreSQL sube y Redis se queda en
		// cero. La oferta pasa a ser incomprable sin ningun error, sin ninguna
		// marca y sin nada que lo explique. Se corta aqui porque abrir una
		// venta relampago sin unidades no sirve para nada en ningun caso.
		if (o.stock <= 0) {
			errorRelampago =
				'No tienes unidades que apartar. Repone primero y abre la venta despues.';
			return;
		}

		// El backend no abre una venta relampago sin descuento (409). El panel
		// ya no ofrece el boton en ese caso; esto es por si llega igual.
		if (!tieneDescuento(o.porcentaje_descuento)) {
			errorRelampago = 'Primero ponle un descuento a esta oferta.';
			return;
		}

		// Sin validar el rango: `duracionRelampago` sale de un <select> con la
		// lista DURACIONES, cuyo tope ES el tope del backend. Lo unico que puede
		// llegar aqui es una de esas opciones o el vacio.
		const cuerpo: { duracion_segundos?: number } = {};
		const elegido = duracionRelampago;
		if (elegido !== '') {
			cuerpo.duracion_segundos = Number(elegido);
		}

		relampagoOcupado = true;
		const r = await pedir<{ id_oferta: string; stock_sembrado: number }>(
			`/vendedor/ofertas/${o.id_oferta}/venta-limitada`,
			conJson('POST', cuerpo)
		);
		relampagoOcupado = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			marcarRelampago(o.id_oferta, true, r.payload.stock_sembrado);
			relampagoDe = null;
			duracionRelampago = '';
			// El aviso reusa el TEXTO de la opcion elegida en vez de traducir los
			// segundos otra vez. Con dos traducciones separadas, el dia que se
			// agregue una opcion a DURACIONES el aviso diria otra cosa que el
			// select, y nadie sabria cual de las dos manda.
			const cuando = DURACIONES.find((d) => d.valor === elegido)?.texto ?? '';
			aviso =
				`Venta abierta con ${r.payload.stock_sembrado} ` +
				`${r.payload.stock_sembrado === 1 ? 'unidad' : 'unidades'}. ` +
				(elegido === '' ? 'La cierras tu cuando quieras.' : `Cierra ${cuando.toLowerCase()}.`);
		} else {
			// Los tres que el panel tiene que saber distinguir, y el 404 es el
			// que mas confunde: el backend contesta "No existe una oferta con
			// ese id" tanto si de verdad no existe como si es de otra persona,
			// y leer eso dentro de TU propio panel suena a que la pantalla se
			// rompio. Se traduce.
			errorRelampago =
				r.estado === 404 ? mensaje404(o) : (textoConflictoDescuento(r) ?? mensajeUtil(r));
		}
	}

	/**
	 * DELETE /vendedor/ofertas/:id/venta-limitada
	 *
	 * Apaga la marca y borra las dos claves de Redis de esa oferta. Las
	 * unidades vuelven al stock de PostgreSQL, asi que no se pierde ninguna,
	 * pero quien tuviera una reserva viva se queda sin ella: cerrar NO confirma
	 * lo que estaba apartado. Por eso el boton no cierra directo.
	 */
	async function cerrarRelampago(o: OfertaRelampago) {
		errorRelampago = '';
		relampagoOcupado = true;
		const r = await pedir<null>(`/vendedor/ofertas/${o.id_oferta}/venta-limitada`, {
			method: 'DELETE'
		});
		relampagoOcupado = false;

		if (expiro(r)) return;

		if (r.ok) {
			marcarRelampago(o.id_oferta, false);
			relampagoDe = null;
			aviso = 'Venta relampago cerrada. Las unidades volvieron al stock normal.';
		} else {
			errorRelampago = r.estado === 404 ? mensaje404(o) : mensajeUtil(r);
		}
	}

	/**
	 * El 404 de estas dos rutas dice "No existe una oferta con ese id" y
	 * significa DOS cosas: que no existe, o que es de otra cuenta. El backend
	 * las junta a proposito para no confirmar que una oferta ajena existe, y
	 * esta bien que lo haga; lo que no sirve es repetir ese texto en el panel
	 * de quien es dueno de la fila que esta mirando.
	 */
	function mensaje404(o: OfertaRelampago): string {
		return `El servidor no reconoce la oferta ${o.id_oferta} como tuya. Recarga la lista: puede que se haya borrado o que la sesion sea de otra cuenta.`;
	}

	// -------------------------------------------------------------- descuento
	/**
	 * Abre o cierra el panel de descuento de una fila. Cierra el de la venta
	 * relampago si estaba abierto: los dos paneles cuelgan de la misma fila y
	 * uno debajo del otro no se sabe cual es cual.
	 */
	function alternarDescuento(o: Pick<Oferta, 'id_oferta'>) {
		errorDescuento = '';
		if (descuentoDe === o.id_oferta) {
			descuentoDe = null;
			return;
		}
		descuentoDe = o.id_oferta;
		relampagoDe = null;
		porcentajeNuevo = '';
		duracionDescuento = '';
		aviso = '';
	}

	/**
	 * El mismo filtro del backend (validarPorcentajeDescuento): de 1 a 90,
	 * hasta 2 decimales. Se valida aqui para decirlo sin la vuelta, pero el
	 * que manda es el de alla.
	 */
	function porcentajeValido(texto: string): boolean {
		if (!/^\d+(\.\d{1,2})?$/.test(texto)) return false;
		const n = Number(texto);
		return n >= 1 && n <= 90;
	}

	/**
	 * POST /vendedor/ofertas/:id/descuento
	 *
	 * El backend contesta la oferta entera ya con `precio_final` recalculado,
	 * y esa es la que se mete en la fila: el precio con descuento lo redondea
	 * PostgreSQL y no se adivina aqui.
	 */
	async function aplicarDescuento(o: OfertaDescuento) {
		errorDescuento = '';
		const texto = String(porcentajeNuevo ?? '').trim().replace(',', '.');
		if (!porcentajeValido(texto)) {
			errorDescuento = 'Escribe un numero del 1 al 90, con hasta 2 decimales.';
			return;
		}

		// Sin validar el rango de la duracion: sale de un <select> con los
		// plazos de DURACIONES_DESCUENTO, cuyo tope es el del backend.
		const elegido = duracionDescuento;
		const cuerpo: { porcentaje_descuento: number; duracion_segundos?: number } = {
			porcentaje_descuento: Number(texto)
		};
		if (elegido !== '') cuerpo.duracion_segundos = Number(elegido);

		descuentoOcupado = true;
		const r = await pedir<Oferta>(`/vendedor/ofertas/${o.id_oferta}/descuento`, conJson('POST', cuerpo));
		descuentoOcupado = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			guardarEnLista(r.payload);
			refrescarEnProductoAbierto(r.payload);
			descuentoDe = null;
			porcentajeNuevo = '';
			duracionDescuento = '';
			const cuando = DURACIONES_DESCUENTO.find((d) => d.valor === elegido)?.texto ?? '';
			aviso =
				`Descuento de ${textoPorcentaje(r.payload.porcentaje_descuento)} puesto. Ahora se vende a ${quetzales(r.payload.precio_final)}.` +
				(elegido === '' ? '' : ` Se quita solo ${cuando.toLowerCase()}.`);
		} else {
			// Un 409 aqui casi siempre es la exclusion: la oferta tiene una regla
			// automatica o por periodo activa. Se dice cual y que hacer.
			errorDescuento = textoConflictoDescuento(r) ?? mensajeUtil(r);
		}
	}

	/** DELETE /vendedor/ofertas/:id/descuento */
	async function quitarDescuento(o: OfertaDescuento) {
		errorDescuento = '';

		// El backend contesta 409 si la venta relampago esta abierta. El panel
		// ya no ofrece el boton en ese caso; esto es por si llega igual.
		if (o.es_inventario_limitado) {
			errorDescuento = 'Cierra primero la venta relampago.';
			return;
		}

		descuentoOcupado = true;
		const r = await pedir<Oferta>(`/vendedor/ofertas/${o.id_oferta}/descuento`, {
			method: 'DELETE'
		});
		descuentoOcupado = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			guardarEnLista(r.payload);
			refrescarEnProductoAbierto(r.payload);
			descuentoDe = null;
			aviso = `Descuento quitado. Vuelve a venderse a ${quetzales(r.payload.precio)}.`;
		} else {
			errorDescuento = mensajeUtil(r);
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
		// Y se suelta el acordeon del catalogo. `productoElegido` es de las DOS
		// vistas: si se deja `abierto` apuntando a un producto mientras se
		// vacia su detalle, al volver al catalogo esa fila queda desplegada,
		// con la flecha girada y el cuerpo en blanco -- ni presentaciones, ni
		// "cargando", ni error. Parecia un producto sin variantes.
		abierto = null;
		// El temporizador del debounce puede seguir vivo de una visita
		// anterior y disparar una busqueda que anula productoElegido cuando ya
		// no estamos en esta vista.
		if (temporizador) {
			clearTimeout(temporizador);
			temporizador = null;
		}
	}

	/**
	 * Cuantos caracteres hacen falta antes de empezar a sugerir. Con uno
	 * solo casi todo el catalogo coincide y la lista no ayuda a nadie.
	 */
	const MINIMO_PARA_SUGERIR = 2;

	/** Lo que se espera desde la ultima tecla antes de preguntar. */
	const ESPERA_MS = 300;

	let temporizador: ReturnType<typeof setTimeout> | null = null;

	/**
	 * El numero de la ultima busqueda lanzada.
	 *
	 * Sin esto, dos busquedas seguidas pueden volver en desorden: se escribe
	 * "lap" y luego "lapt", y si la respuesta de "lap" tarda mas, llega
	 * despues y pisa la buena. La lista queda enseñando resultados que no
	 * corresponden a lo que dice la caja. El debounce lo hace raro, no
	 * imposible.
	 */
	let ultimaBusqueda = 0;

	/** Al escribir se busca solo: no hay que pulsar nada. */
	function alEscribir() {
		if (temporizador) clearTimeout(temporizador);

		const texto = busqueda.trim();
		if (texto.length < MINIMO_PARA_SUGERIR) {
			// Se borra lo que hubiera: dejar los resultados de "lapt" cuando la
			// caja ya solo dice "l" es enseñar algo que no se pidio.
			resultados = [];
			buscoAlgunaVez = false;
			buscando = false;
			return;
		}

		temporizador = setTimeout(() => void buscar(), ESPERA_MS);
	}

	async function buscar(evento?: Event) {
		evento?.preventDefault();
		if (temporizador) {
			clearTimeout(temporizador);
			temporizador = null;
		}

		const texto = busqueda.trim();
		if (texto === '') return;

		const mia = ++ultimaBusqueda;

		buscando = true;
		errorPublicar = '';
		productoElegido = null;
		varianteElegida = null;

		const r = await pedir<ProductosPaginados>(
			`/productos?nombre=${encodeURIComponent(texto)}&limite=10`
		);

		// Llego tarde: ya se lanzo otra busqueda mas nueva.
		if (mia !== ultimaBusqueda) return;

		buscando = false;
		buscoAlgunaVez = true;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			resultados = r.payload.productos ?? [];
		} else {
			resultados = [];
			errorPublicar = mensajeUtil(r);
		}
	}

	/**
	 * El id del ultimo producto pedido. Igual que en la busqueda: sin esto,
	 * abrir dos productos seguidos puede pintar el detalle del PRIMERO dentro
	 * del segundo si su respuesta llega mas tarde.
	 */
	let ultimoProducto = 0;

	async function elegirProducto(id: number) {
		const mio = ++ultimoProducto;
		cargandoProducto = true;
		errorPublicar = '';
		varianteElegida = null;

		const r = await pedir<ProductoDelCatalogo>(`/vendedor/ofertas/producto/${id}`);

		// Llego tarde: ya se pidio otro producto.
		if (mio !== ultimoProducto) return;

		cargandoProducto = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			productoElegido = r.payload;
		} else {
			productoElegido = null;
			errorPublicar = mensajeUtil(r);
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

			// Cada quien vuelve a SU pantalla.
			//
			// Antes esto caia siempre en 'lista'. Para un vendedor normal esta
			// bien: ahi tiene sus ofertas y la nueva sale arriba. Pero a quien
			// administra la tienda lo dejaba justo en la lista de 202 que esta
			// vista existe para no cargar -- publicar una oferta disparaba la
			// peticion pesada que acabamos de quitar.
			if (administraLaTienda) {
				vista = 'catalogo';
				// El producto abierto tiene su copia de las variantes y una de
				// ellas acaba de estrenar oferta: se refresca para que aparezca
				// con su precio en vez de seguir diciendo "todavia no la ofreces".
				refrescarEnProductoAbierto(r.payload);
				varianteElegida = null;
				precioNuevaOferta = '';
				stockInicial = '';
			} else {
				vista = 'lista';
				filtro = 'todas';
			}
		} else {
			errorPublicar = mensajeUtil(r);
		}
	}

	/**
	 * La variante ya tomada no se puede elegir para PUBLICAR: seria un 409
	 * seguro, por el UNIQUE de `oferta`.
	 *
	 * Ojo: esto solo vale en la vista de publicar. En la de catalogo una
	 * variante tomada es justamente la interesante -- es la que se edita.
	 */
	function seleccionable(v: VarianteDelCatalogo): boolean {
		return v.mi_oferta == null;
	}

	/** Cuantas variantes de este producto ya tienen oferta mia. */
	function conOferta(p: ProductoDelCatalogo): number {
		return p.variantes.filter((v) => v.mi_oferta != null).length;
	}

	/** Vuelve al catalogo dejandolo como estaba, sin volver a pedir la tanda. */
	function volverAlCatalogo() {
		vista = 'catalogo';
		aviso = '';
		errorPublicar = '';
		// El error de una tanda que fallo hace rato no tiene por que seguir
		// gritando sobre una lista que se ve perfectamente.
		errorCatalogo = '';
		varianteElegida = null;
		cerrarEdicion();
		if (productosCatalogo.length === 0) void cargarTanda(true);
	}

	/**
	 * Abre "publicar" ya apuntando a un producto y a una presentacion.
	 *
	 * Es lo que hace que el boton "Publicar una oferta aqui" cumpla lo que
	 * dice: se vuelve a pedir el detalle del producto (para tenerlo tambien en
	 * la vista de publicar) y se deja marcada esa variante, con lo que el
	 * formulario de precio sale directo.
	 */
	async function publicarSobre(idProducto: number, idVariante: number) {
		vista = 'publicar';
		busqueda = '';
		resultados = [];
		buscoAlgunaVez = false;
		precioNuevaOferta = '';
		stockInicial = '';
		errorPublicar = '';
		aviso = '';
		cerrarEdicion();
		if (temporizador) {
			clearTimeout(temporizador);
			temporizador = null;
		}

		// `abierto` se conserva: al cancelar se vuelve al catalogo y esa fila
		// sigue siendo la que interesa. `elegirProducto` deja el detalle en
		// `productoElegido`, que es el que usan las dos vistas.
		await elegirProducto(idProducto);
		if (productoElegido?._id === idProducto) varianteElegida = idVariante;
	}

	/**
	 * Cancelar la publicacion: se vuelve de donde se vino.
	 *
	 * Para un vendedor normal eso es su lista; para quien administra la tienda,
	 * el catalogo. Mandarlos a los dos a 'lista' era lo que hacia que la tienda
	 * cayera en una lista vacia que le decia "Todavia no tienes ofertas"
	 * teniendo 202 -- vacia porque en esta vista no se cargan a proposito.
	 */
	function cancelarPublicar() {
		if (administraLaTienda) {
			volverAlCatalogo();
		} else {
			vista = 'lista';
		}
	}

	/**
	 * Los id de las ofertas cuya portada no cargo. Ver el comentario del <img>.
	 *
	 * Va como arreglo reasignado y no como Set mutado: un Set normal no es
	 * reactivo en Svelte 5, asi que agregarle un id no volveria a pintar nada.
	 */
	// ------------------------------------------------ la cola de revision
	/**
	 * Solo la ve quien administra la tienda. Es una cola de trabajo, asi que va
	 * de la mas vieja a la mas nueva -- el backend ya la manda en ese orden.
	 */
	let pendientes = $state<Pendiente[]>([]);
	let cargandoPendientes = $state(false);
	let errorPendientes = $state('');
	/** El id de la oferta que se esta rechazando, para pedirle el motivo. */
	let rechazando = $state<string | null>(null);
	let razonRechazo = $state('');
	/** El id de la que se esta mandando, para bloquear solo esa fila. */
	let revisando = $state<string | null>(null);

	async function cargarPendientes() {
		errorPendientes = '';
		cargandoPendientes = true;

		const r = await pedir<Pendiente[]>('/vendedor/ofertas/pendientes');
		cargandoPendientes = false;

		if (expiro(r)) return;

		if (r.ok && r.payload) {
			pendientes = r.payload;
		} else {
			errorPendientes = mensajeUtil(r);
		}
	}

	function abrirRevision() {
		vista = 'revision';
		rechazando = null;
		razonRechazo = '';
		cargarPendientes();
	}

	/**
	 * Aprueba o rechaza una oferta pendiente.
	 *
	 * La fila se quita de la lista en cuanto el backend confirma, sin recargar
	 * toda la cola: es una cola de trabajo y recargar movería lo que la persona
	 * esta mirando.
	 */
	async function revisar(o: Pendiente, decision: 'aprobar' | 'rechazar') {
		if (decision === 'rechazar' && !razonRechazo.trim()) {
			errorPendientes = 'La razon del rechazo es obligatoria';
			return;
		}

		errorPendientes = '';
		revisando = o.id_oferta;

		const cuerpo =
			decision === 'aprobar' ? { decision } : { decision, razon: razonRechazo.trim() };
		const r = await pedir<unknown>(
			`/vendedor/ofertas/${o.id_oferta}/revision`,
			conJson('PATCH', cuerpo)
		);
		revisando = null;

		if (expiro(r)) return;

		if (r.ok) {
			pendientes = pendientes.filter((p) => p.id_oferta !== o.id_oferta);
			rechazando = null;
			razonRechazo = '';
			aviso =
				decision === 'aprobar'
					? `Aprobaste "${o.nombre_producto} - ${o.nombre_variante}" de ${o.vendedor.nombre}`
					: `Rechazaste "${o.nombre_producto} - ${o.nombre_variante}" y ${o.vendedor.nombre} ya puede corregirla`;
		} else {
			errorPendientes = mensajeUtil(r);
		}
	}

	let rotas = $state<string[]>([]);

	function marcarRota(id: string) {
		if (!rotas.includes(id)) rotas = [...rotas, id];
	}
</script>

<!--
	El panel de la venta relampago, una sola vez.

	Va como `{#snippet}` y no copiado en los dos sitios porque lo necesitan las
	DOS vistas -- la lista de un vendedor normal y la tarjeta del catalogo, que
	es por donde entra la tienda -- y son cuarenta lineas con dos textos de
	advertencia dentro. Dos copias de esto es la clase de cosa que se corrige en
	una y no en la otra, y el fallo no se ve hasta que alguien entra por la
	vista que no se toco. Es el primer snippet del archivo; el resto del
	proyecto todavia no usa ninguno.
-->
{#snippet panelRelampago(o: OfertaRelampago)}
	<div class="relampago-panel" class:cerrando={o.es_inventario_limitado}>
		{#if o.es_inventario_limitado}
			<!--
				El aviso NO es adorno. `DELETE /vendedor/ofertas/:id/venta-limitada`
				borra las dos claves de Redis de la oferta, y eso descarta las
				reservas que hubiera en curso: las unidades no se pierden (vuelven
				al stock de PostgreSQL), pero quien habia apartado se queda sin lo
				suyo, y desde este panel no hay forma de saber cuantas personas
				son. Por eso cerrar pide un clic mas y lo dice antes.
			-->
			<p class="nota">
				Tus unidades vuelven al stock normal.
				<strong>Quien tenga algo apartado ahora mismo lo pierde.</strong>
			</p>

			{#if errorRelampago}
				<p class="malo" role="alert">{errorRelampago}</p>
			{/if}

			<div class="acciones">
				<button
					type="button"
					class="principal"
					onclick={() => cerrarRelampago(o)}
					disabled={relampagoOcupado}
				>
					{relampagoOcupado ? 'Cerrando...' : 'Si, cerrar la venta'}
				</button>
				<button type="button" onclick={() => (relampagoDe = null)} disabled={relampagoOcupado}>
					Dejarla abierta
				</button>
			</div>
		{:else if o.stock <= 0}
			<!--
				Sin unidades no hay venta que abrir, y el backend NO lo impide:
				siembra un cero y contesta 201. Se dice aqui, y el boton ni
				aparece, porque el dano llega despues y callado -- reponer
				existencias mas tarde sube PostgreSQL y deja Redis en cero, o sea
				una oferta incomprable sin ninguna senal.
			-->
			<p class="nota">
				No tienes unidades que apartar. Repone con <strong>Editar</strong> y abre la venta
				despues, porque lo que repongas ya no entra en una venta que ya esta abierta.
			</p>

			<div class="acciones">
				<button type="button" onclick={() => (relampagoDe = null)}>Entendido</button>
			</div>
		{:else if !tieneDescuento(o.porcentaje_descuento)}
			<!--
				Desde el 2026-09-23 el backend no abre una venta relampago sin un
				descuento activo (409). En vez de ofrecer el boton y dejar que
				falle, se dice aqui y se lleva al panel del descuento.
			-->
			<p class="nota">
				Una venta relampago tiene que llevar descuento. Ponle uno a esta oferta y despues
				abre la venta.
			</p>

			<div class="acciones">
				<button type="button" class="principal" onclick={() => alternarDescuento(o)}>
					Poner descuento
				</button>
				<button type="button" onclick={() => (relampagoDe = null)}>Cancelar</button>
			</div>
		{:else}
			<p class="nota">
				Se apartan tus <strong>{o.stock}</strong>
				{o.stock === 1 ? 'unidad' : 'unidades'}. Quien las agregue al carrito
				<strong>las reserva de verdad</strong> hasta que pague.
			</p>

			<!--
				Una lista y no una caja de segundos.

				Antes esto era un campo de texto que pedia "en segundos, o vacio" y
				debajo una nota que hablaba de 604800 segundos. Nadie piensa en
				segundos, y sobre todo: el numero invitaba a confundir los DOS
				plazos que hay aqui. Quien queria "quince minutos de venta"
				escribia 900 pensando en el plazo del comprador y cerraba su
				propia venta en quince minutos.

				Con una lista cerrada ese error no se puede cometer, la nota de
				tres lineas sobra, y de paso desaparece la validacion de rango:
				no hay forma de escribir algo fuera del tope.
			-->
			<div class="campos">
				<label>
					Cuando cierra
					<select bind:value={duracionRelampago}>
						{#each DURACIONES as d (d.valor)}
							<option value={d.valor}>{d.texto}</option>
						{/each}
					</select>
				</label>
			</div>

			<p class="menor nota">
				Cada comprador tiene 15 minutos para pagar lo que aparto.
			</p>

			{#if errorRelampago}
				<p class="malo" role="alert">{errorRelampago}</p>
			{/if}

			<div class="acciones">
				<button
					type="button"
					class="principal"
					onclick={() => abrirRelampago(o)}
					disabled={relampagoOcupado}
				>
					{relampagoOcupado ? 'Abriendo...' : 'Abrir la venta'}
				</button>
				<button type="button" onclick={() => (relampagoDe = null)} disabled={relampagoOcupado}>
					Cancelar
				</button>
			</div>
		{/if}
	</div>
{/snippet}

<!--
	El precio de una oferta: el que se cobra grande, y si hay descuento el de
	lista tachado y el %. Lo usan la lista, el catalogo y la cola de revision.
-->
{#snippet precioConDescuento(o: {
	precio: string;
	porcentaje_descuento: string | null;
	precio_final: string;
})}
	<strong class="precio">{quetzales(o.precio_final ?? o.precio)}</strong>
	{#if tieneDescuento(o.porcentaje_descuento)}
		<span class="con-descuento-linea">
			<s class="lista">{quetzales(o.precio)}</s>
			<span class="descuento">-{textoPorcentaje(o.porcentaje_descuento)}</span>
		</span>
	{/if}
{/snippet}

<!--
	El panel del descuento, colgado de su fila igual que el de la venta
	relampago. Un snippet por lo mismo que aquel: lo usan las dos vistas.
-->
{#snippet panelDescuento(o: OfertaDescuento)}
	<div class="descuento-panel">
		{#if tieneDescuento(o.porcentaje_descuento)}
			<p class="nota">
				Tiene <strong>{textoPorcentaje(o.porcentaje_descuento)}</strong> de descuento: se vende a
				<strong>{quetzales(o.precio_final)}</strong> en vez de {quetzales(o.precio)}.
			</p>

			{#if o.es_inventario_limitado}
				<!-- El backend contesta 409 si se quita con la venta abierta: la
				     venta relampago se apoya en este descuento. -->
				<p class="nota">
					Esta oferta esta en venta relampago. Para quitar el descuento, cierra primero la
					venta.
				</p>
				<div class="acciones">
					<button type="button" onclick={() => (descuentoDe = null)}>Entendido</button>
				</div>
			{:else}
				{#if errorDescuento}
					<p class="malo" role="alert">{errorDescuento}</p>
				{/if}
				<div class="acciones">
					<button
						type="button"
						class="principal"
						onclick={() => quitarDescuento(o)}
						disabled={descuentoOcupado}
					>
						{descuentoOcupado ? 'Quitando...' : 'Quitar descuento'}
					</button>
					<button type="button" onclick={() => (descuentoDe = null)} disabled={descuentoOcupado}>
						Dejarlo
					</button>
				</div>
			{/if}
		{:else}
			<div class="campos">
				<label>
					Descuento (%)
					<input
						type="text"
						inputmode="decimal"
						bind:value={porcentajeNuevo}
						placeholder="Del 1 al 90"
						maxlength="5"
					/>
				</label>
				<label>
					Hasta cuando
					<select bind:value={duracionDescuento}>
						{#each DURACIONES_DESCUENTO as d (d.valor)}
							<option value={d.valor}>{d.texto}</option>
						{/each}
					</select>
				</label>
			</div>
			<p class="menor nota">
				Tu precio de {quetzales(o.precio)} no cambia. El comprador ve el precio con el descuento.
			</p>

			{#if errorDescuento}
				<p class="malo" role="alert">{errorDescuento}</p>
			{/if}

			<div class="acciones">
				<button
					type="button"
					class="principal"
					onclick={() => aplicarDescuento(o)}
					disabled={descuentoOcupado}
				>
					{descuentoOcupado ? 'Aplicando...' : 'Aplicar descuento'}
				</button>
				<button type="button" onclick={() => (descuentoDe = null)} disabled={descuentoOcupado}>
					Cancelar
				</button>
			</div>
		{/if}
	</div>
{/snippet}

<section class="ofertas">
	<div class="titulo">
		<div>
			<h2>
				{#if vista === 'catalogo'}
					Tus ofertas, por producto
				{:else if vista === 'lista'}
					Mis ofertas
				{:else if vista === 'revision'}
					Ofertas por revisar
				{:else}
					Publicar una oferta
				{/if}
			</h2>
			<p class="sub">
				{#if vista === 'revision'}
					Lo que otros vendedores quieren publicar. Hasta que la apruebes no se ve en la
					tienda ni se puede comprar. Al rechazar hay que decir por que: el vendedor lo lee
					y corrige.
				{:else if vista === 'catalogo'}
					La tienda oferta todo el catalogo, asi que se entra por el producto: abre uno y
					ajusta ahi el precio y las existencias de cada presentacion.
				{:else if vista === 'lista'}
					Lo que vendes, a que precio y con cuantas unidades. El producto es del catalogo
					compartido; la oferta es tuya.
				{:else if administraLaTienda}
					Busca el producto y ponle precio a una presentacion que todavia no ofrezcas.
				{:else}
					Busca una variante que ya este en el catalogo y ponle tu precio. Crear el producto
					mismo es solo de la tienda.
				{/if}
			</p>
		</div>

		<div class="acciones-titulo">
			{#if vista === 'catalogo'}
				<button type="button" class="principal" onclick={abrirPublicar}>
					Publicar una oferta
				</button>
				<button type="button" onclick={abrirRevision}>Revisar ofertas</button>
				{#if !listaCargada}
					<!--
						Traerse las 202 de golpe sigue siendo posible, pero solo si
						se pide: es la ruta que esta pantalla existe para evitar.
					-->
					<button
						type="button"
						class="enlace"
						onclick={async () => {
							vista = 'lista';
							await cargar();
						}}
					>
						Ver la lista completa
					</button>
				{:else}
					<button type="button" class="enlace" onclick={() => (vista = 'lista')}>
						Ver la lista completa
					</button>
				{/if}
			{:else if vista === 'lista'}
				<button type="button" class="principal" onclick={abrirPublicar}>
					Publicar una oferta
				</button>
				{#if administraLaTienda}
					<button type="button" onclick={abrirRevision}>Revisar ofertas</button>
					<button type="button" class="enlace" onclick={volverAlCatalogo}>
						Volver al catalogo
					</button>
				{/if}
			{:else if vista === 'revision'}
				<button type="button" onclick={volverAlCatalogo}>Volver al catalogo</button>
				<button type="button" class="enlace" onclick={cargarPendientes} disabled={cargandoPendientes}>
					Actualizar
				</button>
			{:else if administraLaTienda}
				<button type="button" onclick={volverAlCatalogo}>Volver al catalogo</button>
			{:else}
				<button type="button" onclick={() => (vista = 'lista')}>Volver a mis ofertas</button>
			{/if}
		</div>
	</div>

	{#if aviso}
		<p class="hecho" role="status">{aviso}</p>
	{/if}

	{#if vista === 'revision'}
		{#if errorPendientes}
			<p class="malo" role="alert">{errorPendientes}</p>
		{/if}

		{#if cargandoPendientes && pendientes.length === 0}
			<p class="menor">Buscando lo que falta por revisar...</p>
		{:else if pendientes.length === 0}
			<p class="vacio">No hay nada esperando revision. Todo lo que se publico ya paso por aqui.</p>
		{:else}
			<ul class="cola">
				{#each pendientes as o (o.id_oferta)}
					<li class="fila">
						<div class="datos">
							<h3>{o.nombre_producto}</h3>
							<p class="menor">{o.nombre_variante}</p>
							<p class="menor">
								La pide {o.vendedor.nombre}
								{o.vendedor.apellido ?? ''} ({o.vendedor.usuario}) &middot; {cuando(o.fecha_creacion)}
							</p>
						</div>

						<div class="numeros">
							{@render precioConDescuento(o)}
							<span class="menor">{o.stock} unidades</span>
						</div>

						<div class="acciones">
							<button
								type="button"
								class="principal"
								disabled={revisando === o.id_oferta}
								onclick={() => revisar(o, 'aprobar')}
							>
								Aprobar
							</button>
							<button
								type="button"
								class="peligro"
								disabled={revisando === o.id_oferta}
								onclick={() => {
									rechazando = rechazando === o.id_oferta ? null : o.id_oferta;
									razonRechazo = '';
									errorPendientes = '';
								}}
							>
								{rechazando === o.id_oferta ? 'Cancelar' : 'Rechazar'}
							</button>
						</div>

						{#if rechazando === o.id_oferta}
							<!-- El motivo es obligatorio: el backend responde 400 sin el, y
							     ademas es lo unico que el vendedor va a leer para saber que
							     corregir. -->
							<div class="edicion">
								<label>
									Por que se rechaza
									<input
										type="text"
										maxlength="500"
										placeholder="El precio no corresponde a esta presentacion"
										bind:value={razonRechazo}
									/>
								</label>
								<div class="botones">
									<button
										type="button"
										class="peligro"
										disabled={revisando === o.id_oferta || !razonRechazo.trim()}
										onclick={() => revisar(o, 'rechazar')}
									>
										Rechazar y avisarle
									</button>
								</div>
							</div>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}
	{:else if vista === 'catalogo'}
		<!-- ------------------------------------------------------ catalogo -->
		<!--
			El catalogo de 20 en 20, con GET /productos (publico y ya paginado).

			Se entra por aqui y no por GET /vendedor/ofertas porque a esta
			cuenta esa ruta le devuelve las 202 ofertas de la tienda de un
			golpe. Ver el comentario de `administraLaTienda` arriba, con lo
			medido.
		-->
		<div class="filtros">
			<label class="campo-filtro">
				Buscar
				<input
					type="search"
					bind:value={fNombre}
					oninput={alFiltrarNombre}
					autocomplete="off"
					placeholder="Nombre del producto"
				/>
			</label>

			<div class="campo-filtro">
				<!--
					La categoria va con Autocompletar y no con un <select>: son 17
					hojas y creciendo, y escribir "lap" es mas rapido que buscarla
					en una lista. `limpiarSiVacio` hace que borrar la caja
					signifique "todas" -- sin eso, vaciarla dejaba el filtro puesto
					y la pantalla decia una cosa y filtraba otra.
				-->
				<Autocompletar
					id="filtro-categoria"
					etiqueta="Categoria"
					opciones={opcionesCategoria}
					bind:valor={fCategoriaTexto}
					bind:elegido={fCategoriaElegida}
					alElegir={alElegirCategoria}
					marcador="Todas"
					mostrarAlEnfocar
					limpiarSiVacio
					opcional
					compacto
				/>
			</div>

			{#if hayFiltro}
				<button type="button" class="enlace" onclick={limpiarFiltros}>Quitar filtros</button>
			{/if}
		</div>

		{#if errorCatalogo}
			<p class="malo" role="alert">{errorCatalogo}</p>
			<!-- Reinicia SOLO si no hay nada cargado. Si lo que fallo fue una
			     continuacion, se reintenta desde el cursor: si no, ochenta
			     productos ya cargados se perdian de un clic. -->
			<button
				type="button"
				class="enlace"
				onclick={() => cargarTanda(productosCatalogo.length === 0)}
			>
				Reintentar
			</button>
		{/if}

		{#if productosCatalogo.length === 0 && cargandoTanda}
			<p class="quieto">Cargando el catalogo...</p>
		{:else if productosCatalogo.length === 0}
			<!-- Sin `&& !errorCatalogo`: con la primera tanda caida se caia al
			     {:else} de abajo, que pinta la lista vacia y remata con "Ya
			     viste los 0 productos del catalogo" -- justo cuando no se pudo
			     ver ninguno. El error ya esta arriba con su Reintentar. -->
			{#if !errorCatalogo}
				{#if hayFiltro}
					<p class="quieto">
						Ningun producto coincide con ese filtro.
						<button type="button" class="enlace" onclick={limpiarFiltros}>Quitarlo</button>
					</p>
				{:else}
					<p class="quieto">El catalogo esta vacio.</p>
				{/if}
			{/if}
		{:else}
			<ul class="catalogo">
				{#each productosCatalogo as p (p._id)}
					{@const estaAbierto = abierto === p._id}
					<li class="producto" class:abierto={estaAbierto}>
						<button
							type="button"
							class="cabecera-producto"
							aria-expanded={estaAbierto}
							onclick={() => alternarProducto(p._id)}
						>
							<span class="datos">
								<strong>{p.nombre}</strong>
								{#if p.categoria?.nombre}
									<span class="menor">{p.categoria.nombre}</span>
								{/if}
							</span>

							{#if estaAbierto && productoElegido?._id === p._id}
								<span class="chip">
									{conOferta(productoElegido)} de {productoElegido.variantes.length}
									{productoElegido.variantes.length === 1 ? 'presentacion' : 'presentaciones'}
								</span>
							{/if}

							<span class="flecha" aria-hidden="true">
								<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">
									<path d="m6 9 6 6 6-6" stroke-linecap="round" stroke-linejoin="round" />
								</svg>
							</span>
						</button>

						{#if estaAbierto}
							<div class="detalle">
								{#if cargandoProducto}
									<p class="quieto">Cargando sus presentaciones...</p>
								{:else if errorPublicar}
									<p class="malo" role="alert">{errorPublicar}</p>
								{:else if productoElegido?._id === p._id}
									{#each productoElegido.variantes as v (v.id_producto_variante)}
										{@const mia = v.mi_oferta}
										<div class="presentacion" class:sin-oferta={mia == null}>
											<div class="resumen">
												<div class="que">
													<strong>{v.nombre_variante}</strong>
													<span class="menor">
														{#if mia}
															{quetzales(mia.precio_final ?? mia.precio)}
															{#if tieneDescuento(mia.porcentaje_descuento)}
																<s class="lista">{quetzales(mia.precio)}</s>
															{/if}
															· {mia.stock}
															{mia.stock === 1 ? 'unidad' : 'unidades'}
														{:else}
															Todavia no la ofreces
														{/if}
														{#if v.total_ofertas > 0}
															· {v.total_ofertas}
															{v.total_ofertas === 1 ? 'vendedor' : 'vendedores'} en total
														{/if}
													</span>
												</div>

												{#if mia}
													<span class="chip {mia.estado}">{mia.estado}</span>
													{#if tieneDescuento(mia.porcentaje_descuento)}
														<span class="descuento">-{textoPorcentaje(mia.porcentaje_descuento)}</span>
													{/if}
													{#if mia.es_inventario_limitado}
														<span
															class="relampago"
															title="El stock de esta oferta lo lleva Redis mientras la venta este abierta"
														>
															Venta relampago abierta
														</span>
													{/if}
													<div class="acciones">
														{#if mia.estado === 'activa'}
															<button
																type="button"
																onclick={() => cambiarEstado(mia, 'pausada')}
																disabled={guardando}
															>
																Pausar
															</button>
														{:else if mia.estado === 'pausada'}
															<button
																type="button"
																onclick={() => cambiarEstado(mia, 'activa')}
																disabled={guardando}
															>
																Activar
															</button>
														{/if}
														<button
															type="button"
															onclick={() =>
																editando === mia.id_oferta ? cerrarEdicion() : abrirEdicion(mia)}
														>
															{editando === mia.id_oferta ? 'Cerrar' : 'Editar'}
														</button>
														<button
															type="button"
															class="descuento-boton"
															class:puesto={tieneDescuento(mia.porcentaje_descuento)}
															onclick={() => alternarDescuento(mia)}
														>
															{descuentoDe === mia.id_oferta ? 'Cerrar el panel' : 'Descuento'}
														</button>
														<!-- El MISMO boton de la lista. Aqui es donde de verdad
														     hace falta: la tienda y el admin entran por esta
														     vista y no por la lista, asi que sin esto la cuenta
														     con mas ofertas no podria abrir ni una venta. -->
														{#if mia.estado === 'activa' || mia.es_inventario_limitado}
															<button
																type="button"
																class="relampago-boton"
																class:abierta={mia.es_inventario_limitado}
																onclick={() => alternarRelampago(mia)}
															>
																{#if relampagoDe === mia.id_oferta}
																	Cerrar el panel
																{:else if mia.es_inventario_limitado}
																	Cerrar la venta
																{:else}
																	Venta relampago
																{/if}
															</button>
														{/if}
													</div>
												{:else}
													<div class="acciones">
														<!-- Se lleva el producto y la presentacion en los que se
														     pulso: antes llamaba a abrirPublicar() a secas, que
														     limpia productoElegido y varianteElegida, asi que el
														     "aqui" del texto se perdia y aparecia un buscador en
														     blanco. -->
														<button
															type="button"
															class="enlace"
															onclick={() => publicarSobre(p._id, v.id_producto_variante)}
														>
															Publicar una oferta aqui
														</button>
													</div>
												{/if}
											</div>

											{#if mia && relampagoDe === mia.id_oferta}
												{@render panelRelampago(mia)}
											{/if}

											{#if mia && descuentoDe === mia.id_oferta}
												{@render panelDescuento(mia)}
											{/if}

											{#if mia && errorFila && editando !== mia.id_oferta}
												<!-- Un Pausar/Activar que falla sin el formulario abierto
												     no tenia donde salir: el boton se quedaba quieto. -->
												<p class="malo" role="alert">{errorFila}</p>
											{/if}

											{#if mia && editando === mia.id_oferta}
												<!-- El MISMO formulario de la lista: `guardarFila` y
												     `stockResultante` toman `OfertaEditable`, asi que
												     `mi_oferta` encaja sin adaptar nada ni duplicar la
												     validacion. -->
												<div class="edicion">
													<div class="campos">
														<label>
															Precio
															<input
																type="text"
																inputmode="decimal"
																bind:value={precioNuevo}
																placeholder={mia.precio}
															/>
														</label>

														<label>
															Estado
															<!-- Solo lo que el backend acepta, mas el actual como
															     "dejalo asi". Antes salian los cinco y elegir
															     "pendiente" o "rechazada" era un error seguro. -->
															<select bind:value={estadoNuevo}>
																{#each estadosPosibles(mia) as e}
																	<option value={e}>
																		{e === mia.estado ? e + ' (no cambiar)' : e}
																	</option>
																{/each}
															</select>
														</label>
														{#if sinAprobar(mia)}
															<p class="nota-estado">
																Todavia sin aprobar: solo puedes retirarla. Si cambias
																el precio o las unidades vuelve a la cola de revision.
															</p>
														{/if}

														<label>
															Ajuste de existencias
															<input
																type="text"
																inputmode="numeric"
																bind:value={ajusteStock}
																placeholder="+5 o -2"
															/>
														</label>
													</div>

													<p class="menor nota">
														El ajuste se suma o se resta a lo que ya hay, no lo reemplaza:
														<code>+5</code> para reponer, <code>-2</code> para corregir a la baja.
														Queda escrito en el kardex.
														{#if stockResultante(mia) !== null}
															<strong
																class="resultante"
																class:imposible={stockResultante(mia)! < 0}
															>
																{mia.stock} → {stockResultante(mia)} unidades
																{#if stockResultante(mia)! < 0}· no se puede bajar de 0{/if}
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
															onclick={() => guardarFila(mia)}
															disabled={guardando}
														>
															{guardando ? 'Guardando...' : 'Guardar cambios'}
														</button>
														<button type="button" onclick={cerrarEdicion} disabled={guardando}>
															Cancelar
														</button>
													</div>
												</div>
											{/if}
										</div>
									{/each}
								{/if}
							</div>
						{/if}
					</li>
				{/each}
			</ul>

			<div class="mas">
				{#if hayMas}
					<button type="button" onclick={() => cargarTanda()} disabled={cargandoTanda}>
						{cargandoTanda ? 'Cargando...' : 'Ver mas productos'}
					</button>
				{:else}
					<p class="quieto">
						{#if hayFiltro}
							{productosCatalogo.length}
							{productosCatalogo.length === 1 ? 'producto coincide' : 'productos coinciden'} con el
							filtro.
						{:else}
							Ya viste los {productosCatalogo.length} productos publicados.
						{/if}
						<br />
						<!--
							Se dice, porque el numero NO cuadra con el del panel del
							catalogo de abajo y quien mire los dos lo va a notar.

							Esta lista sale de `GET /productos`, que es la ruta publica
							y esconde a proposito los estados `borrador` e `inactivo`.
							`GET /vendedor/productos` si los trae, y por eso ahi salen
							mas. No es un fallo de ninguna de las dos: son dos preguntas
							distintas. Sobre un borrador tampoco tendria sentido poner
							una oferta, porque nadie puede verlo ni comprarlo.
						-->
						<span class="menor">
							Los borradores y los retirados no salen aqui: no se pueden
							comprar, asi que no admiten oferta. Estan en el catalogo, mas
							abajo.
						</span>
					</p>
				{/if}
			</div>
		{/if}
	{:else if vista === 'lista'}
		{#if cargando}
			<p class="quieto">Cargando tus ofertas...</p>
		{:else if error}
			<p class="malo" role="alert">{error}</p>
			<button type="button" class="enlace" onclick={cargar}>Reintentar</button>
		{:else if conteos.todas === 0}
			<p class="quieto">
				Todavia no tienes ofertas. Publica una sobre cualquier variante del catalogo.
			</p>
		{:else}
			<div class="barra">
				<div class="pestanas">
					{#each ['todas', ...ESTADOS] as const as e}
						<button
							type="button"
							class="pestana"
							class:elegida={filtro === e}
							onclick={() => elegirFiltro(e)}
						>
							{e === 'todas' ? 'Todas' : e[0].toUpperCase() + e.slice(1) + 's'}
							<span class="cuenta">{conteos[e]}</span>
						</button>
					{/each}
				</div>

				<!-- Filtro local: las ofertas ya estan todas en memoria. No hace
				     falta ni debounce ni ir al servidor. -->
				<label class="buscar-lista">
					<span class="visualmente-oculto">Buscar entre tus ofertas</span>
					<input
						type="search"
						bind:value={busquedaLista}
						oninput={alBuscarEnLista}
						autocomplete="off"
						placeholder="Buscar por producto o presentacion"
					/>
				</label>
			</div>

			{#if hayBusqueda && completas === null}
				<p class="quieto">Buscando entre todas tus ofertas...</p>
			{:else if listaFiltrada.length === 0}
				{#if busquedaLista.trim() !== ''}
					<p class="quieto">
						Ninguna oferta {filtro === 'todas' ? '' : filtro + ' '}se llama asi.
						<button type="button" class="enlace" onclick={() => (busquedaLista = '')}>
							Limpiar la busqueda
						</button>
					</p>
				{:else}
					<p class="quieto">Ninguna oferta {filtro}.</p>
				{/if}
			{:else}
				{#if busquedaLista.trim() !== ''}
					<p class="menor conteo-filtro">
						{listaFiltrada.length} de {conteos[filtro]}
						{conteos[filtro] === 1 ? 'oferta' : 'ofertas'}
					</p>
				{/if}
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
								<!-- Las clases van con `class:` y no interpoladas: Svelte borra del
								     bundle los selectores que no ve escritos en el marcado, y con
								     `class="chip {o.estado}"` no los ve. -->
								<span
									class="chip"
									class:activo={o.estado === 'activa'}
									class:inactivo={o.estado === 'retirada'}
									class:espera={o.estado === 'pendiente'}
									class:negado={o.estado === 'rechazada'}>{o.estado}</span
								>
								<!-- La insignia de venta relampago. Naranja y no roja, y es la
								     MISMA de CarritoRedis.svelte a proposito: es la misma cosa
								     vista desde los dos lados del mostrador, y dos colores
								     distintos la harian parecer dos cosas. No es un error, es
								     una condicion de la venta, asi que el rojo se queda para
								     lo que de verdad esta mal. -->
								{#if o.es_inventario_limitado}
									<span
										class="relampago"
										title="El stock de esta oferta lo lleva Redis mientras la venta este abierta"
									>
										Venta relampago abierta
									</span>
								{/if}
							</div>

							<div class="numeros">
								{@render precioConDescuento(o)}
								<!-- Con la venta relampago abierta se ensenan los DOS numeros, y
								     no solo el real. El vendedor necesita los dos: con cuantas
								     abrio la venta (el congelado de PostgreSQL) y cuantas le
								     quedan ahora (el de Redis). Ensenar solo el segundo deja
								     "3 unidades" sin decir de cuantas, que no dice si va bien. -->
								{#if o.stock_disponible !== null}
									<span class="menor">
										<strong class="quedan">{o.stock_disponible}</strong>
										de {o.stock} sin vender
									</span>
								{:else}
									<span class="menor">{o.stock} unidades</span>
								{/if}
							</div>

							<div class="acciones">
								<!-- Antes esto era un `{:else}` que ofrecia "Activar" para cualquier
								     estado que no fuera activa. Con `pendiente` y `rechazada` eso es
								     un 409 seguro: el vendedor no puede aprobarse a si mismo. Ahora
								     se nombran los estados y a los que esperan revision se les
								     ofrece lo unico que si pueden hacer, que es corregirla. -->
								{#if o.estado === 'activa'}
									<button type="button" onclick={() => cambiarEstado(o, 'pausada')} disabled={guardando}>
										Pausar
									</button>
								{:else if !sinAprobar(o)}
									<button type="button" onclick={() => cambiarEstado(o, 'activa')} disabled={guardando}>
										Activar
									</button>
								{/if}
								{#if o.estado === 'rechazada'}
									<button type="button" class="enlace" onclick={() => verRechazos(o.id_oferta)}>
										{rechazosDe === o.id_oferta ? 'Ocultar el motivo' : 'Ver por que'}
									</button>
								{/if}
								<!-- El boton solo aparece donde tiene sentido: sobre una oferta
								     activa (las demas dan 409) o sobre una que ya la tiene
								     abierta, que siempre se tiene que poder cerrar aunque la
								     oferta haya cambiado de estado por otro camino. -->
								<button
									type="button"
									class="descuento-boton"
									class:puesto={tieneDescuento(o.porcentaje_descuento)}
									onclick={() => alternarDescuento(o)}
								>
									{descuentoDe === o.id_oferta ? 'Cerrar el panel' : 'Descuento'}
								</button>
								{#if o.estado === 'activa' || o.es_inventario_limitado}
									<button
										type="button"
										class="relampago-boton"
										class:abierta={o.es_inventario_limitado}
										onclick={() => alternarRelampago(o)}
									>
										{#if relampagoDe === o.id_oferta}
											Cerrar el panel
										{:else if o.es_inventario_limitado}
											Cerrar la venta
										{:else}
											Abrir venta relampago
										{/if}
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

							{#if rechazosDe === o.id_oferta}
								<div class="motivos">
									{#if cargandoRechazos}
										<p class="menor">Buscando el motivo...</p>
									{:else if errorRechazos}
										<p class="malo" role="alert">{errorRechazos}</p>
									{:else if rechazos.length === 0}
										<p class="menor">La tienda no dejo ningun motivo.</p>
									{:else}
										<ul>
											{#each rechazos as r (r.id_rechazo_oferta)}
												<li>
													<p>{r.razon_rechazo}</p>
													<span class="menor">{cuando(r.fecha_rechazo)}</span>
												</li>
											{/each}
										</ul>
										<p class="menor">
											Corrige el precio o las existencias y la oferta vuelve sola a la cola de
											revision.
										</p>
									{/if}
								</div>
							{/if}

							{#if relampagoDe === o.id_oferta}
								{@render panelRelampago(o)}
							{/if}

							{#if descuentoDe === o.id_oferta}
								{@render panelDescuento(o)}
							{/if}

							{#if editando === o.id_oferta}
								<div class="edicion">
									{#if sinAprobar(o)}
										<!-- Se dice ANTES de que lo intente: el select de abajo no ofrece
										     activa ni pausada porque el backend las rechaza con un 409
										     mientras la tienda no la apruebe. -->
										<p class="menor nota">
											Esta oferta todavia no la aprobo la tienda. Al guardar un cambio vuelve a
											quedar pendiente de revision.
										</p>
									{/if}
									<div class="campos">
										<label>
											Precio
											<input type="text" inputmode="decimal" bind:value={precioNuevo} placeholder={o.precio} />
										</label>

										<label>
											Estado
											<!-- Solo lo que el backend acepta (activa, pausada, retirada),
											     mas el actual como "dejalo asi". Sin aprobar, la unica
											     salida es retirarla: activa y pausada dan 409. -->
											<select bind:value={estadoNuevo}>
												{#each estadosPosibles(o) as e}
													<option value={e}>
														{e === o.estado ? e + ' (no cambiar)' : e}
													</option>
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

				<!-- Solo sin busqueda: con texto se ve la lista completa filtrada y no hay
				     paginas que recorrer. -->
				{#if !hayBusqueda && totalPaginas > 1}
					<nav class="paginas" aria-label="Paginas de tus ofertas">
						<button
							type="button"
							onclick={() => irAPagina(pagina - 1)}
							disabled={cargandoPagina || pagina <= 1}
						>
							Anterior
						</button>
						<span class="cuenta-paginas" aria-live="polite">
							Pagina {pagina} de {totalPaginas}
							<span class="menor">
								({conteos[filtro]}
								{conteos[filtro] === 1 ? 'oferta' : 'ofertas'})
							</span>
						</span>
						<button
							type="button"
							onclick={() => irAPagina(pagina + 1)}
							disabled={cargandoPagina || pagina >= totalPaginas}
						>
							Siguiente
						</button>
					</nav>
				{/if}
			{/if}
		{/if}
	{:else}
		<!-- ------------------------------------------------------ publicar -->
		<!--
			Se busca mientras se escribe.

			Antes habia que escribir y ADEMAS pulsar "Buscar" para ver nada. El
			filtro `nombre` de GET /productos es parcial y no distingue
			mayusculas, y contesta en 7-16 ms medido, asi que aguanta de sobra
			una peticion por pausa de tecleo.

			El boton se queda: sirve para el Enter del teclado y para volver a
			pedir si algo fallo. El <form> con onsubmit es lo que hace que
			Enter no recargue la pagina.
		-->
		<form class="buscador" onsubmit={buscar}>
			<label class="ancho">
				Busca el producto
				<input
					type="search"
					bind:value={busqueda}
					oninput={alEscribir}
					autocomplete="off"
					placeholder="Laptop, camisa, audifonos..."
				/>
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
		{:else if busqueda.trim().length > 0 && busqueda.trim().length < MINIMO_PARA_SUGERIR}
			<p class="quieto">Escribe una letra mas para ver sugerencias.</p>
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
							<span class="chip">ya la ofreces · {quetzales(v.mi_oferta.precio_final ?? v.mi_oferta.precio)}</span>
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
						<!-- Vuelve a la vista de la que se vino. Antes iba siempre a
						     'lista', y para la tienda y el admin esa lista esta VACIA
						     hasta que se pida a proposito: cancelar les pintaba
						     "Todavia no tienes ofertas" teniendo 202. -->
						<button type="button" onclick={cancelarPublicar} disabled={publicando}>
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
		gap: var(--e2);
		margin-bottom: 1rem;
	}

	.pestana {
		display: inline-flex;
		align-items: center;
		gap: var(--e2);
		padding: 0.35rem 0.85rem;
		font-size: var(--f-ms);
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
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.pestana.elegida .cuenta {
		color: var(--indigo);
	}

	/* ---------- la lista ---------- */

	.tabla {
		display: flex;
		flex-direction: column;
		gap: var(--e3);
	}

	/* La cola de revision reusa `.fila`, que es la misma tarjeta de la lista de
	   ofertas: es la misma cosa mirada por otro. Solo hace falta el contenedor,
	   que aqui es un <ul> y por eso lleva su reset. */
	.cola {
		display: flex;
		flex-direction: column;
		gap: var(--e3);
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.cola .edicion {
		flex-basis: 100%;
	}

	.fila {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: var(--e4);
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
		font-size: var(--f-md);
	}

	.numeros {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: var(--e1);
	}

	.precio {
		font-size: var(--f-md);
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

	/* Los dos estados nuevos. `espera` es neutro a proposito: pendiente no es
	   ni bueno ni malo, es que todavia no la miraron. `negado` usa el rojo del
	   sistema, el mismo de los mensajes de error. */
	.chip.espera {
		background: var(--panel);
		color: var(--gris);
	}

	.chip.negado {
		background: var(--rojo-cl);
		color: var(--rojo);
	}

	/* El motivo por el que devolvieron una oferta. Va pegado debajo de su fila,
	   como el bloque de edicion, para que se lea junto a la oferta y no aparte. */
	.motivos {
		margin: 8px 0 0;
		padding: 12px 14px;
		background: var(--rojo-cl);
		border-radius: var(--r);
	}

	.motivos ul {
		margin: 0 0 8px;
		padding: 0;
		list-style: none;
		display: grid;
		gap: var(--e2);
	}

	.motivos li p {
		margin: 0;
	}

	.nota {
		margin: 0 0 12px;
	}

	/* La explicacion de por que el select de estado trae una sola salida
	   cuando la oferta no esta aprobada. Va debajo del control y no como
	   aviso arriba: contesta una pregunta que se hace mirando ESE campo. */
	.nota-estado {
		grid-column: 1 / -1;
		margin: -4px 0 0;
		font-size: var(--f-sm);
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
		gap: var(--e2);
	}

	/* ---------- la venta relampago ---------- */

	/* El naranja va como variable y no clavado en cada regla porque lo usan
	   cuatro sitios de este archivo, y porque el tema oscuro tiene que poder
	   cambiarlo entero desde un solo lugar.

	   Los valores claros son EXACTAMENTE los de la insignia de
	   CarritoRedis.svelte: es la misma venta vista desde el otro lado del
	   mostrador, y dos naranjas distintos la harian parecer dos cosas.

	   Naranja y no rojo: el rojo de .malo tiene que seguir siendo el color que
	   solo sale cuando algo esta mal, o deja de querer decir eso. Una venta
	   relampago abierta no es un error, es una condicion de la venta. */
	.ofertas {
		--relampago-tinta: #7c3a00;
		--relampago-fondo: #ffe8cc;
		--relampago-linea: #ffc98a;
	}

	/* En oscuro no se puede dejar el fondo claro: la tarjeta pasa a ser oscura
	   y una pastilla color crema encima grita mas que el precio. Se invierte,
	   igual que hacen --indigo-cl y --rojo-cl en el layout. */
	:global(html[data-tema='oscuro']) .ofertas {
		--relampago-tinta: #f0b070;
		--relampago-fondo: #3a2410;
		--relampago-linea: #6b4520;
	}

	.relampago {
		display: inline-block;
		font-size: var(--f-xs);
		font-weight: 600;
		line-height: 1.2;
		padding: 2px 10px;
		border-radius: 999px;
		color: var(--relampago-tinta);
		background: var(--relampago-fondo);
		border: 1px solid var(--relampago-linea);
	}

	/* El boton no es `.principal`: el principal de cada fila es Editar, y dos
	   botones indigo uno al lado del otro no dicen cual es cual. Este se
	   distingue por el color de la venta, que es el mismo de la insignia, asi
	   que se lee como "esto es lo del relampago" sin tener que leerlo. */
	.relampago-boton {
		color: var(--relampago-tinta);
		border-color: var(--relampago-linea);
	}

	/* Cuando la venta YA esta abierta el boton cierra, y cerrar descarta
	   reservas. Se pinta lleno para que no se confunda con el de abrir: son la
	   misma posicion en la fila y acciones opuestas. */
	.relampago-boton.abierta {
		background: var(--relampago-fondo);
	}

	/* Ocupa la fila entera y se abre debajo, igual que .edicion y .motivos: son
	   los tres el mismo patron de "un panel colgado de SU fila". */
	.relampago-panel {
		flex-basis: 100%;
		width: 100%;
		margin-top: 0.6rem;
		padding: 0.9rem 1rem;
		border: 1px solid var(--relampago-linea);
		border-radius: var(--r);
		background: var(--relampago-fondo);
		color: var(--relampago-tinta);
	}

	/* Cerrar es la accion destructiva de las dos, asi que su panel se marca.
	   Sin esto los dos paneles son identicos y el unico aviso de que uno
	   descarta reservas seria el texto, que es justo lo que nadie lee. */
	.relampago-panel.cerrando {
		border-width: 2px;
	}

	.relampago-panel .nota {
		color: inherit;
	}

	/* El error del panel se pinta con el rojo del sistema, no con el naranja
	   heredado: dentro de una caja naranja un `.malo` en naranja no se
	   distingue del texto normal y el mensaje pasa desapercibido. */
	.relampago-panel .malo {
		color: var(--rojo);
	}

	/* Las unidades que quedan de una venta abierta, en el color de la venta. Es
	   el numero que se mueve solo mientras la gente aparta, y tiene que
	   distinguirse del `de N` que va al lado y no se mueve. */
	.quedan {
		color: var(--relampago-tinta);
	}

	/* ---------- el descuento ---------- */

	/* Verde, con los colores del layout (--descuento-*): es la misma etiqueta
	   del catalogo, la ficha, el carrito y los pedidos. */
	.descuento {
		display: inline-block;
		font-size: var(--f-xs);
		font-weight: 600;
		line-height: 1.2;
		padding: 2px 10px;
		border-radius: 999px;
		white-space: nowrap;
		color: var(--descuento-tinta);
		background: var(--descuento-fondo);
		border: 1px solid var(--descuento-linea);
	}

	.con-descuento-linea {
		display: inline-flex;
		align-items: baseline;
		flex-wrap: wrap;
		justify-content: flex-end;
		gap: var(--e1);
	}

	.lista {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	/* Mismo trato que .relampago-boton: no es el principal de la fila, y se
	   reconoce por el color. Lleno cuando ya hay un descuento puesto. */
	.descuento-boton {
		color: var(--descuento-tinta);
		border-color: var(--descuento-linea);
	}

	.descuento-boton.puesto {
		background: var(--descuento-fondo);
	}

	/* El mismo patron de panel colgado de su fila que .relampago-panel. */
	.descuento-panel {
		flex-basis: 100%;
		width: 100%;
		margin-top: 0.6rem;
		padding: 0.9rem 1rem;
		border: 1px solid var(--descuento-linea);
		border-radius: var(--r);
		background: var(--descuento-fondo);
		color: var(--descuento-tinta);
	}

	.descuento-panel .nota {
		color: inherit;
	}

	.descuento-panel .malo {
		color: var(--rojo);
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
		gap: var(--e3);
	}

	.campos label,
	.ancho {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		font-size: var(--f-ms);
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
		gap: var(--e3);
		margin-bottom: 1rem;
	}

	.buscador .ancho {
		flex: 1;
	}

	.resultados {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
		margin-bottom: 1.25rem;
	}

	.resultado {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: var(--e4);
		padding: 0.7rem 0.9rem;
		text-align: left;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	/* El nombre del producto en un resultado de busqueda. La clase se usaba en
	   el markup y no estaba definida en ninguna parte, asi que un nombre largo
	   estiraba la tarjeta en vez de recortarse. */
	.resultado .nombre {
		display: block;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		color: var(--tinta);
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
		gap: var(--e3);
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

	/* ══════════════════════════════════════════════════════
	   Los filtros
	   ══════════════════════════════════════════════════════ */

	/* Los del catalogo: van en una tarjeta, como los del catalogo publico. */
	.filtros {
		display: flex;
		align-items: flex-end;
		flex-wrap: wrap;
		gap: var(--e4);
		margin-bottom: 1rem;
		padding: 1rem 1.1rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.campo-filtro {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		flex: 1 1 15rem;
		min-width: 0;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.campo-filtro input {
		width: 100%;
	}

	/* La barra de la lista: las pestanas a la izquierda y el buscador a la
	   derecha, en la misma linea mientras quepan. */
	.barra {
		display: flex;
		align-items: center;
		justify-content: space-between;
		flex-wrap: wrap;
		gap: var(--e3);
		margin-bottom: 1rem;
	}

	/* Los controles de pagina de la lista. */
	.paginas {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: var(--e3);
		flex-wrap: wrap;
		margin-top: var(--e4);
	}

	.cuenta-paginas {
		font-size: var(--f-ms);
		color: var(--gris);
	}


	.buscar-lista {
		flex: 0 1 20rem;
		min-width: 12rem;
	}

	.buscar-lista input {
		width: 100%;
	}

	/* Se oculta a la vista pero NO al lector de pantalla: el campo necesita
	   nombre, y aqui el marcador de posicion ya lo dice todo visualmente. */
	.visualmente-oculto {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		overflow: hidden;
		clip-path: inset(50%);
		white-space: nowrap;
	}

	.conteo-filtro {
		margin-bottom: 0.6rem;
		color: var(--gris);
	}

	/* ══════════════════════════════════════════════════════
	   La vista de catalogo (tienda y admin)
	   ══════════════════════════════════════════════════════ */

	.acciones-titulo {
		display: flex;
		align-items: center;
		gap: var(--e4);
		flex-shrink: 0;
	}

	/* UNA lista con lineas finas, no veinte tarjetas sueltas.

	   Antes cada producto era su propia tarjeta con borde, esquinas y 0.6rem
	   de hueco: veinte cajas iguales, una debajo de otra, que a la vista son
	   ruido y no informacion. Medido con la cuenta de la tienda, la pantalla
	   entera pasaba de 5531 pixeles. Juntandolas cada fila baja de ~72px a
	   ~46px y las veinte caben en un tercio menos de alto. */
	.catalogo {
		list-style: none;
		display: flex;
		flex-direction: column;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		/* `clip` y no `hidden`: las dos recortan las esquinas cuadradas del
		   detalle, pero `hidden` ademas convierte la caja en un contenedor de
		   desplazamiento, y eso se comia el anillo de foco del boton de la
		   cabecera -- el `outline-offset: 3px` global caia fuera y no se veia
		   nada al tabular. Con `clip` el recorte queda igual y el foco sale. */
		overflow: clip;
	}

	.producto {
		position: relative;
		transition: background var(--t);
	}

	/* La raya va ENTRE filas: `+` y no `border-bottom`, para que la ultima no
	   deje una linea suelta pegada al borde de abajo del contenedor. */
	.producto + .producto {
		border-top: 1px solid var(--linea);
	}

	.producto:hover {
		background: var(--off);
	}

	/* La abierta se marca con fondo y con una barra en el canto, no con el
	   borde: dentro de una lista continua ya no hay borde propio que tenir, y
	   una barra se encuentra de un vistazo aunque la fila este a media
	   pantalla. */
	.producto.abierto {
		background: var(--indigo-cl);
	}

	.producto.abierto::before {
		content: '';
		position: absolute;
		left: 0;
		top: 0;
		bottom: 0;
		width: 3px;
		background: var(--indigo);
	}

	/* La cabecera es un boton de ancho completo, no una caja con un boton
	   dentro: asi toda la fila es pulsable y el teclado la alcanza de una. */
	.cabecera-producto {
		display: flex;
		align-items: center;
		gap: var(--e4);
		width: 100%;
		padding: 0.6rem 1rem;
		text-align: left;
		background: none;
		border: none;
		border-radius: 0;
	}

	/* El hover se marca con el BORDE de la tarjeta (.producto:hover, arriba) y
	   con el color de la flecha, no con el fondo: en tema oscuro --panel
	   (#161b31) y --blanco (#141a33) se diferencian en 1.01:1, o sea nada, asi
	   que pintar el fondo no se notaba y encima anulaba el otro efecto. */
	.cabecera-producto:hover:not(:disabled) {
		color: inherit;
		background: none;
	}

	.cabecera-producto:hover:not(:disabled) .flecha {
		color: var(--indigo);
	}

	.cabecera-producto .datos {
		display: flex;
		flex-direction: column;
		flex: 1;
		min-width: 0;
	}

	.cabecera-producto strong {
		color: var(--tinta);
		font-weight: 500;
		/* Un nombre largo corta la linea en vez de estirar la tarjeta y sacarle
		   una barra de desplazamiento horizontal a la pagina entera. */
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.flecha {
		display: grid;
		place-items: center;
		flex-shrink: 0;
		width: 20px;
		height: 20px;
		color: var(--gris);
		transition: transform var(--t);
	}

	.flecha svg {
		width: 18px;
		height: 18px;
	}

	.producto.abierto .flecha {
		transform: rotate(180deg);
		color: var(--indigo);
	}

	.detalle {
		padding: 0 1.1rem 1rem;
		border-top: 1px solid var(--linea);
	}

	.presentacion {
		padding: 0.85rem 0;
		border-bottom: 1px solid var(--linea);
	}

	.presentacion:last-child {
		border-bottom: none;
		padding-bottom: 0;
	}

	/* La que todavia no se oferta se apaga un poco: se ve que esta, y se ve
	   que no es tuya todavia. */
	.presentacion.sin-oferta .que strong {
		color: var(--gris);
	}

	.resumen {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: var(--e3);
	}

	.resumen .que {
		display: flex;
		flex-direction: column;
		flex: 1;
		min-width: 0;
	}

	.resumen .que strong {
		color: var(--tinta);
		font-weight: 500;
	}

	/* Los tres estados de una oferta, con el mismo criterio que el resto:
	   activa en indigo, pausada en gris, retirada en rojo. */
	.chip.activa {
		background: var(--indigo-cl);
		color: var(--indigo);
	}

	.chip.pausada {
		background: var(--panel);
		color: var(--gris);
	}

	.chip.retirada {
		background: var(--rojo-cl);
		color: var(--rojo);
	}

	.mas {
		display: flex;
		justify-content: center;
		margin-top: 1.25rem;
	}

	@media (max-width: 620px) {
		.filtros {
			flex-direction: column;
			align-items: stretch;
		}

		.buscar-lista {
			flex-basis: 100%;
		}

		.titulo {
			flex-direction: column;
			align-items: stretch;
		}

		.acciones-titulo {
			flex-wrap: wrap;
		}

		/* En pantalla angosta el estado y los botones no caben junto al
		   nombre: bajan, y los botones quedan a la izquierda alineados con
		   todo lo demas. */
		.resumen {
			gap: var(--e2);
		}

		.resumen .que {
			flex-basis: 100%;
		}
	}
</style>
