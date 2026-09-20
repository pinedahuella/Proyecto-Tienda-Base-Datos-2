<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';

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
	}

	const MEDIDAS: Medida[] = [
		{ clave: 'vista', nombre: 'Vistas', agrupa: 'producto', unidad: ['sesion distinta', 'sesiones distintas'], suma: false },
		{ clave: 'carrito', nombre: 'Carrito', agrupa: 'producto', unidad: ['cuenta distinta', 'cuentas distintas'], suma: false },
		{ clave: 'compra', nombre: 'Compras', agrupa: 'producto', unidad: ['unidad', 'unidades'], suma: true },
		{ clave: 'devolucion', nombre: 'Devoluciones', agrupa: 'producto', unidad: ['unidad', 'unidades'], suma: true },
		{ clave: 'busqueda', nombre: 'Busquedas', agrupa: 'termino', unidad: ['sesion distinta', 'sesiones distintas'], suma: false },
		{ clave: 'busqueda-clic', nombre: 'Clics de busqueda', agrupa: 'termino', unidad: ['sesion distinta', 'sesiones distintas'], suma: false }
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
		{ id: 'fija-ascenso', nombre: 'Compras en ascenso', clave: 'compra', dias: 30, limite: 8, direccion: 'positivo', comparar: true, fija: true },
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
			return { cargando: false, error: 'Solo se puede comparar compras y devoluciones, que suman unidades.', filas: [] };
		}
		if (c.dias * 2 > 365) {
			return { cargando: false, error: 'Comparar necesita el doble de la ventana y el maximo es 365 dias. Usa 182 o menos.', filas: [] };
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

		const nota = `Los ultimos ${c.dias} dias contra los ${c.dias} anteriores, sobre los ${filas.length} productos con movimiento en ${c.dias * 2} dias.`;
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

	function describir(c: Consulta): string {
		const m = medidaDe(c.clave);
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
		if (c.comparar) return `${cuando} contra los ${c.dias} anteriores`;
		return `${cuando}, ${c.direccion === 'positivo' ? 'los ' + c.limite + ' que mas' : 'los ' + c.limite + ' que menos'}`;
	}

	function veces(f: Fila): string {
		if ((f.antes ?? 0) === 0) return f.total > 0 ? 'nuevo' : '0';
		return `${(f.veces ?? 0).toFixed(1)} veces`;
	}

	/** El ancho de una barra, en porcentaje del mayor valor que se dibuja. */
	function pct(valor: number, tope: number): number {
		return Math.max(0, Math.min(100, (valor / tope) * 100));
	}

	/** El texto que sale al pasar el cursor por una fila, con el nombre completo. */
	function detalle(f: Fila, comparar: boolean, m: Medida): string {
		if (comparar) return `${f.titulo}, ${f.antes ?? 0} en el periodo anterior y ${f.total} ahora`;
		return `${f.titulo}, ${f.total} ${f.total === 1 ? m.unidad[0] : m.unidad[1]}`;
	}
</script>

<!--
	Las filas de un ranking, una sola vez para las tarjetas de fabrica y para la
	vista previa del constructor.

	La barra mide contra el MAYOR valor que se dibuja en esa tarjeta, asi que se
	comparan entre si y no contra un tope inventado. Una barra de cero no existe,
	pero una de uno junto a una de cuarenta y cinco se queda con un minimo para
	que se vea.

	En "en ascenso" la barra es el periodo actual y la marca vertical es donde
	estaba el periodo anterior: de un vistazo se ve cuanto se movio cada producto.
	Un producto nuevo no tiene marca, porque antes no vendia nada.
-->
{#snippet ranking(filas: Fila[], comparar: boolean, m: Medida)}
	{@const tope = Math.max(1, ...filas.map((x) => Math.max(x.total, x.antes ?? 0)))}
	<ol class="filas">
		{#each filas as f, i (f.id)}
			<li title={detalle(f, comparar, m)}>
				<span class="puesto" class:podio={i < 3}>{i + 1}</span>
				{#if f.enlace}
					<a href={f.enlace} class="nombre">{f.titulo}</a>
				{:else}
					<span class="nombre">{f.titulo}</span>
				{/if}
				{#if comparar}
					<span class="cifra">
						<strong>{f.antes} a {f.total}</strong>
						<small class="chip" class:nuevo={(f.antes ?? 0) === 0}>{veces(f)}</small>
					</span>
				{:else}
					<span class="cifra">
						<strong>{f.total}</strong>
						<small>{f.total === 1 ? m.unidad[0] : m.unidad[1]}</small>
					</span>
				{/if}
				<span class="pista" aria-hidden="true">
					<span class="ahora" style="width: {pct(f.total, tope)}%"></span>
					{#if comparar && (f.antes ?? 0) > 0}
						<span class="antes" style="left: {pct(f.antes ?? 0, tope)}%"></span>
					{/if}
				</span>
			</li>
		{/each}
	</ol>
	{#if comparar}
		<p class="leyenda">
			<span class="muestra-ahora"></span> periodo actual
			<span class="muestra-antes"></span> periodo anterior
		</p>
	{/if}
{/snippet}

<div class="auto">
	<div class="cabeza">
		<h3>Consultas automaticas</h3>
		<button type="button" class="suave" onclick={medirTodo}>Volver a medir todo</button>
	</div>
	<p class="nota">
		Se calculan solas al abrir esta pantalla, no hay que pulsar nada. Las de abajo son las de fabrica y
		las que guardes tu con el constructor.
	</p>

	<div class="rejilla">
		{#each todas as c (c.id)}
			{@const m = medidaDe(c.clave)}
			{@const res = resultados[c.id]}
			<article class="tarjeta" class:destacada={c.id === 'fija-ascenso'}>
				<header>
					<div>
						<h4>{c.nombre}</h4>
						<p class="sub">{subtitulo(c)}</p>
					</div>
					{#if c.fija && !c.comparar}
						<button type="button" class="suave" onclick={() => verRanking(c.clave)}>Ver completo</button>
					{:else if !c.fija}
						<button type="button" class="suave" onclick={() => quitar(c)}>Quitar</button>
					{/if}
				</header>

				{#if !res || res.cargando}
					<p class="gris">Midiendo...</p>
				{:else if res.error}
					<p class="fallo" role="alert">{res.error}</p>
				{:else if res.filas.length === 0}
					<p class="gris">
						{c.comparar
							? 'Ningun producto cumple, ni sube ni baja en esta ventana.'
							: 'Sin eventos reales en esta ventana.'}
					</p>
				{:else}
					{@render ranking(res.filas, c.comparar, m)}
					{#if res.nota}
						<p class="pie">{res.nota}</p>
					{/if}
				{/if}
			</article>
		{/each}
	</div>

	<div class="constructor">
		<h3>Crear mi propia consulta</h3>
		<p class="nota">
			Elige que medir, cuantos dias, cuantos resultados y en que orden. Con compras y devoluciones se
			puede comparar contra el periodo anterior para ver que sube o que baja. Si la guardas, se calcula
			sola cada vez que abras esta pantalla.
		</p>

		<div class="mandos">
			<label>
				<span>Que medir</span>
				<select bind:value={bClave} onchange={() => { if (!puedeComparar) bComparar = false; avisoComparar = false; }}>
					{#each MEDIDAS as m (m.clave)}
						<option value={m.clave}>{m.nombre}</option>
					{/each}
				</select>
			</label>
			<label>
				<span>Dias hacia atras</span>
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
			Comparar contra el periodo anterior
			{#if !puedeComparar}
				<small class:aviso={avisoComparar}>
					Solo funciona con compras y devoluciones. Las demas cuentan sesiones o cuentas distintas, y
					dos periodos no se pueden restar sin dar un numero falso.
					{#if avisoComparar}
						<button type="button" class="enlace" onclick={pasarACompras}>Pasar a compras y comparar</button>
					{/if}
				</small>
			{/if}
		</label>

		<div class="acciones">
			<button type="button" class="primaria" onclick={consultar}>Consultar</button>
		</div>

		{#if bError}
			<p class="fallo" role="alert">{bError}</p>
		{/if}

		{#if bResultado && bConsulta}
			{@const m = medidaDe(bConsulta.clave)}
			<article class="tarjeta previa">
				<header>
					<div>
						<h4>{describir(bConsulta)}</h4>
						<p class="sub">{subtitulo(bConsulta)}</p>
					</div>
				</header>
				{#if bResultado.cargando}
					<p class="gris">Midiendo...</p>
				{:else if bResultado.error}
					<p class="fallo" role="alert">{bResultado.error}</p>
				{:else if bResultado.filas.length === 0}
					<p class="gris">Sin resultados en esta ventana.</p>
				{:else}
					{@render ranking(bResultado.filas, bConsulta.comparar, m)}
					{#if bResultado.nota}<p class="pie">{bResultado.nota}</p>{/if}
				{/if}

				{#if !bResultado.cargando && !bResultado.error}
					<div class="guardar">
						<input type="text" placeholder="Nombre de la consulta (opcional)" maxlength="60" bind:value={bNombre} />
						<button type="button" class="primaria" onclick={guardar}>Guardar como automatica</button>
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
		gap: var(--e3, 16px);
	}

	.cabeza {
		display: flex;
		align-items: center;
		gap: var(--e2, 10px);
		flex-wrap: wrap;
	}

	h3 {
		font-size: var(--f-lg, 1.15rem);
		margin-right: auto;
	}

	h4 {
		font-size: var(--f-base);
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

	.rejilla {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(340px, 1fr));
		gap: var(--e3, 16px);
	}

	.tarjeta {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 16px 18px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.tarjeta.destacada {
		border-color: var(--indigo);
		grid-column: 1 / -1;
	}

	.tarjeta header {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: 10px;
	}

	.filas {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.filas li {
		display: grid;
		grid-template-columns: 24px minmax(0, 1fr) auto;
		grid-template-areas: 'p n c' '. b b';
		align-items: center;
		column-gap: 10px;
		row-gap: 6px;
		/* El relleno y el margen negativo dejan la fila con aire para el
		   resaltado al pasar el cursor sin correr el texto de la tarjeta. */
		padding: 6px 8px;
		margin: 0 -8px;
		border-radius: var(--r);
		transition: background var(--t);
	}

	.filas li:hover {
		background: var(--off);
	}

	/* El puesto es una insignia redonda. Los tres primeros van tenidos de indigo,
	   el resto queda en gris: el podio se lee sin gastar un color mas. */
	.puesto {
		grid-area: p;
		display: grid;
		place-items: center;
		width: 24px;
		height: 24px;
		border-radius: 50%;
		font-size: var(--f-xs);
		font-weight: 600;
		font-variant-numeric: tabular-nums;
		color: var(--gris);
		background: var(--off);
		border: 1px solid var(--linea);
	}

	.puesto.podio {
		color: var(--indigo);
		background: var(--indigo-cl);
		border-color: transparent;
	}

	.nombre {
		grid-area: n;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		color: var(--indigo);
	}

	span.nombre {
		color: var(--tinta);
	}

	.cifra {
		grid-area: c;
		display: flex;
		align-items: baseline;
		gap: 6px;
		text-align: right;
		white-space: nowrap;
	}

	.cifra strong {
		font-variant-numeric: tabular-nums;
		color: var(--tinta);
	}

	.cifra small {
		color: var(--gris);
	}

	/* "2.3 veces" o "nuevo" como una etiqueta chica. Va tenida de indigo y no
	   de verde: el verde de estado esta reservado para lo que es bueno o malo,
	   y que un producto suba no siempre lo es. */
	.cifra .chip {
		padding: 1px 8px;
		border-radius: 999px;
		font-size: var(--f-xs);
		color: var(--indigo);
		background: var(--indigo-cl);
	}

	.cifra .chip.nuevo {
		color: var(--sobre-indigo);
		background: var(--indigo);
	}

	/* La pista de la barra es del mismo indigo pero casi transparente, asi se
	   ve en claro y en oscuro sin una variable nueva. */
	.pista {
		grid-area: b;
		position: relative;
		display: block;
		height: 8px;
		border-radius: 4px;
		background: color-mix(in srgb, var(--indigo) 12%, transparent);
	}

	/* Ancla en el cero, la punta del dato redondeada. El minimo de 4px es para
	   que un 1 junto a un 45 no desaparezca. */
	.ahora {
		display: block;
		height: 100%;
		min-width: 4px;
		border-radius: 4px;
		background: var(--indigo);
		transition: width 0.5s ease;
	}

	/* La marca del periodo anterior. Sobresale de la pista para verse aunque
	   caiga dentro de la barra, y lleva un borde del color de la tarjeta para
	   separarse de ella. */
	.antes {
		position: absolute;
		top: -3px;
		bottom: -3px;
		width: 3px;
		margin-left: -1px;
		border-radius: 2px;
		background: var(--tinta);
		box-shadow: 0 0 0 1px var(--blanco);
	}

	.leyenda {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 6px 14px;
		margin: 2px 0 0;
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.muestra-ahora,
	.muestra-antes {
		display: inline-block;
		vertical-align: middle;
		margin-right: 4px;
	}

	.muestra-ahora {
		width: 16px;
		height: 8px;
		border-radius: 4px;
		background: var(--indigo);
	}

	.muestra-antes {
		width: 3px;
		height: 14px;
		border-radius: 2px;
		background: var(--tinta);
	}

	/* La tarjeta ancha (compras en ascenso) reparte sus filas en columnas: a
	   1100 px de ancho una sola columna deja el nombre en un extremo y la cifra
	   en el otro, y obliga a bajar por la pagina. */
	.tarjeta.destacada .filas {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(330px, 1fr));
		gap: 4px 32px;
	}

	.tarjeta.destacada {
		background: linear-gradient(180deg, var(--indigo-cl), var(--blanco) 90px);
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
		padding-top: 18px;
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
		flex-basis: 100%;
		color: var(--gris);
		font-size: var(--f-sm);
	}

	.comparar small.aviso {
		padding: 8px 10px;
		color: var(--tinta);
		background: var(--panel);
		border-left: 3px solid var(--rojo);
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
	}

	button.primaria {
		color: #fff;
		background: var(--indigo);
		border-color: var(--indigo);
		font-size: var(--f-base);
	}

	.tarjeta.previa {
		border-style: dashed;
	}
</style>
