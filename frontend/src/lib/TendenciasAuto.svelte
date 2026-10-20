<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';
	import Barras from './graficas/Barras.svelte';

	/**
	 * Las consultas AUTOMATICAS y las PROPIAS del panel de Tendencias.
	 *
	 * Lo que pidio el admin, en tres partes:
	 *
	 *  1. Las consultas de siempre se calculan SOLAS al abrir la pantalla. Antes
	 *     habia que elegir una pestana y pulsar para ver un ranking.
	 *  2. "Compras en ascenso", que es lo que pide la Entrega 2 para el panel,
	 *     identificar productos cuya demanda crece de forma reciente. Compara la
	 *     ventana de los ultimos N dias contra los N anteriores.
	 *  3. Un constructor para armar la consulta propia (que medir, cuantos dias,
	 *     cuantos resultados, en que orden, y si se compara contra el periodo
	 *     anterior) y GUARDARLA como automatica, para que se calcule sola desde
	 *     entonces.
	 *
	 * TODO SALE DE LAS SEIS RUTAS QUE YA EXISTEN, `GET /admin/eventos/*`. No hay
	 * ninguna ruta nueva, porque el backend no es de este lado y porque una
	 * consulta libre en SQL que el navegador mandara a ClickHouse seria abrir un
	 * agujero. "Consulta propia" quiere decir elegir los parametros que la ruta
	 * acepta, que son cuatro cosas y cubren lo que un admin necesita.
	 *
	 *
	 * COMO SE COMPARA UN PERIODO CONTRA OTRO
	 * ---------------------------------------------------------------
	 * La ruta solo sabe de "los ultimos N dias", no de "entre el dia A y el B".
	 * Asi que el periodo anterior se saca RESTANDO: se pide la ventana de N dias y
	 * la de 2N, y `antes = total(2N) - total(N)`. Eso solo es exacto cuando el
	 * total SUMA, y en Mesh suman las compras y las devoluciones, que cuentan
	 * unidades. Las vistas, el carrito y las busquedas cuentan sesiones o cuentas
	 * DISTINTAS: una persona que entro en los dos periodos cuenta una sola vez en
	 * 2N, y restar daria un numero falso. Por eso la comparacion solo se ofrece
	 * para compra y devolucion, y lo dice la pantalla.
	 *
	 * Cada ruta trae como maximo 200 filas, asi que la comparacion mira los 200
	 * productos con mas movimiento de cada ventana. Con el catalogo de hoy sobra.
	 * La consulta de ascenso que lee del resumen diario de ClickHouse, y que si
	 * compara vistas, sigue viviendo en la consola de ClickHouse y esta pedida
	 * como ruta en docs/BACKEND-PENDIENTE.md.
	 *
	 * Las consultas propias se guardan en el navegador (localStorage) y no en la
	 * base. Son del admin y de este equipo, y no hay tabla para ellas.
	 */

	let {
		alExpirarSesion,
		verRanking
	}: { alExpirarSesion: () => void; verRanking: (clave: Clave) => void } = $props();

	type Clave = 'vista' | 'carrito' | 'compra' | 'devolucion' | 'busqueda' | 'busqueda-clic';
	type Direccion = 'positivo' | 'negativo';

	interface Medida {
		clave: Clave;
		nombre: string;
		agrupa: 'producto' | 'termino';
		unidad: [string, string];
		/** Si el total SUMA entre ventanas, y por tanto se puede comparar restando. */
		suma: boolean;
		/** El color de su tarjeta (los de lib/graficas). */
		color: string;
		/** Que cuenta la cifra, dicho para cualquiera ("personas que lo vieron"). */
		dice: string;
	}

	// Vistas, busquedas y clics cuentan SESIONES distintas y el carrito CUENTAS
	// distintas; en pantalla las dos son "personas", que es lo que una persona
	// entiende. La diferencia queda aqui y en la ayuda de cada ranking completo.
	const MEDIDAS: Medida[] = [
		{ clave: 'vista', nombre: 'Lo mas visto', agrupa: 'producto', unidad: ['persona', 'personas'], suma: false, color: 'var(--g1)', dice: 'personas que lo vieron' },
		{ clave: 'carrito', nombre: 'Lo que mas llevan al carrito', agrupa: 'producto', unidad: ['persona', 'personas'], suma: false, color: 'var(--g5)', dice: 'personas que lo agregaron' },
		{ clave: 'compra', nombre: 'Lo mas vendido', agrupa: 'producto', unidad: ['unidad', 'unidades'], suma: true, color: 'var(--g3)', dice: 'unidades vendidas' },
		{ clave: 'devolucion', nombre: 'Lo mas devuelto', agrupa: 'producto', unidad: ['unidad', 'unidades'], suma: true, color: 'var(--g4)', dice: 'unidades devueltas' },
		{ clave: 'busqueda', nombre: 'Lo mas buscado', agrupa: 'termino', unidad: ['persona', 'personas'], suma: false, color: 'var(--g2)', dice: 'personas que lo buscaron' },
		{ clave: 'busqueda-clic', nombre: 'Busquedas que terminan en clic', agrupa: 'termino', unidad: ['persona', 'personas'], suma: false, color: 'var(--g6)', dice: 'personas que entraron a un resultado' }
	];

	const medidaDe = (clave: Clave): Medida => MEDIDAS.find((m) => m.clave === clave) ?? MEDIDAS[0];

	interface Consulta {
		id: string;
		nombre: string;
		clave: Clave;
		dias: number;
		limite: number;
		direccion: Direccion;
		comparar: boolean;
		/** Las de fabrica no se pueden quitar. */
		fija?: boolean;
	}

	/**
	 * Las de fabrica: el ranking de cada medida en los ultimos 30 dias (30 y no 7,
	 * porque solo cuentan eventos reales y en una base joven casi todo cae fuera de
	 * una semana), y las compras en ascenso.
	 */
	const DE_FABRICA: Consulta[] = [
		{ id: 'fija-ascenso', nombre: 'Lo que mas esta creciendo', clave: 'compra', dias: 30, limite: 8, direccion: 'positivo', comparar: true, fija: true },
		...MEDIDAS.map<Consulta>((m) => ({
			id: 'fija-' + m.clave,
			nombre: m.nombre,
			clave: m.clave,
			dias: 30,
			limite: 5,
			direccion: 'positivo',
			comparar: false,
			fija: true
		}))
	];

	const LLAVE = 'mesh.tendencias.consultas';

	function leerGuardadas(): Consulta[] {
		try {
			const crudo = localStorage.getItem(LLAVE);
			if (!crudo) return [];
			const lista = JSON.parse(crudo);
			if (!Array.isArray(lista)) return [];
			return lista.filter(
				(c) => c && typeof c.id === 'string' && MEDIDAS.some((m) => m.clave === c.clave) && Number.isFinite(c.dias)
			);
		} catch {
			// localStorage bloqueado o roto: la pantalla sigue, sin consultas propias guardadas.
			return [];
		}
	}

	function escribirGuardadas() {
		try {
			localStorage.setItem(LLAVE, JSON.stringify(guardadas));
		} catch {
			/* sin almacenamiento la consulta sigue en pantalla hasta recargar */
		}
	}

	let guardadas = $state<Consulta[]>([]);
	let todas = $derived([...DE_FABRICA, ...guardadas]);

	interface Fila {
		id: string;
		titulo: string;
		detalle: string | null;
		enlace: string | null;
		total: number;
		antes?: number;
		veces?: number;
	}

	interface Resultado {
		cargando: boolean;
		error: string;
		filas: Fila[];
		/** Cuantas unidades hubo en total, para el pie de una comparacion. */
		nota?: string;
	}

	let resultados = $state<Record<string, Resultado>>({});

	const num = (valor: unknown): number => {
		const n = Number(valor);
		return Number.isFinite(n) ? n : 0;
	};

	interface FilaCruda {
		pid: number | null;
		fila: Fila;
	}

	type Pedido = { ok: true; filas: FilaCruda[] } | { ok: false; error: string; sesion: boolean };

	async function pedirLista(clave: Clave, dias: number, limite: number, direccion: Direccion): Promise<Pedido> {
		const medida = medidaDe(clave);
		const r = await pedir<any[]>(`/admin/eventos/${clave}?dias=${dias}&limite=${limite}&direccion=${direccion}`);
		if (r.estado === 401) return { ok: false, error: '', sesion: true };
		if (!r.ok || !Array.isArray(r.payload)) return { ok: false, error: mensajeUtil(r), sesion: false };

		const filas = r.payload.map((f, i): FilaCruda => {
			if (medida.agrupa === 'producto') {
				const p = f.producto;
				return {
					pid: p && Number.isFinite(Number(p._id)) ? Number(p._id) : null,
					fila: {
						id: `${p?._id ?? 'sin-documento'}#${i}`,
						titulo: p ? String(p.nombre) : 'Producto que ya no existe en el catalogo',
						detalle: p?.categoria?.nombre ?? null,
						enlace: p ? `/producto/${p._id}` : null,
						total: num(f.total)
					}
				};
			}
			const termino = typeof f.termino === 'string' ? f.termino : '';
			return {
				pid: null,
				fila: {
					id: `${termino}#${i}`,
					titulo: termino.trim() === '' ? '(vacio)' : termino,
					detalle: null,
					enlace: null,
					total: num(f.total)
				}
			};
		});
		return { ok: true, filas };
	}

	/** Corre una consulta, simple o comparada, y deja el resultado en pantalla. */
	async function ejecutar(c: Consulta): Promise<Resultado> {
		resultados[c.id] = { cargando: true, error: '', filas: [] };
		const res = await calcular(c);
		resultados[c.id] = res;
		return res;
	}

	async function calcular(c: Consulta): Promise<Resultado> {
		if (!c.comparar) {
			const p = await pedirLista(c.clave, c.dias, c.limite, c.direccion);
			if (!p.ok) {
				if (p.sesion) alExpirarSesion();
				return { cargando: false, error: p.error, filas: [] };
			}
			return { cargando: false, error: '', filas: p.filas.map((x) => x.fila) };
		}

		if (!medidaDe(c.clave).suma) {
			return { cargando: false, error: 'Solo se pueden comparar las compras y las devoluciones.', filas: [] };
		}
		if (c.dias * 2 > 365) {
			return { cargando: false, error: 'Para comparar usa 182 dias o menos.', filas: [] };
		}

		const [ahoraP, totalP] = await Promise.all([
			pedirLista(c.clave, c.dias, 200, 'positivo'),
			pedirLista(c.clave, c.dias * 2, 200, 'positivo')
		]);
		for (const p of [ahoraP, totalP]) {
			if (!p.ok) {
				if (p.sesion) alExpirarSesion();
				return { cargando: false, error: p.error, filas: [] };
			}
		}
		if (!ahoraP.ok || !totalP.ok) return { cargando: false, error: '', filas: [] };

		const ahora = new Map<number, number>();
		for (const f of ahoraP.filas) if (f.pid !== null) ahora.set(f.pid, f.fila.total);

		// La union es la ventana grande: todo lo que se movio en los 2N dias, este o
		// no en los ultimos N. Lo que tuvo movimiento antes y ahora no, es una baja.
		const filas: Fila[] = [];
		for (const f of totalP.filas) {
			if (f.pid === null) continue;
			const en = ahora.get(f.pid) ?? 0;
			const antes = Math.max(0, f.fila.total - en);
			filas.push({
				...f.fila,
				id: `${f.pid}`,
				total: en,
				antes,
				veces: en / Math.max(antes, 1)
			});
		}

		const elegidas =
			c.direccion === 'positivo'
				? filas.filter((f) => f.total > 0).sort((a, b) => (b.veces ?? 0) - (a.veces ?? 0) || b.total - a.total)
				: filas.filter((f) => (f.antes ?? 0) > f.total).sort((a, b) => (b.antes ?? 0) - b.total - ((a.antes ?? 0) - a.total));

		const nota = `De ${filas.length} productos que se vendieron en los ultimos ${c.dias * 2} dias.`;
		return { cargando: false, error: '', filas: elegidas.slice(0, c.limite), nota };
	}

	async function medirTodo() {
		await Promise.all(todas.map((c) => ejecutar(c)));
	}

	onMount(() => {
		guardadas = leerGuardadas();
		void medirTodo();
	});

	// -- el constructor --

	let bClave = $state<Clave>('compra');
	let bDias = $state(30);
	let bLimite = $state(10);
	let bDireccion = $state<Direccion>('positivo');
	let bComparar = $state(false);
	let bNombre = $state('');
	let bError = $state('');
	let bResultado = $state<Resultado | null>(null);
	let bConsulta = $state<Consulta | null>(null);

	let puedeComparar = $derived(medidaDe(bClave).suma);

	/**
	 * La casilla de comparar ya no se deshabilita. Una casilla apagada sin
	 * explicacion se lee como un boton roto. Se deja pulsar y, si la medida no
	 * se puede comparar, se queda sin marcar y dice por que, en el momento y con
	 * un boton para pasar a la medida que si se puede.
	 */
	let avisoComparar = $state(false);

	function alCambiarComparar() {
		if (puedeComparar) {
			avisoComparar = false;
			return;
		}
		bComparar = false;
		avisoComparar = true;
	}

	function pasarACompras() {
		bClave = 'compra';
		avisoComparar = false;
		bComparar = true;
	}

	function armar(): Consulta | null {
		bError = '';
		const dias = Math.trunc(Number(bDias));
		const limite = Math.trunc(Number(bLimite));
		if (!Number.isFinite(dias) || dias < 1 || dias > 365) {
			bError = 'Los dias van de 1 a 365.';
			return null;
		}
		if (!Number.isFinite(limite) || limite < 1 || limite > 200) {
			bError = 'Cuantos va de 1 a 200.';
			return null;
		}
		return {
			id: 'propia-' + Date.now().toString(36),
			nombre: bNombre.trim(),
			clave: bClave,
			dias,
			limite,
			direccion: bDireccion,
			comparar: bComparar && puedeComparar
		};
	}

	async function consultar() {
		const c = armar();
		if (!c) return;
		bConsulta = c;
		bResultado = { cargando: true, error: '', filas: [] };
		bResultado = await calcular(c);
	}

	function guardar() {
		if (!bConsulta) return;
		const nombre = bNombre.trim() || describir(bConsulta);
		const c: Consulta = { ...bConsulta, nombre };
		guardadas = [...guardadas, c];
		escribirGuardadas();
		bNombre = '';
		if (bResultado) resultados[c.id] = bResultado;
		bConsulta = null;
		bResultado = null;
	}

	function quitar(c: Consulta) {
		guardadas = guardadas.filter((g) => g.id !== c.id);
		escribirGuardadas();
		delete resultados[c.id];
	}

	/** El nombre corto de cada medida, para el constructor y lo que se guarda. */
	const CORTO: Record<Clave, string> = {
		vista: 'Vistas',
		carrito: 'Carrito',
		compra: 'Compras',
		devolucion: 'Devoluciones',
		busqueda: 'Busquedas',
		'busqueda-clic': 'Clics en resultados'
	};

	function describir(c: Consulta): string {
		const m = { nombre: CORTO[c.clave] };
		const cuando = c.dias === 1 ? 'ultimo dia' : `ultimos ${c.dias} dias`;
		const orden = c.direccion === 'positivo' ? 'los que mas' : 'los que menos';
		if (c.comparar) {
			return c.direccion === 'positivo'
				? `${m.nombre} en ascenso, ${cuando}`
				: `${m.nombre} en caida, ${cuando}`;
		}
		return `${m.nombre}, ${orden}, ${cuando}`;
	}

	function subtitulo(c: Consulta): string {
		const cuando = c.dias === 1 ? 'Ultimo dia' : `Ultimos ${c.dias} dias`;
		if (c.comparar) return `Ventas de los ${cuando.toLowerCase()} contra los ${c.dias} anteriores`;
		// La unidad va aqui y no en cada fila: en una tarjeta angosta "unidades
		// vendidas" al lado de cada numero le quitaba el sitio al nombre.
		return `${cuando}, en ${medidaDe(c.clave).dice}`;
	}

	/** Una fila de la consulta como la pinta lib/graficas/Barras. */
	function aBarras(filas: Fila[], comparar: boolean) {
		return filas.map((f) => ({
			id: f.id,
			nombre: f.titulo,
			valor: f.total,
			antes: comparar ? (f.antes ?? 0) : null,
			enlace: f.enlace
		}));
	}

	/** El primero de cada ranking de fabrica, para los destacados de arriba. */
	function primero(clave: Clave): Fila | null {
		const r = resultados['fija-' + clave];
		return r && !r.cargando && !r.error && r.filas.length ? r.filas[0] : null;
	}

	const DESTACADOS: { clave: Clave; rotulo: string }[] = [
		{ clave: 'compra', rotulo: 'El mas vendido' },
		{ clave: 'vista', rotulo: 'El mas visto' },
		{ clave: 'busqueda', rotulo: 'Lo mas buscado' },
		{ clave: 'devolucion', rotulo: 'El mas devuelto' }
	];

