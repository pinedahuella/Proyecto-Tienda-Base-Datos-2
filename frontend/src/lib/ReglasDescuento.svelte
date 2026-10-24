<script lang="ts">
	/**
	 * Las reglas de descuento automatico del vendedor, con las rutas de
	 * /vendedor/reglas-descuento (commit 56ce5f8, tabla de la migracion 021).
	 *
	 * Una regla dice "si de esta oferta se venden N unidades en M minutos,
	 * rebajala X% durante un rato", o "abre una venta relampago". Hay UNA por
	 * oferta como mucho: el backend contesta 409 a la segunda, asi que el
	 * selector solo ofrece las ofertas que todavia no tienen.
	 *
	 * El disparo existe desde el 2026-09-25 (DisparadorReglasAutomaticoService,
	 * cada minuto): mira en ClickHouse cuantas unidades se vendieron en la
	 * ventana y, si llegan al umbral, pone el descuento con vencimiento. Lo
	 * quita el mismo worker que quita los descuentos manuales con duracion.
	 *
	 * Dos cosas de ese disparo que la pantalla tiene que decir, porque no se
	 * adivinan (las cuenta el backend en cambio_propuestas/2026-09-25_0700):
	 *
	 *   - Si la duracion es MENOR o igual que la ventana, la oferta parpadea: el
	 *     descuento vence, las mismas ventas siguen dentro de la ventana y se
	 *     vuelve a prender en el siguiente minuto. Se avisa en el formulario.
	 *   - Pausar no apaga un descuento que ya se prendio. Termina su duracion.
	 *
	 * Una regla activa excluye cualquier otro descuento en la misma oferta (409,
	 * `textoConflictoDescuento`).
	 *
	 * Un admin ve y edita las de la tienda: el backend lo resuelve solo.
	 */
	import { onMount } from 'svelte';
	import { pedir, conJson, mensajeUtil, type RespuestaApi } from './api';
	import { textoConflictoDescuento, textoPorcentaje } from './descuento';
	import Autocompletar from './Autocompletar.svelte';

	let { alExpirarSesion }: { alExpirarSesion?: () => void } = $props();

	/** Tal como la devuelve el backend. Los bigint y el numeric llegan como texto. */
	interface Regla {
		id_regla_descuento_automatico: string;
		id_oferta: string;
		umbral_unidades: number;
		ventana_minutos: number;
		es_venta_relampago: boolean;
		duracion_segundos: number;
		porcentaje_descuento: string;
		activa: boolean;
		fecha_creacion: string;
		fecha_actualizacion: string;
	}

	interface ReglasPaginadas {
		reglas: Regla[];
		pagina: number;
		limite: number;
		total_reglas: number;
		total_paginas: number;
	}

	/** Solo lo que hace falta de GET /vendedor/ofertas para ponerle nombre a la regla. */
	interface OfertaBreve {
		id_oferta: string;
		nombre_producto: string;
		nombre_variante: string;
	}

	/** Lo que se escribe en el formulario, en las unidades que entiende una persona. */
	interface Borrador {
		umbral: string;
		ventana: string;
		relampago: boolean;
		duracion: string;
		porcentaje: string;
	}

	const LIMITE = 10;

	let reglas = $state<Regla[]>([]);
	let ofertas = $state<OfertaBreve[]>([]);
	let pagina = $state(1);
	let totalPaginas = $state(1);
	let totalReglas = $state(0);
	let cargando = $state(true);
	let error = $state('');

	let idOfertaNueva = $state('');
	let textoOfertaNueva = $state('');
	let ofertaNuevaElegida = $state(false);
	let nueva = $state<Borrador>(vacio());
	let creando = $state(false);
	let errorCrear = $state('');

	/** La regla que se esta editando, o '' si ninguna. */
	let editando = $state('');
	let edicion = $state<Borrador>(vacio());
	let guardando = $state('');
	let errorFila = $state<Record<string, string>>({});

	/**
	 * Las ofertas que ya tienen regla se sacan del selector. Solo se conocen las
	 * de la pagina a la vista, asi que si hay mas de una pagina el backend puede
	 * seguir contestando 409, y ese mensaje se ensena tal cual.
	 */
	let conRegla = $derived(new Set(reglas.map((r) => r.id_oferta)));
	let libres = $derived(ofertas.filter((o) => !conRegla.has(o.id_oferta)));

	function vacio(): Borrador {
		return { umbral: '10', ventana: '60', relampago: false, duracion: '120', porcentaje: '15' };
	}

	/**
	 * true si la duracion no pasa de la ventana, el caso que hace parpadear la
	 * oferta. Las dos se escriben en minutos en el formulario, asi que se
	 * comparan tal cual. Con un campo vacio no se avisa de nada.
	 */
	function parpadea(b: Borrador): boolean {
		const duracion = Number(b.duracion);
		const ventana = Number(b.ventana);
		if (!(duracion > 0) || !(ventana > 0)) return false;
		return duracion <= ventana;
	}

	function expiro(r: RespuestaApi<unknown>): boolean {
		if (r.estado === 401) {
			alExpirarSesion?.();
			return true;
		}
		return false;
	}

	function nombreOferta(id: string): string {
		const o = ofertas.find((x) => x.id_oferta === id);
		return o ? `${o.nombre_producto}, ${o.nombre_variante}` : `Oferta ${id}`;
	}

	/** "90 min", "2 h", "1 h 30 min". La duracion se guarda en segundos pero nadie piensa asi. */
	function tiempo(minutos: number): string {
		const h = Math.floor(minutos / 60);
		const m = minutos % 60;
		if (h === 0) return `${m} min`;
		return m === 0 ? `${h} h` : `${h} h ${m} min`;
	}

	/**
	 * Del formulario al cuerpo de la peticion. La duracion se escribe en
	 * minutos y viaja en segundos. Los numeros van como numero: el backend
	 * rechaza un "10" de texto.
	 */
	function aCuerpo(b: Borrador) {
		return {
			umbral_unidades: Number(b.umbral),
			ventana_minutos: Number(b.ventana),
			es_venta_relampago: b.relampago,
			duracion_segundos: Math.round(Number(b.duracion) * 60),
			porcentaje_descuento: Number(b.porcentaje)
		};
	}

	async function cargar(n = pagina) {
		cargando = true;
		error = '';
		const [r, o] = await Promise.all([
			pedir<ReglasPaginadas>(`/vendedor/reglas-descuento/paginado?pagina=${n}&limite=${LIMITE}`),
			ofertas.length ? Promise.resolve(null) : pedir<OfertaBreve[]>('/vendedor/ofertas')
		]);
		cargando = false;
		if (expiro(r) || (o && expiro(o))) return;
		if (o && o.ok && Array.isArray(o.payload)) ofertas = o.payload;
		if (!r.ok || !r.payload) {
			error = mensajeUtil(r) || 'No se pudieron traer las reglas.';
			return;
		}
		reglas = r.payload.reglas;
		pagina = r.payload.pagina;
		totalPaginas = Math.max(1, r.payload.total_paginas);
		totalReglas = r.payload.total_reglas;
	}

	async function crear(e: SubmitEvent) {
		e.preventDefault();
		if (!idOfertaNueva) {
			errorCrear = 'Elige la oferta.';
			return;
		}
		creando = true;
		errorCrear = '';
		const r = await pedir<Regla>(
			'/vendedor/reglas-descuento',
			conJson('POST', { id_oferta: Number(idOfertaNueva), ...aCuerpo(nueva) })
		);
		creando = false;
		if (expiro(r)) return;
		if (!r.ok) {
			errorCrear = textoConflictoDescuento(r) ?? (mensajeUtil(r) || 'No se pudo guardar la regla.');
			return;
		}
		idOfertaNueva = '';
		textoOfertaNueva = '';
		ofertaNuevaElegida = false;
		nueva = vacio();
		await cargar(1);
	}

	function abrirEdicion(r: Regla) {
		editando = r.id_regla_descuento_automatico;
		edicion = {
			umbral: String(r.umbral_unidades),
			ventana: String(r.ventana_minutos),
			relampago: r.es_venta_relampago,
			duracion: String(Math.round(r.duracion_segundos / 60)),
			porcentaje: String(Number(r.porcentaje_descuento))
		};
	}

	async function cambiar(regla: Regla, cuerpo: Record<string, unknown>) {
		const id = regla.id_regla_descuento_automatico;
		guardando = id;
		errorFila = { ...errorFila, [id]: '' };
		const r = await pedir<Regla>(`/vendedor/reglas-descuento/${id}`, conJson('PATCH', cuerpo));
		guardando = '';
		if (expiro(r)) return;
		if (!r.ok || !r.payload) {
			errorFila = {
				...errorFila,
				[id]: textoConflictoDescuento(r) ?? (mensajeUtil(r) || 'No se pudo guardar.')
			};
			return;
		}
		reglas = reglas.map((x) => (x.id_regla_descuento_automatico === id ? r.payload : x));
		editando = '';
	}

	/**
	 * Borrar una regla (DELETE, desde el 2026-09-25). El backend solo borra una
	 * regla pausada y contesta 409 si esta activa, porque borrarla prendida
	 * dejaba un descuento huerfano. Por eso el boton solo sale en las pausadas,
	 * y pide confirmar en la misma fila en vez de abrir un dialogo del navegador.
	 */
	let confirmandoBorrar = $state('');

	async function borrar(regla: Regla) {
		const id = regla.id_regla_descuento_automatico;
		guardando = id;
		errorFila = { ...errorFila, [id]: '' };
		const r = await pedir<unknown>(`/vendedor/reglas-descuento/${id}`, { method: 'DELETE' });
		guardando = '';
		confirmandoBorrar = '';
		if (expiro(r)) return;
		if (!r.ok) {
			errorFila = { ...errorFila, [id]: mensajeUtil(r) || 'No se pudo borrar.' };
			return;
		}
		reglas = reglas.filter((x) => x.id_regla_descuento_automatico !== id);
		totalReglas = Math.max(0, totalReglas - 1);
	}

	onMount(() => cargar(1));
