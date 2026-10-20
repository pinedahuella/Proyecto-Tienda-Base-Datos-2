<script lang="ts">
	import { untrack } from 'svelte';
	import { conJson, pedir, type RespuestaApi } from './api';
	import Autocompletar from './Autocompletar.svelte';
	import { textoPorcentaje, tieneDescuento } from './descuento';
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
		crearDireccion,
		direccionEnUnaLinea,
		quetzales,
		subtotal,
		totalPedido,
		traerDirecciones,
		traerMetodosPago,
		type AvisoDePrecio,
		type DatosTarjeta,
		type DireccionUsuario,
		type LineaPedido,
		type MetodoPago,
		type ResultadoCompra
	} from './pedido';

	/**
	 * El paso final: elegir a donde se entrega y como se paga, y cerrar la
	 * compra con POST /carrito/comprar.
	 *
	 * Se pinta como una ventana modal encima de todo, no como otra pagina: lo
	 * que se esta comprando es el carrito, y mandar a la persona a otra ruta la
	 * obligaria a acordarse de lo que habia.
	 *
	 * Desde el 2026-10-17 (carrito-postgres-verdad.md de Jose David) el carrito
	 * es el pedido `pendiente` de la cuenta en PostgreSQL, con una copia rapida
	 * en Redis. La compra lo compra entero en una transaccion: la direccion
	 * viaja EN el cuerpo, porque el carrito no la tiene hasta pagar. Hasta esa
	 * fecha esta pantalla tenia ademas un modo "pedido" que compraba con
	 * POST /comprador/pedidos/:id/comprar; esas rutas ya no existen y el modo
	 * se quito.
	 *
	 * Esta pantalla NO decide el precio. Cada linea del carrito guarda el que
	 * la persona vio al agregarla, y el backend lo compara con el de hoy al
	 * cobrar. Aqui solo se ensena y, si cambio, se avisa.
	 *
	 * Lo unico que hace falta entender de la respuesta de comprar es que tiene
	 * CUATRO finales distintos, y solo uno es "salio mal":
	 *
	 *   ok + comprado:true    compro. Se avisa al padre con alComprado().
	 *   ok + comprado:false   NO compro nada: hay precios que cambiaron y hay
	 *                         que verlos antes. Se repite la MISMA peticion con
	 *                         confirmar_cambios para seguir.
	 *   402                   el cobro simulado se rechazo. Se puede reintentar
	 *                         con otra tarjeta, el carrito sigue intacto.
	 *   409                   la oferta se pauso, no hay unidades, el carrito
	 *                         vencio o no quedo guardado en PostgreSQL. Esto no
	 *                         se salta con ninguna bandera: hay que volver al
	 *                         carrito, asi que aqui no se ofrece "seguir igual".
	 */
	let {
		abierto = false,
		lineas = [],
		alCerrar,
		alComprado,
		alVolverAlCarrito,
		alExpirarSesion
	}: {
		abierto?: boolean;
		/** Solo para pintar el resumen: el backend compra el carrito entero. */
		lineas?: LineaPedido[];
		alCerrar?: () => void;
		alComprado?: (resultado: ResultadoCompra) => void;
		/**
		 * Cierra esta ventana y vuelve a abrir el carrito. Es la salida de un
		 * 409: la linea que hay que quitar o ajustar esta alla, no aqui.
		 */
		alVolverAlCarrito?: () => void;
		alExpirarSesion?: () => void;
	} = $props();

	// ---------------------------------------------------------------- estado
	let metodos = $state<MetodoPago[]>([]);
	let cargandoMetodos = $state(false);
	let errorMetodos = $state('');
	/** El `metodo_nombre`, no el id: es lo que espera el backend al comprar. */
	let metodoElegido = $state('');

	/**
	 * Las direcciones VIVAS del usuario, las que se pueden elegir. La que se
	 * marca viaja en el cuerpo de POST /carrito/comprar, y el backend guarda
	 * esa version en direccion_historial al comprar.
	 */
	let direcciones = $state<DireccionUsuario[]>([]);
	/** El radio marcado: la direccion a la que se entrega. */
	let idElegida = $state('');
	let cargandoEntrega = $state(false);
	/** true solo cuando la lista de direcciones llego de verdad. Ver `sinDirecciones`. */
	let listaLeida = $state(false);
	let errorEntrega = $state('');

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
	/**
	 * El 409 de "tu carrito no quedo guardado del todo": la copia de Redis a
	 * PostgreSQL fallo o choco, y el backend no compra lo que no es verdad. Se
	 * arregla con POST /carrito/sincronizar, y despues hay que REVISAR el
	 * carrito (si mando PostgreSQL, puede no ser lo que se veia). No hay codigo
	 * aparte en la respuesta, asi que se reconoce por su mensaje.
	 */
	let desincronizado = $derived(/sincroniza/i.test(bloqueo));
	let sincronizando = $state(false);
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
	 * NO puede ser `id_pedido_producto`: ese campo llega VACIO en todas las
	 * lineas (ver `aLineasDePedido` en CarritoRedis.svelte), y con dos lineas
	 * las dos claves eran `''`, Svelte reventaba con `each_key_duplicate` y el
	 * checkout entero dejaba de pintarse. `id_oferta` sirve: el carrito guarda
	 * UNA linea por oferta (PUT /carrito/lineas/:idOferta fija la cantidad).
	 * Se prefiere `id_pedido_producto` cuando existe porque es la identidad de
	 * verdad de la fila.
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
	 * Con un 409 en pantalla el boton de confirmar desaparece a proposito: la
	 * unica salida es volver al carrito y quitar o cambiar esa linea.
	 *
	 * Sin direccion elegida tampoco se paga: nadie deberia pagar un envio sin
	 * haber leido a donde va. Mientras se guarda una direccion nueva se
	 * espera: hasta que vuelve, la marcada sigue siendo la de antes.
	 */
	let entregaFinal = $derived(direcciones.find((d) => d.id_direccion === idElegida) ?? null);

	let sePuedeConfirmar = $derived(
		!cobrando &&
			!vacio &&
			bloqueo === '' &&
			metodoElegido !== '' &&
			entregaFinal != null &&
			!sinDirecciones &&
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
	 * Las direcciones de la CUENTA. El carrito no tiene direccion hasta pagar
	 * (045: id_direccion_historial va NULL mientras el pedido es pendiente), asi
	 * que no hay una "del pedido" que preseleccionar: se marca la primera. Con
	 * una sola direccion, el caso normal, eso evita un paso que no decide nada;
	 * con varias, se puede cambiar.
	 */
	async function cargarEntrega() {
		const mia = ++cargaEntrega;

		errorEntrega = '';
		cargandoEntrega = true;
		const rDir = await traerDirecciones();
		// Una carga vieja no escribe nada, ni siquiera apaga el "Cargando...":
		// el de la nueva sigue puesto a proposito.
		if (mia !== cargaEntrega) return;
		cargandoEntrega = false;

		if (expiro(rDir)) return;

		if (rDir.ok && Array.isArray(rDir.payload)) {
			direcciones = rDir.payload;
			listaLeida = true;
			idElegida = direcciones[0]?.id_direccion ?? '';
		} else {
			direcciones = [];
			listaLeida = false;
			idElegida = '';
			errorEntrega = motivo(rDir, 'No se pudieron leer tus direcciones');
		}
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

	function elegirDireccion(idDireccion: string) {
		idElegida = idDireccion;
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
	 * Crea la direccion y ademas la deja marcada para ESTE envio: crearla sola no
	 * cambia a donde se entrega, y quien la escribe aqui la escribe para esta
	 * compra. Es la que viaja despues en el cuerpo de POST /carrito/comprar.
	 */
	async function crearYUsar(evento: SubmitEvent) {
		evento.preventDefault();

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
			// su id no hay con que marcarla. Se dice eso, no el mensaje
			// de exito del backend, y no se cierra el formulario: volver a mandarla
			// crearia una copia.
			errorNueva = motivo(
				r,
				'Se guardo la direccion pero el servidor no dijo cual. Recarga la pagina y elegila en la lista.'
			);
			return;
		}

		const nueva = r.payload;
		direcciones = [nueva, ...direcciones];
		listaLeida = true;
		guardandoDireccion = false;
		idElegida = nueva.id_direccion;
		cerrarNueva();
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
		if (idElegida === '') {
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

		// EL PRECIO QUE SE VIO YA NO VIAJA CON LA COMPRA (cambio del
		// 2026-09-23, commit e7f1e02 del backend).
		//
		// Antes el carrito de Redis guardaba solo `id_oferta -> cantidad`, y
		// para no cobrar un precio distinto del que se enseno, esta pantalla
		// mandaba de vuelta `lineas_precio_visto`. Ahora cada linea del HASH
		// guarda una FOTO con el precio que enseno `GET /carrito` (ya con el
		// descuento, si la oferta tenia), asi que el backend compara esa foto
		// contra el precio de hoy el solo, dentro de la misma peticion que
		// cobra. Aqui no hay nada que acordarse.
		//
		// Si algo no cuadra, el backend no cobra nada y contesta
		// `comprado: false` con los `avisos`. La segunda pulsacion manda
		// `confirmar_cambios: true` y acepta el precio de hoy.
		const r = await pedir<ResultadoCompra>(
			'/carrito/comprar',
			conJson('POST', {
				id_direccion: idElegida,
				metodo_pago: cuerpo.metodo_pago,
				...(cuerpo.tarjeta ? { tarjeta: cuerpo.tarjeta } : {}),
				...(confirmarCambios ? { confirmar_cambios: true } : {})
			})
		);
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
			// El aviso del carrito es { id_oferta, precio_visto, precio_actual }
			// y la tabla pinta AvisoDePrecio, que viene de la compra de un pedido
			// (id_pedido_producto, precio_congelado). Se traduce campo por campo:
			// un `as` compilaria y ensenaria celdas vacias.
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

		if (r.estado === 503) {
			// La compra la escribe una sola base en una transaccion: si no responde,
			// no se cobro nada y el carrito sigue como estaba (medido con
			// pruebas/falla_checkout.sh y en docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md).
			error = 'No pudimos completar la compra ahora. Tu carrito sigue guardado, intenta de nuevo en un momento.';
			return;
		}

		error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
	}

	// ------------------------------------------------------- volver al carrito
	/**
	 * La salida de un 409. Antes solo cerraba esta ventana, y el carrito ya se
	 * habia cerrado al pasar al pago: la persona se quedaba en la ficha sin ver
	 * la linea que tenia que arreglar.
	 */
	function volverAlCarrito() {
		if (cobrando || sincronizando) return;
		if (alVolverAlCarrito) alVolverAlCarrito();
		else alCerrar?.();
	}

	/**
	 * POST /carrito/sincronizar decide quien tiene razon (si a PostgreSQL le
	 * falta la ultima escritura de Redis, la vuelve a copiar; si PostgreSQL es
	 * mas nuevo, Redis se rehace desde ahi) y devuelve el carrito como queda.
	 * Despues se vuelve al carrito a REVISARLO: si mando PostgreSQL, puede no
	 * ser lo que se veia, y cobrarlo de una vez seria cobrar algo no leido.
	 */
	async function guardarYRevisar() {
		sincronizando = true;
		const r = await pedir('/carrito/sincronizar', { method: 'POST' });
		sincronizando = false;

		if (expiro(r)) return;
		if (!r.ok) {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
			return;
		}
		bloqueo = '';
		volverAlCarrito();
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
					{#if entregaFinal}
						<p class="actual">{direccionEnUnaLinea(entregaFinal)}</p>
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
								Agregala aqui abajo, o desde <a href="/panel?s=cuenta">tu perfil</a>.
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
							disabled={guardandoDireccion}
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
										disabled={cobrando || guardandoDireccion}
										onchange={() => elegirDireccion(d.id_direccion)}
									/>
									<span class="datos">
										<strong>{direccionEnUnaLinea(d)}</strong>
									</span>
								</label>
							{/each}
						</div>
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
							disabled={cobrando}
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
										{#if tieneDescuento(l.porcentaje_descuento_aplicado)}
											<span class="descuento">-{textoPorcentaje(l.porcentaje_descuento_aplicado)}</span>
										{/if}
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
					     ficha del producto. Cada linea guarda el precio que se vio al
					     agregarla; al pagar, el backend lo compara con el de hoy y,
					     si cambio, responde `comprado:false` con avisos y solo cobra
					     el nuevo cuando la persona confirma. Es la misma frase que en
					     CarritoRedis. -->
					<p class="menor nota">
						Ves el precio de cuando agregaste cada producto. Si cambia antes de
						pagar, te avisamos antes de cobrar.
					</p>
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
					<!-- Lo que se vio al agregar no obliga a nadie: si sigues, se cobra el
					     precio de HOY. La pantalla enseno un numero y el cobro va a ser
					     otro, asi que el aviso tiene que decir cual de los dos manda. -->
					<p class="menor">
						Todavia no se compro nada. El precio cambio desde que lo agregaste: si
						sigues, se te cobra el precio de hoy.
					</p>

					<div class="rodillo">
						<table>
							<thead>
								<tr>
									<th scope="col">Linea</th>
									<th scope="col">Lo que viste</th>
									<th scope="col">Se te cobra hoy</th>
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
					{#if desincronizado}
						<!-- El mensaje del backend nombra la ruta; a la persona le basta
						     saber que paso y que hacer. -->
						<p>Tu carrito no quedo guardado del todo y no se cobro nada.</p>
						<p class="menor">Guardalo y revisalo antes de pagar.</p>
						<button
							type="button"
							class="reintentar"
							disabled={sincronizando}
							onclick={guardarYRevisar}
						>
							{sincronizando ? 'Guardando...' : 'Guardar y revisar el carrito'}
						</button>
					{:else}
						<p>{bloqueo}</p>
						<p class="menor">
							Esto no se salta confirmando: vuelve al carrito, revisa lo que llevas y
							vuelve a intentarlo.
						</p>
					{/if}
				</div>
			{/if}

			{#if error}
				<p class="malo" role="alert">{error}</p>
			{/if}

			<!-- --------------------------------------------------------- botones -->
			<!-- La direccion otra vez, pegada al boton que cobra: arriba se pudo
			     leer hace tres pantallas de scroll, y lo que importa es que se lea
			     en el momento de pagar. -->
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
				<button
					type="button"
					onclick={bloqueo ? volverAlCarrito : intentarCerrar}
					disabled={cobrando || sincronizando}
				>
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
	/* El % de descuento de una linea. Colores del layout. */
	.descuento {
		margin-left: 4px;
		padding: 0.1rem 0.4rem;
		font-size: var(--f-xs);
		font-weight: 600;
		border-radius: 999px;
		color: var(--descuento-tinta);
		background: var(--descuento-fondo);
		border: 1px solid var(--descuento-linea);
	}

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
