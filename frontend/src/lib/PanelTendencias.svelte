<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';

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
	 * LO QUE ESTAS RUTAS NO SABEN
	 * ---------------------------------------------------------------
	 * No reciben `lote`. Las tablas de eventos llevan la columna `lote` ('real' o
	 * 'generado') justamente para no confundir lo que midio el portal con lo que
	 * sembro clickhouse/lote, y estas seis consultas cuentan TODO. Con un lote
	 * sembrado en la base, el ranking mezcla las dos cosas y desde aqui no se
	 * puede saber cual es cual. Se dice en pantalla, en la propia nota, y esta
	 * pedido a Jose David en docs/BACKEND-PENDIENTE.md.
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

	type Clave = 'vista' | 'carrito' | 'compra' | 'devolucion' | 'busqueda' | 'busqueda-clic';

	interface Ranking {
		clave: Clave;
		nombre: string;
		/** Por que se agrupa, que decide como se pinta cada fila. */
		agrupa: 'producto' | 'termino';
		/** Que cuenta el total, en singular y en plural. */
		unidad: [string, string];
		/** Una linea que dice que mide esta pestana y por que se mide asi. */
		explica: string;
	}

	const RANKINGS: Ranking[] = [
		{
			clave: 'vista',
			nombre: 'Vistas',
			agrupa: 'producto',
			unidad: ['sesion distinta', 'sesiones distintas'],
			explica:
				'Cuantas sesiones distintas abrieron la ficha. Una persona que la mira cien veces cuenta una sola. La ficha es publica, por eso se cuentan sesiones y no cuentas.'
		},
		{
			clave: 'carrito',
			nombre: 'Carrito',
			agrupa: 'producto',
			unidad: ['cuenta distinta', 'cuentas distintas'],
			explica:
				'Cuantas cuentas distintas lo agregaron al carrito. El carrito exige cuenta, asi que aqui se cuentan cuentas.'
		},
		{
			clave: 'compra',
			nombre: 'Compras',
			agrupa: 'producto',
			unidad: ['unidad', 'unidades'],
			explica: 'Unidades vendidas en pedidos pagados. Cada unidad cuenta, sin dividir por persona.'
		},
		{
			clave: 'devolucion',
			nombre: 'Devoluciones',
			agrupa: 'producto',
			unidad: ['unidad', 'unidades'],
			explica:
				'Unidades devueltas de pedidos que ya estaban pagados. Cancelar un pedido pendiente no cuenta.'
		},
		{
			clave: 'busqueda',
			nombre: 'Busquedas',
			agrupa: 'termino',
			unidad: ['sesion distinta', 'sesiones distintas'],
			explica: 'Que tan buscado esta cada termino, en sesiones distintas y no en teclazos.'
		},
		{
			clave: 'busqueda-clic',
			nombre: 'Clics de busqueda',
			agrupa: 'termino',
			unidad: ['sesion distinta', 'sesiones distintas'],
			explica:
				'Que terminos terminan en un clic sobre un resultado, en sesiones distintas. Un termino muy buscado y poco cliqueado suele ser un buscador que no encuentra lo que la gente quiere.'
		}
	];

	/** Las ventanas que se pueden pedir. La ruta tope en 365, que es el TTL de las tablas. */
	const VENTANAS = [1, 7, 14, 30, 90, 365];

	const LIMITES = [5, 10, 20, 50];

	let clave = $state<Clave>('vista');
	let dias = $state(7);
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

		filas =
			ranking.agrupa === 'producto'
				? (r.payload as FilaProducto[]).map(deProducto)
				: (r.payload as FilaTermino[]).map(deTermino);
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
		{#if !cargando}
			<div class="acciones">
				<button type="button" onclick={cargar}>Volver a medir</button>
			</div>
		{/if}
	</div>

	<p class="intro">
		Lo que se mira aqui son eventos, no ventas. Cada vista, cada carrito, cada compra y cada
		busqueda queda guardada con su hora, y de ese rastro sale lo que se esta calentando antes de
		que llegue a la tabla de pedidos.
	</p>

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
			<span>Ventana</span>
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
	<p class="mide">
		<strong>{actual.nombre}.</strong>
		{actual.explica}
	</p>

	<p class="aviso">
		Estas cuentas incluyen todo lo guardado, tambien las filas que sembro el generador de lotes.
		La ruta no separa lo medido de lo sembrado.
	</p>

	{#if cargando}
		<p class="gris">Midiendo el rastro de eventos...</p>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if filas.length === 0}
		<!-- El vacio CON su denominador. Un cero solo es una duda; un cero que dice
		     contra que se midio es un resultado. -->
		<p class="vacio">
			No hubo ningun evento de {actual.nombre.toLowerCase()} en {dias === 1
				? 'el ultimo dia'
				: `los ultimos ${dias} dias`}. La consulta corrio bien y no devolvio filas, o sea que no
			falta nada, no paso.
		</p>
	{:else}
		<ul class="lista">
			{#each filas as f, i (f.id)}
				<li class="fila">
					<div class="fila-cabeza">
						<span class="puesto">{i + 1}</span>
						{#if f.enlace}
							<a class="nombre" href={f.enlace}>{f.titulo}</a>
						{:else}
							<span class="nombre sin-enlace">{f.titulo}</span>
						{/if}
						{#if f.detalle}
							<span class="detalle">{f.detalle}</span>
						{/if}
						<span class="total">
							{f.total}
							<small>{f.total === 1 ? actual.unidad[0] : actual.unidad[1]}</small>
						</span>
					</div>

					<div class="barra" aria-hidden="true">
						<span style="width: {ancho(f.total)}%"></span>
					</div>
				</li>
			{/each}
		</ul>

		{#if direccion === 'negativo'}
			<p class="pie">
				Solo aparecen los que tuvieron al menos un evento en la ventana. Lo que no se movio nada
				no sale en ninguna lista.
			</p>
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

	.aviso {
		max-width: 640px;
		margin-bottom: var(--e5);
		font-size: var(--f-ms);
		color: var(--gris-2);
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

	/* -- la lista -- */

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
		align-items: baseline;
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
		overflow-wrap: anywhere;
	}

	/* Un producto ya borrado no tiene a donde llevar: se pinta en gris y sin
	   subrayado, para que no parezca un enlace roto. */
	.nombre.sin-enlace {
		color: var(--gris);
		font-weight: 400;
	}

	.detalle {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	/* El total es lo primero que se busca al mirar la fila, y va al final para
	   que la columna de cifras quede alineada a la derecha. */
	.total {
		margin-left: auto;
		font-size: var(--f-md);
		font-weight: 500;
		color: var(--tinta);
		white-space: nowrap;
	}

	.total small {
		font-size: var(--f-sm);
		font-weight: 400;
		color: var(--gris);
	}

	.barra {
		height: 8px;
		margin-top: var(--e2);
		background: var(--panel);
		border-radius: 999px;
		overflow: hidden;
	}

	.barra span {
		display: block;
		height: 100%;
		background: var(--indigo);
		border-radius: 999px;
	}

	@media (max-width: 620px) {
		.tendencias {
			padding: 18px 16px;
		}

		.total {
			margin-left: 0;
		}
	}
</style>
