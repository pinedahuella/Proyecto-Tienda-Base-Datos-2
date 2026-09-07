<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';

	/**
	 * Panel de tendencias y de fraude por IP. Es la pantalla de la familia
	 * COLUMNAR del proyecto -- ClickHouse -- y es la unica que mira EVENTOS y no
	 * filas de negocio.
	 *
	 * La diferencia con PanelFraude, que es su hermano, importa para entender
	 * por que existen las dos:
	 *
	 *   - PanelFraude recorre el GRAFO. Sabe que dos cuentas se califican en
	 *     circulo, y no sabe desde donde se conectan.
	 *   - Esta pantalla lee el RASTRO. No sabe quien califica a quien, y si sabe
	 *     que cinco cuentas entran desde la misma IP la misma tarde.
	 *
	 * Ninguna de las dos senales prueba nada sola. Juntas si.
	 *
	 *
	 * LAS DOS RUTAS
	 * ---------------------------------------------------------------
	 *   GET /admin/eventos/tendencias?dias=7&lote=real
	 *   GET /admin/eventos/fraude/ip?dias=30
	 *
	 * El backend es de Jose David y aqui no se toca. Al escribir esta pantalla
	 * las dos rutas TODAVIA NO EXISTEN, asi que el servidor contesta 404 y
	 * `mensajeUtil` lo traduce a "Esa opcion todavia no esta disponible en el
	 * servidor.". Ese texto es lo que sale, tal cual, y la pantalla no se rompe
	 * ni se inventa filas para tapar el hueco. El dia que las rutas se publiquen
	 * este archivo funciona sin tocar una linea.
	 *
	 * Por eso el 404 tiene caja propia y NO sale en la caja roja de fallo. Una
	 * ruta que aun no se escribio no es un error del sistema, y pintarla en rojo
	 * manda a alguien a buscar un problema que no hay.
	 *
	 *
	 * # ====================================================================
	 * # POR QUE HAY UN SELECTOR DE LOTE, Y POR QUE ES LO MAS IMPORTANTE DE
	 * # ESTA PANTALLA
	 * # ====================================================================
	 *
	 * Las tablas de ClickHouse llevan una columna `lote` con dos valores,
	 * 'real' y 'generado'. No es un adorno del esquema, sale de un dato que se
	 * midio en esta misma base: los 317 logueos de verdad de `log_login`
	 * comparten UNA sola IP -- 127.0.0.1, porque todo el desarrollo es local --
	 * y `log_registro` tiene UNA sola fila. Contra eso no se puede medir nada de
	 * fraude por IP. Las doce cuentas del proyecto darian anillo por
	 * construccion, y lo unico que se estaria detectando es que el equipo
	 * trabaja en su propia maquina.
	 *
	 * De ahi salen las IP sembradas, y de ahi sale este selector. Un panel de
	 * fraude que acusa a cuentas de la semilla por un patron que dibujo un
	 * script hace mas dano que no tener panel, porque tiene forma de hallazgo.
	 *
	 * Asi que la regla de esta pantalla, que no se negocia, es que el lote se
	 * DICE SIEMPRE Y ARRIBA, antes de cualquier numero, y cuando el lote no es
	 * 'real' el aviso deja de ser un dato gris y pasa a ser una advertencia.
	 * Es la misma leccion que el resto del proyecto ya aprendio con el grafo --
	 * un panel que falla se arregla, uno que calla se cree.
	 *
	 *
	 * LO QUE EL FRAUDE POR IP NO PUEDE FILTRAR
	 * ---------------------------------------------------------------
	 * La ruta de tendencias recibe `lote` y la de fraude por IP NO. Esa es la
	 * firma que publica el backend y aqui no se inventa un parametro que el
	 * servidor no lee -- mandarlo daria la impresion de que filtra cuando no
	 * filtra, que es peor que no ofrecerlo. Se dice en pantalla, en la propia
	 * seccion, y ademas se marca la fila de la IP local, que es la que va a
	 * salir arriba de todas contra la base de hoy y NO es un hallazgo.
	 */

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	/**
	 * Un producto que esta subiendo.
	 *
	 * `ahora` y `antes` son las vistas de la ventana actual y de la ventana
	 * inmediatamente anterior del mismo largo. `veces` es cuantas veces subio,
	 * o sea `ahora / antes`, ya calculado por ClickHouse.
	 *
	 * `personas` sale de un `uniq` sobre la columna `sesion`, no sobre el
	 * usuario, porque la ficha de un producto es publica y se puede mirar sin
	 * cuenta. En pantalla se llama "sesiones distintas" y no "personas" a
	 * proposito. Es el numero que separa "cien personas miraron esto" de "una
	 * persona lo miro cien veces", que para una tendencia son cosas opuestas, y
	 * llamarlo personas seria prometer una precision que el dato no tiene.
	 *
	 * `nombre` puede llegar en null. El evento guarda el id y nada mas, asi que
	 * un producto borrado despues de ser visto no tiene nombre que ensenar.
	 */
	interface ProductoEnAlza {
		id_producto: number;
		nombre: string | null;
		ahora: number;
		antes: number;
		veces: number;
		personas: number;
	}

	interface RespuestaTendencias {
		desde: string;
		hasta: string;
		lote: string;
		productos: ProductoEnAlza[];
	}

	/**
	 * Una IP desde la que entraron varias cuentas distintas.
	 *
	 * `cuentas` es el numero que importa. `entradas` y `registros` son el
	 * contexto que dice si el patron es de uso o de creacion: veinte entradas
	 * de dos cuentas es una casa con dos personas, y cinco REGISTROS la misma
	 * tarde detras de la misma IP es otra cosa completamente distinta.
	 */
	interface IpSospechosa {
		ip: string;
		cuentas: number;
		entradas: number;
		registros: number;
		primera: string;
		ultima: string;
		usuarios: string[];
	}

	interface RespuestaFraudeIp {
		ips: IpSospechosa[];
	}

	type Lote = 'real' | 'generado' | 'todo';

	/** Que dice la etiqueta de arriba para cada lote. */
	const NOMBRE_LOTE: Record<Lote, string> = {
		real: 'Lote real',
		generado: 'Lote generado',
		todo: 'Los dos lotes'
	};

	/**
	 * El aviso de lote, entero y escrito de una pieza en cada rama.
	 *
	 * Se guarda como texto completo y no se arma con trozos dentro de la
	 * plantilla porque una frase partida con un {#if} en medio deja el salto de
	 * linea como espacio y el punto termina separado de la ultima palabra. Ya
	 * paso en este proyecto y se vio en pantalla, no leyendo el codigo.
	 */
	const AVISO_LOTE: Record<Lote, string> = {
		real: 'Se esta mirando el lote real, lo que el portal midio de verdad.',
		generado:
			'Se esta mirando el lote generado. Estos numeros los sembro un script y nadie los midio, asi que sirven para probar que el analisis corre y no para senalar a ninguna cuenta.',
		todo: 'Se estan mirando los dos lotes mezclados. Una parte de estos numeros la sembro un script y desde aqui no se puede saber cual, asi que no sirven para senalar a ninguna cuenta.'
	};

	/** Las ventanas que se pueden pedir. Dias enteros, como los toma la ruta. */
	const VENTANAS = [7, 14, 30, 90];

	/** La ventana del fraude por IP. Fija, porque la firma de la ruta la fija. */
	const DIAS_FRAUDE = 30;

	let lote = $state<Lote>('real');
	let dias = $state(7);

	let tendencias = $state<RespuestaTendencias | null>(null);
	let cargando = $state(true);
	let error = $state('');

	/**
	 * El 404 se guarda aparte del texto del error.
	 *
	 * El texto que sale en pantalla es el de `mensajeUtil` en los dos casos, sin
	 * cambiarlo. Lo que cambia es la CAJA: el 404 va en la caja neutra de
	 * pendiente y cualquier otro fallo va en la roja. Ver la nota de arriba.
	 */
	let noPublicado = $state(false);

	/**
	 * El fraude por IP. `respondio` empieza en false y solo se pone en true
	 * cuando la segunda peticion sale bien.
	 *
	 * Hace falta porque una lista vacia llega identica en dos casos que no son
	 * el mismo, y aqui se resuelven distinto. Si la ruta fallo NO se pinta nada,
	 * ni siquiera un aviso: es informacion de apoyo, y una caja roja de "no se
	 * pudo comprobar el fraude por IP" al lado de una tendencia correcta asusta
	 * mas de lo que informa. Si la ruta contesto y no habia nada, eso SI se
	 * dice, porque un cero que se sabe que es cero es un resultado.
	 */
	let ips = $state<IpSospechosa[]>([]);
	let fraudeRespondio = $state(false);

	/** Que IP esta desplegada. Una a la vez, que la lista de cuentas es larga. */
	let abierta = $state<string | null>(null);

	/**
	 * El maximo de todas las barras, para que las dos de cada fila y las de
	 * filas distintas se puedan comparar entre si.
	 *
	 * Se mira `ahora` y tambien `antes`. Con solo `ahora` de escala, un producto
	 * que BAJO -- que puede aparecer si el backend cambia el orden algun dia --
	 * dibujaria una barra de antes desbordada fuera de su caja.
	 */
	let tope = $derived(
		Math.max(
			1,
			...(tendencias?.productos ?? []).map((p) => Math.max(num(p.ahora), num(p.antes)))
		)
	);

	// onMount y no $effect: esto tiene que correr UNA vez al montar. Con $effect
	// se dispara solo cada vez que cambia cualquier cosa que se lea adentro, y
	// en este mismo proyecto se midieron seis llamadas en el mismo instante con
	// un console.trace. Aqui serian doce, porque son dos rutas.
	//
	// Y por eso mismo el selector de lote llama a `cargar` a mano desde su
	// onchange. Un cambio de lote es una accion de una persona, no una reaccion
	// del estado.
	onMount(cargar);

	async function cargar() {
		cargando = true;
		error = '';
		noPublicado = false;

		const respuesta = await pedir<RespuestaTendencias>(
			`/admin/eventos/tendencias?dias=${dias}&lote=${encodeURIComponent(lote)}`
		);

		cargando = false;

		// 401 y nada mas. Un 503 o un 0 dicen que el problema es del servidor y
		// la sesion puede seguir buena; sacar a alguien de la aplicacion porque
		// ClickHouse se cayo es cambiar un problema chico por uno grande.
		if (respuesta.estado === 401) {
			alExpirarSesion();
			return;
		}

		// Los DOS lados. `respuesta.ok` en false con payload lleno y `ok` en true
		// con payload nulo se han visto los dos, y cualquiera de los dos solo
		// deja pasar basura al resto del componente.
		if (!respuesta.ok || !respuesta.payload) {
			// mensajeUtil y no `respuesta.mensaje` a secas. Si el cuerpo no trae
			// `mensaje` -- un 404 de Nest, que usa `message`, o un proxy en el
			// medio -- `error` quedaba en undefined, que es FALSY, la cadena de
			// {#if error} lo saltaba y la pantalla terminaba ensenando "no se
			// hallo nada" HABIENDO FALLADO. Un fallo disfrazado de medicion
			// limpia es exactamente lo que este panel no puede hacer.
			error = mensajeUtil(respuesta);
			noPublicado = respuesta.estado === 404;
			tendencias = null;
			ips = [];
			fraudeRespondio = false;
			return;
		}

		tendencias = respuesta.payload;

		void cargarFraudeIp();
	}

	/**
	 * El fraude por IP va en una peticion APARTE, despues, y sin await.
	 *
	 * No depende de la tendencia y la tendencia no depende de el, asi que
	 * encadenarlos solo lograria que una ruta lenta retrasara a la otra. Un
	 * fallo aqui deja la lista vacia y la seccion sin pintar, en silencio -- ver
	 * la nota de `fraudeRespondio`.
	 */
	async function cargarFraudeIp() {
		ips = [];
		fraudeRespondio = false;

		const r = await pedir<RespuestaFraudeIp>(`/admin/eventos/fraude/ip?dias=${DIAS_FRAUDE}`);

		if (!r.ok || !r.payload) return;

		ips = r.payload.ips ?? [];
		fraudeRespondio = true;
	}

	function cambiarLote(valor: string) {
		lote = valor as Lote;
		abierta = null;
		void cargar();
	}

	function cambiarVentana(valor: string) {
		dias = Number(valor) || 7;
		abierta = null;
		void cargar();
	}

	function alternar(clave: string) {
		abierta = abierta === clave ? null : clave;
	}

	/**
	 * Un numero del backend, blindado.
	 *
	 * Los conteos de ClickHouse pueden viajar como texto segun como el driver
	 * serialice un UInt64, y `undefined` en una resta produce NaN, que se pinta
	 * en pantalla tal cual. Un NaN en medio de una tabla de tendencia se lee
	 * como un fallo del panel y no como un dato que falta.
	 */
	function num(valor: unknown): number {
		const n = Number(valor);
		return Number.isFinite(n) ? n : 0;
	}

	/**
	 * Cuanto subio, para leerse de un vistazo.
	 *
	 * El caso que hay que atender es `antes` en cero, que NO es un salto
	 * infinito sino un producto que nadie habia mirado. Dividir ahi da Infinity
	 * y se pinta como el simbolo de infinito, que ademas de feo dice algo falso.
	 */
	function salto(p: ProductoEnAlza): string {
		const antes = num(p.antes);
		if (antes === 0) return 'nuevo';

		const veces = Number.isFinite(Number(p.veces)) ? Number(p.veces) : num(p.ahora) / antes;
		if (veces < 1.05) return 'igual';
		return `x${veces.toFixed(1)}`;
	}

	/** El ancho de una barra contra el maximo de la lista. */
	function ancho(valor: unknown): number {
		return Math.round((num(valor) / tope) * 100);
	}

	function nombreProducto(p: ProductoEnAlza): string {
		return p.nombre ?? `Producto ${p.id_producto}`;
	}

	/**
	 * La IP local. Contra la base de hoy va a salir arriba de todas y con las
	 * doce cuentas del proyecto colgando, y NO es un hallazgo -- es el equipo
	 * trabajando en su maquina. Decirlo en la fila cuesta una linea y evita que
	 * alguien salga a investigar su propio ordenador.
	 *
	 * Se comprueban las tres escrituras porque la columna es IPv6 y una IPv4
	 * puede volver envuelta.
	 */
	function esLocal(ip: string): boolean {
		return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
	}

	/**
	 * Una fecha del backend, para leerse.
	 *
	 * `new Date` de algo invalido no lanza, devuelve una fecha invalida que se
	 * pinta como "Invalid Date" en medio de la tabla. Un guion dice lo mismo sin
	 * ensuciar.
	 */
	function fecha(valor: string): string {
		if (!valor) return '--';
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '--';
		return d.toLocaleString('es-GT', {
			day: 'numeric',
			month: 'short',
			hour: '2-digit',
			minute: '2-digit'
		});
	}

	function soloFecha(valor: string): string {
		if (!valor) return '--';
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '--';
		return d.toLocaleDateString('es-GT', { day: 'numeric', month: 'short', year: 'numeric' });
	}
