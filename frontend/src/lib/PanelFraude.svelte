<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';

	/**
	 * Panel de manipulacion de resenas. Es una pantalla que pide el enunciado
	 * de la Entrega 2, textual:
	 *
	 *   "Panel, visible para el equipo administrativo, que senale patrones de
	 *    posible manipulacion de resenas -- por ejemplo, conjuntos de cuentas
	 *    que se califican entre si de forma reiterada sobre los mismos
	 *    productos"
	 *
	 * Lo que ensena NO se calcula aqui ni en PostgreSQL: sale del grafo de
	 * Neo4j, que es la familia que el equipo eligio implementar. Las consultas
	 * viven en neo4j/consultas/A1_anillo.cypher .. A5_puntaje.cypher y el
	 * backend las expone ya resueltas.
	 *
	 *
	 * LA RUTA -- conectada desde el 2026-08-30
	 * ---------------------------------------------------------------
	 *   GET /admin/fraude/anillos     (solo admin; la tienda recibe 403)
	 *
	 * El backend es de Jose David y aqui no se toca. El contrato quedo igual
	 * al que este componente ya esperaba -- se comprobo campo por campo contra
	 * `backend/src/models/fraude.ts` -- asi que las interfaces de abajo son
	 * las suyas y no una copia que se pueda desfasar en silencio.
	 *
	 * La ruta NO devuelve 404 nunca. Los codigos que si contesta son
	 * 401 (sesion), 403 (no sos admin), 503 (Neo4j caido o el analisis paso de
	 * 15 s) y 500. Por eso ya no hay un estado "todavia no conectado": seria
	 * codigo que describe un mundo que dejo de existir.
	 *
	 *
	 * LOS DOS VACIOS, QUE NO SON EL MISMO
	 * ---------------------------------------------------------------
	 * Esto es lo mas facil de hacer mal en esta pantalla, y son DOS casos que
	 * llegan identicos: `anillos: []` y un 200.
	 *
	 * 1. **Se analizo y no habia nada.** La consulta corrio perfecta y devolvio
	 *    CERO. Una pantalla que ante eso dice "no hay datos" hace pensar que
	 *    esta rota, asi que aqui se dice cuantas cuentas y cuantas resenas se
	 *    ANALIZARON para llegar a ese cero. Un cero con denominador es un
	 *    resultado; un cero solo es una duda.
	 *
	 *    Con el conjunto sembrado esto ya NO deberia pasar: desde el 2026-08-30
	 *    la semilla trae un anillo de verdad -- tres cuentas `anillo.*@mesh.com`
	 *    que se compran entre si para poder calificarse en circulo -- y la ruta
	 *    devuelve tres grupos (`ciclo`, `reiterado` y `direccion`). Si esta
	 *    pantalla sale vacia contra la semilla, algo se rompio: mira el grafo.
	 *
	 *    Aqui ya no hay datos de ejemplo. Los hubo mientras la ruta no existia,
	 *    y se quitaron el dia que hubo un anillo real: una pantalla de fraude
	 *    con nombres inventados adentro es la ultima que uno quiere ensenar.
	 *
	 * 2. **No se analizo nada, porque el grafo esta vacio.** Si nadie corrio
	 *    `etl/cargar_grafo.sh`, la ruta contesta 200 con `analizado` en CEROS.
	 *    Ensenar "se recorrieron 0 cuentas y 0 resenas sin encontrar nada" es
	 *    presentar una auditoria que no ocurrio como si fuera una auditoria
	 *    limpia. Es la peor de las dos mentiras posibles aqui, porque tiene
	 *    forma de buena noticia. Se detecta con `analizado.cuentas === 0` y se
	 *    dice lo que hay que hacer para arreglarlo.
	 *
	 *
	 * LA SEGUNDA SECCION -- intentos de entrada sospechosos (2026-09-10)
	 * ---------------------------------------------------------------
	 *   GET /admin/fraude/alertas-login?pagina=&limite=&estado=
	 *
	 * Otra fuente y otro mecanismo: no sale del grafo sino de la tabla
	 * `alerta_fraude` de PostgreSQL, que llenan unos contadores de Redis en el
	 * propio login. Va debajo, con su propio titulo y su propia carga. Ver el
	 * bloque "intentos de entrada" mas abajo.
	 */

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	/** Una cuenta dentro de un grupo sospechoso. */
	interface CuentaSenalada {
		id_usuario: number;
		usuario: string;
		correo_electronico: string;
		nombre: string;
		apellido: string;
	}

	/** Una resena concreta que forma parte del patron. */
	interface ResenaSenalada {
		id_resena: number;
		autor: string;
		vendedor: string;
		producto: string;
		calificacion: number;
		fecha: string;
	}

	/**
	 * Un grupo de cuentas con un patron anomalo.
	 *
	 * `tipo` dice QUE forma tiene el patron, y no es cosmetico: cada forma se
	 * detecta con una consulta distinta y significa una cosa distinta. Se
	 * guarda para poder explicarle a quien mira POR QUE esas cuentas estan
	 * juntas en la lista, en vez de darle una lista de nombres sin motivo.
	 */
	interface Anillo {
		id: string;
		tipo: 'ciclo' | 'mutuo' | 'reiterado' | 'direccion';
		/** Cuantos saltos tiene el camino que las une. Es el dato que hace que esto sea un grafo y no una tabla. */
		saltos: number;
		cuentas: CuentaSenalada[];
		productos: { id_producto: number; nombre: string }[];
		resenas: ResenaSenalada[];
		/** Frases cortas, ya redactadas por el backend, que explican la sospecha. */
		senales: string[];
	}

	interface RespuestaFraude {
		anillos: Anillo[];
		/** El denominador. Sin esto, un cero no se puede interpretar. */
		analizado: {
			cuentas: number;
			resenas: number;
			relaciones: number;
		};
	}

	const NOMBRE_TIPO: Record<Anillo['tipo'], string> = {
		ciclo: 'Ciclo de calificaciones',
		mutuo: 'Se califican entre si',
		reiterado: 'Reiteracion sobre los mismos productos',
		direccion: 'Cuentas que comparten direccion'
	};

	const EXPLICACION_TIPO: Record<Anillo['tipo'], string> = {
		ciclo: 'A califica a B, B a C y C vuelve a A. Un comprador normal no recibe de vuelta la calificacion que da: el camino se cierra solo cuando las cuentas se estan sosteniendo entre ellas.',
		mutuo: 'Las dos cuentas se calificaron la una a la otra. Puede ser legitimo una vez; deja de serlo cuando se repite.',
		reiterado:
			'Las mismas cuentas se califican una y otra vez sobre los mismos productos. Es la frase exacta del enunciado, y es la senal mas dificil de producir por casualidad.',
		direccion:
			'Cuentas distintas registradas en la misma direccion normalizada. Por si solo no prueba nada -- una familia comparte casa -- pero junto con calificaciones cruzadas deja de ser coincidencia.'
	};

	/**
	 * Lo que devuelve `GET /admin/grafo/conciliacion`, del que aqui solo se usa
	 * lo justo para poder decir si este analisis mira datos frescos.
	 *
	 * `cuadra` sale de CUATRO recursos, no de los seis: los conteos de
	 * productos y usuarios NO cuentan para el veredicto, porque el ETL completo
	 * carga todas las cuentas y no solo las que aparecen en una resena, y el
	 * worker incremental puede dejar nodos sueltos. Una diferencia ahi es
	 * normal y no significa que falte nada.
	 */
	interface Conciliacion {
		cuadra: boolean;
		ultima_sincronizacion: string | null;
		cola: { pendientes: number; apartados: number } | null;
		sugerencia: string | null;
	}

	let anillos = $state<Anillo[]>([]);
	let analizado = $state<RespuestaFraude['analizado'] | null>(null);

	/**
	 * El estado de la sincronizacion del grafo. `null` mientras no llega o si
	 * la ruta fallo.
	 *
	 * Existe por una razon concreta que este documento repitio durante dias:
	 * el grafo se actualiza por una cola y el panel **enseñaba un analisis
	 * correcto sobre datos incompletos sin decirlo**. Un panel que falla se
	 * arregla; uno que calla se cree. Ahora lo dice.
	 */
	let conciliacion = $state<Conciliacion | null>(null);

	let cargando = $state(true);
	let error = $state('');
	/**
	 * El grafo esta vacio: la ruta contesto bien pero no habia nada que
	 * recorrer. Es un estado propio y no un resultado -- ver la nota de arriba.
	 */
	let grafoVacio = $derived(
		anillos.length === 0 && analizado !== null && analizado.cuentas === 0
	);

	/** Que tarjeta esta desplegada. Una a la vez: son largas. */
	let abierta = $state<string | null>(null);

	// onMount y no $effect: esto corre UNA vez al montar el panel. Con $effect
	// se repite solo -- en este mismo proyecto se vieron seis llamadas en el
	// mismo instante con un console.trace.
	//
	// Las dos secciones salen a la vez y ninguna espera a la otra. El analisis
	// del grafo tarda unos 8 s y las alertas de entrada contestan en menos de
	// medio segundo: encadenarlas dejaria las alertas esperando por nada.
	onMount(() => {
		void cargar();
		void cargarAlertas(1);
	});

	async function cargar() {
		cargando = true;
		error = '';

		const respuesta = await pedir<RespuestaFraude>('/admin/fraude/anillos');

		cargando = false;

		if (respuesta.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!respuesta.ok || !respuesta.payload) {
			// mensajeUtil y no `respuesta.mensaje` a secas. Si el cuerpo no trae
			// `mensaje` -- un 500 que no salio del controlador, un proxy en el
			// medio -- `error` quedaba en undefined, que es FALSY, y la pantalla
			// se caia en la rama del vacio: ensenaba "no se encontro ningun
			// patron anomalo" habiendo fallado. Un fallo disfrazado de auditoria
			// limpia es exactamente lo que este panel no puede hacer.
			error = mensajeUtil(respuesta);
			anillos = [];
			analizado = null;
			return;
		}

		anillos = respuesta.payload.anillos ?? [];
		analizado = respuesta.payload.analizado ?? null;

		void cargarConciliacion();
	}

	/**
	 * Si el grafo que se acaba de analizar esta al dia con PostgreSQL.
	 *
	 * Va en una peticion APARTE y despues, no antes, y no se espera con await:
	 * es informacion SOBRE el analisis, no parte de el. Si esta ruta falla o
	 * tarda, el panel tiene que ensenar sus anillos igual -- bloquear el
	 * analisis por no poder decir si esta fresco seria cambiar un problema
	 * chico por uno grande.
	 *
	 * Y por eso un fallo aqui deja `conciliacion` en null y no pinta nada, en
	 * vez de pintar un aviso de error: "no se pudo comprobar si esta al dia" al
	 * lado de un analisis correcto asusta mas de lo que informa.
	 */
	async function cargarConciliacion() {
		conciliacion = null;
		const r = await pedir<Conciliacion>('/admin/grafo/conciliacion');
		if (r.ok && r.payload) conciliacion = r.payload;
	}

	/**
	 * "hace 3 minutos", para la ultima sincronizacion.
	 *
	 * Un reloj absoluto no contesta la pregunta que se hace aqui, que es "esto
	 * que estoy viendo, de cuando es". Nadie resta horas de cabeza mirando un
	 * panel de fraude.
	 */
	function hace(iso: string | null): string {
		if (!iso) return 'nunca';
		const ms = Date.now() - new Date(iso).getTime();
		if (Number.isNaN(ms)) return 'nunca';
		const min = Math.floor(ms / 60000);
		if (min < 1) return 'hace menos de un minuto';
		if (min < 60) return `hace ${min} ${min === 1 ? 'minuto' : 'minutos'}`;
		const h = Math.floor(min / 60);
		if (h < 24) return `hace ${h} ${h === 1 ? 'hora' : 'horas'}`;
		const d = Math.floor(h / 24);
		return `hace ${d} ${d === 1 ? 'dia' : 'dias'}`;
	}

	function alternar(id: string) {
		abierta = abierta === id ? null : id;
	}

	/**
	 * La fecha de una resena, para leerse.
	 *
	 * Se blinda porque es el unico campo del payload que el backend manda tal
	 * como sale del grafo, sin valor de respaldo. `new Date(null)` no lanza:
	 * devuelve una fecha invalida que se pinta como "Invalid Date" en medio de
	 * la tabla. Un guion dice lo mismo sin ensuciar.
	 */
	function fecha(valor: string): string {
		if (!valor) return '--';
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '--';
		return d.toLocaleString('es-GT', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}

	function nombreCompleto(c: CuentaSenalada): string {
		return [c.nombre, c.apellido].filter(Boolean).join(' ') || c.usuario;
	}

	// ------------------------------------------------ intentos de entrada
	/**
	 * Las alertas que deja `FraudeLoginService` del backend cuando un contador
	 * de Redis cruza su umbral en el propio login. Tres senales y nada mas:
	 *
	 *   fuerza_bruta_ip       muchos fallos desde una misma IP
	 *   fuerza_bruta_cuenta   muchos fallos contra un mismo identificador
	 *   multi_cuenta_ip       muchos identificadores distintos desde una IP,
	 *                         salieran bien o mal
	 *
	 * Ojo con el tercero, que su propio campo engana: `cuentas_distintas` NO
	 * cuenta cuentas. `revisarMultiCuentaIp` hace SADD de lo que se tecleo en
	 * TODO intento, el bueno incluido, y el texto no tiene por que ser de una
	 * cuenta que exista. Por eso en pantalla se habla de correos o usuarios
	 * tecleados y se avisa que las entradas buenas tambien cuentan: si no, el
	 * equipo entrando bien como admin, tienda y dos vendedores desde la misma
	 * maquina se lee como un ataque que probo cuatro cuentas.
	 *
	 * Los tipos de abajo son copia de `backend/src/models/alerta-fraude.ts`
	 * (`AlertaFraude`) y de `dto/paginar-alertas-fraude.ts`, con las fechas
	 * como texto porque asi llegan por JSON.
	 *
	 * Lo que esta seccion NO hace, a proposito: marcar una alerta como
	 * revisada o descartada. Esa ruta no existe todavia, y un boton que llama a
	 * una ruta que no existe es un error que la pantalla provoca sola. El
	 * filtro por estado si esta, porque la ruta ya lo acepta.
	 */
	type TipoAlerta = 'fuerza_bruta_ip' | 'fuerza_bruta_cuenta' | 'multi_cuenta_ip';
	type EstadoAlerta = 'pendiente' | 'revisada' | 'descartada';
	type FiltroAlerta = 'todas' | EstadoAlerta;

	interface AlertaLogin {
		id_alerta_fraude: string;
		tipo_alerta: TipoAlerta;
		/** La IP en los dos tipos de IP; el identificador intentado en fuerza_bruta_cuenta. */
		clave: string;
		/** Solo en fuerza_bruta_cuenta, y solo si el identificador es de una cuenta real. */
		cuenta_involucrada: { id_usuario: string; usuario: string } | null;
		/**
		 * La evidencia, distinta por tipo: `fallos` y `ventana_segundos` en los
		 * de fuerza bruta; `cuentas_distintas`, `ventana_segundos` e
		 * `identificadores` (hasta 20) en multi_cuenta_ip. Es un jsonb sin
		 * esquema, asi que cada campo se lee blindado.
		 */
		detalle: Record<string, unknown>;
		/** Cuantas veces se cruzo el umbral dentro del mismo minuto. Nace en 1. */
		contador: number;
		/** El minuto, truncado, en que se detecto. */
		ventana_inicio: string;
		estado: EstadoAlerta;
		fecha_creacion: string;
		fecha_actualizacion: string;
	}

	interface AlertasPaginadas {
		alertas: AlertaLogin[];
		pagina: number;
		limite: number;
		total_alertas: number;
		total_paginas: number;
	}

	const QUE_PASO: Record<TipoAlerta, string> = {
		fuerza_bruta_ip: 'Muchos intentos fallidos desde una IP',
		fuerza_bruta_cuenta: 'Muchos intentos fallidos contra una cuenta',
		multi_cuenta_ip: 'Muchos correos o usuarios distintos desde una IP'
	};

	const FILTROS: FiltroAlerta[] = ['todas', 'pendiente', 'revisada', 'descartada'];

	const NOMBRE_FILTRO: Record<FiltroAlerta, string> = {
		todas: 'Todas',
		pendiente: 'Pendientes',
		revisada: 'Revisadas',
		descartada: 'Descartadas'
	};

	const NOMBRE_ESTADO: Record<EstadoAlerta, string> = {
		pendiente: 'Pendiente',
		revisada: 'Revisada',
		descartada: 'Descartada'
	};

	/** Cuantas por pagina. El mismo 20 que el resto de las listas del panel. */
	const POR_PAGINA = 20;

	let alertas = $state<AlertaLogin[]>([]);
	let filtroAlertas = $state<FiltroAlerta>('todas');
	let paginaAlertas = $state(1);
	let totalPaginasAlertas = $state(0);
	let totalAlertas = $state(0);
	/**
	 * El filtro de las alertas que SE ESTAN VIENDO, que no siempre es el
	 * elegido: entre el clic y la respuesta, la lista y el total siguen siendo
	 * los del filtro anterior. La etiqueta y el vacio leen este, o dirian
	 * "12 pendientes" con el total de "todas".
	 */
	let filtroVisto = $state<FiltroAlerta>('todas');
	let cargandoAlertas = $state(true);
	let errorAlertas = $state('');

	/**
	 * El numero del ultimo pedido de alertas. No es $state a proposito: nadie
	 * lo pinta.
	 *
	 * Hace falta porque las paginas y el filtro se pueden pulsar mas rapido de
	 * lo que contesta el servidor, y las respuestas no tienen por que volver en
	 * orden. Sin esto, la respuesta vieja que llega tarde pisa a la nueva y la
	 * lista dice "Pendientes" ensenando las de otro filtro.
	 */
	let pedidoAlertas = 0;

	/** Si en la pagina hay alguna IP local, para ensenar la linea que lo explica. */
	let hayLocales = $derived(alertas.some((a) => origenEsIp(a) && esLocal(a.clave)));

	async function cargarAlertas(pagina: number) {
		const este = ++pedidoAlertas;
		// La pagina se fija ANTES de pedirla: si falla, "Reintentar" vuelve a
		// pedir la que se quiso ver y no la anterior.
		paginaAlertas = pagina;
		cargandoAlertas = true;
		errorAlertas = '';

		const partes = [`pagina=${pagina}`, `limite=${POR_PAGINA}`];
		if (filtroAlertas !== 'todas') partes.push(`estado=${filtroAlertas}`);

		const r = await pedir<AlertasPaginadas>(`/admin/fraude/alertas-login?${partes.join('&')}`);

		if (este !== pedidoAlertas) return;
		cargandoAlertas = false;

		// 401 y nada mas, igual que los anillos. Un 500 o un 503 son del
		// servidor y la sesion puede seguir buena.
		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			// mensajeUtil, por lo mismo que en `cargar`: un fallo sin `mensaje`
			// dejaria el error vacio y la pantalla caeria en la rama del vacio,
			// diciendo "ningun intento" habiendo fallado.
			errorAlertas = mensajeUtil(r);
			alertas = [];
			return;
		}

		const p = r.payload;
		const lista = p.alertas ?? [];

		// Una pagina que ya no existe. La ruta no falla: contesta vacio con el
		// total real. Pasa si entre dos clics se borraron alertas, y ensenar
		// "no hay" teniendo unas cuantas en la pagina anterior seria mentir.
		if (lista.length === 0 && p.total_paginas > 0 && pagina > p.total_paginas) {
			void cargarAlertas(p.total_paginas);
			return;
		}

		alertas = lista;
		filtroVisto = filtroAlertas;
		paginaAlertas = p.pagina;
		totalPaginasAlertas = p.total_paginas;
		totalAlertas = p.total_alertas;
	}

	/** Cambiar de filtro vuelve a la pagina 1: la 3 de "todas" no es la 3 de "pendientes". */
	function cambiarFiltro(f: FiltroAlerta) {
		if (f === filtroAlertas) return;
		filtroAlertas = f;
		void cargarAlertas(1);
	}

	/** La clave es una IP en dos de los tres tipos; en el otro es un correo o un usuario. */
	function origenEsIp(a: AlertaLogin): boolean {
		return a.tipo_alerta !== 'fuerza_bruta_cuenta';
	}

	/**
	 * La propia maquina. Mismo criterio y mismas tres escrituras que en
	 * PanelTendencias: una IPv4 puede volver envuelta en IPv6.
	 *
	 * Importa mas aqui que alla. En desarrollo el navegador, los arneses de
	 * pruebas/ y el servidor corren en la misma maquina, y `api.ts` le habla
	 * directo a localhost:3000, sin proxy en el medio. Asi que 127.0.0.1 no es
	 * una IP mal leida: ES la IP real de todo el que prueba. Quien entre con
	 * cuatro cuentas seguidas en desarrollo es, para el contador, alguien
	 * probando cuatro cuentas. Sin la marca, la primera alerta que sale en esta
	 * lista es el propio equipo, con cara de ataque.
	 */
	function esLocal(ip: string): boolean {
		return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
	}

	/**
	 * Un entero del `detalle`, o null. Es un jsonb sin esquema: un campo que
	 * falta daria "undefined intentos" en pantalla.
	 */
	function entero(valor: unknown): number | null {
		const n = Number(valor);
		return valor != null && Number.isFinite(n) ? n : null;
	}

	/** 60 -> "1 minuto", 300 -> "5 minutos", 45 -> "45 segundos". */
	function duracion(segundos: unknown): string {
		const n = entero(segundos);
		if (n === null || n <= 0) return '';
		if (n % 60 === 0) {
			const m = n / 60;
			return `${m} ${m === 1 ? 'minuto' : 'minutos'}`;
		}
		return `${n} segundos`;
	}

	/**
	 * Lo que se midio, en una frase. Se arma aqui y no en la plantilla por lo
	 * mismo que la linea de sincronizacion: un {#if} en medio de una frase deja
	 * espacios sueltos antes del punto.
	 */
	function evidencia(a: AlertaLogin): string {
		const d = a.detalle ?? {};
		const ventana = duracion(d.ventana_segundos);
		const cola = ventana ? ` en ${ventana}` : '';

		if (a.tipo_alerta === 'multi_cuenta_ip') {
			const n = entero(d.cuentas_distintas);
			if (n === null) return '--';
			return `${n} ${n === 1 ? 'correo o usuario distinto' : 'correos o usuarios distintos'}${cola}`;
		}

		const f = entero(d.fallos);
		if (f === null) return '--';
		return `${f} ${f === 1 ? 'intento fallido' : 'intentos fallidos'}${cola}`;
	}

	/**
	 * Los identificadores que vio multi_cuenta_ip. El backend guarda hasta 20.
	 * Un null se vuelve texto vacio y no la palabra "null", que en esta lista
	 * pareceria alguien que tecleo "null".
	 */
	function identificadores(a: AlertaLogin): string[] {
		const lista = a.detalle?.identificadores;
		return Array.isArray(lista) ? lista.map((x) => (x == null ? '' : String(x))) : [];
	}

	/** Hasta donde se pinta un texto tecleado antes de cortarlo. */
	const LARGO_VISIBLE = 80;
	/** Y hasta donde llega el title que lo ensena entero. */
	const LARGO_TITULO = 1000;

	/**
	 * Un texto que tecleo quien intento entrar: la clave de fuerza_bruta_cuenta
	 * y cada identificador de multi_cuenta_ip. No lo escribe el sistema, lo
	 * escribe cualquiera, asi que se pinta blindado por dos lados:
	 *
	 *   - Vacio. La validacion del login rechaza un identificador vacio, pero
	 *     el controlador lo pasa igual a los contadores (es texto, no null), y
	 *     un '' o unos espacios salian como una casilla en blanco. Se dice
	 *     "(vacio)", que es lo que paso.
	 *   - Largo. El cuerpo del login admite hasta 1 MB y el backend no recorta
	 *     el identificador: veinte de esos entran enteros al jsonb y la tarjeta
	 *     los pintaba enteros. Se corta a LARGO_VISIBLE y lo completo va en el
	 *     title. El title tambien tiene tope, porque un tooltip de un mega no se
	 *     puede leer y si pesa en la pagina.
	 *
	 * Se corta por unidades de UTF-16 y no con Array.from: partir en letras un
	 * texto de un mega para quedarse con 80 es gastar por nada. Solo se cuida
	 * no dejar medio emoji suelto al final del corte.
	 *
	 * Nada de {@html}: Svelte ya escapa el texto, y aqui eso es justo lo que
	 * se quiere.
	 */
	function tecleado(valor: unknown): { texto: string; titulo: string | undefined } {
		const crudo = valor == null ? '' : String(valor);
		if (crudo.trim() === '') return { texto: '(vacio)', titulo: undefined };
		if (crudo.length <= LARGO_VISIBLE) return { texto: crudo, titulo: undefined };
		return { texto: cortar(crudo, LARGO_VISIBLE), titulo: cortar(crudo, LARGO_TITULO) };
	}

	/** Corta a `largo` y agrega "...", sin partir un par sustituto. */
	function cortar(texto: string, largo: number): string {
		if (texto.length <= largo) return texto;
		let corte = texto.slice(0, largo);
		if (/[\uD800-\uDBFF]$/.test(corte)) corte = corte.slice(0, -1);
		return `${corte}...`;
	}

	/**
	 * Cuantas veces salto dentro del mismo minuto. El backend junta en una
	 * fila los cruces del umbral de un mismo minuto y aqui se dice cuantos
	 * fueron, porque una sola vez y cuarenta no son la misma alerta.
	 */
	function veces(a: AlertaLogin): string {
		const n = entero(a.contador) ?? 1;
		return n === 1 ? 'Una vez en ese minuto' : `${n} veces en ese minuto`;
	}

	/** El texto de la etiqueta del titulo: "12 alertas", "3 pendientes". */
	function etiquetaAlertas(): string {
		if (filtroVisto === 'todas') {
			return `${totalAlertas} ${totalAlertas === 1 ? 'alerta' : 'alertas'}`;
		}
		const nombre = NOMBRE_FILTRO[filtroVisto].toLowerCase();
		return `${totalAlertas} ${totalAlertas === 1 ? nombre.slice(0, -1) : nombre}`;
	}

	/** Lo que se dice cuando no hay ninguna, segun el filtro. */
	function textoVacio(): string {
		switch (filtroVisto) {
			case 'pendiente':
				return 'No hay alertas pendientes.';
			case 'revisada':
				return 'No hay alertas revisadas. Marcarlas todavia no se puede desde aqui.';
			case 'descartada':
				return 'No hay alertas descartadas. Marcarlas todavia no se puede desde aqui.';
			default:
				return 'Ningun intento de entrada ha cruzado un limite. Se vigilan los fallos desde una IP, los fallos contra una cuenta y cuantos correos o usuarios distintos se teclean desde una IP.';
		}
	}
