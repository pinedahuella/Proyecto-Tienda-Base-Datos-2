<script lang="ts">
	import { onMount } from 'svelte';
	import { conJson, mensajeUtil, pedir } from './api';
	import BloquearCuenta from './BloquearCuenta.svelte';

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
	 * Neo4j, que es la familia que el equipo eligio implementar.
	 *
	 * **Hasta el 2026-09-18 esto tenia DOS vistas: una EN VIVO** (
	 * `GET /admin/fraude/anillos`, recalculaba A.1/A.2/A.4 contra Neo4j en
	 * cada carga, sin persistir nada) **y una PERSISTIDA** (la de abajo,
	 * `alertas-resenas`, alimentada por el worker `AnillosDetectorService`).
	 * Jose David elimino la EN VIVO ese dia -- era la prueba de concepto de
	 * la Entrega 2, ya redundante con la persistida, sin estado de revision
	 * ni forma de marcar un caso trabajado. Con ella se fue tambien
	 * `GrafoSyncService.estadoSincronizacion()`, que era su unico consumidor
	 * (ver `plan pendiente/anillos-fraude-persistencia.md`). Este componente
	 * se actualizo el mismo dia: ya no hay "grupos en vivo" ni el vacio con
	 * denominador que tenian (`analizado.cuentas`) -- todo lo que se ve
	 * ahora sale de la tabla `anillo_fraude`, con su propio estado
	 * (pendiente/revisada/descartada).
	 *
	 *
	 * LA RUTA
	 * ---------------------------------------------------------------
	 *   GET/PATCH /admin/fraude/alertas-resenas   (solo admin; la tienda 403)
	 *
	 * El backend es de Jose David y aqui no se toca. Renombrada ese mismo
	 * 2026-09-18 desde `anillos-persistidos`: sin la version en vivo con la
	 * que contrastar, el sufijo ya no decia nada, y queda en paralelo con
	 * `alertas-login`.
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

	/**
	 * Lo que devuelve `GET /admin/grafo/conciliacion`: si el grafo que
	 * detecta los anillos esta al dia con PostgreSQL. `conciliar()` no
	 * dependia de la ruta EN VIVO que se elimino -- solo su prima
	 * `estadoSincronizacion()` era exclusiva de esa ruta -- asi que esto
	 * sigue funcionando igual, solo que ahora acompana a los anillos
	 * PERSISTIDOS en vez de a un analisis en vivo.
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

	// onMount y no $effect: esto corre UNA vez al montar el panel. Con $effect
	// se repite solo -- en este mismo proyecto se vieron seis llamadas en el
	// mismo instante con un console.trace.
	//
	// Las tres cargas salen a la vez y ninguna espera a la otra.
	onMount(() => {
		void cargarConciliacion();
		void cargarAlertas(1);
		void cargarAnillosPersistidos(1);
	});

	/**
	 * Si el grafo que alimenta a `AnillosDetectorService` esta al dia con
	 * PostgreSQL.
	 *
	 * Va en una peticion APARTE y no se espera con await: es informacion
	 * SOBRE los anillos, no parte de ellos. Si esta ruta falla o tarda, el
	 * panel tiene que ensenar sus anillos igual -- bloquear la lista por no
	 * poder decir si esta fresca seria cambiar un problema chico por uno
	 * grande.
	 *
	 * Y por eso un fallo aqui deja `conciliacion` en null y no pinta nada, en
	 * vez de pintar un aviso de error: "no se pudo comprobar si esta al dia" al
	 * lado de una lista correcta asusta mas de lo que informa.
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
	 * Ampliado el 2026-09-18 a las nueve senales que ya usa el backend (tres
	 * de Redis, seis de Elasticsearch -- ver la tabla en
	 * `backend/elementos Generales/endpoints/endpoints-fraude.md`) y con el
	 * triage (`PATCH /admin/fraude/alertas-login/:id`) que hasta ahora estaba
	 * escrito como "no existe todavia".
	 */
	type TipoAlerta =
		| 'fuerza_bruta_ip'
		| 'fuerza_bruta_cuenta'
		| 'multi_cuenta_ip'
		| 'ip_rotacion_cuenta'
		| 'toma_cuenta'
		| 'viaje_imposible'
		| 'fuerza_bruta_cuenta_lenta'
		| 'multi_cuenta_ip_lenta'
		| 'ip_rotacion_cuenta_lenta';
	type EstadoAlerta = 'pendiente' | 'revisada' | 'descartada';
	type FiltroAlerta = 'todas' | EstadoAlerta;
	type FiltroTipo = 'todos' | TipoAlerta;

	/**
	 * Una cuenta a la que le corresponde ver esta alerta, con su propia
	 * lectura -- viene de `notificacion_fraude`. Reemplaza a
	 * `cuenta_involucrada` (un objeto o null, una sola cuenta), que cambio de
	 * forma el 2026-09-15: `multi_cuenta_ip`/`multi_cuenta_ip_lenta` le tocan
	 * a VARIAS cuentas a la vez, no a una sola.
	 */
	interface CuentaAfectada {
		id_usuario: string;
		usuario: string;
		fecha_lectura: string | null;
	}

	interface AlertaLogin {
		id_alerta_fraude: string;
		tipo_alerta: TipoAlerta;
		/** La IP en los tipos por IP; el identificador intentado en los demas. */
		clave: string;
		/**
		 * Vacio en fuerza_bruta_ip (no trae lista de cuentas objetivo). Un
		 * elemento en la mayoria de los tipos; varios en multi_cuenta_ip /
		 * multi_cuenta_ip_lenta (una por cada cuenta real que esa IP probo).
		 */
		cuentas_afectadas: CuentaAfectada[];
		/**
		 * La evidencia, distinta por tipo -- ver `evidencia()` mas abajo para
		 * el detalle campo por campo. Es un jsonb sin esquema, asi que cada
		 * campo se lee blindado.
		 */
		detalle: Record<string, unknown>;
		/** Cuantas veces se cruzo el umbral dentro de la misma ventana. Nace en 1. */
		contador: number;
		/** El minuto (Redis/toma_cuenta/viaje_imposible) o la hora (worker de 15 min), truncado. */
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
		multi_cuenta_ip: 'Muchos correos o usuarios distintos desde una IP',
		ip_rotacion_cuenta: 'Muchas IPs distintas contra una misma cuenta',
		toma_cuenta: 'Login exitoso desde una IP nueva para la cuenta',
		viaje_imposible: 'Velocidad imposible entre dos logins de la cuenta',
		fuerza_bruta_cuenta_lenta: 'Intentos fallidos contra una cuenta, repartidos en 24h',
		multi_cuenta_ip_lenta: 'Correos o usuarios distintos desde una IP, repartidos en 24h',
		ip_rotacion_cuenta_lenta: 'IPs distintas contra una cuenta, repartidas en 24h'
	};

	/** Las tres senales cuya `clave` es una IP. En las otras seis, la clave es el identificador tecleado. */
	const TIPOS_POR_IP = new Set<TipoAlerta>(['fuerza_bruta_ip', 'multi_cuenta_ip', 'multi_cuenta_ip_lenta']);

	/** Las que agrupan una LISTA de valores en `detalle` (identificadores o IPs vistas). */
	const TIPOS_CON_LISTA = new Set<TipoAlerta>([
		'multi_cuenta_ip',
		'multi_cuenta_ip_lenta',
		'ip_rotacion_cuenta',
		'ip_rotacion_cuenta_lenta'
	]);

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

	const NOMBRE_FILTRO_TIPO: Record<FiltroTipo, string> = {
		todos: 'Todos los tipos',
		...QUE_PASO
	};

	/**
	 * Las nueve senales agrupadas por lo que miran, para el select de tipo. El
	 * backend filtra por UN tipo a la vez, asi que la clasificacion es del
	 * select (optgroup) y no un filtro de familia.
	 */
	const GRUPOS_TIPO: { nombre: string; tipos: Exclude<FiltroTipo, 'todos'>[] }[] = [
		{ nombre: 'Por IP', tipos: ['fuerza_bruta_ip', 'multi_cuenta_ip', 'multi_cuenta_ip_lenta'] },
		{
			nombre: 'Por cuenta',
			tipos: [
				'fuerza_bruta_cuenta',
				'fuerza_bruta_cuenta_lenta',
				'ip_rotacion_cuenta',
				'ip_rotacion_cuenta_lenta'
			]
		},
		{ nombre: 'Ubicacion y acceso', tipos: ['toma_cuenta', 'viaje_imposible'] }
	];

	/** Las vistas de Fraude, una a la vez, para no tener que bajar por toda la pagina. */
	type PestanaFraude = 'casos' | 'entradas' | 'resenas' | 'eventos';
	/**
	 * `/panel?s=fraude&t=resenas` abre directo en los anillos: la campana del
	 * admin y la demo lo usan. `t=casos` y `t=eventos` abren las suyas.
	 */
	const PESTANA_DE_LA_DIRECCION =
		typeof location !== 'undefined' ? new URLSearchParams(location.search).get('t') : null;
	let pestanaFraude = $state<PestanaFraude>(
		PESTANA_DE_LA_DIRECCION === 'resenas' ||
			PESTANA_DE_LA_DIRECCION === 'eventos' ||
			PESTANA_DE_LA_DIRECCION === 'casos'
			? PESTANA_DE_LA_DIRECCION
			: 'entradas'
	);

	/** Cuantas por pagina. El mismo 20 que el resto de las listas del panel. */
	const POR_PAGINA = 20;

	let alertas = $state<AlertaLogin[]>([]);
	let filtroAlertas = $state<FiltroAlerta>('todas');
	let filtroTipoAlertas = $state<FiltroTipo>('todos');
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

	/** Id de la alerta cuyo PATCH esta en vuelo, para deshabilitar sus botones y no doble-mandar. */
	let marcandoAlerta = $state<string | null>(null);

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
		if (filtroTipoAlertas !== 'todos') partes.push(`tipo=${filtroTipoAlertas}`);

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

	function cambiarFiltroTipo(t: FiltroTipo) {
		if (t === filtroTipoAlertas) return;
		filtroTipoAlertas = t;
		void cargarAlertas(1);
	}

	/** La clave es una IP en tres de las nueve senales; en las otras seis es el identificador tecleado. */
	function origenEsIp(a: AlertaLogin): boolean {
		return TIPOS_POR_IP.has(a.tipo_alerta);
	}

	/**
	 * PATCH /admin/fraude/alertas-login/:id -- marca una alerta pendiente
	 * como revisada o descartada. Solo transiciona desde pendiente (mismo
	 * criterio que el backend): un 409 quiere decir que alguien mas (otra
	 * pestana, otro admin) ya la movio mientras se miraba esta.
	 */
	async function marcarAlerta(a: AlertaLogin, estado: 'revisada' | 'descartada') {
		marcandoAlerta = a.id_alerta_fraude;
		const r = await pedir<AlertaLogin>(
			`/admin/fraude/alertas-login/${a.id_alerta_fraude}`,
			conJson('PATCH', { estado })
		);
		marcandoAlerta = null;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			// Un 409 (ya se movio) o un 404 (ya no existe) se leen igual que
			// cualquier otro fallo: se avisa y se refresca la pagina actual, que
			// es lo que hace que la alerta "vieja" desaparezca o cambie sola.
			errorAlertas = mensajeUtil(r);
			void cargarAlertas(paginaAlertas);
			return;
		}

		// Reemplaza la fila en el sitio, sin recargar la pagina entera: si el
		// filtro elegido es "pendiente", la fila ya no deberia estar en la
		// lista visible, asi que se quita en vez de dejarla con el estado
		// nuevo y el filtro viejo contradiciendose en pantalla.
		if (filtroAlertas !== 'todas' && filtroAlertas !== estado) {
			alertas = alertas.filter((x) => x.id_alerta_fraude !== a.id_alerta_fraude);
			totalAlertas = Math.max(0, totalAlertas - 1);
		} else {
			alertas = alertas.map((x) => (x.id_alerta_fraude === a.id_alerta_fraude ? r.payload! : x));
		}
	}

	/**
	 * La propia maquina. Mismo criterio y mismas tres escrituras que en
	 * PanelTendencias: una IPv4 puede volver envuelta en IPv6.
	 *
	 * Importa mas aqui que alla. En desarrollo el navegador, los arneses de
	 * pruebas/ y el servidor corren en la misma maquina. Asi que 127.0.0.1 no es
	 * una IP mal leida: ES la IP real de todo el que prueba. (Por el tunel del
	 * celular tambien sale 127.0.0.1 mientras el backend no lleve trustProxy;
	 * ver docs/ENTRAR-DESDE-EL-CELULAR.md.) Quien entre con
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
	 *
	 * Cada tipo llena su `detalle` distinto (ver "Que llena cada columna" en
	 * `endpoints-fraude.md`); esta funcion sabe leer las nueve formas.
	 */
	function evidencia(a: AlertaLogin): string {
		const d = a.detalle ?? {};
		const ventana = duracion(d.ventana_segundos) || (entero(d.ventana_horas) ? `${entero(d.ventana_horas)} horas` : '');
		const cola = ventana ? ` en ${ventana}` : '';

		switch (a.tipo_alerta) {
			case 'multi_cuenta_ip':
			case 'multi_cuenta_ip_lenta': {
				const n = entero(d.cuentas_distintas);
				if (n === null) return '--';
				return `${n} ${n === 1 ? 'correo o usuario distinto' : 'correos o usuarios distintos'}${cola}`;
			}

			case 'ip_rotacion_cuenta':
			case 'ip_rotacion_cuenta_lenta': {
				const n = entero(d.ips_distintas);
				if (n === null) return '--';
				return `${n} ${n === 1 ? 'IP distinta' : 'IPs distintas'}${cola}`;
			}

			case 'toma_cuenta': {
				const conocidas = entero(d.ips_conocidas);
				const previos = entero(d.logins_exitosos_previos);
				if (conocidas === null) return '--';
				return `IP nueva para la cuenta (tenia ${conocidas} conocida${conocidas === 1 ? '' : 's'}${previos !== null ? `, ${previos} login${previos === 1 ? '' : 's'} previo${previos === 1 ? '' : 's'}` : ''})`;
			}

			case 'viaje_imposible': {
				const km = entero(d.distancia_km);
				const kmh = entero(d.velocidad_kmh);
				if (km === null || kmh === null) return '--';
				return `${km.toLocaleString('es-GT')} km en poco tiempo -- ${kmh.toLocaleString('es-GT')} km/h implicitos`;
			}

			default: {
				const f = entero(d.fallos);
				if (f === null) return '--';
				return `${f} ${f === 1 ? 'intento fallido' : 'intentos fallidos'}${cola}`;
			}
		}
	}

	/**
	 * Los valores vistos en las senales que agrupan una lista: identificadores
	 * en multi_cuenta_ip/multi_cuenta_ip_lenta, IPs en
	 * ip_rotacion_cuenta/ip_rotacion_cuenta_lenta. El backend guarda hasta 20.
	 * Un null se vuelve texto vacio y no la palabra "null", que en esta lista
	 * pareceria alguien que tecleo "null".
	 */
	function vistosEnDetalle(a: AlertaLogin): string[] {
		const campo = a.tipo_alerta === 'ip_rotacion_cuenta' || a.tipo_alerta === 'ip_rotacion_cuenta_lenta'
			? a.detalle?.ips
			: a.detalle?.identificadores;
		return Array.isArray(campo) ? campo.map((x) => (x == null ? '' : String(x))) : [];
	}

	/** El titulo de la lista de `vistosEnDetalle`, distinto si son IPs o identificadores tecleados. */
	function tituloVistos(a: AlertaLogin): string {
		return a.tipo_alerta === 'ip_rotacion_cuenta' || a.tipo_alerta === 'ip_rotacion_cuenta_lenta'
			? 'IPs vistas'
			: 'Correos o usuarios tecleados';
	}

	/** La ubicacion de `viaje_imposible`, como "Ciudad, Pais" -- ya sea la anterior o la actual. */
	function ubicacion(valor: unknown): string {
		if (valor == null || typeof valor !== 'object') return '--';
		const u = valor as { pais?: unknown; ciudad?: unknown };
		return [u.ciudad, u.pais].filter((x) => typeof x === 'string' && x.length > 0).join(', ') || '--';
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
	 * Cuantas veces se detecto. Desde el refactor de fraude (migraciones 031 a
	 * 033) la alerta es una senal por (tipo, clave) y `contador` es su
	 * total_detecciones de siempre, ya no los cruces de un minuto. Una sola vez y
	 * cuarenta no son la misma alerta.
	 */
	function veces(a: AlertaLogin): string {
		const n = entero(a.contador) ?? 1;
		return n === 1 ? 'Una vez' : `${n} veces`;
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
				return 'No hay alertas revisadas.';
			case 'descartada':
				return 'No hay alertas descartadas.';
			default:
				return 'Ningun intento de entrada ha cruzado un limite. Se vigilan nueve senales: cuatro contadores de Redis en el propio login y cinco consultas contra el historial en Elasticsearch.';
		}
	}

	// ------------------------------------------------ manipulacion de resenas
	/**
	 * La segunda fuente de esta pantalla: `anillo_fraude` /
	 * `anillo_fraude_resena` de PostgreSQL, que llena `AnillosDetectorService`
	 * (worker cada 15 min + chequeo acotado por resena nueva) cuando A.1/A.2
	 * encuentran un grupo dentro de la ventana de 60 dias.
	 *
	 * Hasta el 2026-09-18 esto convivia con un panel EN VIVO
	 * (`GET /admin/fraude/anillos`, Neo4j puro, sin persistencia ni triage) --
	 * Jose David lo elimino ese dia por redundante, y esta es ahora la UNICA
	 * vista de "manipulacion de resenas" del panel, con estado
	 * (pendiente/revisada/descartada) para que un admin la trabaje como una
	 * cola, igual que las alertas de login. Renombrada el mismo dia de
	 * `anillos-persistidos` a `alertas-resenas` -- ver
	 * `backend/elementos Generales/plan pendiente/anillos-fraude-persistencia.md`.
	 *
	 * Sin evidencia jsonb ni notificacion a las cuentas del anillo: al reves
	 * que en fraude de login, aqui la cuenta senalada es la SOSPECHOSA, y
	 * avisarle le daria la oportunidad de evadir la deteccion. El detalle real
	 * (autor/vendedor/producto/fecha/calificacion) se pide aparte, contra
	 * Neo4j, solo cuando se despliega una fila -- `detalle-grafo` no vuelve a
	 * correr A.1/A.2.
	 */
	/**
	 * Los tipos del catalogo `tipo_anillo_fraude`. 1 a 3 son A.1/A.2
	 * (migracion 019); 4 a 10 son la familia B de `neo4j/consultas/B1..B7`
	 * (migracion 023), que persiste PatronesFraudeDetectorService desde el
	 * 2026-09-24. `anillo_en_el_tiempo` (B.4, id 7) esta reservado: el backend
	 * no lo guarda y rechaza el filtro con 400, asi que tiene nombre por si
	 * llega pero no sale en el selector.
	 */
	type TipoAnillo =
		| 'mutuo'
		| 'ciclo'
		| 'reiterado'
		| 'satelites'
		| 'persistente'
		| 'anillo_en_el_tiempo'
		| 'coordinados'
		| 'reputacion_expres'
		| 'resenas_repetidas'
		| 'anillo_de_texto'
		| 'notas_incoherentes_cuenta'
		| 'notas_incoherentes_producto'
		| 'notas_incoherentes_vendedor'
		| 'resenas_parecidas_vendedor'
		| 'resenas_parecidas_producto'
		| 'resena_positiva_cancelada'
		| 'resenas_negativas_canceladas_vendedor';
	type FiltroTipoAnillo = 'todos' | Exclude<TipoAnillo, 'anillo_en_el_tiempo'>;

	interface CuentaDeAnillo {
		id_usuario: string;
		usuario: string;
	}

	interface AnilloPersistido {
		id_anillo_fraude: string;
		tipo: TipoAnillo;
		/** Los ids de cuenta ordenados y unidos con "-", ej. "9-10". Sin el tipo: ver el .sql para el porque. */
		clave: string;
		cuentas: CuentaDeAnillo[];
		/** Los ids de resena que son la evidencia -- los mismos en Postgres y en Neo4j. */
		resenas: number[];
		estado: EstadoAlerta;
		fecha_creacion: string;
		ultima_vez_confirmado_activo: string;
		fecha_actualizacion: string;
	}

	interface AnillosPersistidosPaginados {
		anillos: AnilloPersistido[];
		pagina: number;
		limite: number;
		total_anillos: number;
		total_paginas: number;
	}

	/** Una resena de `GET .../:id/detalle-grafo`, contra Neo4j en vivo. */
	interface ResenaDetalleAnillo {
		id_resena: number;
		autor: string;
		correo_autor: string;
		vendedor: string;
		correo_vendedor: string;
		producto: string;
		calificacion: number;
		fecha: string;
	}

	interface DetalleAnilloGrafo {
		id_anillo_fraude: string;
		tipo: TipoAnillo;
		clave: string;
		resenas: ResenaDetalleAnillo[];
	}

	const NOMBRE_TIPO_ANILLO: Record<TipoAnillo, string> = {
		mutuo: 'Se califican entre si',
		ciclo: 'Ciclo de calificaciones',
		reiterado: 'Reiteracion sobre los mismos productos',
		satelites: 'Cuentas que solo califican a un vendedor',
		persistente: 'Siempre califica al mismo vendedor',
		anillo_en_el_tiempo: 'Anillo que vuelve con el tiempo',
		coordinados: 'Califican juntas lo mismo',
		reputacion_expres: 'Reputacion en minutos',
		resenas_repetidas: 'Repite la misma resena',
		anillo_de_texto: 'Varias cuentas, la misma resena',
		notas_incoherentes_cuenta: 'Sus estrellas contradicen sus textos',
		notas_incoherentes_producto: 'Producto con notas que contradicen el texto',
		notas_incoherentes_vendedor: 'Vendedor con notas que contradicen el texto',
		resenas_parecidas_vendedor: 'Vendedor con resenas copiadas',
		resenas_parecidas_producto: 'Producto con resenas copiadas',
		resena_positiva_cancelada: 'Resena buena y compra cancelada',
		resenas_negativas_canceladas_vendedor: 'Resenas malas y compras canceladas'
	};

	const FILTROS_TIPO_ANILLO: FiltroTipoAnillo[] = [
		'todos',
		'mutuo',
		'ciclo',
		'reiterado',
		'satelites',
		'persistente',
		'coordinados',
		'reputacion_expres',
		'resenas_repetidas',
		'anillo_de_texto',
		'notas_incoherentes_cuenta',
		'notas_incoherentes_producto',
		'notas_incoherentes_vendedor',
		'resenas_parecidas_vendedor',
		'resenas_parecidas_producto',
		'resena_positiva_cancelada',
		'resenas_negativas_canceladas_vendedor'
	];
	const NOMBRE_FILTRO_TIPO_ANILLO: Record<FiltroTipoAnillo, string> = {
		todos: 'Todos los tipos',
		...NOMBRE_TIPO_ANILLO
	};

	let anillosPersistidos = $state<AnilloPersistido[]>([]);
	let filtroEstadoAnillosP = $state<FiltroAlerta>('pendiente');
	let filtroTipoAnillosP = $state<FiltroTipoAnillo>('todos');
	let paginaAnillosP = $state(1);
	let totalPaginasAnillosP = $state(0);
	let totalAnillosP = $state(0);
	let filtroVistoAnillosP = $state<FiltroAlerta>('pendiente');
	let cargandoAnillosP = $state(true);
	let errorAnillosP = $state('');
	let pedidoAnillosP = 0;
	let marcandoAnilloP = $state<string | null>(null);

	/** Que fila tiene el detalle-grafo desplegado. Una a la vez. */
	let abiertoAnilloP = $state<string | null>(null);
	/** Cache por id: null mientras carga, el detalle una vez llega. No se vuelve a pedir al cerrar y reabrir. */
	let detalleAnilloP = $state<Record<string, DetalleAnilloGrafo | 'cargando' | 'error'>>({});

	async function cargarAnillosPersistidos(pagina: number) {
		const este = ++pedidoAnillosP;
		paginaAnillosP = pagina;
		cargandoAnillosP = true;
		errorAnillosP = '';

		const partes = [`pagina=${pagina}`, `limite=${POR_PAGINA}`];
		if (filtroEstadoAnillosP !== 'todas') partes.push(`estado=${filtroEstadoAnillosP}`);
		if (filtroTipoAnillosP !== 'todos') partes.push(`tipo=${filtroTipoAnillosP}`);

		const r = await pedir<AnillosPersistidosPaginados>(
			`/admin/fraude/alertas-resenas?${partes.join('&')}`
		);

		if (este !== pedidoAnillosP) return;
		cargandoAnillosP = false;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			errorAnillosP = mensajeUtil(r);
			anillosPersistidos = [];
			return;
		}

		const p = r.payload;
		const lista = p.anillos ?? [];

		if (lista.length === 0 && p.total_paginas > 0 && pagina > p.total_paginas) {
			void cargarAnillosPersistidos(p.total_paginas);
			return;
		}

		anillosPersistidos = lista;
		filtroVistoAnillosP = filtroEstadoAnillosP;
		paginaAnillosP = p.pagina;
		totalPaginasAnillosP = p.total_paginas;
		totalAnillosP = p.total_anillos;
	}

	function cambiarFiltroEstadoAnillosP(f: FiltroAlerta) {
		if (f === filtroEstadoAnillosP) return;
		filtroEstadoAnillosP = f;
		void cargarAnillosPersistidos(1);
	}

	function cambiarFiltroTipoAnillosP(t: FiltroTipoAnillo) {
		if (t === filtroTipoAnillosP) return;
		filtroTipoAnillosP = t;
		void cargarAnillosPersistidos(1);
	}

	async function marcarAnilloPersistido(a: AnilloPersistido, estado: 'revisada' | 'descartada') {
		marcandoAnilloP = a.id_anillo_fraude;
		const r = await pedir<AnilloPersistido>(
			`/admin/fraude/alertas-resenas/${a.id_anillo_fraude}`,
			conJson('PATCH', { estado })
		);
		marcandoAnilloP = null;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			errorAnillosP = mensajeUtil(r);
			void cargarAnillosPersistidos(paginaAnillosP);
			return;
		}

		if (filtroEstadoAnillosP !== 'todas' && filtroEstadoAnillosP !== estado) {
			anillosPersistidos = anillosPersistidos.filter((x) => x.id_anillo_fraude !== a.id_anillo_fraude);
			totalAnillosP = Math.max(0, totalAnillosP - 1);
		} else {
			anillosPersistidos = anillosPersistidos.map((x) =>
				x.id_anillo_fraude === a.id_anillo_fraude ? r.payload! : x
			);
		}
	}

	/**
	 * Despliega/cierra el detalle real de un anillo. Lo pide contra Neo4j
	 * SOLO la primera vez que se abre (`detalle-grafo` no vuelve a correr
	 * A.1/A.2, pero sigue siendo una consulta al grafo, y pedirla en cada
	 * clic de "cerrar y volver a abrir" seria gratuito).
	 */
	async function alternarDetalleAnilloP(a: AnilloPersistido) {
		if (abiertoAnilloP === a.id_anillo_fraude) {
			abiertoAnilloP = null;
			return;
		}
		abiertoAnilloP = a.id_anillo_fraude;

		if (detalleAnilloP[a.id_anillo_fraude]) return;

		detalleAnilloP = { ...detalleAnilloP, [a.id_anillo_fraude]: 'cargando' };
		const r = await pedir<DetalleAnilloGrafo>(
			`/admin/fraude/alertas-resenas/${a.id_anillo_fraude}/detalle-grafo`
		);

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		detalleAnilloP = {
			...detalleAnilloP,
			[a.id_anillo_fraude]: r.ok && r.payload ? r.payload : 'error'
		};
	}

	/** El texto de la etiqueta del titulo, igual que `etiquetaAlertas`. */
	function etiquetaAnillosP(): string {
		if (filtroVistoAnillosP === 'todas') {
			return `${totalAnillosP} ${totalAnillosP === 1 ? 'anillo' : 'anillos'}`;
		}
		const nombre = NOMBRE_FILTRO[filtroVistoAnillosP].toLowerCase();
		return `${totalAnillosP} ${totalAnillosP === 1 ? nombre.slice(0, -1) : nombre}`;
	}

	/**
	 * Hallazgos F1 a F6 sobre los eventos de ClickHouse (compras, carritos,
	 * vistas, devoluciones y registros). Los detecta una vez al dia
	 * HallazgosEventoFraudeDetectorService y viven en hallazgo_evento_fraude
	 * (migracion 025). GET y PATCH /admin/fraude/alertas-eventos, mismo triage
	 * que los anillos. Se piden la primera vez que se abre la pestana.
	 */
	type TipoHallazgo =
		| 'vistas_infladas'
		| 'compras_en_rafaga'
		| 'ip_multicuenta_compras'
		| 'devoluciones_seriales'
		| 'granja_de_registros';
	type FiltroTipoHallazgo = 'todos' | TipoHallazgo;

	interface Hallazgo {
		id_hallazgo_evento_fraude: string;
		tipo: TipoHallazgo;
		clave: string;
		cuentas: { id_usuario: string; usuario: string; es_nucleo: boolean }[];
		id_producto_mongo: string | number | null;
		detalle: Record<string, unknown>;
		contador: number;
		ventana_inicio: string;
		estado: EstadoAlerta;
		fecha_creacion: string;
		fecha_actualizacion: string;
	}

	interface HallazgosPaginados {
		hallazgos: Hallazgo[];
		pagina: number;
		limite: number;
		total_hallazgos: number;
		total_paginas: number;
	}

	const NOMBRE_TIPO_HALLAZGO: Record<TipoHallazgo, string> = {
		vistas_infladas: 'Vistas infladas',
		compras_en_rafaga: 'Compras en rafaga',
		ip_multicuenta_compras: 'Varias cuentas, una IP',
		devoluciones_seriales: 'Devoluciones seriales',
		granja_de_registros: 'Granja de registros'
	};

	const QUE_ES_HALLAZGO: Record<TipoHallazgo, string> = {
		vistas_infladas: 'Un producto con demasiadas vistas por sesion, como si alguien refrescara su ficha.',
		compras_en_rafaga: 'Una cuenta con muchos pedidos en pocos minutos.',
		ip_multicuenta_compras: 'Varias cuentas que compran desde la misma IP.',
		devoluciones_seriales: 'Devuelve la mitad o mas de lo que compra.',
		granja_de_registros: 'Muchas cuentas registradas desde la misma IP en una hora.'
	};

	const FILTROS_TIPO_HALLAZGO: FiltroTipoHallazgo[] = ['todos', ...(Object.keys(NOMBRE_TIPO_HALLAZGO) as TipoHallazgo[])];

	/** Los numeros de `detalle` con nombre de persona. Lo que no este aqui sale con su clave legible. */
	const NOMBRE_DATO: Record<string, string> = {
		vistas: 'Vistas',
		sesiones: 'Sesiones',
		vistas_por_sesion: 'Vistas por sesion',
		pedidos: 'Pedidos',
		pedidos_en_la_peor_rafaga: 'Pedidos en la peor rafaga',
		ventana_minutos: 'Ventana en minutos',
		total_cuentas: 'Cuentas',
		cuentas_distintas: 'Cuentas',
		unidades_carrito: 'Unidades al carrito',
		unidades_compradas: 'Unidades compradas',
		unidades_devueltas: 'Unidades devueltas',
		veces: 'Veces',
		tasa: 'Tasa'
	};

	/** Las claves que son un id interno no se ensenan: la cuenta ya sale con su nombre. */
	const CLAVE_VISIBLE: Partial<Record<TipoHallazgo, string>> = {
		ip_multicuenta_compras: 'IP',
		granja_de_registros: 'IP'
	};

	function datosHallazgo(h: Hallazgo): { nombre: string; valor: string }[] {
		return Object.entries(h.detalle ?? {})
			.filter(([k, v]) => !k.startsWith('id_') && (typeof v === 'number' || typeof v === 'string'))
			.map(([k, v]) => ({
				nombre: NOMBRE_DATO[k] ?? k.replace(/_/g, ' '),
				valor: k === 'tasa' && typeof v === 'number' && v <= 1 ? `${Math.round(v * 100)} %` : String(v)
			}));
	}

	let hallazgos = $state<Hallazgo[]>([]);
	let filtroEstadoHallazgos = $state<FiltroAlerta>('pendiente');
	let filtroVistoHallazgos = $state<FiltroAlerta>('pendiente');
	let filtroTipoHallazgos = $state<FiltroTipoHallazgo>('todos');
	let paginaHallazgos = $state(1);
	let totalPaginasHallazgos = $state(0);
	let totalHallazgos = $state(0);
	let cargandoHallazgos = $state(false);
	let errorHallazgos = $state('');
	let pedidoHallazgos = 0;
	let marcandoHallazgo = $state<string | null>(null);
	let hallazgosPedidos = false;

	$effect(() => {
		if (pestanaFraude === 'eventos' && !hallazgosPedidos) {
			hallazgosPedidos = true;
			void cargarHallazgos(1);
		}
	});

	async function cargarHallazgos(pagina: number) {
		const este = ++pedidoHallazgos;
		paginaHallazgos = pagina;
		cargandoHallazgos = true;
		errorHallazgos = '';

		const partes = [`pagina=${pagina}`, `limite=${POR_PAGINA}`];
		if (filtroEstadoHallazgos !== 'todas') partes.push(`estado=${filtroEstadoHallazgos}`);
		if (filtroTipoHallazgos !== 'todos') partes.push(`tipo=${filtroTipoHallazgos}`);

		const r = await pedir<HallazgosPaginados>(`/admin/fraude/alertas-eventos?${partes.join('&')}`);

		if (este !== pedidoHallazgos) return;
		cargandoHallazgos = false;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			errorHallazgos = mensajeUtil(r);
			hallazgos = [];
			return;
		}

		const p = r.payload;
		const lista = p.hallazgos ?? [];

		if (lista.length === 0 && p.total_paginas > 0 && pagina > p.total_paginas) {
			void cargarHallazgos(p.total_paginas);
			return;
		}

		hallazgos = lista;
		filtroVistoHallazgos = filtroEstadoHallazgos;
		paginaHallazgos = p.pagina;
		totalPaginasHallazgos = p.total_paginas;
		totalHallazgos = p.total_hallazgos;
	}

	function cambiarFiltroEstadoHallazgos(f: FiltroAlerta) {
		if (f === filtroEstadoHallazgos) return;
		filtroEstadoHallazgos = f;
		void cargarHallazgos(1);
	}

	function cambiarFiltroTipoHallazgos(t: FiltroTipoHallazgo) {
		if (t === filtroTipoHallazgos) return;
		filtroTipoHallazgos = t;
		void cargarHallazgos(1);
	}

	async function marcarHallazgo(h: Hallazgo, estado: 'revisada' | 'descartada') {
		marcandoHallazgo = h.id_hallazgo_evento_fraude;
		const r = await pedir<Hallazgo>(
			`/admin/fraude/alertas-eventos/${h.id_hallazgo_evento_fraude}`,
			conJson('PATCH', { estado })
		);
		marcandoHallazgo = null;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			errorHallazgos = mensajeUtil(r);
			void cargarHallazgos(paginaHallazgos);
			return;
		}

		if (filtroEstadoHallazgos !== 'todas' && filtroEstadoHallazgos !== estado) {
			hallazgos = hallazgos.filter((x) => x.id_hallazgo_evento_fraude !== h.id_hallazgo_evento_fraude);
			totalHallazgos = Math.max(0, totalHallazgos - 1);
		} else {
			hallazgos = hallazgos.map((x) =>
				x.id_hallazgo_evento_fraude === h.id_hallazgo_evento_fraude ? r.payload! : x
			);
		}
	}

	function etiquetaHallazgos(): string {
		if (filtroVistoHallazgos === 'todas') {
			return `${totalHallazgos} ${totalHallazgos === 1 ? 'hallazgo' : 'hallazgos'}`;
		}
		const nombre = NOMBRE_FILTRO[filtroVistoHallazgos].toLowerCase();
		return `${totalHallazgos} ${totalHallazgos === 1 ? nombre.slice(0, -1) : nombre}`;
	}

	function textoVacioHallazgos(): string {
		switch (filtroVistoHallazgos) {
			case 'pendiente':
				return 'No hay hallazgos pendientes de revisar.';
			case 'revisada':
				return 'No hay hallazgos revisados.';
			case 'descartada':
				return 'No hay hallazgos descartados.';
			default:
				return 'El detector todavia no encontro nada raro en compras, carritos ni registros.';
		}
	}

	function textoVacioAnillosP(): string {
		switch (filtroVistoAnillosP) {
			case 'pendiente':
				return 'No hay anillos pendientes de revisar.';
			case 'revisada':
				return 'No hay anillos revisados.';
			case 'descartada':
				return 'No hay anillos descartados.';
			default:
				return 'Ningun anillo ni patron de resenas sigue activo en la ventana de 60 dias.';
		}
	}

	// ------------------------------------------------ casos agrupados
	/**
	 * Los casos de fraude (migracion 026, agrupador de Jose David). Un caso
	 * junta hallazgos de las otras tres pestanas cuando comparten cuentas y
	 * les pone puntaje y nivel. Los arma AgrupadorFraudeWorkerService cada 15
	 * minutos, asi que un hallazgo nuevo tarda hasta eso en salir aqui.
	 * GET /admin/fraude/casos, GET y PATCH /admin/fraude/casos/:id.
	 */
	type NivelCaso = 'informativo' | 'revisar' | 'prioritario' | 'casi_confirmado';
	type EstadoCaso = EstadoAlerta | 'confirmada';
	type FiltroEstadoCaso = 'todas' | EstadoCaso;
	type FiltroNivelCaso = 'todos' | NivelCaso;

	interface CasoResumen {
		id_caso_fraude: number;
		nivel: NivelCaso;
		puntaje: number;
		estado: EstadoCaso;
		reglas_cumplidas: string[];
		cantidad_evidencias: number;
		cantidad_cuentas: number;
		ultima_evidencia: string;
		fecha_creacion: string;
		fecha_actualizacion: string;
	}

	interface EvidenciaCaso {
		id_evidencia_caso_fraude: number;
		fuente: 'grafo' | 'eventos' | 'login' | 'elastic' | 'postgres';
		tipo: string;
		clave: string;
		/** numeric de PostgreSQL: puede llegar como texto. */
		puntos: number | string;
		metricas: Record<string, unknown>;
		ultima_evidencia: string;
	}

	interface CasoDetalle extends CasoResumen {
		motivo: string | null;
		cuentas: { id_usuario: string; usuario: string; es_nucleo: boolean }[];
		evidencia: EvidenciaCaso[];
	}

	interface CasosPaginados {
		casos: CasoResumen[];
		pagina: number;
		limite: number;
		total_casos: number;
		total_paginas: number;
	}

	const NOMBRE_NIVEL: Record<NivelCaso, string> = {
		informativo: 'Informativo',
		revisar: 'Revisar',
		prioritario: 'Prioritario',
		casi_confirmado: 'Casi confirmado'
	};

	const FILTROS_NIVEL_CASO: FiltroNivelCaso[] = ['todos', 'casi_confirmado', 'prioritario', 'revisar', 'informativo'];

	/** Pendientes primero: es lo que abre la pestana y lo que falta por mirar. */
	const FILTROS_ESTADO_CASO: FiltroEstadoCaso[] = ['pendiente', 'todas', 'revisada', 'confirmada', 'descartada'];

	const NOMBRE_FILTRO_CASO: Record<FiltroEstadoCaso, string> = {
		todas: 'Todos',
		pendiente: 'Pendientes',
		revisada: 'Revisados',
		confirmada: 'Confirmados',
		descartada: 'Descartados'
	};

	const NOMBRE_ESTADO_CASO: Record<EstadoCaso, string> = {
		pendiente: 'Pendiente',
		revisada: 'Revisado',
		confirmada: 'Confirmado',
		descartada: 'Descartado'
	};

	/** Lo que quiere decir cada regla, en corto. El texto largo esta en la tabla regla_casi_confirmado. */
	const QUE_ES_REGLA: Record<string, string> = {
		'R-CASI-1': 'Se califican entre si y compraron o se registraron desde la misma IP',
		'R-CASI-2': 'Recibieron resenas de cuentas con menos de una hora de vida',
		'R-CASI-3': 'Califico un producto y despues lo devolvio',
		'R-CASI-5': 'Califican juntas y compraron o se registraron desde la misma IP'
	};

	/** El nombre de cada fuente, el mismo de su pestana. */
	const NOMBRE_FUENTE: Record<EvidenciaCaso['fuente'], string> = {
		grafo: 'Resenas',
		eventos: 'Compras y navegacion',
		login: 'Intentos de entrada',
		elastic: 'Texto de las resenas',
		postgres: 'Compras canceladas'
	};

	function tipoDeEvidencia(e: EvidenciaCaso): string {
		// Las senales de texto (elastic) y las de compras canceladas (postgres)
		// son tipos de la misma lista que los anillos: salen en la pestana Resenas.
		if (e.fuente === 'grafo' || e.fuente === 'elastic' || e.fuente === 'postgres') {
			return NOMBRE_TIPO_ANILLO[e.tipo as TipoAnillo] ?? e.tipo;
		}
		if (e.fuente === 'eventos') return NOMBRE_TIPO_HALLAZGO[e.tipo as TipoHallazgo] ?? e.tipo;
		return QUE_PASO[e.tipo as TipoAlerta] ?? e.tipo;
	}

	/** Los numeros de la evidencia que valen la pena. Las listas (IPs, identificadores) se quedan en su pestana. */
	function datosEvidencia(e: EvidenciaCaso): string {
		return Object.entries(e.metricas ?? {})
			.filter(([k, v]) => !k.startsWith('id_') && (typeof v === 'number' || typeof v === 'string'))
			.map(([k, v]) => `${NOMBRE_DATO[k] ?? k.replace(/_/g, ' ')} ${typeof v === 'number' ? Math.round(v * 100) / 100 : v}`)
			.join(', ');
	}

	function puntos(valor: number | string): string {
		const n = Number(valor);
		return Number.isFinite(n) ? String(Math.round(n * 10) / 10) : '--';
	}

	let casos = $state<CasoResumen[]>([]);
	let filtroEstadoCasos = $state<FiltroEstadoCaso>('pendiente');
	let filtroVistoCasos = $state<FiltroEstadoCaso>('pendiente');
	let filtroNivelCasos = $state<FiltroNivelCaso>('todos');
	let paginaCasos = $state(1);
	let totalPaginasCasos = $state(0);
	let totalCasos = $state(0);
	let cargandoCasos = $state(false);
	let errorCasos = $state('');
	let pedidoCasos = 0;
	let casosPedidos = false;

	/** El detalle de cada caso abierto: se pide al desplegarlo y se guarda. */
	let detalleCaso = $state<Record<number, CasoDetalle | 'cargando' | 'error'>>({});
	let abiertoCaso = $state<number | null>(null);
	let marcandoCaso = $state<number | null>(null);
	/** El caso que esta pidiendo el motivo para descartarse, y lo escrito. */
	let descartandoCaso = $state<number | null>(null);
	let motivoCaso = $state('');
	let errorMarcarCaso = $state('');

	$effect(() => {
		if (pestanaFraude === 'casos' && !casosPedidos) {
			casosPedidos = true;
			void cargarCasos(1);
		}
	});

	async function cargarCasos(pagina: number) {
		const este = ++pedidoCasos;
		paginaCasos = pagina;
		cargandoCasos = true;
		errorCasos = '';

		const partes = [`pagina=${pagina}`, `limite=${POR_PAGINA}`];
		if (filtroEstadoCasos !== 'todas') partes.push(`estado=${filtroEstadoCasos}`);
		if (filtroNivelCasos !== 'todos') partes.push(`nivel=${filtroNivelCasos}`);

		const r = await pedir<CasosPaginados>(`/admin/fraude/casos?${partes.join('&')}`);

		if (este !== pedidoCasos) return;
		cargandoCasos = false;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			errorCasos = mensajeUtil(r);
			casos = [];
			return;
		}

		const p = r.payload;
		const lista = p.casos ?? [];

		if (lista.length === 0 && p.total_paginas > 0 && pagina > p.total_paginas) {
			void cargarCasos(p.total_paginas);
			return;
		}

		casos = lista;
		filtroVistoCasos = filtroEstadoCasos;
		paginaCasos = p.pagina;
		totalPaginasCasos = p.total_paginas;
		totalCasos = p.total_casos;
	}

	function cambiarFiltroEstadoCasos(f: FiltroEstadoCaso) {
		if (f === filtroEstadoCasos) return;
		filtroEstadoCasos = f;
		void cargarCasos(1);
	}

	function cambiarFiltroNivelCasos(n: FiltroNivelCaso) {
		if (n === filtroNivelCasos) return;
		filtroNivelCasos = n;
		void cargarCasos(1);
	}

	async function traerDetalleCaso(id: number) {
		detalleCaso[id] = 'cargando';
		const r = await pedir<CasoDetalle>(`/admin/fraude/casos/${id}`);
		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}
		detalleCaso[id] = r.ok && r.payload ? r.payload : 'error';
	}

	function alternarDetalleCaso(c: CasoResumen) {
		if (abiertoCaso === c.id_caso_fraude) {
			abiertoCaso = null;
			return;
		}
		abiertoCaso = c.id_caso_fraude;
		// Se vuelve a pedir cada vez que se abre: el worker lo pudo recalcular.
		void traerDetalleCaso(c.id_caso_fraude);
	}

	function pedirMotivo(c: CasoResumen) {
		descartandoCaso = c.id_caso_fraude;
		motivoCaso = '';
		errorMarcarCaso = '';
	}

	async function marcarCaso(c: CasoResumen, estado: 'revisada' | 'confirmada' | 'descartada') {
		const motivo = motivoCaso.trim();
		if (estado === 'descartada' && motivo === '') {
			errorMarcarCaso = 'Escribe por que se descarta. Si llega evidencia nueva, el caso se reabre solo.';
			return;
		}
		marcandoCaso = c.id_caso_fraude;
		errorMarcarCaso = '';
		const r = await pedir<CasoDetalle>(
			`/admin/fraude/casos/${c.id_caso_fraude}`,
			conJson('PATCH', estado === 'descartada' ? { estado, motivo } : { estado })
		);
		marcandoCaso = null;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			// Un 409 quiere decir que otro admin ya lo movio: se recarga para ver como quedo.
			errorCasos = mensajeUtil(r);
			void cargarCasos(paginaCasos);
			return;
		}

		descartandoCaso = null;
		motivoCaso = '';
		detalleCaso[c.id_caso_fraude] = r.payload;
		if (filtroEstadoCasos !== 'todas' && filtroEstadoCasos !== estado) {
			casos = casos.filter((x) => x.id_caso_fraude !== c.id_caso_fraude);
			totalCasos = Math.max(0, totalCasos - 1);
		} else {
			casos = casos.map((x) => (x.id_caso_fraude === c.id_caso_fraude ? r.payload! : x));
		}
	}

	function etiquetaCasos(): string {
		if (filtroVistoCasos === 'todas') {
			return `${totalCasos} ${totalCasos === 1 ? 'caso' : 'casos'}`;
		}
		const nombre = NOMBRE_FILTRO_CASO[filtroVistoCasos].toLowerCase();
		return `${totalCasos} ${totalCasos === 1 ? nombre.slice(0, -1) : nombre}`;
	}

	function textoVacioCasos(): string {
		switch (filtroVistoCasos) {
			case 'pendiente':
				return 'No hay casos pendientes de revisar.';
			case 'revisada':
				return 'No hay casos revisados.';
			case 'confirmada':
				return 'No hay casos confirmados.';
			case 'descartada':
				return 'No hay casos descartados.';
			default:
				// Desde de5de2a el agrupador corre tambien al arrancar el backend, no
				// solo cada 15 minutos.
				return 'Todavia no hay casos. El sistema los arma al arrancar y cada 15 minutos con lo que encuentran las otras pestanas.';
		}
	}
