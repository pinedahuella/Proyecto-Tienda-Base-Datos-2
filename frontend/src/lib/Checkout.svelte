<script lang="ts">
	import { untrack } from 'svelte';
	import { conJson, pedir, type RespuestaApi } from './api';
	import Autocompletar from './Autocompletar.svelte';
	import {
		cargarPaises,
		ciudadesDeDepartamento,
		ciudadesDePais,
		comparable,
		etiquetaDivision,
		paraLeer,
		type Pais
	} from './lugares';
	import {
		cambiarDireccionPedido,
		comprarPedido,
		crearDireccion,
		direccionEnUnaLinea,
		quetzales,
		subtotal,
		totalPedido,
		traerDirecciones,
		traerMetodosPago,
		traerPedido,
		type AvisoDePrecio,
		type DatosTarjeta,
		type DireccionDelPedido,
		type DireccionUsuario,
		type LineaPedido,
		type MetodoPago,
		type ResultadoCompra
	} from './pedido';

	/**
	 * El paso final: elegir forma de pago, meter la tarjeta si toca, y cerrar
	 * la compra con POST /comprador/pedidos/:id/comprar.
	 *
	 * Se pinta como una ventana modal encima del carrito, no como otra pagina:
	 * lo que se esta comprando es justo lo que hay detras, y mandar a la
	 * persona a otra ruta la obligaria a acordarse de lo que habia.
	 *
	 * Aqui tambien se ensena y se cambia A DONDE SE ENTREGA. El pedido nace en
	 * la ficha del producto con la PRIMERA direccion que tenga la persona, sin
	 * preguntarle: si tiene tres, la que se usa es al azar desde su punto de
	 * vista. Este es el ultimo sitio donde se puede corregir, porque despues de
	 * comprar el pedido ya no admite el PATCH.
	 *
	 * Esta pantalla NO decide el precio. El precio se congelo al agregar cada
	 * linea (`agregar_linea` guarda el id de la fila de `precio_historial` que
	 * regia ese dia) y es el que se cobra, aunque el vendedor lo haya subido
	 * despues. Aqui solo se ensena y, si cambio, se avisa.
	 *
	 * Lo unico que hace falta entender de la respuesta de comprar es que tiene
	 * CUATRO finales distintos, y solo uno es "salio mal":
	 *
	 *   ok + comprado:true    compro. Se avisa al padre con alComprado().
	 *   ok + comprado:false   NO compro nada: hay precios que cambiaron y hay
	 *                         que verlos antes. Se repite la MISMA peticion con
	 *                         confirmar_cambios para seguir.
	 *   402                   el cobro simulado se rechazo. Se puede reintentar
	 *                         con otra tarjeta, el pedido sigue intacto.
	 *   409                   la oferta se pauso o ya no hay unidades. Esto no
	 *                         se salta con ninguna bandera: hay que arreglar el
	 *                         carrito, asi que aqui no se ofrece "seguir igual".
	 */

	let {
		abierto = false,
		idPedido,
		lineas = [],
		alCerrar,
		alComprado,
		modo = 'pedido',
		alExpirarSesion
	}: {
		abierto?: boolean;
		idPedido: string | null;
		lineas?: LineaPedido[];
		alCerrar?: () => void;
		alComprado?: (resultado: ResultadoCompra) => void;
		/**
		 * De donde sale lo que se compra.
		 *
		 *   'pedido'  el de siempre: hay una fila de `pedido` en `pendiente`,
		 *             la direccion se le puso antes con un PATCH, y se compra
		 *             con POST /comprador/pedidos/:id/comprar
		 *   'carrito' el de la Entrega 2: el carrito vive en Redis y no hay
		 *             pedido todavia. La direccion viaja EN el cuerpo de la
		 *             compra, y POST /carrito/comprar crea el pedido, le mete
		 *             las lineas y lo compra de una sola vez.
		 *
		 * Todo lo demas -- elegir direccion, crear una nueva, la forma de pago,
		 * la tarjeta -- es identico, y por eso esto es un modo y no un segundo
		 * componente: duplicar 1800 lineas para cambiar la ultima llamada seria
		 * garantizar que las dos se separen.
		 */
		modo?: 'pedido' | 'carrito';
		alExpirarSesion?: () => void;
	} = $props();

	// ---------------------------------------------------------------- estado
	let metodos = $state<MetodoPago[]>([]);
	let cargandoMetodos = $state(false);
	let errorMetodos = $state('');
	/** El `metodo_nombre`, no el id: es lo que espera el backend al comprar. */
	let metodoElegido = $state('');

	/**
	 * Las direcciones VIVAS del usuario (las que se pueden elegir) y la version
	 * CONGELADA que hoy tiene el pedido. No son la misma cosa: el pedido guarda
	 * una fila de direccion_historial, asi que si la persona corrigio la
	 * direccion despues de abrir el pedido, lo que se entrega sigue siendo la
	 * version vieja hasta que se vuelva a poner con el PATCH.
	 */
	let direcciones = $state<DireccionUsuario[]>([]);
	let direccionPedido = $state<DireccionDelPedido | null>(null);
	/** El radio marcado. Se guarda aparte para poder devolverlo si el PATCH falla. */
	let idElegida = $state('');
	let cargandoEntrega = $state(false);
	/** true solo cuando la lista de direcciones llego de verdad. Ver `sinDirecciones`. */
	let listaLeida = $state(false);
	let errorEntrega = $state('');
	let cambiandoDireccion = $state(false);
	let errorCambio = $state('');

	let formNueva = $state(false);
	let dirPais = $state('');
	let dirDepartamento = $state('');
	let dirCiudad = $state('');
	/** La calle. Texto libre y obligatoria: sin ella no se entrega el pedido. */
	let dirExacta = $state('');
	let dirPostal = $state('');
	let guardandoDireccion = $state(false);
	let errorNueva = $state('');

	// ---------------------------------------------- paises, departamentos, ciudades
	/**
	 * El formulario de aqui tenia cuatro <input type="text"> pelados: se
	 * escribia "gua" en Pais y no pasaba nada, y se podia guardar una direccion
	 * con un pais que no existe y una ciudad que no es de ese pais.
	 *
	 * El registro y el panel ya resolvian esto con `lugares.ts` y
	 * `Autocompletar`: se elige el pais, eso trae sus departamentos, y el
	 * departamento trae sus ciudades. Es la misma cascada, aqui.
	 *
	 * Los paises se bajan una sola vez (226 KB) y SOLO al abrir el formulario,
	 * no al abrir el checkout: quien paga con una direccion que ya tiene --
	 * que es lo normal -- no paga ese peso.
	 */
	let paises = $state<Pais[]>([]);
	let cargandoPaises = $state(false);
	let opcionesDepartamento = $state<{ texto: string; valor: string }[]>([]);
	let opcionesCiudad = $state<{ texto: string; valor: string }[]>([]);
	let paisElegido = $state(false);
	let departamentoElegido = $state(false);
	let ciudadElegida = $state(false);

	let opcionesPais = $derived(paises.map((p) => ({ texto: p.nombre, valor: p.nombre })));
	let hayDepartamentos = $derived(opcionesDepartamento.length > 0);
	let rotuloDivision = $derived(etiquetaDivision(opcionesDepartamento.map((o) => o.valor)));

	/**
	 * Al elegir pais se rehacen las dos listas de abajo.
	 *
	 * Y si el pais no tiene departamentos -- 50 de los 246 no los tienen -- se
	 * salta ese paso y las ciudades se piden del pais entero, o el campo se
	 * queda libre si tampoco hay.
	 */
	async function alElegirPais(nombre: string) {
		dirDepartamento = '';
		dirCiudad = '';
		departamentoElegido = false;
		ciudadElegida = false;
		opcionesCiudad = [];

		const p = paises.find((x) => comparable(x.nombre) === comparable(nombre));
		opcionesDepartamento = (p?.departamentos ?? []).map((d) => ({
			texto: paraLeer(d),
			valor: d
		}));

		if (opcionesDepartamento.length === 0 && nombre) {
			const lista = await ciudadesDePais(p?.nombre ?? nombre);
			opcionesCiudad = lista.map((c) => ({ texto: c, valor: c }));
		}
	}

	async function alElegirDepartamento(estado: string) {
		dirCiudad = '';
		ciudadElegida = false;
		if (!estado) {
			opcionesCiudad = [];
			return;
		}

		const p = paises.find((x) => comparable(x.nombre) === comparable(dirPais));
		let lista = await ciudadesDeDepartamento(p?.nombre ?? dirPais, estado);

		// Espana y Francia devuelven cero ciudades por departamento y miles por
		// pais: si el departamento sale vacio se cae al listado del pais.
		if (lista.length === 0) lista = await ciudadesDePais(p?.nombre ?? dirPais);

		opcionesCiudad = lista.map((c) => ({ texto: c, valor: c }));
	}

	let numero = $state('');
	let vencimiento = $state('');
	let cvv = $state('');
	let titular = $state('');
	let errorTarjeta = $state('');

	let cobrando = $state(false);
	/** Lo que fallo de verdad (red, 400, 404, 500). */
	let error = $state('');
	/** El mensaje del 402: el cobro simulado no paso. Se reintenta con otra tarjeta. */
	let rechazo = $state('');
	/** El mensaje del 409: la oferta cambio. Este no se reintenta desde aqui. */
	let bloqueo = $state('');
	/** Las lineas cuyo precio de hoy ya no es el congelado. Ver el bloque de avisos. */
	let avisos = $state<AvisoDePrecio[]>([]);

	let caja = $state<HTMLDivElement | null>(null);

	// ------------------------------------------------------------- derivados
	let esTarjeta = $derived(metodoElegido === 'tarjeta');
	let total = $derived(totalPedido(lineas));
	let vacio = $derived(lineas.length === 0);

	/**
	 * La clave de cada linea en el resumen.
	 *
	 * NO puede ser `id_pedido_producto` a secas, y esto tumbaba la pantalla:
	 * en modo carrito ese campo llega VACIO en todas las lineas -- lo crea la
	 * compra, y aqui todavia no hay pedido (ver `aLineasDePedido` en
	 * CarritoRedis.svelte). Con una sola linea no se notaba; con dos, las dos
	 * claves eran `''`, Svelte reventaba con `each_key_duplicate` y el
	 * checkout entero dejaba de pintarse: el boton de pagar no aparecia y no
	 * habia forma de comprar.
	 *
	 * `id_oferta` sirve para los dos modos: el carrito de Redis guarda UNA
	 * linea por oferta (PUT /carrito/lineas/:idOferta fija la cantidad
	 * absoluta), y en un pedido dos lineas del mismo producto son de ofertas
	 * distintas -- otra variante, u otro vendedor.
	 *
	 * Se prefiere `id_pedido_producto` cuando existe porque es la identidad de
	 * verdad de la fila: si algun dia un pedido llegara a tener dos lineas de
	 * la misma oferta, ese id las sigue distinguiendo.
	 */
	function claveLinea(l: LineaPedido): string {
		return l.id_pedido_producto !== '' && l.id_pedido_producto != null
			? `linea-${l.id_pedido_producto}`
			: `oferta-${l.id_oferta}`;
	}

	/**
	 * Que la persona NO tiene ni una direccion, y no que no se pudieron leer:
	 * son dos cosas distintas y solo la primera impide pagar. Si la peticion se
	 * cayo, `listaLeida` se queda en false y el boton no se bloquea por eso.
	 */
	let sinDirecciones = $derived(listaLeida && direcciones.length === 0);

	/**
	 * La fila VIVA de la que salio la version congelada del pedido, y si las dos
	 * ya no dicen lo mismo.
	 *
	 * Pasa de verdad: se abre el pedido, se corrige la direccion en el panel, y
	 * el pedido sigue apuntando a la version de antes -- que es lo correcto (un
	 * pedido recuerda a donde se dijo que se mandaba), pero nadie lo adivina
	 * viendo una sola linea. Se comparan por su texto, que es justo lo que la
	 * persona lee.
	 */
	let vivaDelPedido = $derived(
		direcciones.find((d) => d.id_direccion === direccionPedido?.id_direccion) ?? null
	);
	let textoViva = $derived(vivaDelPedido ? direccionEnUnaLinea(vivaDelPedido) : '');
	let entregaDesactualizada = $derived(
		direccionPedido != null && textoViva !== '' && textoViva !== direccionEnUnaLinea(direccionPedido)
	);

	/**
	 * Con un 409 en pantalla el boton de confirmar desaparece a proposito: la
	 * unica salida es volver al carrito y quitar o cambiar esa linea.
	 *
	 * Sin direccion en pantalla tampoco se paga: no por capricho del backend
	 * (comprar no la pide), sino porque nadie deberia pagar un envio sin haber
	 * leido a donde va. Mientras el PATCH esta en vuelo se espera: la direccion
	 * de la pantalla todavia no es la que quedo.
	 *
	 * Guardar una direccion nueva cuenta igual, y no es lo mismo que el PATCH:
	 * entre el POST que la crea y el PATCH que se la pone al pedido, lo que hay
	 * en pantalla sigue siendo la direccion VIEJA. Sin esperar aqui, quien
	 * acaba de escribir a donde quiere que le llegue podria pulsar Pagar en ese
	 * hueco y comprar a la de antes -- justo lo que esta pantalla existe para
	 * que no pase.
	 */
	/**
	 * Las dos condiciones que cambian entre los modos, y por que.
	 *
	 * En modo carrito NO hay `idPedido` (lo crea la compra) ni
	 * `direccionPedido` (no hay pedido al que ponersela). Lo que sustituye a
	 * las dos es `idElegida`: la direccion que la persona marco aqui y que
	 * viaja en el cuerpo de POST /carrito/comprar.
	 *
	 * Exigir las de arriba en modo carrito dejaba el boton apagado para
	 * siempre, sin decir por que -- se veia igual que si estuviera roto.
	 */
	let listoElPedido = $derived(
		modo === 'carrito' ? idElegida !== '' : idPedido != null && direccionPedido != null
	);

	/**
	 * A donde se entrega, en los dos modos.
	 *
	 * En modo pedido la verdad es la del pedido, que ya la guardo el servidor.
	 * En modo carrito el pedido no existe todavia, asi que es la que este
	 * marcada en la lista -- la misma que viaja en POST /carrito/comprar.
	 *
	 * Existe para que el pie de la pantalla no tenga que preguntar por
	 * `direccionPedido`, que en carrito es null siempre.
	 */
	let entregaFinal = $derived(
		modo === 'carrito'
			? (direcciones.find((d) => d.id_direccion === idElegida) ?? null)
			: direccionPedido
	);

	let sePuedeConfirmar = $derived(
		!cobrando &&
			!vacio &&
			bloqueo === '' &&
			metodoElegido !== '' &&
			listoElPedido &&
			!sinDirecciones &&
			!cambiandoDireccion &&
			!guardandoDireccion
	);

	// ------------------------------------------------------------- al abrir
	/**
	 * Estas dos NO son $state: no se pintan, solo sirven para no repetir
	 * trabajo. Si fueran reactivas, escribirlas dentro del $effect que las
	 * lee lo volveria a disparar.
	 */
	let estabaAbierto = false;
	let metodosPedidos = false;

	/**
	 * Cual de las cargas de entrega manda. Tampoco es $state, por lo mismo.
	 *
	 * Cerrar la ventana no cancela el fetch que ya salio. Si se cierra y se
	 * vuelve a abrir antes de que conteste, hay dos en vuelo y la vieja puede
	 * llegar de ultima: pisaria a la nueva y dejaria en pantalla la direccion
	 * de la apertura anterior, que es exactamente la mentira que este bloque
	 * existe para evitar. Solo escribe la ultima que salio.
	 */
	let cargaEntrega = 0;

	// La modal vive montada dentro del carrito, asi que "abrir" es que cambie
	// un booleano, no montarse: por eso el arranque va en un $effect que mira
	// el flanco y no en onMount, que solo correria una vez.
	$effect(() => {
		const ahora = abierto;
		if (ahora === estabaAbierto) return;
		estabaAbierto = ahora;
		if (ahora) untrack(() => alAbrir());
	});

	// Enfoca la ventana al abrirla para que Escape funcione sin tener que
	// pulsar dentro antes, y para que el lector de pantalla anuncie el dialogo.
	$effect(() => {
		caja?.focus();
	});

	function alAbrir() {
		error = '';
		rechazo = '';
		bloqueo = '';
		avisos = [];
		errorTarjeta = '';

		// Los datos de la tarjeta no sobreviven a cerrar la ventana. No se
		// guardan en ninguna parte (el backend tampoco tiene columna para
		// ellos), asi que dejarlos escritos solo seria un descuido.
		numero = '';
		vencimiento = '';
		cvv = '';
		titular = '';

		cerrarNueva();

		if (!metodosPedidos) cargarMetodos();

		// La entrega SI se vuelve a pedir en cada apertura, al reves que los
		// metodos de pago: la direccion se puede haber cambiado desde el panel
		// entre una apertura y otra, y ensenar la de hace un rato seria mentir
		// justo en el dato que esta pantalla existe para ensenar.
		cargarEntrega();
	}

	// ------------------------------------------------------------- entrega
	/**
	 * La lista de direcciones y el pedido, a la vez: ninguna depende de la
	 * otra. Hacen falta las dos porque el pedido solo dice CUAL tiene puesta
	 * (con su id_direccion dentro de la version congelada), no cuales hay.
	 */
	async function cargarEntrega() {
		const id = idPedido;
		const mia = ++cargaEntrega;

		errorEntrega = '';
		errorCambio = '';

		// En modo carrito NO hay pedido, y eso es lo normal: el pedido lo crea
		// la compra. Las direcciones se leen igual -- son de la CUENTA, no del
		// pedido -- y la elegida viaja despues en el cuerpo de
		// POST /carrito/comprar.
		//
		// Sin esta rama la pantalla salia sin una sola direccion y con el boton
		// de pagar apagado para siempre, porque el unico camino que las cargaba
		// pedia un idPedido que en este modo nunca existe.
		if (modo === 'carrito') {
			cargandoEntrega = true;
			const rDir = await traerDirecciones();
			if (mia !== cargaEntrega) return;
			cargandoEntrega = false;

			if (expiro(rDir)) return;

			if (rDir.ok && Array.isArray(rDir.payload)) {
				direcciones = rDir.payload;
				listaLeida = true;
				// No hay direccion "del pedido" que preseleccionar, asi que se
				// elige la primera. Con una sola direccion -- el caso normal --
				// eso evita un paso que no decide nada; con varias, se puede
				// cambiar.
				direccionPedido = null;
				idElegida = direcciones[0]?.id_direccion ?? '';
			} else {
				direcciones = [];
				listaLeida = false;
				idElegida = '';
				errorEntrega = motivo(rDir, 'No se pudieron leer tus direcciones');
			}
			return;
		}

		if (id == null) {
			// Sin pedido no hay direccion de entrega que ensenar. No es un error
			// que haya que gritar: el boton de pagar ya esta apagado por eso.
			//
			// El "Cargando..." se apaga aqui aunque esta carga no lo encendiera:
			// pudo dejarlo puesto una anterior que ya no manda, y esa no lo va a
			// apagar. Sin esto la seccion se quedaba cargando para siempre.
			direcciones = [];
			direccionPedido = null;
			idElegida = '';
			listaLeida = false;
			cargandoEntrega = false;
			return;
		}

		cargandoEntrega = true;
		const [rDirecciones, rPedido] = await Promise.all([traerDirecciones(), traerPedido(id)]);

		// Una carga vieja no escribe nada, ni siquiera apaga el "Cargando...":
		// el de la nueva sigue puesto a proposito.
		if (mia !== cargaEntrega) return;
		cargandoEntrega = false;

		// El `||` corta si la primera ya era un 401, para no sacar a la persona
		// dos veces por la misma sesion caducada.
		if (expiro(rDirecciones) || expiro(rPedido)) return;

		if (rDirecciones.ok && Array.isArray(rDirecciones.payload)) {
			direcciones = rDirecciones.payload;
			listaLeida = true;
		} else {
			direcciones = [];
			listaLeida = false;
			errorEntrega = motivo(rDirecciones, 'No se pudieron leer tus direcciones');
		}

		if (rPedido.ok && rPedido.payload != null) {
			direccionPedido = rPedido.payload.direccion ?? null;
		} else {
			direccionPedido = null;
			if (errorEntrega === '') {
				errorEntrega = motivo(rPedido, 'No se pudo leer la direccion de este pedido');
			}
		}

		idElegida = direccionPedido?.id_direccion ?? '';
	}

	/**
	 * Que decirle a la persona cuando una respuesta no sirvio.
	 *
	 * Son tres casos, no uno. Con `estado` 0 el backend no contesto y no hay
	 * ningun mensaje suyo que ensenar. Con un error de verdad, el suyo es el
	 * bueno. Y con `ok` pero sin datos utiles, su `mensaje` es uno de EXITO:
	 * pintarlo en rojo dejaria "Direcciones obtenidas" en pantalla como si
	 * fuera el problema.
	 */
	function motivo(r: RespuestaApi<unknown>, sinDatos: string): string {
		if (r.ok) return sinDatos;
		return r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
	}

	/**
	 * Vuelve a leer el pedido para saber que direccion quedo de VERDAD.
	 *
	 * La respuesta del PATCH devuelve el id que se le mando, no lo que guardo,
	 * asi que pintarla seria pintar lo que uno creyo. Si la relectura falla se
	 * deja en null a proposito: ensenar la de antes junto a un error dejaria a
	 * la vista una direccion que ya puede no ser la del pedido.
	 */
	async function releerPedido(id: string): Promise<boolean> {
		const r = await traerPedido(id);

		if (expiro(r)) return false;

		if (!r.ok || r.payload == null) {
			direccionPedido = null;
			errorEntrega = motivo(r, 'No se pudo leer la direccion de este pedido');
			return false;
		}

		errorEntrega = '';
		direccionPedido = r.payload.direccion ?? null;
		return direccionPedido != null;
	}

	/**
	 * Pone esa direccion en el pedido. Solo funciona mientras sigue pendiente,
	 * que es justo el caso de esta pantalla; un pedido ya comprado contesta 409
	 * y se ensena tal cual, sin traducirlo.
	 */
	async function ponerDireccion(idDireccion: string): Promise<boolean> {
		// En modo carrito no hay pedido al que ponerle la direccion: todavia no
		// existe. Se elige aqui y viaja en el cuerpo de POST /carrito/comprar.
		// Devolver true no es mentir: la direccion QUEDO elegida, que es lo que
		// esta funcion promete a quien la llama.
		if (modo === 'carrito') return true;

		const id = idPedido;
		if (id == null || idDireccion === '') return false;

		cambiandoDireccion = true;
		errorCambio = '';

		const r = await cambiarDireccionPedido(id, idDireccion);

		if (expiro(r)) {
			cambiandoDireccion = false;
			return false;
		}

		if (!r.ok) {
			cambiandoDireccion = false;
			errorCambio = motivo(r, 'No se pudo cambiar la direccion del pedido');
			return false;
		}

		const leido = await releerPedido(id);
		cambiandoDireccion = false;
		return leido;
	}

	/**
	 * El boton de "usar la version de hoy": es la MISMA direccion, asi que solo
	 * hay que volver a ponerla para que el pedido apunte a su version nueva.
	 *
	 * El radio se resincroniza igual que al elegir otra, y por lo mismo: si la
	 * relectura falla, el pedido se queda sin direccion conocida, y dejar un
	 * punto marcado ahi diria que se entrega en un sitio que ya nadie sabe si
	 * es el del pedido.
	 */
	async function reponerLaDeHoy() {
		const idDireccion = direccionPedido?.id_direccion ?? '';
		if (idDireccion === '') return;

		await ponerDireccion(idDireccion);
		idElegida = direccionPedido?.id_direccion ?? '';
	}

	async function elegirDireccion(idDireccion: string) {
		if (idDireccion === idElegida || cambiandoDireccion) return;

		// Se marca antes de que conteste el servidor para que el radio no se
		// quede saltando, y despues se deja el que diga el pedido: si el PATCH
		// fallo, el punto vuelve solo a donde estaba.
		idElegida = idDireccion;
		await ponerDireccion(idDireccion);

		// Esa relectura es SOLO del modo pedido, y olvidarlo rompia el otro.
		//
		// En modo carrito no hay pedido, asi que `direccionPedido` es null
		// SIEMPRE y esta linea dejaba `idElegida` en '': marcabas una direccion
		// y se desmarcaba sola, sin ningun error. Y como `listoElPedido` en
		// este modo es justo `idElegida !== ''`, quedaba sin poder pagar.
		//
		// `ponerDireccion` ya trae su rama para el carrito -- se acordaron de
		// esta funcion y no de la de al lado. Por eso el candado va aqui y no
		// dentro: la que sabe si hay pedido del que releer es esta.
		if (modo !== 'carrito') {
			idElegida = direccionPedido?.id_direccion ?? '';
		}
	}

	/**
	 * Abre el formulario y, la primera vez, baja la lista de paises.
	 *
	 * Se baja AQUI y no al montar el checkout: son 226 KB, y quien paga con
	 * una direccion que ya tiene guardada no tiene por que descargarlos. Si la
	 * API no contesta, `cargarPaises` devuelve una lista vacia y los tres
	 * campos se comportan como texto libre -- que es lo que hacian antes de
	 * este cambio, asi que en el peor caso no se pierde nada.
	 */
	async function abrirNueva() {
		formNueva = true;
		if (paises.length > 0 || cargandoPaises) return;

		cargandoPaises = true;
		paises = await cargarPaises();
		cargandoPaises = false;
	}

	function cerrarNueva() {
		formNueva = false;
		dirPais = '';
		dirDepartamento = '';
		dirCiudad = '';
		dirExacta = '';
		dirPostal = '';
		errorNueva = '';
		paisElegido = false;
		departamentoElegido = false;
		ciudadElegida = false;
		opcionesDepartamento = [];
		opcionesCiudad = [];
	}

	/**
	 * Las mismas reglas del backend (helpers/validaciones-direccion.ts) y con
	 * sus mismos mensajes: repetirlas aqui ahorra una peticion que ya se sabe
	 * que vuelve con un 400.
	 */
	function revisarDireccion(): string {
		if (dirPais.trim() === '') return 'El pais es obligatorio';
		if (dirPais.trim().length > 100) return 'El pais no puede tener mas de 100 caracteres';
		if (dirDepartamento.trim() === '') return 'El departamento es obligatorio';
		// Se mide lo que se va a MANDAR, no lo que se ve: el sufijo se quita
		// antes de guardar, asi que contarlo aqui rechazaria nombres que caben.
		if (paraLeer(dirDepartamento.trim()).length > 100) {
			return 'El departamento no puede tener mas de 100 caracteres';
		}

		// Y que lo escrito sea de verdad una opcion de la lista, no algo
		// tecleado encima. Sin esto se podia elegir Guatemala, escribir
		// "Sacate" a mano sobre el departamento y guardar un lugar que no
		// existe -- que es justo lo que Autocompletar sirve para evitar.
		if (opcionesPais.length > 0 && !paisElegido) {
			return 'Elegi un pais de la lista';
		}
		if (hayDepartamentos && !departamentoElegido) {
			return 'Elegi un departamento de la lista';
		}
		if (opcionesCiudad.length > 0 && !ciudadElegida) {
			return 'Elegi una ciudad de la lista';
		}
		if (dirCiudad.trim() === '') return 'La ciudad es obligatoria';
		if (dirCiudad.trim().length > 100) return 'La ciudad no puede tener mas de 100 caracteres';
		// La calle: obligatoria, y con el mensaje del backend palabra por palabra,
		// que es el criterio que sigue toda esta funcion.
		if (dirExacta.trim() === '') return 'La direccion exacta es obligatoria';
		if (dirExacta.trim().length > 255) {
			return 'La direccion exacta no puede tener mas de 255 caracteres';
		}
		if (dirPostal.trim().length > 20) {
			return 'El codigo postal no puede tener mas de 20 caracteres';
		}
		return '';
	}

	/**
	 * Crea la direccion y ademas la deja usada para ESTE envio: crearla sola no
	 * cambia a donde se entrega, y quien la escribe aqui la escribe para esta
	 * compra.
	 *
	 * Como se "usa" depende del modo, igual que en `cargarEntrega` y en
	 * `listoElPedido`:
	 *
	 *   modo pedido   -> se le pone al pedido con un PATCH (hay fila que tocar)
	 *   modo carrito  -> se marca en `idElegida`, que es lo que viaja despues en
	 *                    el cuerpo de POST /carrito/comprar
	 *
	 * Esta rama FALTABA y era un callejon sin salida: en modo carrito no hay
	 * `idPedido` -- lo crea la compra -- asi que el formulario contestaba "No
	 * hay un pedido abierto al que ponersela" y no guardaba nada. A quien no
	 * tuviera ya una direccion guardada le dejaba el checkout muerto: no podia
	 * crearla aqui, y sin direccion el boton de pagar nunca se enciende.
	 */
	async function crearYUsar(evento: SubmitEvent) {
		evento.preventDefault();

		if (modo === 'pedido' && idPedido == null) {
			errorNueva = 'No hay un pedido abierto al que ponersela';
			return;
		}

		const problema = revisarDireccion();
		if (problema !== '') {
			errorNueva = problema;
			return;
		}

		errorNueva = '';
		guardandoDireccion = true;

		const r = await crearDireccion({
			pais: dirPais.trim(),
			// `paraLeer` le quita el sufijo con el que viene de la API:
			// "Sacatepequez Department" -> "Sacatepequez". Es lo mismo que hace
			// Direcciones.svelte al guardar, y sin esto las direcciones creadas
			// desde el checkout quedarian escritas distinto que las creadas
			// desde el panel -- y encima con una palabra en ingles.
			departamento: paraLeer(dirDepartamento.trim()),
			ciudad: dirCiudad.trim(),
			// Esta NO va como null cuando esta vacia, a diferencia del codigo
			// postal: es obligatoria, y el formulario ya no deja llegar aqui sin
			// ella.
			direccion_exacta: dirExacta.trim(),
			// El vacio va como null y no como '': la columna es opcional, y ''
			// seria un codigo postal que existe y esta en blanco.
			codigo_postal: dirPostal.trim() === '' ? null : dirPostal.trim()
		});

		if (expiro(r)) {
			guardandoDireccion = false;
			return;
		}

		if (!r.ok || r.payload == null) {
			guardandoDireccion = false;
			// El `ok` sin payload es el caso feo: la direccion SI se creo, pero sin
			// su id no hay con que ponersela al pedido. Se dice eso, no el mensaje
			// de exito del backend, y no se cierra el formulario: volver a mandarla
			// crearia una copia.
			errorNueva = motivo(
				r,
				'Se guardo la direccion pero el servidor no dijo cual. Recarga la pagina y elegila en la lista.'
			);
			return;
		}

		// Ya existe aunque el PATCH de despues falle, asi que entra en la lista
		// igual: perderla de vista obligaria a escribirla otra vez.
		const nueva = r.payload;
		direcciones = [nueva, ...direcciones];
		listaLeida = true;

		// En modo carrito no hay pedido al que ponersela: basta con marcarla.
		// Es la misma direccion que viaja en el cuerpo de la compra, asi que
		// con esto el boton de pagar ya se enciende.
		if (modo === 'carrito') {
			guardandoDireccion = false;
			idElegida = nueva.id_direccion;
			cerrarNueva();
			return;
		}

		const puesta = await ponerDireccion(nueva.id_direccion);
		guardandoDireccion = false;

		idElegida = direccionPedido?.id_direccion ?? '';
		if (puesta) cerrarNueva();
	}

	/**
	 * El catalogo de formas de pago se pide, no se escribe a mano: son filas de
	 * `metodo_pago` en PostgreSQL y lo que viaja al comprar es `metodo_nombre`.
	 * Escribirlas aqui dejaria de cuadrar en cuanto la base cambiara una.
	 */
	async function cargarMetodos() {
		metodosPedidos = true;
		cargandoMetodos = true;
		errorMetodos = '';

		const r = await traerMetodosPago();
		cargandoMetodos = false;

		if (expiro(r)) return;

		if (r.ok) {
			// Un `ok` puede traer el payload en null, asi que la lista se
			// comprueba antes de guardarla: pintar `null` en el {#each} tumba la
			// ventana entera, y tratar ese caso como un fallo ensenaria el
			// mensaje de exito del backend en rojo. Sin filas hay estado vacio.
			metodos = Array.isArray(r.payload) ? r.payload : [];
			// Se preselecciona la primera solo si hay una sola opcion; con tres,
			// elegir por la persona es decidir como paga sin preguntarle.
			if (metodos.length === 1) metodoElegido = metodos[0].metodo_nombre;
		} else {
			// Sin catalogo no se puede comprar: no se sabe que mandar.
			metodosPedidos = false;
			metodos = [];
			errorMetodos = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	/** true si la sesion se acabo. Se avisa arriba para que saque a la persona. */
	function expiro(r: RespuestaApi<unknown>): boolean {
		if (r.estado === 401) {
			alExpirarSesion?.();
			return true;
		}
		return false;
	}

	// -------------------------------------------------------------- cerrar
	/**
	 * Mientras se esta cobrando no se cierra ni con Escape ni pulsando el
	 * fondo: la peticion YA salio y cerrar seria tirar su respuesta -- la
	 * compra podria haberse hecho y nadie se enteraria.
	 */
	function intentarCerrar() {
		if (cobrando) return;
		alCerrar?.();
	}

	/**
	 * Escape se atiende en la fase de CAPTURA y se corta la propagacion a
	 * proposito: el carrito de detras escucha Escape en esta misma ventana y
	 * sigue abierto mientras esta pantalla esta encima. Sin cortarlo, una sola
	 * pulsacion cerraria las dos cosas -- y peor: mientras se esta cobrando,
	 * aqui no se cierra nada pero el carrito si se cerraria.
	 */
	function alTecla(evento: KeyboardEvent) {
		if (!abierto || evento.key !== 'Escape') return;
		evento.stopPropagation();
		intentarCerrar();
	}

	// ------------------------------------------------------------- tarjeta
	function soloDigitos(texto: string): string {
		return texto.replace(/\D/g, '');
	}

	/** El numero se ensena de cuatro en cuatro, pero se manda pelado. */
	function agrupar(digitos: string): string {
		return digitos.replace(/(.{4})/g, '$1 ').trim();
	}

	/**
	 * Deja el campo del navegador igual a lo que quedo en la variable.
	 *
	 * Hace falta porque estos tres campos son de una via (`value={...}` con
	 * `oninput`) y Svelte solo reescribe el DOM cuando la variable CAMBIA. Al
	 * teclear una letra en el numero, o un digito de mas pasados los 19, el
	 * texto limpio sale identico al de antes: la variable no cambia, Svelte no
	 * toca nada, y el caracter sobrante se queda visible en pantalla aunque no
	 * este en lo que se va a mandar.
	 */
	function sincronizar(campo: HTMLInputElement, valor: string) {
		if (campo.value !== valor) campo.value = valor;
	}

	function alEscribirNumero(evento: Event) {
		const campo = evento.currentTarget as HTMLInputElement;
		// 19 es el maximo que acepta el backend; cortarlo aqui evita escribir
		// digitos que van a dar un 400 seguro.
		numero = agrupar(soloDigitos(campo.value).slice(0, 19));
		sincronizar(campo, numero);
	}

	function alEscribirVencimiento(evento: Event) {
		const campo = evento.currentTarget as HTMLInputElement;
		const d = soloDigitos(campo.value).slice(0, 4);
		// La barra la pone el campo. Si la escribiera la persona, borrar hacia
		// atras se quedaria trabado en ella.
		vencimiento = d.length <= 2 ? d : `${d.slice(0, 2)}/${d.slice(2)}`;
		sincronizar(campo, vencimiento);
	}

	function alEscribirCvv(evento: Event) {
		const campo = evento.currentTarget as HTMLInputElement;
		cvv = soloDigitos(campo.value).slice(0, 4);
		sincronizar(campo, cvv);
	}

	/**
	 * El algoritmo de Luhn: se dobla un digito si y no desde la derecha, y si
	 * doblado pasa de 9 se le restan 9. La suma tiene que ser multiplo de 10.
	 *
	 * Es la misma comprobacion que hace el backend, y esta repetida a
	 * proposito: un numero mal tecleado se caza aqui sin gastar una peticion
	 * que ya se sabe que devuelve 400.
	 */
	function pasaLuhn(digitos: string): boolean {
		let suma = 0;
		let doble = false;

		for (let i = digitos.length - 1; i >= 0; i--) {
			let d = digitos.charCodeAt(i) - 48;
			if (doble) {
				d *= 2;
				if (d > 9) d -= 9;
			}
			suma += d;
			doble = !doble;
		}

		return suma % 10 === 0;
	}

	/**
	 * Devuelve el problema de la tarjeta, o '' si esta bien. Las cuatro reglas
	 * son las del backend, ni una mas: inventarse otra aqui rechazaria tarjetas
	 * que el servidor si aceptaria.
	 */
	function revisarTarjeta(): string {
		const digitos = soloDigitos(numero);

		if (digitos.length < 13 || digitos.length > 19) {
			return 'El numero de tarjeta debe tener entre 13 y 19 digitos';
		}
		if (!pasaLuhn(digitos)) {
			// El mensaje de antes decia "revisa que no falte ni sobre un digito",
			// y eso habla de la LONGITUD -- que a estas alturas ya paso. Con 19
			// digitos, que es el maximo que acepta el campo, se leia como que la
			// pantalla se contradecia: te deja escribir 19 y luego te dice que
			// cuentes los digitos.
			//
			// Lo que falla es otra cosa y conviene decirla: el ultimo digito de
			// una tarjeta no es libre, se calcula a partir de los demas (Luhn),
			// asi que una tirada de numeros al azar casi nunca cuadra.
			return (
				'Ese numero no puede ser de una tarjeta: el ultimo digito es una cifra de ' +
				'control que se calcula con los demas, y no cuadra. Para probar usa ' +
				'4242 4242 4242 4242.'
			);
		}

		const mm = /^(\d{2})\/(\d{2})$/.exec(vencimiento.trim());
		if (!mm) return 'El vencimiento debe tener el formato MM/AA';

		const mes = Number(mm[1]);
		const anio = 2000 + Number(mm[2]);
		if (mes < 1 || mes > 12) return 'El mes del vencimiento tiene que estar entre 01 y 12';

		const hoy = new Date();
		// La tarjeta vale hasta el ULTIMO dia de su mes, asi que el mes en curso
		// todavia sirve: solo se rechaza uno anterior.
		if (anio < hoy.getFullYear() || (anio === hoy.getFullYear() && mes < hoy.getMonth() + 1)) {
			return 'Esa tarjeta ya vencio';
		}

		if (!/^\d{3,4}$/.test(cvv.trim())) return 'El CVV debe tener 3 o 4 digitos';
		if (titular.trim() === '') return 'Escribe el nombre del titular';

		return '';
	}

	// ------------------------------------------------------------- comprar
	/**
	 * @param confirmarCambios lo manda el boton del aviso de precios. Es la
	 * MISMA peticion de antes con una bandera de mas: sin ella el backend
	 * vuelve a avisar y no compra.
	 */
	async function confirmar(confirmarCambios = false) {
		// En modo carrito NO hay idPedido, y no es un error: lo crea la propia
		// compra. Solo el modo viejo lo exige.
		if (modo === 'pedido' && idPedido == null) {
			error = 'No hay un pedido abierto que comprar';
			return;
		}
		if (modo === 'carrito' && idElegida === '') {
			error = 'Elige una direccion de entrega';
			return;
		}
		if (metodoElegido === '') {
			error = 'Elige una forma de pago';
			return;
		}

		error = '';
		rechazo = '';
		bloqueo = '';
		errorTarjeta = '';

		const cuerpo: {
			metodo_pago: string;
			tarjeta?: DatosTarjeta;
			confirmar_cambios?: boolean;
		} = { metodo_pago: metodoElegido };

		if (esTarjeta) {
			const problema = revisarTarjeta();
			if (problema !== '') {
				errorTarjeta = problema;
				return;
			}
			cuerpo.tarjeta = {
				// Se manda sin espacios: los grupos de cuatro son de la pantalla.
				numero: soloDigitos(numero),
				vencimiento: vencimiento.trim(),
				cvv: cvv.trim(),
				titular: titular.trim()
			};
		}

		if (confirmarCambios) cuerpo.confirmar_cambios = true;

		cobrando = true;

		// EL PRECIO QUE SE VIO VIAJA CON LA COMPRA, y esto cambio hace poco.
		//
		// El carrito de Redis guarda `id_oferta -> cantidad` y nada mas: no
		// guarda el precio, a proposito, porque el precio no es del carrito,
		// es de la oferta. La consecuencia era un cobro incorrecto silencioso:
		// esta pantalla ensenaba un total, la persona decidia con ese numero, y
		// si el vendedor lo movia antes del clic se le cobraba otro sin que
		// nadie se enterara.
		//
		// La solucion NO fue guardar el precio en Redis. Es que se acuerde
		// quien lo enseno: el frontend manda de vuelta lo que puso en pantalla,
		// y el backend compara contra el precio de hoy DENTRO de la misma
		// peticion que cobra. Ahi esta la gracia, y es lo que una comprobacion
		// hecha aqui antes de llamar no puede dar: entre mirar y cobrar no
		// queda ninguna ventana, porque son el mismo viaje.
		//
		// Si algo no cuadra, el backend no cobra nada -- ni Redis, ni Postgres,
		// ni Mongo -- y contesta `comprado: false` con los `avisos`. La segunda
		// pulsacion manda `confirmar_cambios: true` y acepta el precio de hoy.
		//
		// `confirmar_cambios` SI viaja ahora en modo carrito. Antes no, y aqui
		// habia escrito que no era un olvido sino que no habia con que
		// comparar. Eso dejo de ser cierto en cuanto existio
		// `lineas_precio_visto`.
		//
		// El precio se manda TAL CUAL vino, como texto. Son decimales de
		// PostgreSQL y el backend los compara como tales: pasarlos por Number
		// aqui podria convertir 4269.00 en 4269 y hacer que dos precios iguales
		// parezcan distintos.
		const r =
			modo === 'carrito'
				? await pedir<ResultadoCompra>(
						'/carrito/comprar',
						conJson('POST', {
							id_direccion: idElegida,
							metodo_pago: cuerpo.metodo_pago,
							...(cuerpo.tarjeta ? { tarjeta: cuerpo.tarjeta } : {}),
							lineas_precio_visto: lineas.map((l) => ({
								id_oferta: Number(l.id_oferta),
								precio_visto: l.precio_unitario
							})),
							...(confirmarCambios ? { confirmar_cambios: true } : {})
						})
					)
				: await comprarPedido(idPedido as string, cuerpo);
		cobrando = false;

		if (expiro(r)) return;

		if (r.ok) {
			if (r.payload == null) {
				// `ok` con el payload en null no deberia pasar en esta ruta, pero
				// si pasa NO se sabe si el cobro se hizo, y volver a pulsar a
				// ciegas podria comprar dos veces. Por eso no se ensena el
				// mensaje del backend (que aqui seria uno de exito) sino que se
				// manda a mirar los pedidos.
				error =
					'El servidor contesto sin decir que paso. Revisa tus pedidos antes de volver a intentarlo.';
				return;
			}

			if (r.payload.comprado) {
				// El padre decide que pasa despues (vaciar el carrito, olvidar el
				// id, ensenar el comprobante): aqui no se sabe donde vive nada de
				// eso.
				avisos = [];
				alComprado?.(r.payload);
				return;
			}

			// ok con comprado:false NO es un fallo: no se toco el stock, ni el
			// pago, ni el estado del pedido. Es la unica parada antes de cobrar.
			//
			// LAS DOS RUTAS NO MANDAN EL MISMO AVISO, y hay que normalizarlo.
			//
			//   pedido    { id_pedido_producto, precio_congelado, precio_actual }
			//   carrito   { id_oferta,          precio_visto,     precio_actual }
			//
			// Los nombres distintos no son un descuido de nadie: describen cosas
			// distintas. En el pedido el precio esta CONGELADO y el aviso dice
			// "esto vale otra cosa hoy, pero te cobro el tuyo". En el carrito no
			// hay nada congelado: el aviso dice "esto ya no vale lo que viste, y
			// si sigues te cobro el de hoy". Son avisos opuestos.
			//
			// Se traducen al tipo del pedido porque es el que pinta la tabla, y
			// la tabla ya distingue los dos casos por el modo. Meter aqui un
			// `as` para taparlo compilaria y ensenaria celdas vacias: los campos
			// no existen con ese nombre.
			avisos = (r.payload.avisos ?? []).map((a) => {
				const c = a as unknown as Partial<AvisoDePrecio> & {
					id_oferta?: number;
					precio_visto?: string;
				};
				return {
					id_pedido_producto: c.id_pedido_producto ?? c.id_oferta ?? 0,
					nombre_producto: c.nombre_producto ?? '',
					nombre_variante: c.nombre_variante ?? '',
					precio_congelado: c.precio_congelado ?? c.precio_visto ?? '0',
					precio_actual: c.precio_actual ?? '0'
				};
			});
			if (avisos.length === 0) {
				// No deberia pasar, pero si el backend contesta "no compre" sin
				// decir por que, callarlo dejaria la ventana igual que antes y
				// pareceria que el boton no hizo nada.
				error = r.mensaje;
			}
			return;
		}

		if (r.estado === 402) {
			// El mensaje del backend es el motivo exacto del rechazo simulado
			// (sin fondos, robada, CVV malo...). Se ensena tal cual: resumirlo
			// en "tarjeta rechazada" perderia lo unico util que trae.
			rechazo = r.mensaje;
			return;
		}

		if (r.estado === 409) {
			bloqueo = r.mensaje;
			return;
		}

		error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
	}

	// -------------------------------------------------------------- rotulos
	function rotulo(nombre: string): string {
		return nombre.charAt(0).toUpperCase() + nombre.slice(1);
	}

	/**
	 * Una linea de ayuda por metodo. No estan todos a proposito: el catalogo
	 * vive en la base y uno nuevo sale sin ayuda, que es mejor que salir con
	 * una ayuda inventada.
	 */
	const AYUDA: Record<string, string> = {
		tarjeta: 'Cobro simulado. No se guarda ningun dato de la tarjeta.',
		'efectivo contra entrega': 'Pagas al recibir el pedido.'
	};
</script>

<svelte:window onkeydowncapture={alTecla} />

{#if abierto}
	<div class="capa">
		<!-- El fondo es un <button> de verdad y no un <div> con onclick: asi
		     cerrar pulsando fuera tambien funciona con teclado, y no hace falta
		     ningun rol inventado para que sea accesible. -->
		<button
			type="button"
			class="fondo"
			aria-label="Cerrar sin comprar"
			disabled={cobrando}
			onclick={intentarCerrar}
		></button>

		<div
			class="caja"
			role="dialog"
			aria-modal="true"
			aria-labelledby="titulo-checkout"
			tabindex="-1"
			bind:this={caja}
		>
			<header class="cabeza">
				<div>
					<h2 id="titulo-checkout">Confirmar la compra</h2>
					<p class="menor">Revisa lo que llevas y elige como pagarlo.</p>
				</div>
				<button type="button" class="cerrar" onclick={intentarCerrar} disabled={cobrando}>
					Cerrar
				</button>
			</header>

			<!-- ------------------------------------------------------ entrega -->
			<!-- Va lo primero, antes del resumen: es lo que nadie estaba viendo, y
			     al final del todo se repite junto al boton de pagar. -->
			<section class="bloque">
				<h3>A donde se entrega</h3>

				{#if cargandoEntrega}
					<p class="quieto">Cargando la direccion de entrega...</p>
				{:else}
					{#if direccionPedido}
						<p class="actual">{direccionEnUnaLinea(direccionPedido)}</p>

						{#if entregaDesactualizada}
							<!-- El pedido guarda una VERSION, no la direccion viva: si se
							     corrigio despues de abrirlo, sigue apuntando a la de antes
							     hasta que se vuelva a poner. -->
							<p class="menor eleccion">
								Esa es la version que se guardo al abrir el pedido. Esa misma
								direccion hoy dice <strong>{textoViva}</strong>.
							</p>
							<button
								type="button"
								class="enlace"
								disabled={cobrando || cambiandoDireccion || guardandoDireccion}
								onclick={reponerLaDeHoy}
							>
								Entregar en la version de hoy
							</button>
						{/if}
					{/if}

					{#if sinDirecciones}
						<!-- Sin ninguna direccion no se entrega nada, asi que aqui no se
						     "avisa": se dice que no se puede pagar y se dan las dos
						     salidas, la del panel y la de escribirla sin salir. -->
						<div class="malo" role="alert">
							<p>
								Todavia no tienes ninguna direccion guardada, y sin una no se
								puede entregar el pedido.
							</p>
							<p class="menor">
								Agregala aqui abajo, o desde <a href="/panel">tu panel</a>.
							</p>
						</div>
					{/if}

					{#if errorEntrega}
						<div class="malo" role="alert">
							<p>{errorEntrega}</p>
						</div>
						<button
							type="button"
							class="reintentar"
							onclick={cargarEntrega}
							disabled={cambiandoDireccion || guardandoDireccion}
						>
							Reintentar
						</button>
					{/if}

					{#if direcciones.length > 1}
						<!-- El selector solo sale con mas de una: con una sola, elegir
						     entre una cosa no es elegir, solo estorba. -->
						<p class="menor eleccion">Se entrega en la que este marcada:</p>
						<div class="opciones">
							{#each direcciones as d (d.id_direccion)}
								<label class="opcion" class:elegida={idElegida === d.id_direccion}>
									<input
										type="radio"
										name="direccion-entrega"
										checked={idElegida === d.id_direccion}
										disabled={cobrando || cambiandoDireccion || guardandoDireccion}
										onchange={() => elegirDireccion(d.id_direccion)}
									/>
									<span class="datos">
										<strong>{direccionEnUnaLinea(d)}</strong>
									</span>
								</label>
							{/each}
						</div>
					{/if}

					{#if cambiandoDireccion}
						<p class="quieto" role="status">Cambiando la direccion del pedido...</p>
					{/if}

					{#if errorCambio}
						<p class="malo" role="alert">{errorCambio}</p>
					{/if}

					{#if formNueva}
						<form class="nueva" onsubmit={crearYUsar} novalidate>
							<div class="campos">
								{#if cargandoPaises}
									<p class="quieto ancho" role="status">Cargando los paises...</p>
								{/if}

								<!--
									Los mismos tres campos encadenados que el registro y el
									panel: el pais trae sus departamentos y el departamento
									sus ciudades. Antes eran tres <input type="text"> sueltos,
									y se podia guardar un pais que no existe.

									Con la lista vacia (la API caida, o un pais sin
									departamentos) Autocompletar se vuelve texto libre solo,
									asi que el formulario nunca se queda bloqueado.
								-->
								<div class="ancho">
									<Autocompletar
										id="ck-pais"
										etiqueta="Pais"
										opciones={opcionesPais}
										bind:valor={dirPais}
										bind:elegido={paisElegido}
										alElegir={alElegirPais}
										deshabilitado={guardandoDireccion || cargandoPaises}
										mostrarAlEnfocar
										compacto
									/>
								</div>

								<div>
									<Autocompletar
										id="ck-departamento"
										etiqueta={rotuloDivision}
										opciones={opcionesDepartamento}
										bind:valor={dirDepartamento}
										bind:elegido={departamentoElegido}
										alElegir={alElegirDepartamento}
										deshabilitado={guardandoDireccion || !dirPais}
										permitirLibre={!hayDepartamentos}
										mostrarAlEnfocar
										compacto
									/>
								</div>

								<div>
									<Autocompletar
										id="ck-ciudad"
										etiqueta="Ciudad"
										opciones={opcionesCiudad}
										bind:valor={dirCiudad}
										bind:elegido={ciudadElegida}
										deshabilitado={guardandoDireccion || !dirPais}
										permitirLibre={opcionesCiudad.length === 0}
										mostrarAlEnfocar
										compacto
									/>
								</div>

								<label class="ancho">
									Calle, numero y zona
									<input
										type="text"
										maxlength="255"
										autocomplete="street-address"
										placeholder="5a. Avenida Norte 22, frente al Arco"
										bind:value={dirExacta}
										disabled={guardandoDireccion}
									/>
								</label>

								<label class="ancho">
									Codigo postal <span class="opcional">opcional</span>
									<input type="text" bind:value={dirPostal} disabled={guardandoDireccion} />
								</label>
							</div>

							{#if errorNueva}
								<p class="malo" role="alert">{errorNueva}</p>
							{/if}

							<div class="acciones">
								<button type="submit" class="principal" disabled={guardandoDireccion}>
									{guardandoDireccion ? 'Guardando...' : 'Guardar y usar esta'}
								</button>
								<button type="button" onclick={cerrarNueva} disabled={guardandoDireccion}>
									Cancelar
								</button>
							</div>
						</form>
					{:else}
						<button
							type="button"
							class="enlace"
							onclick={abrirNueva}
							disabled={cobrando || cambiandoDireccion}
						>
							{sinDirecciones ? 'Agregar una direccion' : 'Usar otra direccion'}
						</button>
					{/if}
				{/if}
			</section>

			<!-- ------------------------------------------------------ resumen -->
			<section class="bloque">
				<h3>Lo que llevas</h3>

				{#if vacio}
					<p class="quieto">
						El pedido no tiene ninguna linea. Agrega algo antes de comprar.
					</p>
				{:else}
					<ul class="resumen">
						{#each lineas as l (claveLinea(l))}
							<li class="linea">
								<span class="datos">
									<strong>{l.nombre_producto}</strong>
									<span class="menor">
										{l.nombre_variante} · {l.nombre_vendedor}
									</span>
									<span class="menor">
										{l.cantidad} × {quetzales(Number(l.precio_unitario))}
									</span>
								</span>
								<strong class="importe">{quetzales(subtotal(l))}</strong>
							</li>
						{/each}
					</ul>

					<p class="total">
						<span>Total</span>
						<strong>{quetzales(total)}</strong>
					</p>
					<!-- Se dice aqui y no solo cuando cambia: es la regla del modelo,
					     y saberla antes evita la sorpresa de ver otro precio en la
					     ficha del producto.

					     Y el texto DEPENDE DEL MODO, porque hoy la regla no es la
					     misma en los dos. En modo pedido el precio se congelo de
					     verdad al agregar la linea, que es lo que decia esta nota.
					     En modo carrito NO: el carrito de Redis guarda intencion
					     (`id_oferta -> cantidad`) y el precio se resuelve al pagar,
					     asi que prometer aqui un precio congelado es prometer algo
					     que el sistema todavia no hace -- y sobre dinero. Es el
					     pendiente #1: la migracion 013 ya deja congelarlo, pero
					     falta que el carrito guarde el `id_precio_historial`.
					     Cuando eso exista, las dos ramas dicen lo mismo y esto se
					     vuelve una sola linea otra vez. -->
					{#if modo === 'carrito'}
						<p class="menor nota">
							Se cobra el precio de <strong>ahora</strong>. Si el vendedor lo cambio
							mientras el carrito esperaba, el total de arriba ya es el nuevo.
						</p>
					{:else}
						<p class="menor nota">
							Se cobra el precio que quedo congelado al agregar cada linea, aunque el
							vendedor lo haya cambiado despues.
						</p>
					{/if}
				{/if}
			</section>

			<!-- ------------------------------------------------ forma de pago -->
			<section class="bloque">
				<h3>Como quieres pagar</h3>

				{#if cargandoMetodos}
					<p class="quieto">Cargando las formas de pago...</p>
				{:else if errorMetodos}
					<p class="malo" role="alert">{errorMetodos}</p>
					<button type="button" onclick={cargarMetodos}>Reintentar</button>
				{:else if metodos.length === 0}
					<!-- Sin esto la seccion se quedaba en blanco y el boton de pagar
					     deshabilitado sin decir por que. Se dice lo unico que se sabe
					     de verdad -- que no llego ninguna --, no que no existan. -->
					<p class="quieto">No llego ninguna forma de pago.</p>
					<button type="button" onclick={cargarMetodos}>Reintentar</button>
				{:else}
					<div class="metodos">
						{#each metodos as m (m.id_metodo_pago)}
							<label class="metodo" class:elegido={metodoElegido === m.metodo_nombre}>
								<input
									type="radio"
									name="metodo-pago"
									value={m.metodo_nombre}
									disabled={cobrando}
									bind:group={metodoElegido}
								/>
								<span class="datos">
									<strong>{rotulo(m.metodo_nombre)}</strong>
									{#if AYUDA[m.metodo_nombre]}
										<span class="menor">{AYUDA[m.metodo_nombre]}</span>
									{/if}
								</span>
							</label>
						{/each}
					</div>
				{/if}
			</section>

			<!-- ---------------------------------------------------- la tarjeta -->
			{#if esTarjeta}
				<section class="bloque">
					<h3>Los datos de la tarjeta</h3>

					<div class="campos">
						<label class="ancho">
							Numero
							<input
								type="text"
								inputmode="numeric"
								autocomplete="cc-number"
								placeholder="4242 4242 4242 4242"
								value={numero}
								disabled={cobrando}
								oninput={alEscribirNumero}
							/>
						</label>

						<label>
							Vencimiento
							<input
								type="text"
								inputmode="numeric"
								autocomplete="cc-exp"
								placeholder="MM/AA"
								value={vencimiento}
								disabled={cobrando}
								oninput={alEscribirVencimiento}
							/>
						</label>

						<label>
							CVV
							<input
								type="text"
								inputmode="numeric"
								autocomplete="cc-csc"
								placeholder="123"
								value={cvv}
								disabled={cobrando}
								oninput={alEscribirCvv}
							/>
						</label>

						<label class="ancho">
							Titular
							<input
								type="text"
								autocomplete="cc-name"
								placeholder="Como aparece en la tarjeta"
								bind:value={titular}
								disabled={cobrando}
							/>
						</label>
					</div>

					{#if errorTarjeta}
						<p class="malo" role="alert">{errorTarjeta}</p>
					{/if}

					<!-- Esto es un proyecto academico y quien lo revise necesita saber
					     que el cobro es de mentira y con que numero probarlo. Va
					     discreto, no escondido. -->
					<p class="menor nota">
						El cobro es simulado: no se cobra nada y la tarjeta no se guarda en ninguna
						tabla. Para probar sirve <code>4242 4242 4242 4242</code> con cualquier
						vencimiento futuro y cualquier CVV.
					</p>
				</section>
			{/if}

			<!-- --------------------------------------------- precios cambiados -->
			{#if avisos.length > 0}
				<section class="bloque aviso" role="status">
					<h3>Hay precios que cambiaron</h3>
					<!--
						El texto cambia con el modo porque LO QUE PASA es distinto, y
						decirlo igual en los dos seria mentir en uno.

						En modo pedido el precio SI esta congelado: se cobra el que se
						guardo al agregar la linea, y el de hoy es solo informacion.

						En modo carrito NO hay nada congelado todavia: se cobra el de
						HOY, que es justo el problema que el pendiente 1 arregla. Aqui
						la pantalla enseno un numero y el cobro va a ser otro, asi que
						el aviso tiene que decir cual de los dos manda.
					-->
					{#if modo === 'carrito'}
						<p class="menor">
							Todavia no se compro nada. El precio cambio desde que abriste esta
							pantalla, y en el carrito NO se congela: si sigues, se te cobra el
							precio de hoy.
						</p>
					{:else}
						<p class="menor">
							Todavia no se compro nada. Estas lineas valen hoy otra cosa, pero se te
							cobra el precio congelado:
						</p>
					{/if}

					<div class="rodillo">
						<table>
							<thead>
								<tr>
									<th scope="col">Linea</th>
									<!--
										En modo carrito las dos columnas significan lo contrario
										que en modo pedido, y por eso cambian de nombre. Alla la
										primera es la que se cobra; aqui la que se cobra es la
										segunda, la de hoy. Dejarlas con el mismo encabezado
										haria que la tabla dijera exactamente al reves de lo que
										va a pasar.
									-->
									<th scope="col">{modo === 'carrito' ? 'Lo que viste' : 'Se te cobra'}</th>
									<th scope="col">{modo === 'carrito' ? 'Se te cobra hoy' : 'Precio de hoy'}</th>
								</tr>
							</thead>
							<tbody>
								{#each avisos as a (a.id_pedido_producto)}
									<tr>
										<td>
											{a.nombre_producto}
											<span class="menor">{a.nombre_variante}</span>
										</td>
										<td class="congelado">{quetzales(Number(a.precio_congelado))}</td>
										<td class="hoy">{quetzales(Number(a.precio_actual))}</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				</section>
			{/if}

			<!-- ------------------------------------------------ cobro rechazado -->
			{#if rechazo}
				<p class="malo" role="alert">
					{rechazo} Puedes intentarlo con otra tarjeta: el pedido sigue como estaba.
				</p>
			{/if}

			<!-- --------------------------------------------- la oferta ya no esta -->
			{#if bloqueo}
				<!-- Sin boton de "seguir igual", y no por descuido: ningun 409 de
				     esta ruta lo salta una bandera. La unica salida es volver al
				     carrito.

				     El texto de abajo no nombra ninguna causa: un 409 aqui puede ser
				     la oferta pausada, el stock corto, el pedido ya comprado o un
				     metodo de pago que ya no existe (los cinco estan en
				     endpoints-compradores.md). Decir "quita la linea" cuando el
				     pedido ya estaba comprado seria mandar a arreglar algo que no
				     esta roto. El motivo exacto ya lo dice el backend arriba. -->
				<div class="malo" role="alert">
					<p>{bloqueo}</p>
					<p class="menor">
						Esto no se salta confirmando: vuelve al carrito, revisa lo que llevas y
						vuelve a intentarlo.
					</p>
				</div>
			{/if}

			{#if error}
				<p class="malo" role="alert">{error}</p>
			{/if}

			<!-- --------------------------------------------------------- botones -->
			<!-- La direccion otra vez, pegada al boton que cobra: arriba se pudo
			     leer hace tres pantallas de scroll, y lo que importa es que se lea
			     en el momento de pagar. -->
			<!--
				`direccionPedido` es la del PEDIDO, y en modo carrito no hay pedido:
				es null siempre. Preguntando solo por ella, este pie enseñaba el
				aviso rojo "no se sabe a donde se entrega" con la direccion marcada
				ahi arriba, en la misma pantalla. Decia que faltaba algo que no
				faltaba, justo al lado del boton de pagar.
			-->
			{#if entregaFinal}
				<p class="entrega-pie">
					Se entrega en <strong>{direccionEnUnaLinea(entregaFinal)}</strong>
				</p>
			{:else if !cargandoEntrega}
				<p class="malo" role="alert">
					No se sabe a donde se entrega este pedido, asi que no se puede pagar
					todavia. Revisa la direccion de entrega alla arriba.
				</p>
			{/if}

			<footer class="pie">
				<button type="button" onclick={intentarCerrar} disabled={cobrando}>
					{bloqueo ? 'Volver al carrito' : 'Cancelar'}
				</button>

				{#if bloqueo === ''}
					<!-- El mismo boton con los avisos en pantalla repite la peticion
					     con confirmar_cambios: es la misma compra, no otra. -->
					<button
						type="button"
						class="principal"
						disabled={!sePuedeConfirmar}
						onclick={() => confirmar(avisos.length > 0)}
					>
						{#if cobrando}
							Cobrando...
						{:else if avisos.length > 0}
							Comprar de todas formas
						{:else}
							Pagar {quetzales(total)}
						{/if}
					</button>
				{/if}
			</footer>
		</div>
	</div>
{/if}

<style>
	.capa {
		position: fixed;
		inset: 0;
		/* Por encima del carrito, que usa 60 para su velo y 61 para el panel: si
		   esta ventana se monta como hermana suya (y no dentro), con 60 saldria
		   por DEBAJO del panel y solo se veria a medias. */
		z-index: 70;
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 1.25rem;
	}

	/*
	 * El velo se hace con las variables del tema y no con un negro fijo, y por
	 * eso son dos reglas: en el tema claro la que oscurece es --tinta, y en el
	 * oscuro --tinta es casi blanca -- usarla ahi encenderia la pantalla en vez
	 * de apagarla. El que es oscuro en el tema oscuro es --off.
	 */
	.fondo {
		position: absolute;
		inset: 0;
		width: 100%;
		border: 0;
		padding: 0;
		cursor: pointer;
		background: color-mix(in srgb, var(--tinta) 45%, transparent);
	}

	:global(html[data-tema='oscuro']) .fondo {
		background: color-mix(in srgb, var(--off) 80%, transparent);
	}

	.fondo:disabled {
		cursor: default;
	}

	.caja {
		position: relative;
		width: 100%;
		max-width: 520px;
		max-height: 90vh;
		overflow-y: auto;
		padding: 1.35rem 1.5rem 1.5rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.cabeza {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: var(--e4);
		padding-bottom: 0.9rem;
		border-bottom: 1px solid var(--linea);
	}

	h2 {
		font-size: var(--f-xl);
	}

	h3 {
		font-size: var(--f-base);
		font-weight: 600;
		color: var(--tinta);
		margin-bottom: 0.6rem;
	}

	.bloque {
		padding-top: 1.1rem;
	}

	.bloque + .bloque {
		border-top: 1px solid var(--linea);
		margin-top: 0.2rem;
	}

	.menor {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.nota {
		margin-top: 0.55rem;
	}

	.nota code {
		background: var(--panel);
		padding: 0 4px;
		border-radius: 4px;
	}

	.quieto {
		padding: 0.75rem 0;
		color: var(--gris);
		font-size: var(--f-ms);
	}

	/* ---------------- a donde se entrega ---------------- */

	/* La direccion puesta va destacada como una tarjeta y no como un parrafo
	   mas: es el dato que hasta ahora no se veia por ningun lado. */
	.actual {
		padding: 0.6rem 0.75rem;
		background: var(--off);
		color: var(--tinta);
		font-weight: 500;
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.eleccion {
		margin-top: 0.7rem;
	}

	.opciones {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
		margin-top: 0.4rem;
	}

	.opcion {
		display: flex;
		align-items: flex-start;
		gap: var(--e2);
		padding: 0.6rem 0.75rem;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	.opcion.elegida {
		border-color: var(--indigo);
		background: var(--indigo-cl);
	}

	.opcion strong {
		font-weight: 500;
		color: var(--tinta);
	}

	/* Un boton de verdad vestido de enlace: abre un formulario en esta misma
	   pantalla, no lleva a ninguna direccion, y un <a href="#"> mentiria. */
	.enlace {
		margin-top: 0.7rem;
		padding: 0;
		background: none;
		border: 0;
		color: var(--indigo);
		font-size: var(--f-sm);
		text-decoration: underline;
	}

	.enlace:hover:not(:disabled) {
		color: var(--indigo-os);
	}

	.reintentar {
		margin-top: 0.6rem;
	}

	.nueva {
		margin-top: 0.8rem;
	}

	.opcional {
		color: var(--gris-2);
	}

	.acciones {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e2);
		margin-top: 0.8rem;
	}

	.malo a {
		color: var(--rojo);
	}

	/* La repeticion de la direccion junto al boton de pagar. */
	.entrega-pie {
		margin-top: 1.2rem;
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.entrega-pie strong {
		color: var(--tinta);
		font-weight: 500;
	}

	/* ---------------- resumen ---------------- */

	.resumen {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
		list-style: none;
	}

	.linea {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: var(--e3);
		padding: 0.6rem 0.75rem;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.datos {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		min-width: 0;
	}

	.linea strong,
	.total strong {
		color: var(--tinta);
	}

	.importe {
		white-space: nowrap;
	}

	.total {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: var(--e2);
		margin-top: 0.8rem;
		padding-top: 0.7rem;
		border-top: 1px solid var(--linea);
	}

	.total strong {
		font-size: var(--f-lg);
	}

	/* ---------------- formas de pago ---------------- */

	.metodos {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
	}

	.metodo {
		display: flex;
		align-items: flex-start;
		gap: var(--e2);
		padding: 0.6rem 0.75rem;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	.metodo.elegido {
		border-color: var(--indigo);
		background: var(--indigo-cl);
	}

	.metodo strong {
		font-weight: 500;
		color: var(--tinta);
	}

	/* ---------------- campos (la tarjeta y la direccion nueva) ---------------- */

	.campos {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e3);
	}

	.campos label {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		flex: 1;
		min-width: 7rem;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.campos label.ancho {
		flex-basis: 100%;
	}

	.campos input {
		padding: 0.5rem 0.6rem;
		background: var(--off);
		color: var(--tinta);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		font: inherit;
		font-size: var(--f-base);
	}

	.campos input:disabled {
		opacity: 0.6;
	}

	/* ---------------- avisos de precio ---------------- */

	.aviso {
		margin-top: 1rem;
		padding: 0.9rem 1rem;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-left: 3px solid var(--indigo);
		border-radius: var(--r2);
	}

	/* La tabla se desplaza dentro de su caja: en un telefono tres columnas de
	   precios no caben, y sin esto la modal entera se iria de ancho. */
	.rodillo {
		overflow-x: auto;
		margin-top: 0.6rem;
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: var(--f-sm);
	}

	th,
	td {
		padding: 0.4rem 0.5rem;
		text-align: left;
		border-bottom: 1px solid var(--linea);
	}

	th {
		font-weight: 600;
		color: var(--gris);
	}

	td .menor {
		display: block;
	}

	/* El congelado es el que se paga, asi que es el que se destaca; el de hoy
	   va apagado para que no se lea como el importe. */
	.congelado {
		color: var(--tinta);
		font-weight: 600;
		white-space: nowrap;
	}

	.hoy {
		color: var(--gris);
		white-space: nowrap;
	}

	/* ---------------- mensajes y botones ---------------- */

	.malo {
		margin-top: 1rem;
		padding: 0.65rem 0.85rem;
		background: var(--panel);
		color: var(--rojo);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
		font-size: var(--f-ms);
	}

	.malo .menor {
		color: var(--rojo);
		margin-top: 0.25rem;
	}

	.pie {
		display: flex;
		justify-content: flex-end;
		gap: var(--e2);
		margin-top: 1.35rem;
		padding-top: 1rem;
		border-top: 1px solid var(--linea);
	}

	button {
		padding: 0.5rem 0.9rem;
		background: var(--blanco);
		color: var(--tinta);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		font: inherit;
		font-size: var(--f-ms);
		cursor: pointer;
		transition: border-color var(--t);
	}

	button:hover:not(:disabled) {
		border-color: var(--indigo);
	}

	button:disabled {
		opacity: 0.55;
		cursor: default;
	}

	.cerrar {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.principal {
		background: var(--indigo);
		color: var(--blanco);
		border-color: var(--indigo);
	}

	.principal:hover:not(:disabled) {
		background: var(--indigo-os);
		border-color: var(--indigo-os);
	}

	@media (max-width: 620px) {
		.capa {
			padding: 0.75rem;
		}

		.caja {
			padding: 1.1rem 1rem 1.25rem;
		}
	}
</style>