</script>

<section class="tendencias">
	<div class="titulo">
		<h2>Tendencias y fraude por eventos</h2>
		<span class="etiqueta" class:sembrado={lote !== 'real'}>{NOMBRE_LOTE[lote]}</span>
		{#if !cargando}
			<div class="acciones">
				<button type="button" onclick={cargar}>Volver a medir</button>
			</div>
		{/if}
	</div>

	<p class="intro">
		Lo que se mira aqui son eventos, no ventas. Cada clic en una ficha, cada entrada y cada
		registro queda guardado con su hora y su direccion, y de ese rastro salen dos cosas que
		ninguna tabla del catalogo puede contestar. Que producto se esta calentando antes de
		venderse, y desde que direcciones entran varias cuentas distintas.
	</p>

	<div class="mandos">
		<label>
			<span>Lote</span>
			<select value={lote} onchange={(e) => cambiarLote(e.currentTarget.value)}>
				<option value="real">Real, medido por el portal</option>
				<option value="generado">Generado por el script</option>
				<option value="todo">Los dos</option>
			</select>
		</label>

		<label>
			<span>Ventana</span>
			<select value={String(dias)} onchange={(e) => cambiarVentana(e.currentTarget.value)}>
				{#each VENTANAS as v (v)}
					<option value={String(v)}>Ultimos {v} dias</option>
				{/each}
			</select>
		</label>
	</div>

	<!--
		EL AVISO DE LOTE. Va siempre y va arriba, antes de cualquier cifra, y no
		se esconde ni mientras carga ni cuando algo falla. Es la decision de
		diseno de esta pantalla entera y esta explicada larga en la cabecera del
		componente.

		En gris cuando el lote es real, porque ahi es un dato normal y no tiene
		que competir con lo que se viene a ver. Con fondo y en rojo cuando no lo
		es, porque entonces deja de ser un dato y pasa a ser una advertencia
		sobre lo que se esta leyendo justo debajo.
	-->
	<p class="aviso" class:sembrado={lote !== 'real'}>
		{#if lote === 'real'}
			{AVISO_LOTE.real}
		{:else if lote === 'generado'}
			<strong>Estos numeros no son medidos.</strong>
			{AVISO_LOTE.generado}
		{:else}
			<strong>Estos numeros no son todos medidos.</strong>
			{AVISO_LOTE.todo}
		{/if}
	</p>

	{#if cargando}
		<p class="gris">Midiendo el rastro de eventos...</p>
	{:else if noPublicado}
		<!--
			La ruta no existe todavia. Caja neutra y no roja: no hay nada roto que
			ir a arreglar, solo falta que se publique. El texto es el mismo que
			devuelve mensajeUtil, sin retocar.
		-->
		<div class="pendiente">
			<h3>Todavia no se puede medir desde aqui</h3>
			<p>{error}</p>
			<p class="gris">
				La base de eventos si esta viva y con datos. Lo que falta es la ruta del servidor que
				los saca, y esta pantalla queda lista para ensenarlos en cuanto conteste.
			</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if tendencias}
		<div class="bloque">
			<div class="cabecera-bloque">
				<h3>Productos en alza</h3>
				<span class="rango">
					Del {soloFecha(tendencias.desde)} al {soloFecha(tendencias.hasta)}, contra los {dias}
					dias anteriores
				</span>
			</div>

			{#if tendencias.productos.length === 0}
				<!--
					El vacio CON su denominador. Un cero solo es una duda; un cero que
					dice contra que se midio es un resultado. Aqui no se rellena con
					filas de ejemplo, que en una pantalla de fraude es lo ultimo que
					uno quiere ensenar.
				-->
				<p class="vacio">
					Ningun producto subio de vistas en esta ventana. La consulta corrio bien sobre el
					lote elegido y no devolvio ninguna fila, o sea que no faltan datos, no hubo alza.
				</p>
			{:else}
				<ul class="lista">
					<!--
						La clave lleva el indice pegado al id. No es paranoia: una clave
						repetida en un {#each} de Svelte 5 no degrada la lista, lanza
						`each_key_duplicate` y revienta el panel entero. Y el id de
						producto puede venir repetido en cuanto el backend agrupe por algo
						mas que el producto, por ejemplo por lote cuando se piden los dos.
					-->
					{#each tendencias.productos as p, i (p.id_producto + '#' + i)}
						<li class="fila">
							<div class="fila-cabeza">
								<span class="puesto">{i + 1}</span>
								<a class="nombre" href="/producto/{p.id_producto}">{nombreProducto(p)}</a>
								<span
									class="salto"
									class:nuevo={salto(p) === 'nuevo'}
									class:plano={salto(p) === 'igual'}
								>
									{salto(p)}
								</span>
							</div>

							<!--
								Dos barras, la de antes encima de la de ahora y las dos a la
								misma escala. Es lo que hace que se lea de un vistazo cual
								esta subiendo, sin que nadie tenga que dividir de cabeza.
							-->
							<div class="barras" aria-hidden="true">
								<div class="barra">
									<span class="antes" style="width: {ancho(p.antes)}%"></span>
								</div>
								<div class="barra">
									<span class="ahora" style="width: {ancho(p.ahora)}%"></span>
								</div>
							</div>

							<div class="cifras">
								<span><strong class="fuerte">{num(p.ahora)}</strong> vistas ahora</span>
								<span class="gris">{num(p.antes)} antes</span>
								<span class="gris">
									{num(p.personas)}
									{num(p.personas) === 1 ? 'sesion distinta' : 'sesiones distintas'}
								</span>
							</div>
						</li>
					{/each}
				</ul>
				<p class="pie">
					Las sesiones distintas son el numero que separa un producto de moda de uno inflado. La
					ficha se puede mirar sin cuenta, asi que se cuentan sesiones y no personas.
				</p>
			{/if}
		</div>

		<!--
			El fraude por IP solo aparece si su ruta contesto. Si fallo no se pinta
			nada, a proposito. Ver la nota de `fraudeRespondio`.
		-->
		{#if fraudeRespondio}
			<div class="bloque">
				<div class="cabecera-bloque">
					<h3>Varias cuentas desde una misma direccion</h3>
					<span class="rango">Ultimos {DIAS_FRAUDE} dias</span>
				</div>

				<p class="nota-seccion">
					Esta lista se calcula sobre todo el rastro de entradas y registros, sin separar lote,
					porque la ruta del servidor no recibe ese filtro. Y una direccion compartida por si
					sola no prueba nada. Una familia, una oficina y un cafe comparten salida a internet.
					Lo que si pesa es que varias cuentas se hayan REGISTRADO desde la misma direccion, y
					mas todavia si el grafo de resenas senala a esas mismas cuentas.
				</p>

				{#if ips.length === 0}
					<p class="vacio">
						Ninguna direccion tiene mas de una cuenta detras en esta ventana. El analisis corrio
						y no hallo nada, o sea que no faltan datos.
					</p>
				{:else}
					<ul class="lista-ip">
						{#each ips as fila, i (fila.ip + '#' + i)}
							{@const clave = fila.ip + '#' + i}
							{@const desplegada = abierta === clave}
							<li class="ip-item" class:desplegada>
								<button type="button" class="cabeza" onclick={() => alternar(clave)}>
									<span class="ip">{fila.ip}</span>
									{#if esLocal(fila.ip)}
										<span class="marca-local">entrada local de desarrollo</span>
									{/if}
									<span class="cuentas" class:alta={num(fila.cuentas) >= 3}>
										{num(fila.cuentas)}
										{num(fila.cuentas) === 1 ? 'cuenta' : 'cuentas'}
									</span>
									<span class="menudo">{num(fila.entradas)} entradas</span>
									<span class="menudo" class:resalta={num(fila.registros) > 1}>
										{num(fila.registros)}
										{num(fila.registros) === 1 ? 'registro' : 'registros'}
									</span>
									<span class="chevron" aria-hidden="true">{desplegada ? '-' : '+'}</span>
								</button>

								{#if desplegada}
									<div class="detalle">
										{#if esLocal(fila.ip)}
											<p class="porque">
												Es la direccion de la propia maquina. Todo el desarrollo del
												proyecto entra por aqui, asi que ver todas las cuentas colgando de
												esta fila es lo esperado y no una senal de nada.
											</p>
										{/if}

										<div class="tabla">
											<table>
												<thead>
													<tr>
														<th>Cuentas</th>
														<th>Entradas</th>
														<th>Registros</th>
														<th>Primera</th>
														<th>Ultima</th>
													</tr>
												</thead>
												<tbody>
													<tr>
														<td class="fuerte">{num(fila.cuentas)}</td>
														<td>{num(fila.entradas)}</td>
														<td>{num(fila.registros)}</td>
														<td class="gris">{fecha(fila.primera)}</td>
														<td class="gris">{fecha(fila.ultima)}</td>
													</tr>
												</tbody>
											</table>
										</div>

										<h4>Las cuentas que entran desde aqui ({fila.usuarios.length})</h4>
										<ul class="cuentas-lista">
											{#each fila.usuarios as usuario, j (usuario + '#' + j)}
												<li class="cuenta">{usuario}</li>
											{/each}
										</ul>
									</div>
								{/if}
							</li>
						{/each}
					</ul>
				{/if}
			</div>
		{/if}
	{/if}
</section>

<style>
	.tendencias {
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

	/* La etiqueta del lote. Neutra cuando es real, marcada cuando no lo es. */
	.etiqueta {
		padding: 3px 11px;
		font-size: var(--f-sm);
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: 999px;
		white-space: nowrap;
	}

	.etiqueta.sembrado {
		color: var(--rojo);
		background: var(--rojo-cl);
		border-color: var(--rojo);
	}

	.acciones {
		margin-left: auto;
		display: flex;
		gap: var(--e2);
	}

	.intro {
		max-width: 640px;
		margin-bottom: var(--e4);
		color: var(--gris);
		font-size: var(--f-base);
	}

	/* -- los dos selectores -- */

	.mandos {
		display: flex;
		align-items: flex-end;
		gap: var(--e4);
		flex-wrap: wrap;
		margin-bottom: var(--e3);
	}

	.mandos label {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		font-size: var(--f-sm);
		color: var(--gris);
	}

	/* -- el aviso de lote -- */

	.aviso {
		max-width: 640px;
		margin-bottom: var(--e5);
		font-size: var(--f-ms);
		color: var(--gris-2);
	}

	.aviso.sembrado {
		padding: 10px 12px;
		font-size: var(--f-base);
		color: var(--rojo);
		background: var(--rojo-cl);
		border-radius: var(--r);
	}

	.gris {
		color: var(--gris);
	}

	.fuerte {
		font-weight: 500;
		color: var(--tinta);
	}

	/* -- estados que no son la lista -- */

	.pendiente {
		padding: 22px 24px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.pendiente h3 {
		font-size: var(--f-md);
		margin-bottom: 8px;
	}

	.pendiente p {
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

	.vacio {
		max-width: 620px;
		padding: 18px 20px;
		font-size: var(--f-base);
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	/* -- los dos bloques -- */

	.bloque {
		margin-top: var(--e5);
	}

	.cabecera-bloque {
		display: flex;
		align-items: baseline;
		gap: var(--e3);
		flex-wrap: wrap;
		margin-bottom: var(--e3);
	}

	.cabecera-bloque h3 {
		font-size: var(--f-lg);
	}

	.rango {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.nota-seccion {
		max-width: 640px;
		margin-bottom: var(--e4);
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.pie {
		max-width: 640px;
		margin-top: var(--e3);
		font-size: var(--f-sm);
		color: var(--gris-2);
	}

	/* -- la lista de productos en alza -- */

	.lista {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--e3);
	}

	.fila {
		padding: 14px 18px;
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.fila-cabeza {
		display: flex;
		align-items: center;
		gap: var(--e2);
		flex-wrap: wrap;
	}

	.puesto {
		min-width: 22px;
		font-size: var(--f-sm);
		color: var(--gris-2);
	}

	.nombre {
		font-size: var(--f-base);
		font-weight: 500;
		color: var(--indigo);
	}

	/* Cuantas veces subio. Es el numero que se busca primero al mirar la
	   pantalla, asi que es lo unico de la fila que va con relleno solido. */
	.salto {
		margin-left: auto;
		padding: 2px 10px;
		font-size: var(--f-sm);
		font-weight: 500;
		color: var(--sobre-indigo);
		background: var(--indigo);
		border: 1px solid var(--indigo);
		border-radius: 999px;
		white-space: nowrap;
	}

	/* Un producto que nadie habia mirado antes no tiene con que compararse, y
	   pintarlo igual que un salto medido seria darle un peso que no tiene. */
	.salto.nuevo,
	.salto.plano {
		color: var(--gris);
		background: var(--panel);
		border-color: var(--linea);
	}

	.barras {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		margin: var(--e2) 0;
	}

	.barra {
		height: 8px;
		background: var(--panel);
		border-radius: 999px;
		overflow: hidden;
	}

	.barra span {
		display: block;
		height: 100%;
		border-radius: 999px;
	}

	/* La de antes en gris y la de ahora en indigo. El contraste entre las dos ES
	   la tendencia; si las dos fueran del mismo color habria que leer los
	   numeros para saber cual es cual. */
	.antes {
		background: var(--gris-2);
		opacity: 0.4;
	}

	.ahora {
		background: var(--indigo);
	}

	.cifras {
		display: flex;
		gap: var(--e4);
		flex-wrap: wrap;
		font-size: var(--f-sm);
	}

	/* -- la lista de IP -- */

	.lista-ip {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--e3);
	}

	.ip-item {
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
	}

	.ip-item.desplegada {
		border-color: var(--indigo);
	}

	/* La fila entera es el boton. Un objetivo de doce pixeles al borde de la
	   tarjeta se falla mas de lo que se acierta en un telefono. */
	.cabeza {
		display: flex;
		align-items: center;
		justify-content: flex-start;
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
		border-radius: 0;
		white-space: normal;
		cursor: pointer;
	}

	.cabeza:hover {
		background: var(--panel);
		color: var(--tinta);
	}

	.ip {
		font-weight: 500;
		overflow-wrap: anywhere;
	}

	.marca-local {
		padding: 2px 9px;
		font-size: var(--f-xs);
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: 999px;
	}

	.cuentas {
		padding: 2px 10px;
		font-size: var(--f-sm);
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: 999px;
		white-space: nowrap;
	}

	/* Tres cuentas o mas es donde la coincidencia deja de explicarse sola. */
	.cuentas.alta {
		color: var(--rojo);
		background: var(--rojo-cl);
		border-color: var(--rojo);
	}

	.menudo {
		font-size: var(--f-sm);
		color: var(--gris);
		white-space: nowrap;
	}

	/* Mas de un registro desde la misma direccion pesa mucho mas que muchas
	   entradas. Entrar se repite todos los dias; crearse una cuenta no. */
	.menudo.resalta {
		color: var(--rojo);
		font-weight: 500;
	}

	.chevron {
		margin-left: auto;
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

	/* La tabla se desborda en horizontal DENTRO de su caja y nunca empuja el
	   ancho de la pagina. */
	.tabla {
		margin-top: var(--e4);
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

	.cuentas-lista {
		list-style: none;
		display: flex;
		gap: var(--e2);
		flex-wrap: wrap;
		font-size: var(--f-base);
	}

	.cuenta {
		padding: 3px 10px;
		font-weight: 500;
		color: var(--tinta);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	@media (max-width: 620px) {
		.tendencias {
			padding: 22px 20px;
		}
		.acciones {
			margin-left: 0;
			width: 100%;
		}
		.mandos label {
			width: 100%;
		}
		.salto {
			margin-left: 0;
		}
		.chevron {
			margin-left: 0;
		}
	}
</style>
