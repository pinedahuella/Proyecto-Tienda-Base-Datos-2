<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';
	import { NOMBRE_PRECIO, NOMBRE_CALIFICACION } from './buscador';
	import TendenciasAuto from './TendenciasAuto.svelte';
	import TendenciasSenales from './TendenciasSenales.svelte';
	import Barras from './graficas/Barras.svelte';

	/**
	 * Panel de tendencias. Es la pantalla de la familia COLUMNAR del proyecto,
	 * ClickHouse, y la unica que mira EVENTOS y no filas de negocio.
	 *
	 *
	 * LAS SEIS RUTAS
	 * ---------------------------------------------------------------
	 *   GET /admin/eventos/vista
	 *   GET /admin/eventos/carrito
	 *   GET /admin/eventos/compra
	 *   GET /admin/eventos/devolucion
	 *   GET /admin/eventos/busqueda
	 *   GET /admin/eventos/busqueda-clic
	 *
	 * Las seis reciben lo mismo: `dias` (la ventana hacia atras), `limite` (cuantos
	 * del ranking) y `direccion` (`positivo`, los que mas; `negativo`, los que
	 * menos). El contrato esta en
	 * backend/elementos Generales/endpoints/endpoints-eventos.md.
	 *
	 * Hasta el 2026-09-18 esta pantalla estaba escrita contra dos rutas que nunca
	 * se publicaron (`/admin/eventos/tendencias` y `/admin/eventos/fraude/ip`) y
	 * ese dia el backend publico otra cosa: un ranking por tabla. El fraude por IP
	 * ya no vive aqui, lo cubre la pestana Fraude con las alertas de login.
	 *
	 * `/admin/eventos/tendencias` llego al fin el 2026-09-25, junto con el embudo
	 * y las busquedas sin respuesta (T1, T2 y T3 de docs/fraude-entrega3). Viven
	 * en su propia vista, "Senales", en TendenciasSenales.svelte: no son rankings
	 * de una tabla sino cruces entre tablas con umbral, y se leen distinto.
	 *
	 *
	 * LA METRICA NO ES LA MISMA EN LAS SEIS
	 * ---------------------------------------------------------------
	 * Y es lo primero que hay que decir en pantalla, porque un mismo "total" de 40
	 * quiere decir cosas distintas segun la pestana:
	 *
	 *   vista, busqueda, busqueda-clic   sesiones DISTINTAS
	 *   carrito                          cuentas DISTINTAS (el carrito exige cuenta)
	 *   compra, devolucion               unidades, sin dividir por persona
	 *
	 * Ver una ficha o agregar al carrito lo hace cualquiera muchas veces, asi que
	 * lo que informa es a cuanta gente le intereso. Completar una compra cuesta
	 * mas, y ahi cada unidad cuenta por lo que es.
	 *
	 *
	 * SOLO CUENTAN LOS EVENTOS REALES
	 * ---------------------------------------------------------------
	 * Las tablas de eventos llevan la columna `lote` ('real' para lo que mando el
	 * portal o salio de un pedido pagado, 'generado-N' para lo que siembra
	 * clickhouse/lote). Desde el 2026-09-19 las seis consultas filtran
	 * `lote = 'real'` y NO reciben ningun parametro para pedir lo contrario:
	 * decision de Jose David, "las metricas en todo lugar son sobre solo los
	 * reales". Lo sembrado no entra en ninguna lista de esta pantalla, y por eso
	 * aqui no hay selector de lote ni aviso de mezcla. Antes de esa fecha si
	 * mezclaban y esta pantalla lo avisaba; ya no es cierto.
	 *
	 * Consecuencia para una demo: los datos de demo sembrados no se ven aqui. Lo
	 * que se ve es lo real, que en una base recien armada son las ventas que copia
	 * etl/cargar_compras.sh desde PostgreSQL y lo que se genere usando la app.
	 *
	 * Y el producto sale sin su id cuando ya no tiene documento en Mongo: la ruta
	 * contesta `producto: null` y el id se pierde por el camino. La fila se pinta
	 * igual, con su total, porque el total sigue siendo un dato valido.
	 */

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	/** Lo que la ruta manda de un producto. Solo se leen tres campos. */
	interface ProductoRanking {
		_id: number;
		nombre: string;
		categoria?: { nombre: string };
	}

	/** Una fila de vista, carrito, compra o devolucion. */
	interface FilaProducto {
		total: number;
		producto: ProductoRanking | null;
	}

	/** Una fila de busqueda o busqueda-clic. */
	interface FilaTermino {
		termino: string;
		total: number;
	}

	type Clave =
		| 'vista'
		| 'carrito'
		| 'compra'
		| 'devolucion'
		| 'busqueda'
		| 'busqueda-clic'
		| 'categorias-mas-buscadas'
		| 'precios-mas-buscados'
		| 'calificaciones-mas-buscadas';

	interface Ranking {
		clave: Clave;
		nombre: string;
		/**
		 * Por que se agrupa, que decide como se pinta cada fila. `faceta` llega
		 * con la misma forma que `termino`, pero el termino es una clave de
		 * /buscar (un id de categoria, `250-500`, `4-o-mas`) y se traduce.
		 */
		agrupa: 'producto' | 'termino' | 'faceta';
		/** Que cuenta el total, en singular y en plural. */
		unidad: [string, string];
		/** Una linea que dice que mide esta pestana y por que se mide asi. */
		explica: string;
	}

	// Vistas, busquedas, clics y filtros cuentan SESIONES distintas, y el carrito
	// CUENTAS distintas; en pantalla las dos son "personas". Una persona que mira
	// algo cien veces cuenta una sola.
	const RANKINGS: Ranking[] = [
		{
			clave: 'vista',
			nombre: 'Vistas',
			agrupa: 'producto',
			unidad: ['persona', 'personas'],
			explica: 'Cuantas personas abrieron cada producto. Si alguien lo abre muchas veces, cuenta una.'
		},
		{
			clave: 'carrito',
			nombre: 'Carrito',
			agrupa: 'producto',
			unidad: ['persona', 'personas'],
			explica: 'Cuantas personas lo pusieron en su carrito.'
		},
		{
			clave: 'compra',
			nombre: 'Compras',
			agrupa: 'producto',
			unidad: ['unidad', 'unidades'],
			explica: 'Cuantas unidades se vendieron de cada producto.'
		},
		{
			clave: 'devolucion',
			nombre: 'Devoluciones',
			agrupa: 'producto',
			unidad: ['unidad', 'unidades'],
			explica: 'Cuantas unidades se devolvieron despues de pagarlas.'
		},
		{
			clave: 'busqueda',
			nombre: 'Busquedas',
			agrupa: 'termino',
			unidad: ['persona', 'personas'],
			explica: 'Lo que mas escribe la gente en el buscador.'
		},
		{
			clave: 'busqueda-clic',
			nombre: 'Clics en resultados',
			agrupa: 'termino',
			unidad: ['persona', 'personas'],
			explica: 'Busquedas que terminaron en un clic. Si algo se busca mucho y casi no tiene clics, la gente no encuentra lo que quiere.'
		},
		{
			clave: 'categorias-mas-buscadas',
			nombre: 'Categorias',
			agrupa: 'faceta',
			unidad: ['persona', 'personas'],
			explica: 'Las categorias que mas eligen en los filtros de busqueda.'
		},
		{
			clave: 'precios-mas-buscados',
			nombre: 'Precios',
			agrupa: 'faceta',
			unidad: ['persona', 'personas'],
			explica: 'Los rangos de precio que mas eligen. Dice cuanto quieren gastar.'
		},
		{
			clave: 'calificaciones-mas-buscadas',
			nombre: 'Estrellas',
			agrupa: 'faceta',
			unidad: ['persona', 'personas'],
			explica: 'Cuantas veces piden un minimo de estrellas al buscar.'
		}
	];

	/** El color de cada ranking, el mismo que su tarjeta en el resumen. */
	const COLOR: Record<Clave, string> = {
		vista: 'var(--g1)',
		carrito: 'var(--g5)',
		compra: 'var(--g3)',
		devolucion: 'var(--g4)',
		busqueda: 'var(--g2)',
		'busqueda-clic': 'var(--g6)',
		'categorias-mas-buscadas': 'var(--g1)',
		'precios-mas-buscados': 'var(--g2)',
		'calificaciones-mas-buscadas': 'var(--g3)'
	};

	/** Las ventanas que se pueden pedir. La ruta tope en 365, que es el TTL de las tablas. */
	const VENTANAS = [1, 7, 14, 30, 90, 365];

	const LIMITES = [5, 10, 20, 50];

	/**
	 * Que se ve al abrir. `auto` es lo nuevo y es lo que abre: las consultas de
	 * siempre y la de compras en ascenso YA CALCULADAS, mas el constructor de
	 * consultas propias (TendenciasAuto). `rankings` es la pantalla de antes, con
	 * sus seis pestanas y sus mandos, a la que se llega con un clic o desde el
	 * "Ver completo" de una tarjeta.
	 */
	let vista = $state<'auto' | 'senales' | 'rankings'>('auto');

	function verRanking(nueva: Clave) {
		clave = nueva;
		vista = 'rankings';
		void cargar();
	}

	let clave = $state<Clave>('vista');
	// 30 y no 7: como solo cuentan los eventos REALES, en una base joven casi todo
	// cae fuera de una semana. Medido el 2026-09-19 (filas de compra reales a 7 / 30
	// / 365 dias: 5 / 45 / 143); con 7 el ranking de compras trae 4 filas y con 30,
	// 9. La ventana se cambia desde el selector.
	let dias = $state(30);
	let limite = $state(10);
	let direccion = $state<'positivo' | 'negativo'>('positivo');

	/** Lo que se ve, ya normalizado: las seis pestanas terminan en la misma forma. */
	interface Fila {
		id: string;
		titulo: string;
		detalle: string | null;
		enlace: string | null;
		total: number;
	}

	let filas = $state<Fila[]>([]);
	let cargando = $state(true);
	let error = $state('');

	/**
	 * Cual medicion es la vigente. Cambiar de pestana con una ruta lenta deja dos
	 * peticiones en vuelo, y si la vieja llega la segunda pisaria la pantalla con
	 * el ranking de la pestana equivocada, sin ningun error. Cada respuesta mira
	 * si sigue siendo la ultima que se pidio.
	 */
	let vigente = 0;

	let actual = $derived(RANKINGS.find((r) => r.clave === clave) ?? RANKINGS[0]);

	/** El maximo de la lista, para que las barras se comparen entre si. */
	let tope = $derived(Math.max(1, ...filas.map((f) => f.total)));

	// onMount y no $effect: esto tiene que correr UNA vez al montar. Con $effect se
	// dispara solo cada vez que cambia cualquier cosa que se lea adentro, y en este
	// mismo proyecto se midieron seis llamadas en el mismo instante. Cada mando
	// llama a `cargar` a mano desde su onchange: un cambio de ventana es una accion
	// de una persona, no una reaccion del estado.
	onMount(cargar);

	async function cargar() {
		const mia = ++vigente;
		const ranking = actual;
		cargando = true;
		error = '';

		const r = await pedir<(FilaProducto | FilaTermino)[]>(
			`/admin/eventos/${ranking.clave}?dias=${dias}&limite=${limite}&direccion=${direccion}`
		);

		if (mia !== vigente) return;
		cargando = false;

		// 401 y nada mas. Un 503 o un 0 dicen que el problema es del servidor y la
		// sesion puede seguir buena; sacar a alguien de la aplicacion porque
		// ClickHouse se cayo es cambiar un problema chico por uno grande.
		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		// Los DOS lados. `ok` en false con payload lleno y `ok` en true con payload
		// que no es lista se han visto los dos.
		if (!r.ok || !Array.isArray(r.payload)) {
			// mensajeUtil y no `r.mensaje` a secas: un 404 de Nest o un proxy no
			// traen `mensaje`, y una caja de error vacia se lee como "todo bien".
			error = mensajeUtil(r);
			filas = [];
			return;
		}

		if (ranking.clave === 'categorias-mas-buscadas') {
			await cargarCategorias();
			if (mia !== vigente) return;
		}

		filas =
			ranking.agrupa === 'producto'
				? (r.payload as FilaProducto[]).map(deProducto)
				: ranking.agrupa === 'faceta'
					? (r.payload as FilaTermino[]).map((f, i) => deFaceta(ranking.clave, f, i))
					: (r.payload as FilaTermino[]).map(deTermino);
	}

	/**
	 * Los nombres de las categorias, para el ranking de categorias filtradas.
	 * ClickHouse guarda el id que mando /buscar, no el nombre. Se piden una vez,
	 * y si /categorias falla la fila sale con el id en vez de tapar el ranking.
	 */
	let nombreCategoria: Map<string, string> | null = null;

	async function cargarCategorias() {
		if (nombreCategoria) return;
		const r = await pedir<{ id_categoria: number; nombre: string }[]>('/categorias');
		if (r.ok && Array.isArray(r.payload)) {
			nombreCategoria = new Map(r.payload.map((c) => [String(c.id_categoria), c.nombre]));
		}
	}

	function deFaceta(clave: Clave, f: FilaTermino, i: number): Fila {
		const valor = typeof f.termino === 'string' ? f.termino : '';
		const titulo =
			clave === 'categorias-mas-buscadas'
				? (nombreCategoria?.get(valor) ?? `Categoria ${valor}`)
				: clave === 'precios-mas-buscados'
					? (NOMBRE_PRECIO[valor] ?? valor)
					: (NOMBRE_CALIFICACION[valor] ?? valor);
		return { id: `${valor}#${i}`, titulo, detalle: null, enlace: null, total: num(f.total) };
	}

	function deProducto(f: FilaProducto, i: number): Fila {
		const p = f.producto;
		return {
			// El id del producto no viaja cuando no hay documento, asi que la clave
			// lleva el puesto: una clave repetida en un {#each} de Svelte 5 no
			// degrada la lista, lanza `each_key_duplicate` y revienta el panel.
			id: `${p?._id ?? 'sin-documento'}#${i}`,
			titulo: p ? p.nombre : 'Producto que ya no existe en el catalogo',
			detalle: p?.categoria?.nombre ?? null,
			enlace: p ? `/producto/${p._id}` : null,
			total: num(f.total)
		};
	}

	function deTermino(f: FilaTermino, i: number): Fila {
		const termino = typeof f.termino === 'string' ? f.termino : '';
		return {
			id: `${termino}#${i}`,
			// Un termino vacio es un dato real (alguien pulso buscar sin escribir) y
			// una fila sin texto se lee como un fallo del panel.
			titulo: termino.trim() === '' ? '(vacio)' : termino,
			detalle: null,
			enlace: null,
			total: num(f.total)
		};
	}

	function cambiarRanking(nueva: Clave) {
		if (nueva === clave) return;
		clave = nueva;
		void cargar();
	}

	function cambiarVentana(valor: string) {
		dias = Number(valor) || 7;
		void cargar();
	}

	function cambiarLimite(valor: string) {
		limite = Number(valor) || 10;
		void cargar();
	}

	function cambiarDireccion(valor: string) {
		direccion = valor === 'negativo' ? 'negativo' : 'positivo';
		void cargar();
	}

	/**
	 * Un numero del backend, blindado. Los conteos de ClickHouse pueden viajar
	 * como texto segun como el driver serialice un UInt64, y un NaN se pinta en
	 * pantalla tal cual, como si fuera un dato.
	 */
	function num(valor: unknown): number {
		const n = Number(valor);
		return Number.isFinite(n) ? n : 0;
	}

	function ancho(valor: number): number {
		return Math.round((valor / tope) * 100);
	}

	function etiquetaVentana(v: number): string {
		return v === 1 ? 'Ultimo dia' : `Ultimos ${v} dias`;
	}