</script>

<section class="fraude">
	<div class="titulo">
		<h2>Manipulacion de resenas</h2>
		{#if !cargando && !error && !grafoVacio}
			<span class="etiqueta" class:limpio={anillos.length === 0}>
				{anillos.length}
				{anillos.length === 1 ? 'grupo senalado' : 'grupos senalados'}
			</span>
		{/if}
		{#if !cargando}
			<div class="acciones">
				<button type="button" onclick={cargar}>Volver a analizar</button>
			</div>
		{/if}
	</div>

	<p class="intro">
		Grupos de cuentas cuyo patron de calificaciones no se explica por el uso normal de la
		tienda. Se calcula recorriendo el grafo de relaciones entre cuentas, resenas y productos,
		no consultando una tabla.
	</p>

	<!--
		De cuando son los datos que se acaban de analizar.

		Este renglon es la respuesta a algo que este proyecto tuvo escrito como
		pendiente durante dias: el grafo se llena por una cola, y hasta ahora el
		panel ensenaba un analisis correcto sobre datos que podian estar
		incompletos SIN DECIRLO. Un panel que falla se arregla; uno que calla se
		cree.

		Solo aparece con el analisis ya pintado. Antes de eso no hay nada de que
		decir la antiguedad, y ponerlo arriba de un "Analizando..." solo agrega
		ruido.
	-->
	{#if conciliacion && !cargando && !error}
		<p class="sincro" class:atrasado={!conciliacion.cuadra}>
			{#if conciliacion.cuadra}
				Grafo al dia con PostgreSQL, sincronizado {hace(conciliacion.ultima_sincronizacion)}.
			{:else}
				<!-- La frase se escribe ENTERA en cada rama en vez de armarla con un
				     {#if} en medio. Con el {#if} intercalado, Svelte deja el salto de
				     linea como espacio y el punto quedaba separado: "con PostgreSQL ."
				     Se vio en pantalla, no leyendo el codigo. Repetir seis palabras es
				     mas barato que pelearse con los espacios de la plantilla. -->
				<strong>Este analisis puede estar incompleto.</strong>
				{#if conciliacion.cola && conciliacion.cola.pendientes > 0}
					El grafo no cuadra con PostgreSQL y hay {conciliacion.cola.pendientes}
					{conciliacion.cola.pendientes === 1 ? 'cambio' : 'cambios'} sin aplicar.
				{:else}
					El grafo no cuadra con PostgreSQL.
				{/if}
				{#if conciliacion.sugerencia}
					{conciliacion.sugerencia}
				{/if}
			{/if}
			<!-- Los apartados se dicen SIEMPRE, cuadre o no. Un evento que fallo
			     cinco veces no se va a reintentar solo, asi que si nadie lo mira
			     se queda ahi para siempre: es la unica parte de este mecanismo
			     que necesita una persona. -->
			{#if conciliacion.cola && conciliacion.cola.apartados > 0}
				<strong>
					Hay {conciliacion.cola.apartados}
					{conciliacion.cola.apartados === 1 ? 'cambio' : 'cambios'} que fallaron y ya no se
					reintentan.
				</strong>
			{/if}
		</p>
	{/if}

	{#if cargando}
		<p class="gris">Analizando el grafo de resenas...</p>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if grafoVacio}
		<!-- El OTRO vacio: la ruta contesto bien, pero no habia grafo que
		     recorrer. Sin esta rama, el bloque de abajo diria "se recorrieron 0
		     cuentas y 0 resenas sin encontrar nada", que es una auditoria que
		     nunca ocurrio presentada como una auditoria limpia. -->
		<div class="pendiente">
			<h3>El grafo esta vacio: no se analizo nada</h3>
			<p>
				La consulta corrio y contesto bien, pero Neo4j no tiene ni una cuenta ni una resena
				que recorrer. <strong>Esto no quiere decir que no haya fraude</strong>: quiere decir
				que todavia no se ha mirado.
			</p>
			<p class="gris">
				El grafo es una proyeccion de PostgreSQL y se carga con
				<code>bash etl/cargar_grafo.sh</code> (desde Git Bash). Se corre solo tambien al
				arrancar con <code>.\arrancar.ps1</code>.
			</p>
			<button type="button" onclick={cargar}>Volver a analizar</button>
		</div>
	{:else if anillos.length === 0}
		<!-- El vacio con su denominador. Ver la nota larga de arriba. -->
		<div class="limpio-caja">
			<h3>No se encontro ningun patron anomalo</h3>
			{#if analizado}
				<p>
					Se recorrieron <strong>{analizado.cuentas}</strong> cuentas,
					<strong>{analizado.resenas}</strong> resenas y
					<strong>{analizado.relaciones}</strong> relaciones del grafo sin encontrar ciclos de
					calificacion, pares mutuos ni reiteracion sobre los mismos productos.
				</p>
				<p class="gris">
					Un resultado vacio aqui significa que el analisis corrio y no hallo nada, no que
					falten datos.
				</p>
			{:else}
				<p class="gris">El analisis corrio y no devolvio ningun grupo.</p>
			{/if}
		</div>
	{:else}
		<ul class="lista">
			<!-- La clave lleva el indice ademas del id, y no es paranoia: el id
			     de un grupo `direccion` se arma solo con los ids de sus cuentas,
			     asi que dos direcciones distintas habitadas por LAS MISMAS dos
			     cuentas producen el mismo id dos veces. Pasa de verdad -- la
			     misma casa esta cargada varias veces escrita distinto, lo
			     documenta etl/extraer_grafo.sql -- y una clave repetida en un
			     {#each} de Svelte 5 no degrada la lista: lanza
			     `each_key_duplicate` y revienta el panel entero. -->
			{#each anillos as anillo, i (anillo.id + '#' + i)}
				{@const clave = anillo.id + '#' + i}
				{@const desplegada = abierta === clave}
				<li class="anillo" class:desplegada>
					<button type="button" class="cabeza" onclick={() => alternar(clave)}>
						<span class="tipo tipo-{anillo.tipo}">{NOMBRE_TIPO[anillo.tipo]}</span>

						<span class="cuentas-resumen">
							{#each anillo.cuentas as cuenta, i (cuenta.id_usuario)}
								<span class="cuenta">{cuenta.usuario}</span>{#if i < anillo.cuentas.length - 1}<span
										class="flecha">-&gt;</span
									>{/if}
							{/each}
							{#if anillo.tipo === 'ciclo'}
								<span class="flecha">-&gt;</span>
								<span class="cuenta cierra">{anillo.cuentas[0].usuario}</span>
							{/if}
						</span>

						<span class="saltos">{anillo.saltos} saltos</span>
						<span class="chevron" aria-hidden="true">{desplegada ? '-' : '+'}</span>
					</button>

					{#if desplegada}
						<div class="detalle">
							<p class="porque">{EXPLICACION_TIPO[anillo.tipo]}</p>

							<div class="columnas">
								<div>
									<h4>Cuentas ({anillo.cuentas.length})</h4>
									<ul class="simple">
										{#each anillo.cuentas as cuenta (cuenta.id_usuario)}
											<li>
												<span class="fuerte">{cuenta.usuario}</span>
												<span class="gris">{nombreCompleto(cuenta)}</span>
												<span class="gris correo">{cuenta.correo_electronico}</span>
											</li>
										{/each}
									</ul>
								</div>

								<div>
									<h4>Productos involucrados ({anillo.productos.length})</h4>
									<ul class="simple">
										{#each anillo.productos as producto (producto.id_producto)}
											<li>
												<a href="/producto/{producto.id_producto}">{producto.nombre}</a>
											</li>
										{/each}
									</ul>
								</div>
							</div>

							{#if anillo.senales.length > 0}
								<h4>Por que se senalo</h4>
								<ul class="senales">
									{#each anillo.senales as senal}
										<li>{senal}</li>
									{/each}
								</ul>
							{/if}

							<h4>Las resenas del patron ({anillo.resenas.length})</h4>
							<div class="tabla">
								<table>
									<thead>
										<tr>
											<th>Quien califica</th>
											<th>A quien</th>
											<th>Producto</th>
											<th>Nota</th>
											<th>Cuando</th>
										</tr>
									</thead>
									<tbody>
										{#each anillo.resenas as resena (resena.id_resena)}
											<tr>
												<td class="fuerte">{resena.autor}</td>
												<td>{resena.vendedor}</td>
												<td>{resena.producto}</td>
												<td class="nota">{resena.calificacion}</td>
												<td class="gris">{fecha(resena.fecha)}</td>
											</tr>
										{/each}
									</tbody>
								</table>
							</div>
						</div>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
</section>

<!--
	Intentos de entrada sospechosos. Tarjeta aparte, con su titulo y su carga:
	no espera a los anillos ni los hace esperar. Ver el bloque "intentos de
	entrada" del script.
-->
<section class="fraude" aria-labelledby="titulo-entradas">
	<div class="titulo">
		<h2 id="titulo-entradas">Intentos de entrada sospechosos</h2>
		{#if !errorAlertas && !(cargandoAlertas && alertas.length === 0)}
			<!-- Rojo solo cuando cuenta lo que falta por mirar. Diez revisadas
			     no son una alarma. -->
			<span
				class="etiqueta"
				class:limpio={totalAlertas === 0 ||
					filtroVisto === 'revisada' ||
					filtroVisto === 'descartada'}
			>
				{etiquetaAlertas()}
			</span>
		{/if}
		<div class="acciones">
			<button
				type="button"
				onclick={() => cargarAlertas(paginaAlertas)}
				disabled={cargandoAlertas}
			>
				Volver a mirar
			</button>
		</div>
	</div>

	<p class="intro">
		Tres contadores vigilan las entradas al portal: dos cuentan fallos y el otro cuenta los correos
		o usuarios distintos que se teclean desde una IP, salgan bien o mal. Cuando uno cruza su limite
		queda aqui una alerta para que alguien la mire. Nadie se bloquea solo: esto avisa, no frena.
	</p>

	<div class="pestanas" role="group" aria-label="Filtrar por estado">
		{#each FILTROS as f (f)}
			<button
				type="button"
				class="pestana"
				class:elegida={filtroAlertas === f}
				aria-pressed={filtroAlertas === f}
				onclick={() => cambiarFiltro(f)}
			>
				{NOMBRE_FILTRO[f]}
			</button>
		{/each}
	</div>

	{#if hayLocales}
		<p class="ayuda-local">
			<span class="marca-local">este equipo (local)</span> es esta misma maquina. En desarrollo el
			navegador y el servidor corren aqui, asi que cada prueba del equipo entra desde esta IP.
		</p>
	{/if}

	{#if errorAlertas}
		<div class="fallo" role="alert">
			<p>{errorAlertas}</p>
			<button type="button" onclick={() => cargarAlertas(paginaAlertas)}>Reintentar</button>
		</div>
	{:else if cargandoAlertas && alertas.length === 0}
		<p class="gris">Buscando alertas...</p>
	{:else if alertas.length === 0}
		<div class="limpio-caja">
			<p>{textoVacio()}</p>
		</div>
	{:else}
		<!-- Mientras llega otra pagina se deja la de antes, apagada, en vez de
		     vaciar la lista: vaciarla hace saltar la pagina entera en cada clic. -->
		<ul class="lista-alertas" class:esperando={cargandoAlertas} aria-busy={cargandoAlertas}>
			{#each alertas as a (a.id_alerta_fraude)}
				{@const ids = identificadores(a)}
				{@const vistas = entero(a.detalle?.cuentas_distintas)}
				{@const clave = tecleado(a.clave)}
				<li class="alerta">
					<div class="alerta-cabeza">
						<span class="que-paso">{QUE_PASO[a.tipo_alerta] ?? a.tipo_alerta}</span>
						<span class="estado estado-{a.estado}">{NOMBRE_ESTADO[a.estado] ?? a.estado}</span>
					</div>

					<dl class="datos">
						<div>
							<dt>{origenEsIp(a) ? 'IP' : 'Cuenta intentada'}</dt>
							<dd>
								<span class="clave" title={clave.titulo}>{clave.texto}</span>
								{#if origenEsIp(a) && esLocal(a.clave)}
									<span class="marca-local">este equipo (local)</span>
								{/if}
							</dd>
						</div>
						{#if a.cuenta_involucrada}
							<div>
								<dt>Cuenta real</dt>
								<dd class="clave">{a.cuenta_involucrada.usuario}</dd>
							</div>
						{/if}
						<div>
							<dt>Lo que se vio</dt>
							<dd>{evidencia(a)}</dd>
						</div>
						<div>
							<dt>Veces</dt>
							<dd>{veces(a)}</dd>
						</div>
						<div>
							<dt>Cuando</dt>
							<dd>{fecha(a.ventana_inicio)}</dd>
						</div>
					</dl>

					{#if ids.length > 0}
						<div class="probadas">
							<h4>
								Correos o usuarios tecleados{vistas !== null && vistas > ids.length
									? ` (se ven ${ids.length} de ${vistas})`
									: ''}
							</h4>
							<p class="nota-probadas">Cuentan tambien las entradas que salieron bien.</p>
							<!-- La clave es solo la posicion. Antes era texto + posicion, y lo
							     que la hacia unica ya era la posicion; el texto solo sumaba
							     peso, y un identificador puede pesar un mega. La lista no se
							     reordena ni se edita, asi que la posicion basta. -->
							<ul class="lista-probadas">
								{#each ids as id, j (j)}
									{@const t = tecleado(id)}
									<li class="probada" title={t.titulo}>{t.texto}</li>
								{/each}
							</ul>
						</div>
					{/if}
				</li>
			{/each}
		</ul>

		{#if totalPaginasAlertas > 1}
			<!-- Por numero de pagina, igual que el catalogo del panel de vendedor:
			     es lo que devuelve la ruta (`pagina`, `total_paginas`). -->
			<nav class="paginacion" aria-label="Paginas de alertas">
				<button
					type="button"
					onclick={() => cargarAlertas(paginaAlertas - 1)}
					disabled={paginaAlertas <= 1 || cargandoAlertas}
				>
					Anterior
				</button>

				<span class="cuantas">
					Pagina {paginaAlertas} de {totalPaginasAlertas}
					<span class="menor">({etiquetaAlertas()})</span>
				</span>

				<button
					type="button"
					onclick={() => cargarAlertas(paginaAlertas + 1)}
					disabled={paginaAlertas >= totalPaginasAlertas || cargandoAlertas}
				>
					Siguiente
				</button>
			</nav>
		{/if}
	{/if}
</section>

<style>
	.fraude {
		padding: 26px 28px;
		margin-bottom: 28px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.titulo {
		display: flex;
		align-items: center;
		gap: var(--e2);
		flex-wrap: wrap;
		margin-bottom: 8px;
	}

	.titulo h2 {
		font-size: var(--f-xl);
		margin-right: 4px;
	}

	.etiqueta {
		padding: 3px 11px;
		font-size: var(--f-sm);
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: 999px;
	}

	/* Cero grupos no es una alarma: se pinta neutro, no rojo. */
	.etiqueta.limpio {
		color: var(--gris);
		background: var(--panel);
		border-color: var(--linea);
	}

	.acciones {
		margin-left: auto;
		display: flex;
		gap: var(--e2);
	}

	.acciones button,
	.pendiente button,
	.fallo button {
		padding: 8px 16px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.acciones button:hover,
	.pendiente button:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.intro {
		max-width: 620px;
		margin-bottom: 20px;
		color: var(--gris);
		font-size: var(--f-base);
	}

	/* De cuando son los datos analizados.

	   Al dia va en gris, del tamano de un pie de foto: es lo normal y no tiene
	   que competir con los anillos, que son lo que se viene a ver. Solo cuando
	   NO cuadra se pone rojo y con fondo, porque ahi deja de ser un dato y pasa
	   a ser una advertencia sobre lo que se esta leyendo justo debajo. */
	.sincro {
		max-width: 620px;
		margin: -12px 0 20px;
		font-size: var(--f-ms);
		color: var(--gris-2);
	}

	.sincro.atrasado {
		padding: 10px 12px;
		border-radius: var(--r);
		background: var(--rojo-cl);
		color: var(--rojo);
		font-size: var(--f-base);
	}

	.gris {
		color: var(--gris);
	}

	.fuerte {
		font-weight: 500;
		color: var(--tinta);
	}

	code {
		padding: 1px 6px;
		font-size: 0.88em;
		background: var(--panel);
		border-radius: 4px;
	}

	/* -- estados que no son la lista -- */

	.pendiente,
	.limpio-caja {
		padding: 22px 24px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.pendiente h3,
	.limpio-caja h3 {
		font-size: var(--f-md);
		margin-bottom: 8px;
	}

	.pendiente p,
	.limpio-caja p {
		max-width: 620px;
		margin-bottom: 10px;
		font-size: var(--f-base);
	}

	.pendiente button {
		margin-top: 6px;
	}

	.fallo {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		flex-wrap: wrap;
		padding: 14px 18px;
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	/* -- la lista de anillos -- */

	.lista {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--e3);
	}

	.anillo {
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
	}

	.anillo.desplegada {
		border-color: var(--indigo);
	}

	/* La cabecera entera es el boton: el area pulsable es la fila completa y
	   no solo el signo de la derecha. Un objetivo de 12 pixeles al borde de la
	   tarjeta se falla mas de lo que se acierta en un telefono. */
	.cabeza {
		display: flex;
		align-items: center;
		gap: var(--e3);
		flex-wrap: wrap;
		width: 100%;
		padding: 14px 18px;
		font-family: inherit;
		font-size: var(--f-base);
		text-align: left;
		color: var(--tinta);
		background: none;
		border: 0;
		cursor: pointer;
	}

	.cabeza:hover {
		background: var(--panel);
	}

	.tipo {
		padding: 3px 10px;
		font-size: var(--f-sm);
		border-radius: 999px;
		white-space: nowrap;
	}

	.tipo-ciclo,
	.tipo-reiterado {
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
	}

	.tipo-mutuo,
	.tipo-direccion {
		color: var(--indigo);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
	}

	.cuentas-resumen {
		display: flex;
		align-items: center;
		gap: var(--e1);
		flex-wrap: wrap;
	}

	.cuenta {
		font-weight: 500;
	}

	/* La cuenta repetida que cierra el ciclo. Se pinta distinta para que se
	   lea como "vuelve a la primera" y no como una cuarta cuenta. */
	.cuenta.cierra {
		color: var(--gris);
	}

	.flecha {
		color: var(--gris-2);
	}

	.saltos {
		margin-left: auto;
		font-size: var(--f-sm);
		color: var(--gris);
		white-space: nowrap;
	}

	.chevron {
		width: 18px;
		text-align: center;
		color: var(--gris);
	}

	/* -- el detalle desplegado -- */

	.detalle {
		padding: 4px 18px 20px;
		border-top: 1px solid var(--linea);
	}

	.porque {
		max-width: 680px;
		margin: 16px 0 20px;
		font-size: var(--f-base);
		color: var(--gris);
	}

	.detalle h4 {
		font-size: var(--f-ms);
		margin: 18px 0 8px;
		color: var(--tinta);
	}

	.columnas {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
		gap: var(--e4) var(--e5);
	}

	.columnas h4 {
		margin-top: 0;
	}

	ul.simple {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--e2);
		font-size: var(--f-base);
	}

	ul.simple li {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
	}

	.correo {
		font-size: var(--f-sm);
		overflow-wrap: anywhere;
	}

	ul.simple a {
		color: var(--indigo);
	}

	ul.senales {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		font-size: var(--f-base);
	}

	ul.senales li {
		padding-left: 16px;
		position: relative;
		color: var(--texto);
	}

	ul.senales li::before {
		content: '-';
		position: absolute;
		left: 0;
		color: var(--gris-2);
	}

	/* La tabla se desborda en horizontal DENTRO de su caja, y nunca empuja el
	   ancho de la pagina. */
	.tabla {
		overflow-x: auto;
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: var(--f-ms);
	}

	th {
		padding: 9px 12px;
		text-align: left;
		font-weight: 500;
		font-size: var(--f-sm);
		color: var(--gris);
		background: var(--panel);
		white-space: nowrap;
	}

	td {
		padding: 9px 12px;
		border-top: 1px solid var(--linea);
		white-space: nowrap;
	}

	.nota {
		font-weight: 500;
	}

	/* -- intentos de entrada sospechosos --

	   Sin medidas nuevas: las pestanas son las de OfertasVendedor, la marca
	   local la de PanelTendencias y la barra de paginas la de PanelVendedor.
	   El CSS de Svelte tiene ambito, asi que se copian las reglas y no las
	   clases; lo que tiene que coincidir es el aspecto. */

	.pestanas {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e2);
		margin-bottom: var(--e4);
	}

	.pestana {
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

	/* La linea que explica la marca local. Gris y del tamano de un pie de
	   foto, como la de sincronizacion: es contexto, no una advertencia. */
	.ayuda-local {
		max-width: 620px;
		margin-bottom: var(--e4);
		font-size: var(--f-ms);
		color: var(--gris-2);
	}

	.marca-local {
		padding: 2px 9px;
		font-size: var(--f-xs);
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: 999px;
		white-space: nowrap;
	}

	.lista-alertas {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--e3);
		transition: opacity var(--t);
	}

	/* La pagina de antes, mientras llega la siguiente. */
	.lista-alertas.esperando {
		opacity: 0.6;
	}

	.alerta {
		padding: 14px 18px;
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.alerta-cabeza {
		display: flex;
		align-items: center;
		gap: var(--e2);
		flex-wrap: wrap;
	}

	.que-paso {
		font-size: var(--f-base);
		font-weight: 500;
		color: var(--tinta);
	}

	/* Mismo chip que el tipo de anillo. Pendiente en rojo porque es lo que
	   falta por mirar; revisada en indigo; descartada neutra. */
	.estado {
		margin-left: auto;
		padding: 3px 10px;
		font-size: var(--f-sm);
		border-radius: 999px;
		white-space: nowrap;
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
	}

	.estado-pendiente {
		color: var(--rojo);
		background: var(--off);
		border-color: var(--rojo);
	}

	.estado-revisada {
		color: var(--indigo);
		background: var(--indigo-cl);
		border-color: var(--indigo);
	}

	.datos {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
		gap: var(--e3) var(--e4);
		margin-top: var(--e3);
	}

	.datos dt {
		margin-bottom: var(--e1);
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.datos dd {
		display: flex;
		align-items: center;
		gap: var(--e2);
		flex-wrap: wrap;
		font-size: var(--f-base);
		color: var(--texto);
		overflow-wrap: anywhere;
	}

	.clave {
		font-weight: 500;
		color: var(--tinta);
	}

	.probadas h4 {
		font-size: var(--f-ms);
		margin: var(--e4) 0 var(--e2);
		color: var(--tinta);
	}

	/* Pegada al titulo y en gris: matiza la lista, no compite con ella. */
	.nota-probadas {
		margin: calc(-1 * var(--e1)) 0 var(--e2);
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.lista-probadas {
		list-style: none;
		display: flex;
		gap: var(--e2);
		flex-wrap: wrap;
		font-size: var(--f-sm);
	}

	.probada {
		padding: 3px 10px;
		color: var(--tinta);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		overflow-wrap: anywhere;
	}

	.paginacion {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-wrap: wrap;
		gap: var(--e4);
		margin-top: var(--e5);
	}

	.cuantas {
		color: var(--tinta);
		text-align: center;
	}

	.cuantas .menor {
		display: block;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	@media (max-width: 620px) {
		.fraude {
			padding: 22px 20px;
		}
		.acciones {
			margin-left: 0;
			width: 100%;
		}
		.saltos {
			margin-left: 0;
		}
		.estado {
			margin-left: 0;
		}
	}
</style>