</script>

<!--
	Intentos de entrada sospechosos. Tarjeta aparte, con su titulo y su carga:
	no espera a los anillos ni los hace esperar. Ver el bloque "intentos de
	entrada" del script.
-->
<div class="pestanas pestanas-fraude" role="tablist" aria-label="Vista de fraude">
	<button
		type="button"
		role="tab"
		class="pestana"
		class:elegida={pestanaFraude === 'casos'}
		aria-selected={pestanaFraude === 'casos'}
		onclick={() => (pestanaFraude = 'casos')}
	>
		Casos
	</button>
	<button
		type="button"
		role="tab"
		class="pestana"
		class:elegida={pestanaFraude === 'entradas'}
		aria-selected={pestanaFraude === 'entradas'}
		onclick={() => (pestanaFraude = 'entradas')}
	>
		Intentos de entrada
	</button>
	<button
		type="button"
		role="tab"
		class="pestana"
		class:elegida={pestanaFraude === 'resenas'}
		aria-selected={pestanaFraude === 'resenas'}
		onclick={() => (pestanaFraude = 'resenas')}
	>
		Resenas en anillo
	</button>
	<button
		type="button"
		role="tab"
		class="pestana"
		class:elegida={pestanaFraude === 'eventos'}
		aria-selected={pestanaFraude === 'eventos'}
		onclick={() => (pestanaFraude = 'eventos')}
	>
		Compras y navegacion
	</button>