</script>

<section class="tendencias">
	<div class="titulo">
		<h2>Tendencias</h2>
		{#if vista === 'rankings' && !cargando}
			<div class="acciones">
				<button type="button" onclick={cargar}>Volver a medir</button>
			</div>
		{/if}
	</div>

	<p class="intro">Lo que la gente mira, compra y busca en la tienda.</p>

	<div class="pestanas" role="group" aria-label="Como ver las tendencias">
		<button type="button" class:activa={vista === 'auto'} aria-pressed={vista === 'auto'} onclick={() => (vista = 'auto')}>
			Resumen
		</button>
		<button type="button" class:activa={vista === 'senales'} aria-pressed={vista === 'senales'} onclick={() => (vista = 'senales')}>
			Para revisar
		</button>
		<button type="button" class:activa={vista === 'rankings'} aria-pressed={vista === 'rankings'} onclick={() => (vista = 'rankings')}>
			Rankings
		</button>
	</div>

	{#if vista === 'auto'}
		<TendenciasAuto {alExpirarSesion} {verRanking} />
	{:else if vista === 'senales'}
		<TendenciasSenales {alExpirarSesion} />
	{:else}
	<div class="pestanas" role="group" aria-label="Que medir">
		{#each RANKINGS as r (r.clave)}
			<button
				type="button"
				class:activa={clave === r.clave}
				aria-pressed={clave === r.clave}
				onclick={() => cambiarRanking(r.clave)}
			>
				{r.nombre}
			</button>
		{/each}
	</div>

	<div class="mandos">
		<label>
			<span>Dias</span>
			<select value={String(dias)} onchange={(e) => cambiarVentana(e.currentTarget.value)}>
				{#each VENTANAS as v (v)}
					<option value={String(v)}>{etiquetaVentana(v)}</option>
				{/each}
			</select>
		</label>

		<label>
			<span>Cuantos</span>
			<select value={String(limite)} onchange={(e) => cambiarLimite(e.currentTarget.value)}>
				{#each LIMITES as n (n)}
					<option value={String(n)}>{n}</option>
				{/each}
			</select>
		</label>

		<label>
			<span>Orden</span>
			<select value={direccion} onchange={(e) => cambiarDireccion(e.currentTarget.value)}>
				<option value="positivo">Los que mas</option>
				<option value="negativo">Los que menos</option>
			</select>
		</label>
	</div>

	<!-- Lo que mide esta pestana. Va siempre, antes de cualquier cifra: el mismo 40
	     quiere decir cosas distintas segun la pestana. -->
	<p class="mide">{actual.explica}</p>

	{#if cargando}
		<p class="gris">Calculando...</p>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if filas.length === 0}
		<!-- El vacio CON su denominador. Un cero solo es una duda; un cero que dice
		     contra que se midio es un resultado. -->
		<p class="vacio">
			Nada en {dias === 1 ? 'el ultimo dia' : `los ultimos ${dias} dias`}.
		</p>
	{:else}
		<div class="tarjeta-lista">
			<Barras
				color={COLOR[clave]}
				unidad={actual.unidad[1]}
				filas={filas.map((f) => ({ id: f.id, nombre: f.titulo, valor: f.total, detalle: f.detalle, enlace: f.enlace }))}
			/>
		</div>

		{#if direccion === 'negativo'}
			<p class="pie">Solo salen los que tuvieron algo de movimiento en esos dias.</p>
		{/if}
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

	/* -- las seis pestanas -- */

	/* Un interruptor de varios, no botones sueltos: el borde compartido dice que
	   son la misma decision y que solo una puede estar puesta. Se parte en filas
	   en un telefono en vez de desbordar. */
	.pestanas {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e1);
		margin-bottom: var(--e4);
	}

	.pestanas button {
		padding: 7px 16px;
		font-family: inherit;
		font-size: var(--f-ms);
		color: var(--gris);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: 999px;
		cursor: pointer;
		white-space: nowrap;
		transition:
			color var(--t),
			background var(--t),
			border-color var(--t);
	}

	.pestanas button:hover {
		color: var(--tinta);
		border-color: var(--indigo);
	}

	.pestanas button.activa {
		color: var(--sobre-indigo);
		background: var(--indigo);
		border-color: var(--indigo);
	}

	/* -- los tres selectores -- */

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

	.mide {
		max-width: 640px;
		margin-bottom: var(--e2);
		font-size: var(--f-base);
		color: var(--tinta);
	}


	.gris {
		color: var(--gris);
	}

	/* -- estados que no son la lista -- */

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

	.pie {
		max-width: 640px;
		margin-top: var(--e3);
		font-size: var(--f-sm);
		color: var(--gris-2);
	}

	.tarjeta-lista {
		padding: 20px 22px;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	/* -- la lista -- */












	@media (max-width: 620px) {
		.tendencias {
			padding: 18px 16px;
		}

	}
</style>
