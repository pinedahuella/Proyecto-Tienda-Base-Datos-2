<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';

	/**
	 * Las tres tendencias de la propuesta (docs/fraude-entrega3/03-consultas-clickhouse.md),
	 * que el backend conecto el 2026-09-25 (AdminTendenciasAvanzadasController):
	 *
	 *   T1  GET /admin/eventos/tendencias               productos cuyas vistas diarias
	 *                                                   crecen: ultimos `dias_recientes`
	 *                                                   contra los `dias_base` anteriores
	 *   T2  GET /admin/eventos/embudo                   productos con un problema en el
	 *                                                   camino vista, carrito, compra,
	 *                                                   devolucion
	 *   T3  GET /admin/eventos/busquedas-sin-respuesta  terminos buscados que no dan
	 *                                                   nada o que nadie cliquea
	 *
	 * Y una cuarta, de Jose David (2026-10-16, AdminBusquedasSinResultadosService):
	 *
	 *       GET /admin/eventos/busquedas-sin-resultados lo mas buscado que no dio
	 *                                                   nada, con las formas de
	 *                                                   escribir lo mismo juntas
	 *
	 * Es la version completa del "no lo tenemos" de T3: junta mayusculas, tildes
	 * y espacios de mas (la columna termino_normalizado de ClickHouse) y los
	 * errores de tecleo (editDistanceUTF8), y cuenta sesiones distintas. Recibe
	 * `dias` y no `dias_ventana`.
	 *
	 * Los umbrales (20 vistas, 1.5 veces, 20 sesiones, 2 %, 30 %, 3 sesiones)
	 * estan fijos en el backend; aqui solo se eligen las ventanas y cuantos. Por
	 * eso una lista vacia no es un fallo: quiere decir que nada paso el umbral,
	 * y se dice asi.
	 *
	 * Solo admin, como las seis rutas de siempre. Un 503 es ClickHouse caido.
	 */
	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	interface ProductoBreve {
		_id: number;
		nombre: string;
		categoria?: { nombre: string };
	}

	interface FilaAscenso {
		por_dia_ahora: number;
		por_dia_antes: number;
		veces: number;
		vistas_por_persona: number;
		producto: ProductoBreve | null;
	}

	interface FilaEmbudo {
		sesiones: number;
		en_carrito: number;
		pedidos: number;
		unidades: number;
		devueltas: number;
		conversion: number;
		tasa_devolucion: number;
		diagnostico: 'mucho_interes_poca_compra' | 'devolucion_alta';
		producto: ProductoBreve | null;
	}

	interface FilaBusqueda {
		termino: string;
		busquedas: number;
		sesiones: number;
		mas_resultados: number;
		clics: number;
		diagnostico: 'no_tenemos' | 'no_convence';
	}

	interface FilaSinResultados {
		termino: string;
		sesiones: number;
		terminos_agrupados: string[];
		como_lo_escribieron: string[];
		ultima_busqueda: string;
	}

	type Clave = 'ascenso' | 'embudo' | 'busquedas' | 'sin_resultados';

	const PESTANAS: { clave: Clave; nombre: string; explica: string }[] = [
		{
			clave: 'ascenso',
			nombre: 'En ascenso',
			explica:
				'Productos que se miran cada dia mas que antes. Piden al menos 20 vistas recientes y crecer 1.5 veces. Si las vistas por persona son muchas, puede ser alguien inflandolo y no una tendencia.'
		},
		{
			clave: 'embudo',
			nombre: 'Donde se cae la venta',
			explica:
				'Productos que mucha gente mira y casi nadie compra, o que se devuelven mucho. Lo primero apunta a precio, fotos o descripcion; lo segundo a que el producto no es lo que dice.'
		},
		{
			clave: 'busquedas',
			nombre: 'Busquedas sin respuesta',
			explica:
				'Lo que al menos 3 sesiones buscaron y no encontraron, o encontraron y no les convencio. Es demanda que hoy se va a otra tienda.'
		},
		{
			clave: 'sin_resultados',
			nombre: 'Lo que no tenemos',
			explica:
				'Lo mas buscado que no dio ningun resultado, sin filtros puestos. Junta las formas de escribir lo mismo (mayusculas, tildes, errores de tecleo) y cuenta sesiones distintas.'
		}
	];

	const DIAS_RECIENTES = [3, 7, 14];
	const DIAS_BASE = [14, 21, 30, 60];
	const DIAS_VENTANA = [7, 30, 90, 365];
	const LIMITES = [10, 20, 50];

	let clave = $state<Clave>('ascenso');
	let diasRecientes = $state(7);
	let diasBase = $state(21);
	let diasVentana = $state(30);
	let limite = $state(20);

	let ascenso = $state<FilaAscenso[]>([]);
	let embudo = $state<FilaEmbudo[]>([]);
	let busquedas = $state<FilaBusqueda[]>([]);
	let sinResultados = $state<FilaSinResultados[]>([]);
	let cargando = $state(true);
	let error = $state('');

	/** Mismo candado que PanelTendencias: una respuesta vieja no pisa la nueva. */
	let vigente = 0;

	let actual = $derived(PESTANAS.find((p) => p.clave === clave) ?? PESTANAS[0]);

	onMount(cargar);

	function ruta(): string {
		if (clave === 'ascenso') {
			return `/admin/eventos/tendencias?dias_recientes=${diasRecientes}&dias_base=${diasBase}&limite=${limite}`;
		}
		if (clave === 'sin_resultados') {
			return `/admin/eventos/busquedas-sin-resultados?dias=${diasVentana}&limite=${limite}`;
		}
		const nombre = clave === 'embudo' ? 'embudo' : 'busquedas-sin-respuesta';
		return `/admin/eventos/${nombre}?dias_ventana=${diasVentana}&limite=${limite}`;
	}

	async function cargar() {
		const mia = ++vigente;
		const cual = clave;
		cargando = true;
		error = '';

		const r = await pedir<unknown[]>(ruta());

		if (mia !== vigente) return;
		cargando = false;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !Array.isArray(r.payload)) {
			error = mensajeUtil(r);
			return;
		}

		if (cual === 'ascenso') ascenso = r.payload as FilaAscenso[];
		else if (cual === 'embudo') embudo = r.payload as FilaEmbudo[];
		else if (cual === 'busquedas') busquedas = r.payload as FilaBusqueda[];
		else sinResultados = r.payload as FilaSinResultados[];
	}

	function cambiar(nueva: Clave) {
		if (nueva === clave) return;
		clave = nueva;
		void cargar();
	}

	/** Los conteos de ClickHouse pueden llegar como texto. Un NaN no se pinta. */
	function num(valor: unknown): number {
		const n = Number(valor);
		return Number.isFinite(n) ? n : 0;
	}

	function uno(valor: unknown): string {
		return num(valor).toLocaleString('es-GT', { maximumFractionDigits: 1 });
	}

	function pct(fraccion: unknown): string {
		return (num(fraccion) * 100).toLocaleString('es-GT', { maximumFractionDigits: 1 }) + ' %';
	}

	function nombreProducto(p: ProductoBreve | null): string {
		return p ? p.nombre : 'Producto que ya no esta en el catalogo';
	}

	function vacio(): string {
		if (clave === 'ascenso') {
			return `Ningun producto crecio lo suficiente en los ultimos ${diasRecientes} dias. La consulta corrio bien, nada paso el umbral.`;
		}
		if (clave === 'embudo') {
			return `Ningun producto tiene un problema de venta en los ultimos ${diasVentana} dias. La consulta corrio bien, nada paso el umbral.`;
		}
		if (clave === 'sin_resultados') {
			return `Nadie busco algo que no tengamos en los ultimos ${diasVentana} dias. La consulta corrio bien y no devolvio filas.`;
		}
		return `Ninguna busqueda se quedo sin respuesta en los ultimos ${diasVentana} dias. La consulta corrio bien, nada paso el umbral.`;
	}

	function cuando(valor: string): string {
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '';
		return d.toLocaleString('es-GT', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
	}

	let filas = $derived(
		clave === 'ascenso'
			? ascenso.length
			: clave === 'embudo'
				? embudo.length
				: clave === 'busquedas'
					? busquedas.length
					: sinResultados.length
	);
</script>

<div class="senales">
	<div class="pestanas" role="group" aria-label="Que senal mirar">
		{#each PESTANAS as p (p.clave)}
			<button type="button" class:activa={clave === p.clave} aria-pressed={clave === p.clave} onclick={() => cambiar(p.clave)}>
				{p.nombre}
			</button>
		{/each}
	</div>

	<div class="mandos">
		{#if clave === 'ascenso'}
			<label>
				<span>Ahora</span>
				<select value={String(diasRecientes)} onchange={(e) => { diasRecientes = Number(e.currentTarget.value) || 7; void cargar(); }}>
					{#each DIAS_RECIENTES as d (d)}
						<option value={String(d)}>Ultimos {d} dias</option>
					{/each}
				</select>
			</label>
			<label>
				<span>Contra</span>
				<select value={String(diasBase)} onchange={(e) => { diasBase = Number(e.currentTarget.value) || 21; void cargar(); }}>
					{#each DIAS_BASE as d (d)}
						<option value={String(d)}>Los {d} dias anteriores</option>
					{/each}
				</select>
			</label>
		{:else}
			<label>
				<span>Ventana</span>
				<select value={String(diasVentana)} onchange={(e) => { diasVentana = Number(e.currentTarget.value) || 30; void cargar(); }}>
					{#each DIAS_VENTANA as d (d)}
						<option value={String(d)}>Ultimos {d} dias</option>
					{/each}
				</select>
			</label>
		{/if}
		<label>
			<span>Cuantos</span>
			<select value={String(limite)} onchange={(e) => { limite = Number(e.currentTarget.value) || 20; void cargar(); }}>
				{#each LIMITES as n (n)}
					<option value={String(n)}>{n}</option>
				{/each}
			</select>
		</label>
		<button type="button" onclick={cargar} disabled={cargando}>Volver a medir</button>
	</div>

	<p class="mide"><strong>{actual.nombre}.</strong> {actual.explica}</p>

	{#if cargando}
		<p class="gris">Midiendo...</p>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if filas === 0}
		<p class="vacio">{vacio()}</p>
	{:else if clave === 'ascenso'}
		<ul class="lista">
			{#each ascenso as f, i (`${f.producto?._id ?? 'x'}#${i}`)}
				<li class="fila">
					<div class="cabeza">
						{#if f.producto}
							<a class="nombre" href="/producto/{f.producto._id}">{nombreProducto(f.producto)}</a>
						{:else}
							<span class="nombre sin-enlace">{nombreProducto(null)}</span>
						{/if}
						{#if f.producto?.categoria?.nombre}
							<span class="detalle">{f.producto.categoria.nombre}</span>
						{/if}
						<span class="cifra">x{uno(f.veces)}</span>
					</div>
					<p class="datos">
						{uno(f.por_dia_ahora)} vistas al dia, antes {uno(f.por_dia_antes)}.
						<span class:alerta={num(f.vistas_por_persona) >= 5}>{uno(f.vistas_por_persona)} por persona</span>
					</p>
				</li>
			{/each}
		</ul>
	{:else if clave === 'embudo'}
		<ul class="lista">
			{#each embudo as f, i (`${f.producto?._id ?? 'x'}#${i}`)}
				<li class="fila">
					<div class="cabeza">
						{#if f.producto}
							<a class="nombre" href="/producto/{f.producto._id}">{nombreProducto(f.producto)}</a>
						{:else}
							<span class="nombre sin-enlace">{nombreProducto(null)}</span>
						{/if}
						<span class="diagnostico">
							{f.diagnostico === 'devolucion_alta' ? 'Se devuelve mucho' : 'Mucho interes, poca compra'}
						</span>
					</div>
					<p class="datos">
						{num(f.sesiones)} sesiones lo vieron, {num(f.en_carrito)} al carrito, {num(f.pedidos)}
						{num(f.pedidos) === 1 ? 'pedido' : 'pedidos'}. Compra {pct(f.conversion)}.
						{#if num(f.unidades) > 0}
							Volvieron {num(f.devueltas)} de {num(f.unidades)} ({pct(f.tasa_devolucion)}).
						{/if}
					</p>
				</li>
			{/each}
		</ul>
	{:else if clave === 'sin_resultados'}
		<ul class="lista">
			{#each sinResultados as f, i (`${f.termino}#${i}`)}
				<li class="fila">
					<div class="cabeza">
						<span class="nombre sin-enlace">{f.termino}</span>
						<span class="cifra">{num(f.sesiones)} {num(f.sesiones) === 1 ? 'sesion' : 'sesiones'}</span>
					</div>
					<p class="datos">
						{#if (f.como_lo_escribieron ?? []).length > 1}
							Lo escribieron asi: {f.como_lo_escribieron.join(', ')}.
						{/if}
						Ultima vez el {cuando(f.ultima_busqueda)}
					</p>
				</li>
			{/each}
		</ul>
	{:else}
		<ul class="lista">
			{#each busquedas as f, i (`${f.termino}#${i}`)}
				<li class="fila">
					<div class="cabeza">
						<span class="nombre sin-enlace">{f.termino.trim() === '' ? '(vacio)' : f.termino}</span>
						<span class="diagnostico">
							{f.diagnostico === 'no_tenemos' ? 'No lo tenemos' : 'Hay resultados, nadie entra'}
						</span>
					</div>
					<p class="datos">
						{num(f.busquedas)} busquedas en {num(f.sesiones)} sesiones.
						{#if f.diagnostico === 'no_convence'}
							Hasta {num(f.mas_resultados)} resultados y {num(f.clics)} clics.
						{/if}
					</p>
				</li>
			{/each}
		</ul>
	{/if}
</div>

<style>
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
		margin-bottom: var(--e4);
		font-size: var(--f-base);
		color: var(--tinta);
	}

	.gris {
		color: var(--gris);
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

	.lista {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--e3);
		padding: 0;
	}

	.fila {
		padding: 14px 18px;
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.cabeza {
		display: flex;
		align-items: baseline;
		gap: var(--e2);
		flex-wrap: wrap;
		margin-bottom: 4px;
	}

	.nombre {
		font-size: var(--f-base);
		font-weight: 500;
		color: var(--indigo);
		overflow-wrap: anywhere;
	}

	.nombre.sin-enlace {
		color: var(--tinta);
	}

	.detalle {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.cifra,
	.diagnostico {
		margin-left: auto;
		white-space: nowrap;
	}

	.cifra {
		font-size: var(--f-md);
		font-weight: 500;
	}

	.diagnostico {
		padding: 2px 10px;
		font-size: var(--f-sm);
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: 999px;
	}

	.datos {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.alerta {
		color: var(--rojo);
	}

	@media (max-width: 620px) {
		.cifra,
		.diagnostico {
			margin-left: 0;
		}
	}
</style>