</div>

<!-- Las vistas siguen montadas y solo se esconde la que no toca: asi
     cada una conserva su filtro, su pagina y no vuelve a pedir al cambiar. -->
<div hidden={pestanaFraude !== 'casos'}>
<section class="fraude" aria-labelledby="titulo-casos">
	<div class="titulo">
		<h2 id="titulo-casos">Casos de fraude</h2>
		{#if !errorCasos && !(cargandoCasos && casos.length === 0)}
			<span
				class="etiqueta"
				class:limpio={totalCasos === 0 || (filtroVistoCasos !== 'pendiente' && filtroVistoCasos !== 'todas')}
			>
				{etiquetaCasos()}
			</span>
		{/if}
		<div class="acciones">
			<button type="button" onclick={() => cargarCasos(paginaCasos)} disabled={cargandoCasos}>
				Volver a mirar
			</button>
		</div>
	</div>

	<p class="intro">
		Un caso junta lo que encuentran las otras pestanas cuando toca a las mismas cuentas, y le pone
		un puntaje. Mas puntos si viene de varias fuentes y si es reciente. Casi confirmado quiere decir
		que cumple una regla que casi nunca tiene otra explicacion. Se recalculan al arrancar y cada 15 minutos.
	</p>

	<div class="filtros-alertas">
		<div class="pestanas" role="group" aria-label="Filtrar casos por estado">
			{#each FILTROS_ESTADO_CASO as f (f)}
				<button
					type="button"
					class="pestana"
					class:elegida={filtroEstadoCasos === f}
					aria-pressed={filtroEstadoCasos === f}
					onclick={() => cambiarFiltroEstadoCasos(f)}
				>
					{NOMBRE_FILTRO_CASO[f]}
				</button>
			{/each}
		</div>

		<label class="filtro-tipo">
			<span class="gris">Nivel</span>
			<select value={filtroNivelCasos} onchange={(e) => cambiarFiltroNivelCasos(e.currentTarget.value as FiltroNivelCaso)}>
				{#each FILTROS_NIVEL_CASO as n (n)}
					<option value={n}>{n === 'todos' ? 'Todos' : NOMBRE_NIVEL[n]}</option>
				{/each}
			</select>
		</label>
	</div>

	{#if errorCasos}
		<div class="fallo" role="alert">
			<p>{errorCasos}</p>
			<button type="button" onclick={() => cargarCasos(paginaCasos)}>Reintentar</button>
		</div>
	{:else if cargandoCasos && casos.length === 0}
		<p class="gris">Buscando casos...</p>
	{:else if casos.length === 0}
		<div class="limpio-caja">
			<p>{textoVacioCasos()}</p>
		</div>
	{:else}
		<ul class="lista-alertas" class:esperando={cargandoCasos} aria-busy={cargandoCasos}>
			{#each casos as c (c.id_caso_fraude)}
				{@const detalle = detalleCaso[c.id_caso_fraude]}
				{@const desplegado = abiertoCaso === c.id_caso_fraude}
				<li class="alerta">
					<div class="alerta-cabeza">
						<span class="nivel nivel-{c.nivel}">{NOMBRE_NIVEL[c.nivel] ?? c.nivel}</span>
						<span class="que-paso">Caso {c.id_caso_fraude}, {puntos(c.puntaje)} puntos</span>
						<span class="estado estado-{c.estado}">{NOMBRE_ESTADO_CASO[c.estado] ?? c.estado}</span>
					</div>

					{#if c.reglas_cumplidas.length > 0}
						<ul class="reglas">
							{#each c.reglas_cumplidas as regla (regla)}
								<li><span class="clave">{regla}</span> {QUE_ES_REGLA[regla] ?? ''}</li>
							{/each}
						</ul>
					{/if}

					<dl class="datos">
						<div>
							<dt>Cuentas</dt>
							<dd>{c.cantidad_cuentas}</dd>
						</div>
						<div>
							<dt>Evidencias</dt>
							<dd>{c.cantidad_evidencias}</dd>
						</div>
						<div>
							<dt>Ultima evidencia</dt>
							<dd>{fecha(c.ultima_evidencia)}</dd>
						</div>
						<div>
							<dt>Armado</dt>
							<dd>{fecha(c.fecha_creacion)}</dd>
						</div>
					</dl>

					<div class="triage">
						<button type="button" class="revisar" onclick={() => alternarDetalleCaso(c)}>
							{desplegado ? 'Ocultar detalle' : 'Ver cuentas y evidencia'}
						</button>
						{#if c.estado === 'pendiente'}
							<button
								type="button"
								class="revisar"
								disabled={marcandoCaso === c.id_caso_fraude}
								onclick={() => marcarCaso(c, 'revisada')}
							>
								Marcar revisado
							</button>
							<button
								type="button"
								class="confirmar"
								disabled={marcandoCaso === c.id_caso_fraude}
								onclick={() => marcarCaso(c, 'confirmada')}
							>
								Confirmar fraude
							</button>
							<button
								type="button"
								class="descartar"
								disabled={marcandoCaso === c.id_caso_fraude}
								onclick={() => pedirMotivo(c)}
							>
								Descartar
							</button>
						{/if}
					</div>

					{#if descartandoCaso === c.id_caso_fraude}
						<div class="motivo">
							<label>
								<span class="gris">Por que se descarta</span>
								<textarea bind:value={motivoCaso} rows="2" maxlength="500"></textarea>
							</label>
							{#if errorMarcarCaso}
								<p class="error-motivo" role="alert">{errorMarcarCaso}</p>
							{/if}
							<div class="triage sin-borde">
								<button
									type="button"
									class="descartar"
									disabled={marcandoCaso === c.id_caso_fraude}
									onclick={() => marcarCaso(c, 'descartada')}
								>
									Descartar el caso
								</button>
								<button type="button" class="descartar" onclick={() => (descartandoCaso = null)}>
									Cancelar
								</button>
							</div>
						</div>
					{/if}

					{#if desplegado}
						<div class="detalle">
							{#if detalle === 'cargando' || detalle === undefined}
								<p class="gris">Trayendo el caso...</p>
							{:else if detalle === 'error'}
								<p class="gris">No se pudo traer el detalle del caso.</p>
							{:else}
								{#if detalle.motivo}
									<p class="gris">Motivo, {detalle.motivo}</p>
								{/if}
								<dl class="datos">
									<div>
										<dt>Nucleo</dt>
										<dd class="afectadas">
											{#each detalle.cuentas.filter((x) => x.es_nucleo) as cu (cu.id_usuario)}
												<span class="cuenta-con-accion">
													<span class="clave">{cu.usuario}</span>
													<BloquearCuenta idUsuario={cu.id_usuario} usuario={cu.usuario} {alExpirarSesion} />
												</span>
											{:else}
												<span class="gris">Ninguna</span>
											{/each}
										</dd>
									</div>
									<div>
										<dt>Periferia</dt>
										<dd class="afectadas">
											{#each detalle.cuentas.filter((x) => !x.es_nucleo) as cu (cu.id_usuario)}
												<span class="clave">{cu.usuario}</span>
											{:else}
												<span class="gris">Ninguna</span>
											{/each}
										</dd>
									</div>
								</dl>
								<p class="gris nota-nucleo">
									Nucleo son las cuentas que salen en dos o mas evidencias del caso, o en una fuerte
									como un ciclo. Periferia, las que salen una sola vez.
								</p>
								<ul class="evidencias">
									{#each detalle.evidencia as e (e.id_evidencia_caso_fraude)}
										<li>
											<span class="fuente">{NOMBRE_FUENTE[e.fuente] ?? e.fuente}</span>
											<span>{tipoDeEvidencia(e)}</span>
											<span class="gris">{puntos(e.puntos)} puntos</span>
											{#if datosEvidencia(e)}
												<span class="gris">{datosEvidencia(e)}</span>
											{/if}
										</li>
									{/each}
								</ul>
							{/if}
						</div>
					{/if}
				</li>
			{/each}
		</ul>

		{#if totalPaginasCasos > 1}
			<nav class="paginacion" aria-label="Paginas de casos">
				<button
					type="button"
					onclick={() => cargarCasos(paginaCasos - 1)}
					disabled={paginaCasos <= 1 || cargandoCasos}
				>
					Anterior
				</button>
				<span class="cuantas">
					Pagina {paginaCasos} de {totalPaginasCasos}
					<span class="menor">({etiquetaCasos()})</span>
				</span>
				<button
					type="button"
					onclick={() => cargarCasos(paginaCasos + 1)}
					disabled={paginaCasos >= totalPaginasCasos || cargandoCasos}
				>
					Siguiente
				</button>
			</nav>
		{/if}
	{/if}
</section>
</div>

<div hidden={pestanaFraude !== 'entradas'}>
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
		Nueve senales vigilan las entradas al portal: cuatro contadores de Redis en el propio login y
		cinco consultas contra el historial completo en Elasticsearch (toma de cuenta, viaje imposible
		y tres patrones repartidos en 24 horas). Cuando una cruza su limite queda aqui una alerta para
		que alguien la mire. Nadie se bloquea solo: esto avisa, no frena.
	</p>

	<div class="filtros-alertas">
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

		<label class="filtro-tipo">
			<span class="gris">Tipo</span>
			<select
				value={filtroTipoAlertas}
				onchange={(e) => cambiarFiltroTipo(e.currentTarget.value as FiltroTipo)}
			>
				<option value="todos">{NOMBRE_FILTRO_TIPO.todos}</option>
				{#each GRUPOS_TIPO as g (g.nombre)}
					<optgroup label={g.nombre}>
						{#each g.tipos as t (t)}
							<option value={t}>{NOMBRE_FILTRO_TIPO[t]}</option>
						{/each}
					</optgroup>
				{/each}
			</select>
		</label>
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
				{@const ids = vistosEnDetalle(a)}
				{@const vistas = entero(a.detalle?.cuentas_distintas ?? a.detalle?.ips_distintas)}
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
						{#if a.cuentas_afectadas.length > 0}
							<div>
								<dt>{a.cuentas_afectadas.length === 1 ? 'Cuenta afectada' : 'Cuentas afectadas'}</dt>
								<dd class="afectadas">
									{#each a.cuentas_afectadas as c (c.id_usuario)}
										<span class="cuenta-con-accion">
										<span class="clave afectada" title={c.fecha_lectura ? `Leida ${fecha(c.fecha_lectura)}` : 'No leida por esta cuenta'}>
											{c.usuario}
											<span class="punto-lectura" class:leida={c.fecha_lectura !== null}></span>
										</span>
										<BloquearCuenta idUsuario={c.id_usuario} usuario={c.usuario} {alExpirarSesion} />
										</span>
									{/each}
								</dd>
							</div>
						{/if}
						<div>
							<dt>Lo que se vio</dt>
							<dd>{evidencia(a)}</dd>
						</div>
						{#if a.tipo_alerta === 'viaje_imposible'}
							<div>
								<dt>De</dt>
								<dd>{ubicacion(a.detalle?.ubicacion_anterior)}</dd>
							</div>
							<div>
								<dt>A</dt>
								<dd>{ubicacion(a.detalle?.ubicacion_actual)}</dd>
							</div>
						{/if}
						<div>
							<dt>Veces</dt>
							<dd>{veces(a)}</dd>
						</div>
						<div>
							<dt>Ultima vez</dt>
							<dd>{fecha(a.ventana_inicio)}</dd>
						</div>
					</dl>

					{#if ids.length > 0}
						<div class="probadas">
							<h4>
								{tituloVistos(a)}{vistas !== null && vistas > ids.length
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

					{#if a.estado === 'pendiente'}
						<div class="triage">
							<button
								type="button"
								class="revisar"
								disabled={marcandoAlerta === a.id_alerta_fraude}
								onclick={() => marcarAlerta(a, 'revisada')}
							>
								Marcar revisada
							</button>
							<button
								type="button"
								class="descartar"
								disabled={marcandoAlerta === a.id_alerta_fraude}
								onclick={() => marcarAlerta(a, 'descartada')}
							>
								Descartar
							</button>
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
</div>

<!--
	Manipulacion de resenas: los anillos mutuo/ciclo/reiterado que detecto y
	guardo AnillosDetectorService en anillo_fraude, con estado para que un
	admin los trabaje como cola. Ver el bloque "manipulacion de resenas" del
	script para el porque del panel EN VIVO que este reemplazo el 2026-09-18.
-->
<div hidden={pestanaFraude !== 'eventos'}>
<section class="fraude" aria-labelledby="titulo-hallazgos">
	<div class="titulo">
		<h2 id="titulo-hallazgos">Compras y navegacion sospechosas</h2>
		{#if !errorHallazgos && !(cargandoHallazgos && hallazgos.length === 0)}
			<span
				class="etiqueta"
				class:limpio={totalHallazgos === 0 ||
					filtroVistoHallazgos === 'revisada' ||
					filtroVistoHallazgos === 'descartada'}
			>
				{etiquetaHallazgos()}
			</span>
		{/if}
		<div class="acciones">
			<button type="button" onclick={() => cargarHallazgos(paginaHallazgos)} disabled={cargandoHallazgos}>
				Volver a mirar
			</button>
		</div>
	</div>

	<p class="intro">
		Lo que se ve en los eventos de la tienda y no en las resenas. Compras muy seguidas, varias
		cuentas desde la misma IP, carritos que apartan sin comprar, devoluciones en serie o cuentas
		creadas en lote. Una vez al dia el sistema revisa los ultimos 30 dias en ClickHouse y guarda
		lo que encuentra para revisarlo aqui.
	</p>

	<div class="filtros-alertas">
		<div class="pestanas" role="group" aria-label="Filtrar hallazgos por estado">
			{#each FILTROS as f (f)}
				<button
					type="button"
					class="pestana"
					class:elegida={filtroEstadoHallazgos === f}
					aria-pressed={filtroEstadoHallazgos === f}
					onclick={() => cambiarFiltroEstadoHallazgos(f)}
				>
					{NOMBRE_FILTRO[f]}
				</button>
			{/each}
		</div>

		<label class="filtro-tipo">
			<span class="gris">Tipo</span>
			<select
				value={filtroTipoHallazgos}
				onchange={(e) => cambiarFiltroTipoHallazgos(e.currentTarget.value as FiltroTipoHallazgo)}
			>
				{#each FILTROS_TIPO_HALLAZGO as t (t)}
					<option value={t}>{t === 'todos' ? 'Todos' : NOMBRE_TIPO_HALLAZGO[t]}</option>
				{/each}
			</select>
		</label>
	</div>

	{#if errorHallazgos}
		<div class="fallo" role="alert">
			<p>{errorHallazgos}</p>
			<button type="button" onclick={() => cargarHallazgos(paginaHallazgos)}>Reintentar</button>
		</div>
	{:else if cargandoHallazgos && hallazgos.length === 0}
		<p class="gris">Buscando hallazgos...</p>
	{:else if hallazgos.length === 0}
		<div class="limpio-caja">
			<p>{textoVacioHallazgos()}</p>
		</div>
	{:else}
		<ul class="lista-alertas" class:esperando={cargandoHallazgos} aria-busy={cargandoHallazgos}>
			{#each hallazgos as h (h.id_hallazgo_evento_fraude)}
				<li class="alerta">
					<div class="alerta-cabeza">
						<span class="tipo">{NOMBRE_TIPO_HALLAZGO[h.tipo] ?? h.tipo}</span>
						<span class="estado estado-{h.estado}">{NOMBRE_ESTADO[h.estado] ?? h.estado}</span>
					</div>

					<p class="gris">{QUE_ES_HALLAZGO[h.tipo] ?? ''}</p>

					<dl class="datos">
						{#if h.cuentas.length > 0}
							<div>
								<dt>{h.cuentas.length === 1 ? 'Cuenta' : 'Cuentas'}</dt>
								<dd class="afectadas">
									{#each h.cuentas as c (c.id_usuario)}
										<span class="cuenta-con-accion">
											<span class="clave">{c.usuario}</span>
											<BloquearCuenta idUsuario={c.id_usuario} usuario={c.usuario} {alExpirarSesion} />
										</span>
									{/each}
								</dd>
							</div>
						{/if}
						{#if CLAVE_VISIBLE[h.tipo]}
							<div>
								<dt>{CLAVE_VISIBLE[h.tipo]}</dt>
								<dd class="clave">{h.clave}</dd>
							</div>
						{/if}
						{#if h.id_producto_mongo != null}
							<div>
								<dt>Producto</dt>
								<dd><a href="/producto/{h.id_producto_mongo}" target="_blank" rel="noopener">Ver producto</a></dd>
							</div>
						{/if}
						{#each datosHallazgo(h) as d (d.nombre)}
							<div>
								<dt>{d.nombre}</dt>
								<dd>{d.valor}</dd>
							</div>
						{/each}
						{#if h.contador > 1}
							<div>
								<dt>Veces detectado</dt>
								<dd>{h.contador}</dd>
							</div>
						{/if}
						<div>
							<dt>Detectado</dt>
							<dd>{fecha(h.fecha_creacion)}</dd>
						</div>
					</dl>

					{#if h.estado === 'pendiente'}
						<div class="triage">
							<button
								type="button"
								class="revisar"
								disabled={marcandoHallazgo === h.id_hallazgo_evento_fraude}
								onclick={() => marcarHallazgo(h, 'revisada')}
							>
								Marcar revisado
							</button>
							<button
								type="button"
								class="descartar"
								disabled={marcandoHallazgo === h.id_hallazgo_evento_fraude}
								onclick={() => marcarHallazgo(h, 'descartada')}
							>
								Descartar
							</button>
						</div>
					{/if}
				</li>
			{/each}
		</ul>

		{#if totalPaginasHallazgos > 1}
			<nav class="paginacion" aria-label="Paginas de hallazgos">
				<button
					type="button"
					onclick={() => cargarHallazgos(paginaHallazgos - 1)}
					disabled={paginaHallazgos <= 1 || cargandoHallazgos}
				>
					Anterior
				</button>
				<span class="cuantas">
					Pagina {paginaHallazgos} de {totalPaginasHallazgos}
					<span class="menor">({etiquetaHallazgos()})</span>
				</span>
				<button
					type="button"
					onclick={() => cargarHallazgos(paginaHallazgos + 1)}
					disabled={paginaHallazgos >= totalPaginasHallazgos || cargandoHallazgos}
				>
					Siguiente
				</button>
			</nav>
		{/if}
	{/if}
</section>
</div>

<div hidden={pestanaFraude !== 'resenas'}>
<section class="fraude" aria-labelledby="titulo-anillos-p">
	<div class="titulo">
		<h2 id="titulo-anillos-p">Manipulacion de resenas</h2>
		{#if !errorAnillosP && !(cargandoAnillosP && anillosPersistidos.length === 0)}
			<span
				class="etiqueta"
				class:limpio={totalAnillosP === 0 ||
					filtroVistoAnillosP === 'revisada' ||
					filtroVistoAnillosP === 'descartada'}
			>
				{etiquetaAnillosP()}
			</span>
		{/if}
		<div class="acciones">
			<button
				type="button"
				onclick={() => cargarAnillosPersistidos(paginaAnillosP)}
				disabled={cargandoAnillosP}
			>
				Volver a mirar
			</button>
		</div>
	</div>

	<p class="intro">
		Grupos de cuentas cuyo patron de calificaciones no se explica por el uso normal de la
		tienda. Se califican entre si, se devuelven la nota en minutos, califican juntas, o
		inflan a un vendedor con cuentas recien creadas.
		Cada 15 minutos, y de inmediato tras cada resena nueva, un worker recorre el grafo de
		relaciones entre cuentas, resenas y productos sobre una ventana de 60 dias y guarda lo que
		encuentra, con estado propio para que un admin lo trabaje como una cola. Cuentas que
		comparten direccion todavia no se detecta.
	</p>

	<!--
		De cuando esta al dia el grafo que alimenta esta deteccion. Existe por
		una razon concreta que este proyecto tuvo escrito como pendiente durante
		dias: el grafo se llena por una cola, y un panel que no lo dice ensena un
		analisis correcto sobre datos que podian estar incompletos SIN AVISAR.
	-->
	{#if conciliacion}
		<p class="sincro" class:atrasado={!conciliacion.cuadra}>
			{#if conciliacion.cuadra}
				Grafo al dia con PostgreSQL, sincronizado {hace(conciliacion.ultima_sincronizacion)}.
			{:else}
				<strong>Esta lista puede estar incompleta.</strong>
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
			{#if conciliacion.cola && conciliacion.cola.apartados > 0}
				<strong>
					Hay {conciliacion.cola.apartados}
					{conciliacion.cola.apartados === 1 ? 'cambio' : 'cambios'} que fallaron y ya no se
					reintentan.
				</strong>
			{/if}
		</p>
	{/if}

	<div class="filtros-alertas">
		<div class="pestanas" role="group" aria-label="Filtrar anillos por estado">
			{#each FILTROS as f (f)}
				<button
					type="button"
					class="pestana"
					class:elegida={filtroEstadoAnillosP === f}
					aria-pressed={filtroEstadoAnillosP === f}
					onclick={() => cambiarFiltroEstadoAnillosP(f)}
				>
					{NOMBRE_FILTRO[f]}
				</button>
			{/each}
		</div>

		<label class="filtro-tipo">
			<span class="gris">Tipo</span>
			<select
				value={filtroTipoAnillosP}
				onchange={(e) => cambiarFiltroTipoAnillosP(e.currentTarget.value as FiltroTipoAnillo)}
			>
				{#each FILTROS_TIPO_ANILLO as t (t)}
					<option value={t}>{NOMBRE_FILTRO_TIPO_ANILLO[t]}</option>
				{/each}
			</select>
		</label>
	</div>

	{#if errorAnillosP}
		<div class="fallo" role="alert">
			<p>{errorAnillosP}</p>
			<button type="button" onclick={() => cargarAnillosPersistidos(paginaAnillosP)}>
				Reintentar
			</button>
		</div>
	{:else if cargandoAnillosP && anillosPersistidos.length === 0}
		<p class="gris">Buscando anillos guardados...</p>
	{:else if anillosPersistidos.length === 0}
		<div class="limpio-caja">
			<p>{textoVacioAnillosP()}</p>
		</div>
	{:else}
		<ul class="lista-alertas" class:esperando={cargandoAnillosP} aria-busy={cargandoAnillosP}>
			{#each anillosPersistidos as a (a.id_anillo_fraude)}
				{@const detalle = detalleAnilloP[a.id_anillo_fraude]}
				{@const desplegado = abiertoAnilloP === a.id_anillo_fraude}
				<li class="alerta">
					<div class="alerta-cabeza">
						<span class="tipo tipo-{a.tipo}">{NOMBRE_TIPO_ANILLO[a.tipo]}</span>
						<span class="estado estado-{a.estado}">{NOMBRE_ESTADO[a.estado] ?? a.estado}</span>
					</div>

					<dl class="datos">
						<div>
							<dt>Cuentas</dt>
							<dd class="afectadas">
								{#each a.cuentas as c (c.id_usuario)}
									<span class="cuenta-con-accion">
										<span class="clave">{c.usuario}</span>
										<BloquearCuenta idUsuario={c.id_usuario} usuario={c.usuario} {alExpirarSesion} />
									</span>
								{/each}
							</dd>
						</div>
						<div>
							<dt>Resenas involucradas</dt>
							<dd>{a.resenas.length}</dd>
						</div>
						<div>
							<dt>Visto por ultima vez</dt>
							<dd>{fecha(a.ultima_vez_confirmado_activo)}</dd>
						</div>
						<div>
							<dt>Detectado</dt>
							<dd>{fecha(a.fecha_creacion)}</dd>
						</div>
					</dl>

					<div class="triage">
						<button type="button" class="revisar" onclick={() => alternarDetalleAnilloP(a)}>
							{desplegado ? 'Ocultar detalle' : 'Ver detalle real'}
						</button>
						{#if a.estado === 'pendiente'}
							<button
								type="button"
								class="revisar"
								disabled={marcandoAnilloP === a.id_anillo_fraude}
								onclick={() => marcarAnilloPersistido(a, 'revisada')}
							>
								Marcar revisado
							</button>
							<button
								type="button"
								class="descartar"
								disabled={marcandoAnilloP === a.id_anillo_fraude}
								onclick={() => marcarAnilloPersistido(a, 'descartada')}
							>
								Descartar
							</button>
						{/if}
					</div>

					{#if desplegado}
						<div class="detalle">
							{#if detalle === 'cargando' || detalle === undefined}
								<p class="gris">Consultando el grafo...</p>
							{:else if detalle === 'error'}
								<p class="gris">No se pudo traer el detalle del grafo.</p>
							{:else}
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
											{#each detalle.resenas as resena (resena.id_resena)}
												<tr>
													<td class="fuerte" title={resena.correo_autor}>{resena.autor}</td>
													<td title={resena.correo_vendedor}>{resena.vendedor}</td>
													<td>{resena.producto}</td>
													<td class="nota">{resena.calificacion}</td>
													<td class="gris">{fecha(resena.fecha)}</td>
												</tr>
											{/each}
										</tbody>
									</table>
								</div>
							{/if}
						</div>
					{/if}
				</li>
			{/each}
		</ul>

		{#if totalPaginasAnillosP > 1}
			<nav class="paginacion" aria-label="Paginas de anillos guardados">
				<button
					type="button"
					onclick={() => cargarAnillosPersistidos(paginaAnillosP - 1)}
					disabled={paginaAnillosP <= 1 || cargandoAnillosP}
				>
					Anterior
				</button>

				<span class="cuantas">
					Pagina {paginaAnillosP} de {totalPaginasAnillosP}
					<span class="menor">({etiquetaAnillosP()})</span>
				</span>

				<button
					type="button"
					onclick={() => cargarAnillosPersistidos(paginaAnillosP + 1)}
					disabled={paginaAnillosP >= totalPaginasAnillosP || cargandoAnillosP}
				>
					Siguiente
				</button>
			</nav>
		{/if}
	{/if}
</section>
</div>

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

	.acciones button:hover {
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

	/* -- estados que no son la lista -- */

	.limpio-caja {
		padding: 22px 24px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.limpio-caja p {
		max-width: 620px;
		margin-bottom: 10px;
		font-size: var(--f-base);
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

	/* -- el tipo de anillo, y el detalle desplegado de una fila -- */

	.tipo {
		padding: 3px 10px;
		font-size: var(--f-sm);
		border-radius: 999px;
		white-space: nowrap;
	}

	.tipo-ciclo,
	.tipo-reiterado,
	.tipo-coordinados,
	.tipo-reputacion_expres,
	.tipo-anillo_de_texto,
	.tipo-resenas_parecidas_vendedor,
	.tipo-resenas_parecidas_producto,
	.tipo-resena_positiva_cancelada {
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
	}

	.tipo-mutuo,
	.tipo-satelites,
	.tipo-persistente,
	.tipo-anillo_en_el_tiempo,
	.tipo-resenas_repetidas,
	.tipo-notas_incoherentes_cuenta,
	.tipo-notas_incoherentes_producto,
	.tipo-notas_incoherentes_vendedor,
	.tipo-resenas_negativas_canceladas_vendedor {
		color: var(--indigo);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
	}

	.detalle {
		padding: 4px 18px 20px;
		border-top: 1px solid var(--linea);
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

	.filtros-alertas {
		display: flex;
		align-items: center;
		justify-content: space-between;
		flex-wrap: wrap;
		gap: var(--e3);
	}

	.filtro-tipo {
		display: flex;
		align-items: center;
		gap: var(--e2);
		margin-bottom: var(--e4);
		font-size: var(--f-ms);
	}

	.filtro-tipo select {
		padding: 0.3rem 0.5rem;
		font-family: inherit;
		font-size: var(--f-ms);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
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

	/* La cuenta y su boton de bloquear van juntos, en una sola pieza que no se parte. */
	.cuenta-con-accion {
		display: inline-flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 6px;
	}

	.afectadas {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e1);
	}

	.afectada {
		display: inline-flex;
		align-items: center;
		gap: 5px;
	}

	/* Un puntito, no un texto: nueve cuentas afectadas con "leida"/"no leida"
	   escrito al lado de cada una pesaria mas de lo que ayuda. El title de
	   `.afectada` dice la fecha exacta a quien lo necesite. */
	.punto-lectura {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--rojo);
	}

	.punto-lectura.leida {
		background: var(--verde, #2f8f4e);
	}

	.triage {
		display: flex;
		gap: var(--e2);
		margin-top: var(--e3);
		padding-top: var(--e3);
		border-top: 1px solid var(--linea);
	}

	.triage button {
		padding: 6px 14px;
		font-family: inherit;
		font-size: var(--f-sm);
		background: none;
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.triage .revisar {
		color: var(--indigo);
		border: 1px solid var(--indigo);
	}

	.triage .descartar {
		color: var(--gris);
		border: 1px solid var(--linea);
	}

	/* Confirmar es lo unico que habilita sanciones: en rojo, para que no se pulse por costumbre. */
	.triage .confirmar {
		color: var(--rojo);
		border: 1px solid var(--rojo);
	}

	.triage.sin-borde {
		margin-top: var(--e2);
		padding-top: 0;
		border-top: none;
	}

	/* El nivel del caso. Casi confirmado relleno, porque es lo primero que hay que mirar. */
	.nivel {
		padding: 3px 10px;
		font-size: var(--f-sm);
		border-radius: 999px;
		white-space: nowrap;
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
	}

	.nivel-casi_confirmado {
		color: #fff;
		background: var(--rojo);
		border-color: var(--rojo);
	}

	.nivel-prioritario {
		color: var(--rojo);
		background: var(--off);
		border-color: var(--rojo);
	}

	.nivel-revisar {
		color: var(--indigo);
		background: var(--indigo-cl);
		border-color: var(--indigo);
	}

	.estado-confirmada {
		color: #fff;
		background: var(--rojo);
		border-color: var(--rojo);
	}

	.reglas {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		margin: var(--e3) 0 0;
		padding: 0;
		list-style: none;
		font-size: var(--f-sm);
		color: var(--texto);
	}

	.motivo {
		margin-top: var(--e3);
	}

	.motivo label {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
	}

	.motivo textarea {
		width: 100%;
		padding: 8px 10px;
		font-family: inherit;
		font-size: var(--f-sm);
		color: var(--texto);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		resize: vertical;
	}

	.error-motivo {
		margin: var(--e1) 0 0;
		font-size: var(--f-sm);
		color: var(--rojo);
	}

	.nota-nucleo {
		margin: var(--e2) 0;
		font-size: var(--f-xs);
	}

	.evidencias {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
		margin: 0;
		padding: 0;
		list-style: none;
		font-size: var(--f-sm);
	}

	.evidencias li {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e2);
		align-items: baseline;
		padding-top: var(--e2);
		border-top: 1px solid var(--linea);
	}

	.fuente {
		font-size: var(--f-xs);
		color: var(--gris);
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}

	.triage button:disabled {
		opacity: 0.5;
		cursor: default;
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