</script>

<div class="auto">
	<div class="cabeza">
		<h3>Este mes</h3>
		<button type="button" class="suave" onclick={medirTodo}>Actualizar</button>
	</div>

	<!-- Lo primero de cada ranking, en grande: se lee de un vistazo sin bajar. -->
	<div class="destacados">
		{#each DESTACADOS as d (d.clave)}
			{@const f = primero(d.clave)}
			{@const m = medidaDe(d.clave)}
			<div class="destacado" style="--color: {m.color}">
				<span class="rotulo">{d.rotulo}</span>
				{#if f}
					{#if f.enlace}
						<a class="quien" href={f.enlace} title={f.titulo}>{f.titulo}</a>
					{:else}
						<span class="quien" title={f.titulo}>{f.titulo}</span>
					{/if}
					<span class="cuanto"><strong>{f.total}</strong> {m.dice}</span>
				{:else}
					<span class="quien vacio">{resultados['fija-' + d.clave]?.cargando === false ? 'Nada este mes' : '...'}</span>
				{/if}
			</div>
		{/each}
	</div>

	<div class="rejilla">
		{#each todas as c (c.id)}
			{@const m = medidaDe(c.clave)}
			{@const res = resultados[c.id]}
			<article class="tarjeta" class:destacada={c.id === 'fija-ascenso'} style="--color: {c.comparar ? 'var(--g3)' : m.color}">
				<header>
					<div>
						<h4>{c.nombre}</h4>
						<p class="sub">{subtitulo(c)}</p>
					</div>
					{#if c.fija && !c.comparar}
						<button type="button" class="suave" onclick={() => verRanking(c.clave)}>Ver mas</button>
					{:else if !c.fija}
						<button type="button" class="suave" onclick={() => quitar(c)}>Quitar</button>
					{/if}
				</header>

				{#if !res || res.cargando}
					<p class="gris">Calculando...</p>
				{:else if res.error}
					<p class="fallo" role="alert">{res.error}</p>
				{:else if res.filas.length === 0}
					<p class="gris">{c.comparar ? 'Nada sube ni baja en estos dias.' : 'Nada en estos dias.'}</p>
				{:else}
					<Barras
						filas={aBarras(res.filas, c.comparar)}
						color={c.comparar ? 'var(--g3)' : m.color}
						compacta={!c.comparar}
						columnas={c.id === 'fija-ascenso' ? 2 : 1}
					/>
					{#if c.comparar}
						<p class="leyenda">
							<span class="muestra antes"></span> mes anterior
							<span class="muestra ahora"></span> este mes
							{#if res.nota}<span class="pie">{res.nota}</span>{/if}
						</p>
					{/if}
				{/if}
			</article>
		{/each}
	</div>

	<div class="constructor">
		<h3>Arma tu propio ranking</h3>
		<p class="nota">Elige que ver y de cuantos dias. Si lo guardas, aparece arriba cada vez que entres.</p>

		<div class="mandos">
			<label>
				<span>Que ver</span>
				<select bind:value={bClave} onchange={() => { if (!puedeComparar) bComparar = false; avisoComparar = false; }}>
					{#each MEDIDAS as m (m.clave)}
						<option value={m.clave}>{CORTO[m.clave]}</option>
					{/each}
				</select>
			</label>
			<label>
				<span>Dias</span>
				<input type="number" min="1" max="365" bind:value={bDias} />
			</label>
			<label>
				<span>Cuantos</span>
				<input type="number" min="1" max="200" bind:value={bLimite} />
			</label>
			<label>
				<span>Orden</span>
				<select bind:value={bDireccion}>
					<option value="positivo">{bComparar ? 'Los que suben' : 'Los que mas'}</option>
					<option value="negativo">{bComparar ? 'Los que bajan' : 'Los que menos'}</option>
				</select>
			</label>
		</div>

		<label class="comparar" class:apagado={!puedeComparar}>
			<input type="checkbox" bind:checked={bComparar} onchange={alCambiarComparar} />
			Comparar con los dias anteriores
			{#if !puedeComparar}
				<small class:aviso={avisoComparar}>
					Solo para compras y devoluciones.
					{#if avisoComparar}
						<button type="button" class="enlace" onclick={pasarACompras}>Pasar a compras</button>
					{/if}
				</small>
			{/if}
		</label>

		<div class="acciones">
			<button type="button" class="primaria" onclick={consultar}>Ver</button>
		</div>

		{#if bError}
			<p class="fallo" role="alert">{bError}</p>
		{/if}

		{#if bResultado && bConsulta}
			{@const m = medidaDe(bConsulta.clave)}
			<article class="tarjeta previa" style="--color: {m.color}">
				<header>
					<div>
						<h4>{describir(bConsulta)}</h4>
						<p class="sub">{subtitulo(bConsulta)}</p>
					</div>
				</header>
				{#if bResultado.cargando}
					<p class="gris">Calculando...</p>
				{:else if bResultado.error}
					<p class="fallo" role="alert">{bResultado.error}</p>
				{:else if bResultado.filas.length === 0}
					<p class="gris">Nada en estos dias.</p>
				{:else}
					<Barras filas={aBarras(bResultado.filas, bConsulta.comparar)} color={m.color} compacta />
				{/if}

				{#if !bResultado.cargando && !bResultado.error}
					<div class="guardar">
						<input type="text" placeholder="Ponle un nombre (opcional)" maxlength="60" bind:value={bNombre} />
						<button type="button" class="primaria" onclick={guardar}>Guardar</button>
					</div>
				{/if}
			</article>
		{/if}
	</div>
</div>

<style>
	.auto {
		display: flex;
		flex-direction: column;
		gap: var(--e4);
	}

	.cabeza {
		display: flex;
		align-items: center;
		gap: var(--e2);
		flex-wrap: wrap;
	}

	h3 {
		font-size: var(--f-lg);
		margin-right: auto;
	}

	h4 {
		font-size: var(--f-md);
		color: var(--tinta);
	}

	.nota,
	.sub,
	.pie,
	.gris {
		color: var(--gris);
		font-size: var(--f-sm);
	}

	.nota {
		max-width: 680px;
	}

	/* -- los destacados -- */

	.destacados {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
		gap: var(--e3);
	}

	.destacado {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 6px;
		min-width: 0;
		padding: 16px 18px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
	}

	.rotulo {
		font-size: var(--f-xs);
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--color);
	}

	.quien {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		font-size: var(--f-md);
		font-weight: 600;
		color: var(--tinta);
		text-decoration: none;
	}

	a.quien:hover {
		text-decoration: underline;
	}

	.quien.vacio {
		font-weight: 400;
		color: var(--gris);
	}

	.cuanto {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.cuanto strong {
		font-size: var(--f-lg);
		color: var(--tinta);
		font-variant-numeric: tabular-nums;
	}

	/* -- las tarjetas -- */

	.rejilla {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(330px, 1fr));
		gap: var(--e4);
	}

	.tarjeta {
		position: relative;
		display: flex;
		flex-direction: column;
		gap: 14px;
		padding: 18px 20px;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
	}

	.tarjeta.destacada {
		grid-column: 1 / -1;
	}

	.tarjeta header {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: 10px;
	}

	.leyenda {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 6px 14px;
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.leyenda .pie {
		margin-left: auto;
		font-size: var(--f-xs);
	}

	.muestra {
		display: inline-block;
		width: 18px;
		height: 8px;
		margin-right: -8px;
		border-radius: 999px;
	}

	.muestra.antes {
		background: color-mix(in srgb, var(--g3) 28%, transparent);
	}

	.muestra.ahora {
		background: var(--g3);
	}

	.fallo {
		color: var(--rojo);
		font-size: var(--f-sm);
	}

	/* -- el constructor -- */

	.constructor {
		display: flex;
		flex-direction: column;
		gap: 12px;
		margin-top: var(--e3);
		padding-top: 20px;
		border-top: 1px solid var(--linea);
	}

	.mandos {
		display: flex;
		flex-wrap: wrap;
		gap: 14px;
	}

	.mandos label {
		display: flex;
		flex-direction: column;
		gap: 4px;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	select,
	input[type='number'],
	input[type='text'] {
		padding: 8px 10px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	input[type='number'] {
		width: 110px;
	}

	.comparar {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 8px;
		font-size: var(--f-base);
	}

	.comparar.apagado {
		color: var(--gris);
	}

	.comparar small {
		color: var(--gris);
		font-size: var(--f-sm);
	}

	.comparar small.aviso {
		padding: 6px 10px;
		color: var(--tinta);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.enlace {
		margin-left: 8px;
		padding: 2px 10px;
		color: var(--indigo);
		border-color: var(--indigo);
	}

	.guardar {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		margin-top: 6px;
		padding-top: 12px;
		border-top: 1px solid var(--linea);
	}

	.guardar input {
		flex: 1 1 220px;
	}

	button {
		padding: 7px 14px;
		font-family: inherit;
		font-size: var(--f-sm);
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	button.suave:hover {
		color: var(--indigo);
		border-color: var(--indigo);
	}

	button.primaria {
		color: var(--sobre-indigo);
		background: var(--indigo);
		border-color: var(--indigo);
		font-size: var(--f-base);
	}

	.tarjeta.previa {
		border-style: dashed;
	}
</style>
