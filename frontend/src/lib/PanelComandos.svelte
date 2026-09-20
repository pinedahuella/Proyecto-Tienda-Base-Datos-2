<script lang="ts">
	import { onMount, tick } from 'svelte';

	/**
	 * Comandos de desarrollo dentro de Mesh: levantar las bases, el backend y el
	 * frontend, cargar productos con semilla, borrar lotes y lanzar las demos de
	 * fraude.
	 *
	 * Esta pantalla no ejecuta nada por su cuenta. Le habla a un programa local,
	 * `panel-comandos.ps1`, que escucha solo en 127.0.0.1:5199 y es quien valida
	 * cada comando (hay una lista fija, no se manda texto libre) y quien exige las
	 * confirmaciones. Aqui solo se dibuja lo que ese programa dice que puede hacer:
	 * el catalogo de comandos sale de el, asi que agregar uno no toca este archivo.
	 *
	 * Antes esto era un iframe a la pagina del propio programa. Se cambio porque un
	 * iframe no hereda el tema, el tamano ni la letra de Mesh, y se veia como una
	 * pagina ajena metida en una caja. Ahora usa las mismas variables que Cuentas y
	 * Tendencias, asi que sigue el modo oscuro sin hacer nada.
	 *
	 * El programa solo le concede CORS y el token a este frontend (localhost:5173),
	 * ver `panel-comandos/servidor.mjs`.
	 */

	interface Campo {
		nombre: string;
		etiqueta: string;
		tipo: 'entero' | 'texto' | 'opcion';
		min?: number;
		max?: number;
		opciones?: string[];
		defecto?: string | number;
		opcional?: boolean;
	}

	interface Comando {
		id: string;
		grupo: string;
		titulo: string;
		explica: string;
		campos: Campo[];
		confirmar: string | null;
		peligro?: string;
	}

	interface Trabajo {
		hay: boolean;
		id?: string;
		titulo?: string;
		comando?: string;
		estado?: 'corriendo' | 'ok' | 'fallo' | 'parado';
		codigo?: number | null;
		segundos?: number;
		lineas?: string[];
		siguiente?: number;
	}

	interface Servicio {
		nombre: string;
		puerto: number;
		arriba: boolean;
	}

	const BASE = 'http://127.0.0.1:5199';
	const COMANDO_ENCENDER = '.\\panel-comandos.ps1';

	let estado = $state<'probando' | 'arriba' | 'apagado'>('probando');
	let catalogo = $state<Comando[]>([]);
	let grupoActivo = $state('');
	let grupos = $derived([...new Set(catalogo.map((c) => c.grupo))]);
	let visibles = $derived(catalogo.filter((c) => c.grupo === grupoActivo));

	let valores = $state<Record<string, Record<string, string>>>({});
	let comandos = $state<Record<string, { texto: string; ok: boolean }>>({});
	let mensajes = $state<Record<string, string>>({});
	let servicios = $state<Servicio[]>([]);

	let confirmando = $state<string | null>(null);
	let textoConfirma = $state('');
	let copiado = $state<string | null>(null);

	let trabajo = $state<Trabajo | null>(null);
	let lineas = $state<string[]>([]);
	let salida = $state<HTMLPreElement | null>(null);
	let panelSalida = $state<HTMLDivElement | null>(null);

	let token = '';
	let siguiente = 0;
	let idTrabajo = '';
	let sondeo: ReturnType<typeof setInterval> | undefined;
	let reintento: ReturnType<typeof setTimeout> | undefined;
	let refrescoServicios: ReturnType<typeof setInterval> | undefined;
	const pendientes: Record<string, ReturnType<typeof setTimeout>> = {};

	let corriendo = $derived(trabajo?.estado === 'corriendo');

	async function pedirToken(): Promise<void> {
		const r = await fetch(`${BASE}/api/token`, { cache: 'no-store' });
		if (!r.ok) throw new Error('El panel no acepta esta direccion');
		token = (await r.json()).token;
	}

	async function api<T>(ruta: string, cuerpo?: unknown, reintentar = true): Promise<T> {
		const r = await fetch(BASE + ruta, {
			method: cuerpo === undefined ? 'GET' : 'POST',
			headers: {
				'x-token': token,
				...(cuerpo === undefined ? {} : { 'Content-Type': 'application/json' })
			},
			body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
			cache: 'no-store'
		});
		// El token cambia cada vez que el panel se reinicia: se pide otro y se repite
		if (r.status === 401 && reintentar) {
			await pedirToken();
			return api<T>(ruta, cuerpo, false);
		}
		const j = await r.json().catch(() => ({}));
		if (!r.ok) throw new Error(j.error ?? `Error ${r.status}`);
		return j as T;
	}

	async function conectar() {
		clearTimeout(reintento);
		try {
			await pedirToken();
			catalogo = await api<Comando[]>('/api/catalogo');
			for (const c of catalogo) {
				valores[c.id] = Object.fromEntries(
					c.campos.map((f) => [
						f.nombre,
						String(f.defecto ?? (f.tipo === 'opcion' ? (f.opciones?.[0] ?? '') : ''))
					])
				);
			}
			if (!grupos.includes(grupoActivo)) grupoActivo = grupos[0] ?? '';
			estado = 'arriba';
			await Promise.all([...catalogo.map(vista), cargarServicios(), enlazarTrabajo()]);
		} catch {
			estado = 'apagado';
			// Se reintenta solo, para que al encenderlo desde la terminal esto se llene
			reintento = setTimeout(conectar, 4000);
		}
	}

	async function cargarServicios() {
		try {
			servicios = await api<Servicio[]>('/api/estado');
		} catch {
			/* el siguiente golpe lo reintenta */
		}
	}

	async function vista(c: Comando) {
		try {
			const r = await api<{ comando: string }>('/api/vista', { id: c.id, valores: valores[c.id] });
			comandos[c.id] = { texto: r.comando, ok: true };
		} catch (e) {
			comandos[c.id] = { texto: (e as Error).message, ok: false };
		}
	}

	function alCambiar(c: Comando, campo: Campo, valor: string) {
		valores[c.id][campo.nombre] = valor;
		clearTimeout(pendientes[c.id]);
		pendientes[c.id] = setTimeout(() => vista(c), 150);
	}

	async function copiar(c: Comando) {
		const texto = comandos[c.id]?.texto;
		if (!texto || !comandos[c.id].ok) return;
		try {
			await navigator.clipboard.writeText(texto);
			copiado = c.id;
			setTimeout(() => (copiado = null), 1400);
		} catch {
			/* sin permiso de portapapeles, la persona lo selecciona a mano */
		}
	}

	function pedir(c: Comando) {
		mensajes[c.id] = '';
		if (!c.confirmar) return ejecutar(c);
		confirmando = confirmando === c.id ? null : c.id;
		textoConfirma = '';
	}

	async function ejecutar(c: Comando, confirmacion?: string) {
		mensajes[c.id] = '';
		try {
			await api('/api/ejecutar', { id: c.id, valores: valores[c.id], confirmacion });
			confirmando = null;
			textoConfirma = '';
			siguiente = 0;
			idTrabajo = '';
			lineas = [];
			seguir();
			// La salida esta arriba de la lista: se trae a la vista para que se vea que arranco
			await tick();
			panelSalida?.scrollIntoView({ block: 'nearest' });
		} catch (e) {
			mensajes[c.id] = (e as Error).message;
		}
	}

	function seguir() {
		if (!sondeo) sondeo = setInterval(sondear, 800);
		sondear();
	}

	function dejarDeSeguir() {
		clearInterval(sondeo);
		sondeo = undefined;
	}

	async function sondear() {
		try {
			const j = await api<Trabajo>(`/api/trabajo?desde=${siguiente}`);
			if (!j.hay) {
				trabajo = null;
				dejarDeSeguir();
				return;
			}
			if (j.id !== idTrabajo) {
				idTrabajo = j.id ?? '';
				// Otro comando distinto del que se venia leyendo: se empieza de cero
				if (siguiente !== 0) {
					siguiente = 0;
					lineas = [];
					return sondear();
				}
			}
			const pegado = !salida || salida.scrollHeight - salida.scrollTop - salida.clientHeight < 40;
			if (j.lineas?.length) lineas.push(...j.lineas);
			siguiente = j.siguiente ?? siguiente;
			trabajo = j;
			if (j.estado !== 'corriendo') {
				dejarDeSeguir();
				cargarServicios();
			}
			await tick();
			if (pegado && salida) salida.scrollTop = salida.scrollHeight;
		} catch {
			/* se reintenta en el siguiente golpe */
		}
	}

	/**
	 * Si la pantalla se abre con algo corriendo, se engancha a su salida. Lo que ya
	 * termino NO se ensena: al entrar aparecia la salida vieja de un comando de hace
	 * un rato y parecia que se acababa de lanzar.
	 */
	async function enlazarTrabajo() {
		siguiente = 0;
		idTrabajo = '';
		const j = await api<Trabajo>('/api/trabajo?desde=0');
		if (!j.hay || j.estado !== 'corriendo') return;
		await sondear();
		seguir();
	}

	async function parar() {
		try {
			await api('/api/parar', {});
		} catch {
			/* si ya habia terminado no hay nada que parar */
		}
	}

	function cerrarSalida() {
		trabajo = null;
		lineas = [];
	}

	const ETIQUETA_ESTADO = {
		corriendo: 'En curso',
		ok: 'Termino bien',
		fallo: 'Fallo',
		parado: 'Parado'
	} as const;

	onMount(() => {
		conectar();
		refrescoServicios = setInterval(() => {
			if (estado === 'arriba') cargarServicios();
		}, 8000);
		return () => {
			clearTimeout(reintento);
			clearInterval(refrescoServicios);
			dejarDeSeguir();
			for (const t of Object.values(pendientes)) clearTimeout(t);
		};
	});