</script>

<section class="reglas">
	<div class="titulo">
		<h2>Descuentos automaticos</h2>
		{#if !cargando && !error}
			<span class="etiqueta">{totalReglas} {totalReglas === 1 ? 'regla' : 'reglas'}</span>
		{/if}
		<div class="acciones">
			<button type="button" onclick={() => cargar(pagina)} disabled={cargando}>Volver a mirar</button>
		</div>
	</div>

	<p class="intro">
		Si una oferta se vende rapido, puedes rebajarla sola durante un rato o abrirle una venta
		relampago. Una regla por oferta.
	</p>
	<p class="aviso">
		El sistema revisa las ventas cada minuto. Pausar una regla no quita un descuento que ya se
		activo, ese termina su tiempo.
	</p>

	<form class="nueva" onsubmit={crear}>
		<h3>Nueva regla</h3>
		<div class="campos">
			<!-- Con buscador y no con un <select>: la tienda tiene cientos de
			     ofertas y desplegarlas todas de golpe no se puede recorrer. -->
			<div class="ancho">
				<Autocompletar
					id="regla-ventas-oferta"
					etiqueta="Oferta"
					opciones={libres.map((o) => ({ texto: `${o.nombre_producto}, ${o.nombre_variante}`, valor: String(o.id_oferta) }))}
					bind:valor={textoOfertaNueva}
					bind:elegido={ofertaNuevaElegida}
					alElegir={(v) => (idOfertaNueva = v)}
					marcador={libres.length === 0 ? 'Todas tus ofertas ya tienen regla' : 'Escribe el producto'}
					deshabilitado={libres.length === 0}
					mostrarAlEnfocar
				/>
			</div>
			{@render camposBorrador(nueva, 'n')}
		</div>
		{#if errorCrear}
			<p class="fallo-linea" role="alert">{errorCrear}</p>
		{/if}
		<button type="submit" class="principal" disabled={creando || libres.length === 0}>
			{creando ? 'Guardando...' : 'Guardar regla'}
		</button>
	</form>

	{#if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={() => cargar(pagina)}>Reintentar</button>
		</div>
	{:else if cargando && reglas.length === 0}
		<p class="gris">Buscando reglas...</p>
	{:else if reglas.length === 0}
		<p class="gris">Todavia no tienes reglas.</p>
	{:else}
		<ul class="lista" aria-busy={cargando}>
			{#each reglas as r (r.id_regla_descuento_automatico)}
				{@const id = r.id_regla_descuento_automatico}
				<li class="regla" class:pausada={!r.activa}>
					<div class="cabeza">
						<strong>{nombreOferta(r.id_oferta)}</strong>
						<span class="estado" class:apagada={!r.activa}>{r.activa ? 'Activa' : 'Pausada'}</span>
					</div>

					{#if editando === id}
						<div class="campos">{@render camposBorrador(edicion, id)}</div>
						<div class="pie">
							<button type="button" class="principal" disabled={guardando === id} onclick={() => cambiar(r, aCuerpo(edicion))}>
								Guardar
							</button>
							<button type="button" onclick={() => (editando = '')}>Cancelar</button>
						</div>
					{:else}
						<p class="nota">
							Si se venden <b>{r.umbral_unidades}</b> en <b>{tiempo(r.ventana_minutos)}</b>,
							{r.es_venta_relampago ? 'abre una venta relampago' : 'rebaja'} de
							<b>{textoPorcentaje(r.porcentaje_descuento)}</b> por
							<b>{tiempo(Math.round(r.duracion_segundos / 60))}</b>.
						</p>
						<div class="pie">
							<button type="button" disabled={guardando === id} onclick={() => cambiar(r, { activa: !r.activa })}>
								{r.activa ? 'Pausar' : 'Reactivar'}
							</button>
							<button type="button" onclick={() => abrirEdicion(r)}>Editar</button>
							{#if !r.activa}
								{#if confirmandoBorrar === id}
									<button type="button" class="peligro" disabled={guardando === id} onclick={() => borrar(r)}>
										Si, borrar
									</button>
									<button type="button" onclick={() => (confirmandoBorrar = '')}>No</button>
								{:else}
									<button type="button" onclick={() => (confirmandoBorrar = id)}>Borrar</button>
								{/if}
							{/if}
						</div>
					{/if}
					{#if errorFila[id]}
						<p class="fallo-linea" role="alert">{errorFila[id]}</p>
					{/if}
				</li>
			{/each}
		</ul>

		{#if totalPaginas > 1}
			<nav class="paginacion" aria-label="Paginas de reglas">
				<button type="button" onclick={() => cargar(pagina - 1)} disabled={pagina <= 1 || cargando}>Anterior</button>
				<span class="gris">Pagina {pagina} de {totalPaginas}</span>
				<button type="button" onclick={() => cargar(pagina + 1)} disabled={pagina >= totalPaginas || cargando}>Siguiente</button>
			</nav>
		{/if}
	{/if}
</section>

{#snippet camposBorrador(b: Borrador, clave: string)}
	<label>
		Unidades vendidas
		<input type="number" min="1" max="100000" step="1" bind:value={b.umbral} required />
	</label>
	<label>
		En cuantos minutos
		<input type="number" min="1" max="10080" step="1" bind:value={b.ventana} required />
	</label>
	<label>
		Descuento %
		<input type="number" min="1" max="90" step="0.01" bind:value={b.porcentaje} required />
	</label>
	<label>
		Dura, en minutos
		<input type="number" min="1" max="10080" step="1" bind:value={b.duracion} required />
	</label>
	<label class="marca" for="relampago-{clave}">
		<input id="relampago-{clave}" type="checkbox" bind:checked={b.relampago} />
		Abrir venta relampago
	</label>
	{#if parpadea(b)}
		<p class="aviso ancho" role="status">
			Haz que dure mas que la ventana. Si no, el descuento se apaga y las mismas ventas lo vuelven
			a prender enseguida.
		</p>
	{/if}
{/snippet}

<style>
	.reglas {
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
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: 999px;
	}

	.acciones {
		margin-left: auto;
	}

	.intro {
		color: var(--gris);
		margin-bottom: 6px;
	}

	.aviso {
		padding: 8px 12px;
		margin-bottom: 18px;
		font-size: var(--f-sm);
		color: var(--relampago-tinta);
		background: var(--relampago-fondo);
		border: 1px solid var(--relampago-linea);
		border-radius: var(--r);
	}

	.reglas {
		--relampago-tinta: #7c3a00;
		--relampago-fondo: #ffe8cc;
		--relampago-linea: #ffc98a;
	}

	:global(html[data-tema='oscuro']) .reglas {
		--relampago-tinta: #f0b070;
		--relampago-fondo: #3a2410;
		--relampago-linea: #6b4520;
	}

	.nueva {
		padding: 16px;
		margin-bottom: 20px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.nueva h3 {
		font-size: var(--f-md);
		margin-bottom: 10px;
	}

	.campos {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		gap: 10px 14px;
		margin-bottom: 12px;
	}

	.campos label {
		display: flex;
		flex-direction: column;
		gap: 4px;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.campos .ancho {
		grid-column: 1 / -1;
	}

	.campos .aviso {
		margin-bottom: 0;
	}

	.campos .marca {
		flex-direction: row;
		align-items: center;
		align-self: end;
		gap: 8px;
		color: var(--tinta);
	}

	.campos input[type='number'] {
		width: 100%;
		min-width: 0;
	}

	.principal {
		color: #fff;
		background: var(--indigo);
		border-color: var(--indigo);
	}

	.lista {
		list-style: none;
		padding: 0;
		margin: 0;
		display: grid;
		gap: 10px;
	}

	.regla {
		padding: 14px 16px;
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.regla.pausada {
		background: var(--panel);
	}

	.cabeza {
		display: flex;
		align-items: center;
		gap: 10px;
		flex-wrap: wrap;
		margin-bottom: 6px;
	}

	.estado {
		padding: 1px 9px;
		font-size: var(--f-xs);
		color: var(--indigo);
		background: var(--indigo-cl);
		border-radius: 999px;
	}

	.estado.apagada {
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
	}

	.nota {
		margin-bottom: 10px;
	}

	.pie {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
	}

	.fallo,
	.fallo-linea {
		color: var(--rojo);
	}

	.fallo-linea {
		margin: 8px 0;
		font-size: var(--f-sm);
	}

	.gris {
		color: var(--gris);
	}

	.paginacion {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 12px;
		margin-top: 16px;
	}

	@media (max-width: 560px) {
		.reglas {
			padding: 18px 16px;
		}
	}
	.peligro {
		color: var(--rojo);
		border-color: var(--rojo);
	}
</style>
