<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';
	import Barras from './graficas/Barras.svelte';

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
			nombre: 'Cada vez mas vistos',
			explica: 'Productos que la gente esta mirando mas que antes. Si una sola persona los abre muchas veces, puede no ser interes real.'
		},
		{
			clave: 'embudo',
			nombre: 'Donde se pierde la venta',
			explica: 'Productos que muchos miran y pocos compran, o que se devuelven mucho. Conviene revisar su precio, sus fotos o su descripcion.'
		},
		{
			clave: 'busquedas',
			nombre: 'Busquedas sin respuesta',
			explica: 'Lo que la gente busco y no encontro, o encontro y no le convencio. Son ventas que se van a otra tienda.'
		},
		{
			clave: 'sin_resultados',
			nombre: 'Lo que piden y no tenemos',
			explica: 'Lo mas buscado que no encontro nada. Junta las distintas formas de escribir lo mismo.'
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
		if (clave === 'ascenso') return `Ningun producto crecio en los ultimos ${diasRecientes} dias.`;
		if (clave === 'embudo') return `Ningun producto pierde ventas en los ultimos ${diasVentana} dias.`;
		if (clave === 'sin_resultados') return `En los ultimos ${diasVentana} dias todo lo que buscaron lo tenemos.`;
		return `Ninguna busqueda se quedo sin respuesta en los ultimos ${diasVentana} dias.`;
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
				<span>Dias</span>
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
		<button type="button" onclick={cargar} disabled={cargando}>Actualizar</button>
	</div>

	<p class="mide">{actual.explica}</p>

	{#if cargando}
		<p class="gris">Calculando...</p>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if filas === 0}
		<p class="vacio">{vacio()}</p>
	{:else if clave === 'ascenso'}
		<Barras
			color="var(--g1)"
			filas={ascenso.map((f, i) => ({
				id: `${f.producto?._id ?? 'x'}#${i}`,
				nombre: nombreProducto(f.producto),
				valor: num(f.por_dia_ahora),
				antes: num(f.por_dia_antes),
				texto: `${uno(f.por_dia_ahora)} al dia`,
				detalle: num(f.vistas_por_persona) >= 5 ? `ojo, ${uno(f.vistas_por_persona)} vistas por persona` : null,
				enlace: f.producto ? `/producto/${f.producto._id}` : null
			}))}
		/>
		<p class="leyenda"><span class="muestra antes"></span> vistas al dia antes <span class="muestra ahora"></span> vistas al dia ahora</p>
	{:else if clave === 'embudo'}
		<ul class="embudos">
			{#each embudo as f, i (`${f.producto?._id ?? 'x'}#${i}`)}
				{@const vieron = Math.max(num(f.sesiones), num(f.en_carrito), num(f.pedidos), num(f.devueltas), 1)}
				<li>
					<div class="cabeza">
						{#if f.producto}
							<a class="nombre" href="/producto/{f.producto._id}">{nombreProducto(f.producto)}</a>
						{:else}
							<span class="nombre sin-enlace">{nombreProducto(null)}</span>
						{/if}
						<span class="diagnostico" class:devuelve={f.diagnostico === 'devolucion_alta'}>
							{f.diagnostico === 'devolucion_alta' ? 'Se devuelve mucho' : 'Lo miran y no lo compran'}
						</span>
					</div>
					<div class="pasos">
						{#each [
							{ nombre: 'Lo vieron', valor: num(f.sesiones), color: 'var(--g1)' },
							{ nombre: 'Al carrito', valor: num(f.en_carrito), color: 'var(--g5)' },
							{ nombre: 'Lo compraron', valor: num(f.pedidos), color: 'var(--g3)' },
							{ nombre: 'Lo devolvieron', valor: num(f.devueltas), color: 'var(--g4)' }
						] as p (p.nombre)}
							<div class="paso">
								<span class="paso-nombre">{p.nombre}</span>
								<span class="paso-barra"><span style="width: {Math.max((p.valor / vieron) * 100, p.valor > 0 ? 2 : 0)}%; background: {p.color}"></span></span>
								<span class="paso-cifra">{p.valor}</span>
							</div>
						{/each}
					</div>
					<p class="datos">
						{#if f.diagnostico === 'devolucion_alta'}
							Vuelve el {pct(f.tasa_devolucion)} de lo que se vende.
						{:else if num(f.sesiones) > 0 && num(f.conversion) <= 1}
							Solo lo compra el {pct(f.conversion)} de quienes lo ven.
						{/if}
					</p>
				</li>
			{/each}
		</ul>
	{:else if clave === 'sin_resultados'}
		<Barras
			color="var(--g2)"
			unidad="personas"
			filas={sinResultados.map((f, i) => ({
				id: `${f.termino}#${i}`,
				nombre: f.termino,
				valor: num(f.sesiones),
				detalle: (f.como_lo_escribieron ?? []).length > 1 ? `tambien ${f.como_lo_escribieron.filter((x) => x !== f.termino).slice(0, 3).join(', ')}` : null
			}))}
		/>
	{:else}
		<Barras
			color="var(--g6)"
			unidad="personas"
			filas={busquedas.map((f, i) => ({
				id: `${f.termino}#${i}`,
				nombre: f.termino.trim() === '' ? '(vacio)' : f.termino,
				valor: num(f.sesiones),
				detalle: f.diagnostico === 'no_tenemos' ? 'no lo tenemos' : `${num(f.clics)} clics en ${num(f.mas_resultados)} resultados`
			}))}
		/>
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


	.diagnostico {
		margin-left: auto;
		white-space: nowrap;
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


	@media (max-width: 620px) {
		.diagnostico {
			margin-left: 0;
		}
	}

	/* -- las barras y el embudo -- */

	.leyenda {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 6px 14px;
		margin-top: var(--e3);
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.muestra {
		display: inline-block;
		width: 18px;
		height: 8px;
		margin-right: -8px;
		border-radius: 999px;
	}

	.muestra.antes {
		background: color-mix(in srgb, var(--g1) 28%, transparent);
	}

	.muestra.ahora {
		background: var(--g1);
	}

	.embudos {
		list-style: none;
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(330px, 1fr));
		gap: var(--e3);
	}

	.embudos li {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 16px 18px;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.diagnostico.devuelve {
		color: var(--rojo);
	}

	.pasos {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.paso {
		display: grid;
		grid-template-columns: 96px 1fr 36px;
		align-items: center;
		gap: var(--e2);
		font-size: var(--f-sm);
	}

	.paso-nombre {
		color: var(--gris);
	}

	.paso-barra {
		height: 10px;
		background: var(--panel);
		border-radius: 999px;
		overflow: hidden;
	}

	.paso-barra span {
		display: block;
		height: 100%;
		border-radius: 999px;
	}

	.paso-cifra {
		font-weight: 600;
		text-align: right;
		color: var(--tinta);
		font-variant-numeric: tabular-nums;
	}
</style>