</script>

<section class="comandos">
	<div class="titulo">
		<h2>Comandos</h2>
		{#if estado === 'arriba'}
			<span class="cuantas">{catalogo.length} comandos</span>
		{/if}
	</div>

	{#if estado === 'arriba'}
		<p class="intro">
			Cada fila lanza el mismo comando que escribirias en la terminal. Lo ejecuta un programa
			local de esta maquina y lo que sale se ve abajo.
		</p>

		<ul class="servicios" aria-label="Servicios de Mesh" aria-live="polite">
			{#each servicios as s (s.nombre)}
				<li class:caido={!s.arriba} title={`Puerto ${s.puerto}`}>
					<span class="punto" aria-hidden="true"></span>
					{s.nombre}
					<span class="dice">{s.arriba ? 'arriba' : 'apagado'}</span>
				</li>
			{/each}
		</ul>

		<div class="pestanas" role="tablist" aria-label="Tipo de comando">
			{#each grupos as g (g)}
				<button
					type="button"
					role="tab"
					aria-selected={g === grupoActivo}
					class:activa={g === grupoActivo}
					onclick={() => {
						grupoActivo = g;
						confirmando = null;
					}}
				>
					{g}
				</button>
			{/each}
		</div>

		{#if trabajo}
			<div class="terminal" role="region" aria-label="Salida del comando" bind:this={panelSalida}>
				<div class="barra">
					<div class="que">
						<strong>{trabajo.titulo}</strong>
						<span class="sello {trabajo.estado}">{ETIQUETA_ESTADO[trabajo.estado ?? 'ok']}</span>
						<span class="tiempo">{trabajo.segundos ?? 0} s</span>
					</div>
					<div class="botones">
						{#if corriendo}
							<button type="button" onclick={parar}>Parar</button>
						{:else}
							<button type="button" onclick={cerrarSalida}>Cerrar</button>
						{/if}
					</div>
				</div>
				<pre bind:this={salida}>{lineas.join('\n')}</pre>
			</div>
		{/if}

		<ul class="lista">
			{#each visibles as c (c.id)}
				<li class="fila">
					<div class="cuerpo">
						<h3>{c.titulo}</h3>
						<p class="explica">{c.explica}</p>

						{#if c.campos.length}
							<div class="campos">
								{#each c.campos as f (f.nombre)}
									<label>
										<span>{f.etiqueta}</span>
										{#if f.tipo === 'opcion'}
											<select
												value={valores[c.id]?.[f.nombre]}
												onchange={(e) => alCambiar(c, f, e.currentTarget.value)}
											>
												{#each f.opciones ?? [] as o (o)}
													<option value={o}>{o}</option>
												{/each}
											</select>
										{:else}
											<input
												type={f.tipo === 'entero' ? 'number' : 'text'}
												min={f.min}
												max={f.max}
												placeholder={f.opcional ? 'opcional' : ''}
												value={valores[c.id]?.[f.nombre]}
												oninput={(e) => alCambiar(c, f, e.currentTarget.value)}
											/>
										{/if}
									</label>
								{/each}
							</div>
						{/if}

						<code class="cmd" class:malo={comandos[c.id] && !comandos[c.id].ok}>
							{comandos[c.id]?.texto ?? ''}
						</code>

						{#if mensajes[c.id]}
							<p class="mensaje" role="alert">{mensajes[c.id]}</p>
						{/if}
					</div>

					<div class="acciones">
						<button
							type="button"
							class="suave"
							disabled={!comandos[c.id]?.ok}
							onclick={() => copiar(c)}
						>
							{copiado === c.id ? 'Copiado' : 'Copiar'}
						</button>
						<button
							type="button"
							class={c.confirmar ? 'riesgo' : 'primario'}
							disabled={corriendo || !comandos[c.id]?.ok}
							aria-expanded={c.confirmar ? confirmando === c.id : undefined}
							title={corriendo ? 'Hay un comando corriendo' : undefined}
							onclick={() => pedir(c)}
						>
							Ejecutar
						</button>
					</div>

					{#if confirmando === c.id}
						<div class="confirma" role="group" aria-label="Confirmar">
							<p>{c.peligro ?? 'Esto no se deshace.'}</p>
							{#if c.confirmar !== 'SI'}
								<input
									type="text"
									bind:value={textoConfirma}
									placeholder={`Escribe ${c.confirmar}`}
									aria-label={`Escribe ${c.confirmar} para confirmar`}
								/>
							{/if}
							<div class="botones">
								<button type="button" class="suave" onclick={() => (confirmando = null)}>
									Cancelar
								</button>
								<button
									type="button"
									class="rojo"
									disabled={c.confirmar !== 'SI' && textoConfirma.trim() !== c.confirmar}
									onclick={() => ejecutar(c, c.confirmar ?? undefined)}
								>
									Si, ejecutar
								</button>
							</div>
						</div>
					{/if}
				</li>
			{/each}
		</ul>
	{:else if estado === 'probando'}
		<p class="gris">Buscando el panel de comandos...</p>
	{:else}
		<div class="apagado" role="status">
			<h3>El panel de comandos esta apagado</h3>
			<p>
				Es un programa local de tu maquina, no parte de la tienda. Enciendelo desde la raiz del
				proyecto y esta pantalla se llena sola en unos segundos.
			</p>
			<div class="encender">
				<code>{COMANDO_ENCENDER}</code>
				<button
					type="button"
					class="suave"
					onclick={() => navigator.clipboard?.writeText(COMANDO_ENCENDER)}
				>
					Copiar
				</button>
			</div>
		</div>
	{/if}
</section>

<style>
	.comandos {
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
		margin-bottom: 8px;
	}

	.titulo h2 {
		font-size: var(--f-xl);
	}

	.cuantas {
		padding: 3px 11px;
		font-size: var(--f-sm);
		color: var(--gris);
		background: var(--panel);
		border-radius: 999px;
	}

	.intro {
		max-width: 640px;
		margin-bottom: var(--e4);
		color: var(--gris);
		font-size: var(--f-base);
	}

	.gris {
		color: var(--gris);
	}

	/* -- que esta arriba y que no -- */

	.servicios {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e2);
		margin-bottom: var(--e5);
		list-style: none;
	}

	.servicios li {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 3px 11px;
		font-size: var(--f-sm);
		color: var(--texto);
		background: var(--panel);
		border-radius: 999px;
	}

	.punto {
		width: 7px;
		height: 7px;
		background: var(--indigo);
		border-radius: 50%;
	}

	.servicios .dice {
		color: var(--gris);
	}

	.servicios li.caido {
		color: var(--rojo);
		background: var(--rojo-cl);
	}

	.servicios li.caido .punto {
		background: var(--rojo);
	}

	.servicios li.caido .dice {
		color: var(--rojo);
	}

	/* -- los grupos, el mismo interruptor de pildoras que Tendencias -- */

	.pestanas {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e1);
		margin-bottom: var(--e2);
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

	/* -- una fila por comando, separadas por linea, como la tabla de Cuentas -- */

	.lista {
		list-style: none;
	}

	.fila {
		display: grid;
		grid-template-columns: minmax(0, 1fr) auto;
		gap: var(--e3) var(--e5);
		align-items: start;
		padding: var(--e5) 0;
		border-bottom: 1px solid var(--linea);
	}

	.fila:last-child {
		border-bottom: 0;
		padding-bottom: 0;
	}

	.fila h3 {
		font-size: var(--f-base);
		font-weight: 600;
		color: var(--tinta);
	}

	.explica {
		max-width: 640px;
		margin-top: 2px;
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.campos {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e3) var(--e4);
		margin-top: var(--e3);
	}

	.campos label {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.campos input,
	.campos select {
		min-width: 0;
		padding: 7px 10px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.campos input[type='number'] {
		width: 130px;
	}

	.campos input:not([type='number']) {
		width: 250px;
		max-width: 100%;
	}

	.campos select {
		cursor: pointer;
	}

	.campos input:focus,
	.campos select:focus,
	.confirma input:focus {
		outline: none;
		border-color: var(--indigo);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	.cmd {
		display: inline-block;
		max-width: 100%;
		margin-top: var(--e3);
		padding: 4px 10px;
		font-family: ui-monospace, 'Cascadia Mono', Consolas, monospace;
		font-size: var(--f-sm);
		color: var(--texto);
		background: var(--panel);
		border-radius: var(--r);
		word-break: break-all;
	}

	.cmd.malo {
		color: var(--rojo);
		background: var(--rojo-cl);
	}

	.cmd:empty {
		display: none;
	}

	.mensaje {
		margin-top: var(--e2);
		font-size: var(--f-ms);
		color: var(--rojo);
	}

	/* -- botones: los mismos tres de Mesh, indigo, contorno y contorno rojo -- */

	.acciones {
		display: flex;
		gap: var(--e2);
		align-items: center;
	}

	button {
		font-family: inherit;
		font-size: var(--f-base);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			background var(--t),
			border-color var(--t),
			opacity var(--t);
	}

	button:focus-visible,
	.pestanas button:focus-visible {
		outline: none;
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	button:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.primario {
		padding: 8px 16px;
		color: var(--sobre-indigo);
		background: var(--indigo);
		border: 1px solid var(--indigo);
	}

	.primario:hover:not(:disabled) {
		background: var(--indigo-os);
		border-color: var(--indigo-os);
	}

	.suave {
		padding: 7px 14px;
		color: var(--texto);
		background: var(--blanco);
		border: 1px solid var(--linea);
	}

	.suave:hover:not(:disabled) {
		border-color: var(--indigo);
		color: var(--tinta);
	}

	.riesgo {
		padding: 8px 16px;
		color: var(--rojo);
		background: var(--blanco);
		border: 1px solid var(--rojo);
	}

	.riesgo:hover:not(:disabled) {
		background: var(--rojo-cl);
	}

	/* -- la confirmacion se abre en la misma fila -- */

	.confirma {
		grid-column: 1 / -1;
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: var(--e3) var(--e4);
		padding: var(--e3) var(--e4);
		background: var(--rojo-cl);
		border-radius: var(--r);
	}

	.confirma p {
		flex: 1 1 260px;
		font-size: var(--f-ms);
		color: var(--rojo);
	}

	.confirma input {
		width: 210px;
		padding: 7px 10px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.confirma .botones {
		display: flex;
		gap: var(--e2);
	}

	.rojo {
		padding: 7px 14px;
		color: var(--sobre-rojo);
		background: var(--rojo);
		border: 1px solid var(--rojo);
	}

	/* -- la salida, encima de la lista -- */

	/* Oscura en los dos temas a proposito: es una terminal, y una terminal clara
	   sobre una tarjeta blanca se pierde. Los colores son los del tema oscuro de
	   Mesh, fijos. Va en el flujo y no pegada al borde de la ventana: pegada abajo
	   tapaba las primeras filas de la lista. */
	.terminal {
		margin: var(--e4) 0 var(--e2);
		overflow: hidden;
		color: #dfe3f0;
		background: #0f1428;
		border: 1px solid #262c45;
		border-radius: var(--r2);
	}

	.barra {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e3);
		padding: 10px var(--e4);
		border-bottom: 1px solid #262c45;
	}

	.que {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: var(--e2) var(--e3);
		min-width: 0;
		font-size: var(--f-ms);
	}

	.que strong {
		font-weight: 600;
	}

	.tiempo {
		color: #a6adc0;
	}

	.sello {
		padding: 2px 10px;
		font-size: var(--f-xs);
		color: #10142a;
		background: #a6adc0;
		border-radius: 999px;
	}

	.sello.corriendo {
		background: #8a9ae4;
	}

	.sello.ok {
		background: #b9c3f2;
	}

	.sello.fallo {
		background: #e08b81;
	}

	.barra button {
		padding: 5px 14px;
		font-size: var(--f-sm);
		color: #dfe3f0;
		background: transparent;
		border: 1px solid #3a4266;
	}

	.barra button:hover {
		border-color: #8a9ae4;
	}

	.terminal pre {
		height: 220px;
		padding: var(--e3) var(--e4);
		overflow: auto;
		font-family: ui-monospace, 'Cascadia Mono', Consolas, monospace;
		font-size: var(--f-sm);
		font-weight: 400;
		line-height: 1.5;
		white-space: pre-wrap;
		word-break: break-word;
	}

	/* -- panel apagado -- */

	.apagado {
		max-width: 640px;
	}

	.apagado h3 {
		margin-bottom: var(--e2);
		font-size: var(--f-md);
		color: var(--tinta);
	}

	.apagado p {
		margin-bottom: var(--e4);
		color: var(--gris);
	}

	.encender {
		display: flex;
		align-items: center;
		gap: var(--e3);
	}

	.encender code {
		padding: 7px 12px;
		font-family: ui-monospace, 'Cascadia Mono', Consolas, monospace;
		font-size: var(--f-base);
		color: var(--tinta);
		background: var(--panel);
		border-radius: var(--r);
	}

	@media (max-width: 620px) {
		.comandos {
			padding: 22px 20px;
		}

		.fila {
			grid-template-columns: 1fr;
		}

		.acciones {
			justify-content: flex-start;
		}

		.campos input:not([type='number']) {
			width: 100%;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		button {
			transition: none;
		}
	}
</style>
