<script lang="ts">
	/**
	 * Las reglas de descuento por PERIODO del vendedor, con las rutas de
	 * /vendedor/reglas-descuento-periodos (tabla de la migracion 022). Vive en
	 * la misma pestana que ReglasDescuento y copia su forma.
	 *
	 * Una regla dice "entre estos dias, rebaja esta oferta X%", o "abre una
	 * venta relampago". El rango se arma con dia, mes y anio, y lo que falta
	 * amplia la repeticion:
	 *
	 *   con anio      una sola vez, ese anio
	 *   sin anio      cada anio, mismos dias y meses
	 *   sin mes      cada mes, solo con el rango de dias (y entonces sin anio)
	 *
	 * A diferencia de la regla automatica, una oferta puede tener varias,
	 * siempre que sus dias no se toquen: el backend contesta 409 si se solapan.
	 * Tambien contesta 409 si la oferta ya tiene otro descuento activo (manual,
	 * automatico); los dos se ensenan con `textoConflictoDescuento`.
	 *
	 * El disparo es DisparadorReglasPeriodoService, cada 15 minutos: pone y
	 * quita el descuento solo. Pausar una regla SI lo quita en la siguiente
	 * vuelta, al reves que la automatica.
	 *
	 * El PATCH no deja borrar el mes ni el anio de una regla (un null no se
	 * manda). Para quitarlos hay que pausar esa regla y crear otra, y la
	 * pantalla lo dice en vez de mandar algo que el backend ignoraria.
	 */
	import { onMount } from 'svelte';
	import { pedir, conJson, mensajeUtil, type RespuestaApi } from './api';
	import { textoConflictoDescuento, textoPorcentaje } from './descuento';
	import Autocompletar from './Autocompletar.svelte';

	let { alExpirarSesion }: { alExpirarSesion?: () => void } = $props();

	/** Tal como la devuelve el backend. Los bigint y el numeric llegan como texto. */
	interface Regla {
		id_regla_descuento_periodo: string;
		id_oferta: string;
		dia_inicio: number;
		dia_fin: number;
		mes_inicio: number | null;
		mes_fin: number | null;
		anio: number | null;
		es_venta_relampago: boolean;
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

	interface OfertaBreve {
		id_oferta: string;
		nombre_producto: string;
		nombre_variante: string;
	}

	/** El formulario, como texto. Mes y anio vacios quieren decir "todos". */
	interface Borrador {
		diaInicio: string;
		diaFin: string;
		mesInicio: string;
		mesFin: string;
		anio: string;
		relampago: boolean;
		porcentaje: string;
	}

	const LIMITE = 10;

	const MESES = [
		'enero',
		'febrero',
		'marzo',
		'abril',
		'mayo',
		'junio',
		'julio',
		'agosto',
		'septiembre',
		'octubre',
		'noviembre',
		'diciembre'
	];

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

	let editando = $state('');
	let edicion = $state<Borrador>(vacio());
	let guardando = $state('');
	let errorFila = $state<Record<string, string>>({});

	function vacio(): Borrador {
		return {
			diaInicio: '1',
			diaFin: '7',
			mesInicio: '',
			mesFin: '',
			anio: '',
			relampago: false,
			porcentaje: '15'
		};
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

	/**
	 * La regla dicha como la diria una persona.
	 *   "Del 1 al 7 de cada mes"
	 *   "Del 20 de diciembre al 5 de enero, cada anio"
	 *   "Del 20 al 31 de diciembre de 2026"
	 */
	function periodo(r: Pick<Regla, 'dia_inicio' | 'dia_fin' | 'mes_inicio' | 'mes_fin' | 'anio'>): string {
		if (r.mes_inicio == null || r.mes_fin == null) {
			return `Del ${r.dia_inicio} al ${r.dia_fin} de cada mes`;
		}
		const mi = MESES[r.mes_inicio - 1] ?? `mes ${r.mes_inicio}`;
		const mf = MESES[r.mes_fin - 1] ?? `mes ${r.mes_fin}`;
		const rango =
			r.mes_inicio === r.mes_fin && r.dia_inicio <= r.dia_fin
				? `Del ${r.dia_inicio} al ${r.dia_fin} de ${mf}`
				: `Del ${r.dia_inicio} de ${mi} al ${r.dia_fin} de ${mf}`;
		return r.anio == null ? `${rango}, cada anio` : `${rango} de ${r.anio}`;
	}

	/**
	 * Del formulario al cuerpo. Mes y anio solo viajan si se escribieron: su
	 * ausencia es lo que hace que la regla se repita. Los numeros van como
	 * numero, el backend rechaza un "5" de texto.
	 */
	function aCuerpo(b: Borrador): Record<string, unknown> {
		const cuerpo: Record<string, unknown> = {
			dia_inicio: Number(b.diaInicio),
			dia_fin: Number(b.diaFin),
			es_venta_relampago: b.relampago,
			porcentaje_descuento: Number(b.porcentaje)
		};
		if (b.mesInicio !== '') cuerpo.mes_inicio = Number(b.mesInicio);
		if (b.mesFin !== '') cuerpo.mes_fin = Number(b.mesFin);
		if (tieneAnio(b)) cuerpo.anio = Number(b.anio);
		return cuerpo;
	}

	function tieneAnio(b: Borrador): boolean {
		return b.anio != null && String(b.anio).trim() !== '';
	}

	/** Hoy en Guatemala, AAAA-MM-DD. */
	const HOY = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Guatemala' });
	const ANIO_ACTUAL = Number(HOY.slice(0, 4));

	/**
	 * Los anios que se pueden elegir: este y los cuatro siguientes. Una regla
	 * de un anio que ya paso no se aplicaria nunca. Al editar una regla vieja
	 * su anio tambien sale, para que la lista no lo cambie sin querer.
	 */
	function aniosPara(b: Borrador): string[] {
		const lista = Array.from({ length: 5 }, (_, i) => String(ANIO_ACTUAL + i));
		if (tieneAnio(b) && !lista.includes(b.anio)) lista.unshift(b.anio);
		return lista;
	}

	/** Igual que `diasDelMes` del backend. Febrero sin anio tiene 29. */
	function diasDelMes(mes: number, anio: number | null): number {
		if (mes === 2) {
			if (anio == null) return 29;
			return (anio % 4 === 0 && anio % 100 !== 0) || anio % 400 === 0 ? 29 : 28;
		}
		return [4, 6, 9, 11].includes(mes) ? 30 : 31;
	}

	function topeDia(b: Borrador, mes: string): number {
		return mes === '' ? 31 : diasDelMes(Number(mes), tieneAnio(b) ? Number(b.anio) : null);
	}

	/**
	 * Los dos meses van juntos (Meme, 2026-10-20). Elegir un mes con el otro
	 * en cada mes le pone el mismo, y volver uno a cada mes vuelve los dos y
	 * quita el anio, que sin meses no se puede fijar.
	 */
	function elegirMes(b: Borrador, campo: 'mesInicio' | 'mesFin', valor: string) {
		const otro = campo === 'mesInicio' ? 'mesFin' : 'mesInicio';
		b[campo] = valor;
		if (valor === '') {
			b[otro] = '';
			b.anio = '';
		} else if (b[otro] === '') {
			b[otro] = valor;
		}
	}

	/**
	 * Lo que el backend rechazaria, dicho antes de la vuelta. Los que mandan
	 * son los de alla (`validarCascada` y `validarFechasPosibles`).
	 */
	function problemaCascada(b: Borrador, revisarFechas = true): string {
		if ((b.mesInicio === '') !== (b.mesFin === '')) {
			return 'Elige los dos meses, o ninguno para que se repita cada mes.';
		}
		if (tieneAnio(b) && b.mesInicio === '') {
			return 'Para fijar el anio elige tambien los meses.';
		}
		const di = Number(b.diaInicio);
		const df = Number(b.diaFin);
		if (revisarFechas && b.mesInicio !== '') {
			const anio = tieneAnio(b) ? Number(b.anio) : null;
			for (const [dia, mes] of [
				[di, Number(b.mesInicio)],
				[df, Number(b.mesFin)]
			]) {
				const tope = diasDelMes(mes, anio);
				if (dia > tope) {
					const nombre = MESES[mes - 1];
					return `${nombre[0].toUpperCase()}${nombre.slice(1)}${anio ? ` de ${anio}` : ''} tiene ${tope} dias, el ${dia} no existe.`;
				}
			}
			if (anio != null) {
				const mi = Number(b.mesInicio);
				const mf = Number(b.mesFin);
				if (mf < mi || (mf === mi && df < di)) {
					return 'Con un anio fijo la regla no puede pasar al anio siguiente. Para que cruce el fin de anio, dejala para todos los anios.';
				}
				const fin = `${anio}-${String(mf).padStart(2, '0')}-${String(df).padStart(2, '0')}`;
				if (fin < HOY) return `Esas fechas de ${anio} ya pasaron.`;
			}
		}
		return '';
	}

	async function cargar(n = pagina) {
		cargando = true;
		error = '';
		const [r, o] = await Promise.all([
			pedir<ReglasPaginadas>(`/vendedor/reglas-descuento-periodos/paginado?pagina=${n}&limite=${LIMITE}`),
			ofertas.length ? Promise.resolve(null) : pedir<OfertaBreve[]>('/vendedor/ofertas')
		]);
		cargando = false;
		if (expiro(r) || (o && expiro(o))) return;
		if (o && o.ok && Array.isArray(o.payload)) ofertas = o.payload;
		if (!r.ok || !r.payload) {
			error = mensajeUtil(r) || 'No se pudieron traer las reglas por fecha.';
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
		const problema = problemaCascada(nueva);
		if (problema) {
			errorCrear = problema;
			return;
		}
		creando = true;
		errorCrear = '';
		const r = await pedir<Regla>(
			'/vendedor/reglas-descuento-periodos',
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
		editando = r.id_regla_descuento_periodo;
		edicion = {
			diaInicio: String(r.dia_inicio),
			diaFin: String(r.dia_fin),
			mesInicio: r.mes_inicio == null ? '' : String(r.mes_inicio),
			mesFin: r.mes_fin == null ? '' : String(r.mes_fin),
			anio: r.anio == null ? '' : String(r.anio),
			relampago: r.es_venta_relampago,
			porcentaje: String(Number(r.porcentaje_descuento))
		};
	}

	/** Guardar la edicion. Antes, lo que el PATCH no sabe hacer. */
	function guardarEdicion(regla: Regla) {
		const id = regla.id_regla_descuento_periodo;
		const quitaMes = regla.mes_inicio != null && (edicion.mesInicio === '' || edicion.mesFin === '');
		const quitaAnio = regla.anio != null && !tieneAnio(edicion);
		if (quitaMes || quitaAnio) {
			errorFila = {
				...errorFila,
				[id]: 'El mes y el anio no se pueden quitar de una regla. Pausa esta y crea otra.'
			};
			return;
		}
		// Como el backend, las fechas solo se revisan si cambiaron: una regla
		// vieja se puede guardar con otro porcentaje sin moverle los dias.
		const cuerpo = aCuerpo(edicion);
		const cambianFechas =
			cuerpo.dia_inicio !== regla.dia_inicio ||
			cuerpo.dia_fin !== regla.dia_fin ||
			(cuerpo.mes_inicio ?? null) !== regla.mes_inicio ||
			(cuerpo.mes_fin ?? null) !== regla.mes_fin ||
			(cuerpo.anio ?? null) !== regla.anio;
		const problema = problemaCascada(edicion, cambianFechas);
		if (problema) {
			errorFila = { ...errorFila, [id]: problema };
			return;
		}
		void cambiar(regla, aCuerpo(edicion));
	}

	async function cambiar(regla: Regla, cuerpo: Record<string, unknown>) {
		const id = regla.id_regla_descuento_periodo;
		guardando = id;
		errorFila = { ...errorFila, [id]: '' };
		const r = await pedir<Regla>(`/vendedor/reglas-descuento-periodos/${id}`, conJson('PATCH', cuerpo));
		guardando = '';
		if (expiro(r)) return;
		if (!r.ok || !r.payload) {
			errorFila = {
				...errorFila,
				[id]: textoConflictoDescuento(r) ?? (mensajeUtil(r) || 'No se pudo guardar.')
			};
			return;
		}
		reglas = reglas.map((x) => (x.id_regla_descuento_periodo === id ? r.payload : x));
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
		const id = regla.id_regla_descuento_periodo;
		guardando = id;
		errorFila = { ...errorFila, [id]: '' };
		const r = await pedir<unknown>(`/vendedor/reglas-descuento-periodos/${id}`, { method: 'DELETE' });
		guardando = '';
		confirmandoBorrar = '';
		if (expiro(r)) return;
		if (!r.ok) {
			errorFila = { ...errorFila, [id]: mensajeUtil(r) || 'No se pudo borrar.' };
			return;
		}
		reglas = reglas.filter((x) => x.id_regla_descuento_periodo !== id);
		totalReglas = Math.max(0, totalReglas - 1);
	}

	onMount(() => cargar(1));
</script>

<section class="reglas">
	<div class="titulo">
		<h2>Descuentos por fecha</h2>
		{#if !cargando && !error}
			<span class="etiqueta">{totalReglas} {totalReglas === 1 ? 'regla' : 'reglas'}</span>
		{/if}
		<div class="acciones">
			<button type="button" onclick={() => cargar(pagina)} disabled={cargando}>Volver a mirar</button>
		</div>
	</div>

	<p class="intro">
		Rebaja una oferta en ciertos dias, por ejemplo fin de mes o diciembre. Puede tener varias
		reglas si no se pisan los dias.
	</p>
	<p class="aviso">
		El sistema las revisa cada 15 minutos. Mientras una esta activa, la oferta no admite otro
		descuento.
	</p>

	<form class="nueva" onsubmit={crear}>
		<h3>Nueva regla</h3>
		<div class="campos">
			<!-- Con buscador y no con un <select>: la tienda tiene cientos de
			     ofertas y desplegarlas todas de golpe no se puede recorrer. -->
			<div class="ancho">
				<Autocompletar
					id="regla-fecha-oferta"
					etiqueta="Oferta"
					opciones={ofertas.map((o) => ({ texto: `${o.nombre_producto}, ${o.nombre_variante}`, valor: String(o.id_oferta) }))}
					bind:valor={textoOfertaNueva}
					bind:elegido={ofertaNuevaElegida}
					alElegir={(v) => (idOfertaNueva = v)}
					marcador={ofertas.length === 0 ? 'Todavia no tienes ofertas' : 'Escribe el producto'}
					deshabilitado={ofertas.length === 0}
					mostrarAlEnfocar
				/>
			</div>
			{@render camposBorrador(nueva, 'n')}
		</div>
		{#if errorCrear}
			<p class="fallo-linea" role="alert">{errorCrear}</p>
		{/if}
		<button type="submit" class="principal" disabled={creando || ofertas.length === 0}>
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
		<p class="gris">Todavia no tienes reglas por fecha.</p>
	{:else}
		<ul class="lista" aria-busy={cargando}>
			{#each reglas as r (r.id_regla_descuento_periodo)}
				{@const id = r.id_regla_descuento_periodo}
				<li class="regla" class:pausada={!r.activa}>
					<div class="cabeza">
						<strong>{nombreOferta(r.id_oferta)}</strong>
						<span class="estado" class:apagada={!r.activa}>{r.activa ? 'Activa' : 'Pausada'}</span>
					</div>

					{#if editando === id}
						<div class="campos">{@render camposBorrador(edicion, id)}</div>
						<div class="pie">
							<button type="button" class="principal" disabled={guardando === id} onclick={() => guardarEdicion(r)}>
								Guardar
							</button>
							<button type="button" onclick={() => (editando = '')}>Cancelar</button>
						</div>
					{:else}
						<p class="nota">
							{periodo(r)},
							{r.es_venta_relampago ? 'venta relampago' : 'descuento'} de
							<b>{textoPorcentaje(r.porcentaje_descuento)}</b>.
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
			<nav class="paginacion" aria-label="Paginas de reglas por fecha">
				<button type="button" onclick={() => cargar(pagina - 1)} disabled={pagina <= 1 || cargando}>Anterior</button>
				<span class="gris">Pagina {pagina} de {totalPaginas}</span>
				<button type="button" onclick={() => cargar(pagina + 1)} disabled={pagina >= totalPaginas || cargando}>Siguiente</button>
			</nav>
		{/if}
	{/if}
</section>

{#snippet camposBorrador(b: Borrador, clave: string)}
	<label>
		Desde el dia
		<input type="number" min="1" max={topeDia(b, b.mesInicio)} step="1" bind:value={b.diaInicio} required />
	</label>
	<label>
		Hasta el dia
		<input type="number" min="1" max={topeDia(b, b.mesFin)} step="1" bind:value={b.diaFin} required />
	</label>
	<label>
		Mes de inicio
		<select value={b.mesInicio} onchange={(e) => elegirMes(b, 'mesInicio', e.currentTarget.value)}>
			<option value="">Cada mes</option>
			{#each MESES as m, i (m)}
				<option value={String(i + 1)}>{m}</option>
			{/each}
		</select>
	</label>
	<label>
		Mes de fin
		<select value={b.mesFin} onchange={(e) => elegirMes(b, 'mesFin', e.currentTarget.value)}>
			<option value="">Cada mes</option>
			{#each MESES as m, i (m)}
				<option value={String(i + 1)}>{m}</option>
			{/each}
		</select>
	</label>
	<label>
		Anio
		<!-- Sin meses no se puede fijar el anio: la regla de cada mes se
		     repite todos. -->
		<select bind:value={b.anio} disabled={b.mesInicio === ''}>
			<option value="">Todos los anios</option>
			{#each aniosPara(b) as a (a)}
				<option value={a}>{a}</option>
			{/each}
		</select>
	</label>
	<label>
		Descuento %
		<input type="number" min="1" max="90" step="0.01" bind:value={b.porcentaje} required />
	</label>
	<label class="marca" for="relampago-periodo-{clave}">
		<input id="relampago-periodo-{clave}" type="checkbox" bind:checked={b.relampago} />
		Abrir venta relampago
	</label>
{/snippet}

<style>
	.reglas {
		padding: 26px 28px;
		margin-bottom: 28px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		--relampago-tinta: #7c3a00;
		--relampago-fondo: #ffe8cc;
		--relampago-linea: #ffc98a;
	}

	:global(html[data-tema='oscuro']) .reglas {
		--relampago-tinta: #f0b070;
		--relampago-fondo: #3a2410;
		--relampago-linea: #6b4520;
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

	.campos .marca {
		flex-direction: row;
		align-items: center;
		align-self: end;
		gap: 8px;
		color: var(--tinta);
	}

	.campos input[type='number'],
	.campos select {
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
