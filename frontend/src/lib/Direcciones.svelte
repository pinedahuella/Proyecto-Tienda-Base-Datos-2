<script lang="ts">
	import { onMount } from 'svelte';
	import { conJson, pedir } from './api';
	import Autocompletar from './Autocompletar.svelte';
	import {
		cargarPaises,
		ciudadesDeDepartamento,
		ciudadesDePais,
		comparable,
		etiquetaDivision,
		paraLeer,
		type Pais
	} from './lugares';

	/**
	 * Las direcciones de envio del usuario.
	 *
	 *   GET   /direccion-usuario      las del usuario logueado
	 *   GET   /direccion-usuario/:id  una, con todas sus versiones
	 *   POST  /direccion-usuario      crea una
	 *   PATCH /direccion-usuario/:id  edita pais, departamento, ciudad o codigo postal
	 *
	 * La lista se pide una vez al abrir el panel. Despues no se vuelve a pedir:
	 * crear y editar devuelven la direccion ya guardada, asi que la lista se
	 * actualiza con eso y se ahorra un viaje.
	 *
	 * Pais, departamento y ciudad no se escriben libres: se eligen de listas
	 * encadenadas, para que la ciudad pertenezca de verdad al pais. El detalle
	 * de donde salen esas listas y de los casos raros esta en lugares.ts.
	 *
	 * Los tres son obligatorios porque la tabla los tiene en NOT NULL. Lo que
	 * es opcional es la LISTA de departamentos: 50 de los 246 paises no tienen
	 * ninguno, y ahi el campo se escribe a mano.
	 *
	 * El id_usuario no se manda: el backend lo saca del token. El estado
	 * tampoco, porque toda direccion nueva nace activa.
	 */

	interface Direccion {
		id_direccion: string;
		id_usuario: string;
		pais: string;
		departamento: string;
		ciudad: string;
		codigo_postal: string | null;
		fecha_creacion: string;
		id_estado_direccion: number;
	}

	/** Una version guardada de la direccion. Solo se agregan, nunca se editan. */
	interface Version {
		id_direccion_historial: string;
		pais: string;
		departamento: string;
		ciudad: string;
		codigo_postal: string | null;
		fecha_creacion: string;
	}

	/** Lo que devuelve GET /direccion-usuario/:id */
	interface DireccionConHistorial {
		direccion: Direccion;
		historial: Version[];
	}

	interface Opcion {
		texto: string;
		valor: string;
	}

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	let direcciones = $state<Direccion[]>([]);
	let cargando = $state(true);
	let errorLista = $state('');

	type Modo = 'lista' | 'nueva' | 'editar';
	let modo = $state<Modo>('lista');
	let editando = $state<string | null>(null);
	let versiones = $state<Version[]>([]);

	// --- Las listas de lugares
	let paises = $state<Pais[]>([]);
	let opcionesDepartamento = $state<Opcion[]>([]);
	let opcionesCiudad = $state<Opcion[]>([]);
	let buscandoCiudades = $state(false);

	let opcionesPais = $derived(paises.map((p) => ({ texto: p.nombre, valor: p.nombre })));
	let hayDepartamentos = $derived(opcionesDepartamento.length > 0);

	// Guatemala tiene departamentos, Mexico estados, Espana provincias. El
	// rotulo sigue al pais elegido en vez de decirle departamento a todo.
	let rotuloDivision = $derived(
		etiquetaDivision(opcionesDepartamento.map((o) => o.valor))
	);

	// --- El formulario
	let pais = $state('');
	let paisElegido = $state(false);
	let departamento = $state('');
	let departamentoElegido = $state(false);
	let ciudad = $state('');
	let ciudadElegida = $state(false);
	let codigoPostal = $state('');

	let guardando = $state(false);
	let errorForm = $state('');
	let hecho = $state('');

	onMount(() => {
		// Las dos cosas a la vez: la lista sale del backend y los paises de una
		// API de fuera, y ninguna depende de la otra
		cargarDirecciones();
		cargarPaises().then((p) => (paises = p));
	});

	async function cargarDirecciones() {
		cargando = true;
		errorLista = '';

		const respuesta = await pedir<Direccion[]>('/direccion-usuario');

		cargando = false;

		if (!respuesta.ok || !respuesta.payload) {
			if (vencida(respuesta.estado)) return;
			errorLista = respuesta.mensaje;
			return;
		}

		direcciones = respuesta.payload;
	}

	/**
	 * Cambiar el pais invalida lo de abajo: un departamento de Guatemala no
	 * tiene sentido con Japon. Se limpian los dos y se vuelven a cargar.
	 */
	async function alElegirPais(nombre: string) {
		departamento = '';
		departamentoElegido = false;
		ciudad = '';
		ciudadElegida = false;
		opcionesCiudad = [];

		const p = paises.find((x) => x.nombre === nombre);
		opcionesDepartamento = (p?.departamentos ?? []).map((d) => ({ texto: paraLeer(d), valor: d }));

		// Pais sin departamentos: las ciudades se piden del pais entero
		if (opcionesDepartamento.length === 0) {
			buscandoCiudades = true;
			const lista = await ciudadesDePais(nombre);
			opcionesCiudad = lista.map((c) => ({ texto: c, valor: c }));
			buscandoCiudades = false;
		}
	}

	async function alElegirDepartamento(estado: string) {
		ciudad = '';
		ciudadElegida = false;
		buscandoCiudades = true;

		let lista = await ciudadesDeDepartamento(pais, estado);

		// Hay paises con departamentos que no devuelven ni una ciudad. Espana y
		// Francia son asi en todos los suyos, y sin embargo tienen 7635 y 15974
		// a nivel pais. Sin este respaldo la cadena se queda sin salida.
		if (lista.length === 0) lista = await ciudadesDePais(pais);

		opcionesCiudad = lista.map((c) => ({ texto: c, valor: c }));
		buscandoCiudades = false;
	}

	function limpiar() {
		pais = '';
		paisElegido = false;
		departamento = '';
		departamentoElegido = false;
		ciudad = '';
		ciudadElegida = false;
		codigoPostal = '';
		opcionesDepartamento = [];
		opcionesCiudad = [];
		errorForm = '';
	}

	function abrirNueva() {
		limpiar();
		hecho = '';
		editando = null;
		modo = 'nueva';
	}

	/**
	 * Al editar se parte de lo guardado, pedido con GET /direccion-usuario/:id
	 * en vez de reusar la fila de la lista: asi los datos son los de este
	 * momento y de paso llega el historial, que se ensena debajo del
	 * formulario. Si esa peticion falla se sigue con la fila que ya se tenia,
	 * que es peor que nada pero mejor que no dejar editar.
	 *
	 * El pais viene tal cual, pero el departamento se guardo legible
	 * ("Sacatepequez") y en la API se llama de otra forma ("Sacatepequez
	 * Department"), asi que hay que buscarlo, y sin que un acento los separe.
	 */
	async function abrirEditar(fila: Direccion) {
		limpiar();
		hecho = '';
		versiones = [];
		editando = fila.id_direccion;
		modo = 'editar';

		let d = fila;
		const respuesta = await pedir<DireccionConHistorial>(
			'/direccion-usuario/' + fila.id_direccion
		);
		if (respuesta.ok && respuesta.payload) {
			d = respuesta.payload.direccion;
			versiones = respuesta.payload.historial;
		} else if (vencida(respuesta.estado)) {
			return;
		}

		codigoPostal = d.codigo_postal ?? '';

		pais = d.pais;
		paisElegido = true;
		await alElegirPais(d.pais);

		const enLista = opcionesDepartamento.find(
			(o) => comparable(o.texto) === comparable(d.departamento)
		);
		departamento = enLista ? enLista.valor : d.departamento;
		departamentoElegido = true;
		if (enLista) await alElegirDepartamento(enLista.valor);

		ciudad = d.ciudad;
		ciudadElegida = true;
	}

	function cancelar() {
		limpiar();
		editando = null;
		versiones = [];
		modo = 'lista';
	}

	/**
	 * La linea de una version. Se arma aqui y no en el marcado porque ahi el
	 * bloque {#if} del codigo postal se come el espacio de antes y queda
	 * "Guatemala- 03001" pegado.
	 */
	function resumen(v: Version): string {
		const base = v.ciudad + ', ' + v.departamento + ', ' + v.pais;
		return v.codigo_postal ? base + ' — ' + v.codigo_postal : base;
	}

	/** Solo para ensenar: dia y hora en corto. */
	function cuando(iso: string): string {
		return new Date(iso).toLocaleString('es-GT', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}

	/**
	 * Las mismas reglas que valida el backend, con los mismos mensajes. Se
	 * repiten aqui para no gastar una peticion en un error que se ve solo.
	 */
	function revisar(): boolean {
		if (!pais.trim()) {
			errorForm = 'El pais es obligatorio';
			return false;
		}
		// Si hay lista, tuvo que elegir de la lista. Sin esto se podria colar
		// el valor anterior cuando alguien escribe encima y manda sin elegir.
		if (opcionesPais.length > 0 && !paisElegido) {
			errorForm = 'Elige un pais de la lista';
			return false;
		}
		if (hayDepartamentos && !departamentoElegido) {
			errorForm = 'Elige ' + (rotuloDivision === 'Estado o provincia' ? 'un estado o provincia' : 'un ' + rotuloDivision.toLowerCase()) + ' de la lista';
			return false;
		}
		if (opcionesCiudad.length > 0 && !ciudadElegida) {
			errorForm = 'Elige una ciudad de la lista';
			return false;
		}
		if (!departamento.trim()) {
			errorForm = rotuloDivision === 'Estado o provincia' ? 'El estado o provincia es obligatorio' : 'El ' + rotuloDivision.toLowerCase() + ' es obligatorio';
			return false;
		}
		if (paraLeer(departamento).length > 100) {
			errorForm = 'El departamento no puede tener mas de 100 caracteres';
			return false;
		}
		if (!ciudad.trim()) {
			errorForm = 'La ciudad es obligatoria';
			return false;
		}
		if (ciudad.trim().length > 100) {
			errorForm = 'La ciudad no puede tener mas de 100 caracteres';
			return false;
		}
		if (pais.trim().length > 100) {
			errorForm = 'El pais no puede tener mas de 100 caracteres';
			return false;
		}
		if (codigoPostal.trim().length > 20) {
			errorForm = 'El codigo postal no puede tener mas de 20 caracteres';
			return false;
		}
		return true;
	}

	/** Un 401 aqui significa que la sesion se acabo de verdad. */
	function vencida(estado: number): boolean {
		if (estado !== 401) return false;
		alExpirarSesion();
		return true;
	}

	async function guardar(evento: SubmitEvent) {
		evento.preventDefault();
		errorForm = '';

		if (!revisar()) return;

		// Se guarda el nombre legible, no el de la API: en una direccion se
		// escribe "Sacatepequez", no "Sacatepequez Department"
		const cuerpo = {
			pais: pais.trim(),
			departamento: paraLeer(departamento.trim()),
			ciudad: ciudad.trim(),
			codigo_postal: codigoPostal.trim()
		};

		guardando = true;

		const respuesta =
			modo === 'nueva'
				? await pedir<Direccion>('/direccion-usuario', conJson('POST', cuerpo))
				: await pedir<Direccion>('/direccion-usuario/' + editando, conJson('PATCH', cuerpo));

		guardando = false;

		if (!respuesta.ok || !respuesta.payload) {
			if (vencida(respuesta.estado)) return;
			errorForm = respuesta.mensaje;
			return;
		}

		// El backend devuelve la direccion ya guardada, asi que la lista se arma
		// con eso y no hace falta volver a preguntar
		const guardada = respuesta.payload;

		if (modo === 'nueva') {
			direcciones = [...direcciones, guardada];
		} else {
			direcciones = direcciones.map((d) =>
				d.id_direccion === guardada.id_direccion ? guardada : d
			);
		}

		hecho = respuesta.mensaje;
		cancelar();
	}
</script>

<section class="direcciones">
	<div class="titulo">
		<h2>Tus direcciones</h2>
		{#if modo === 'lista'}
			<button type="button" onclick={abrirNueva}>Agregar direccion</button>
		{/if}
	</div>

	{#if hecho}
		<p class="hecho" role="status">{hecho}</p>
	{/if}

	{#if modo === 'lista'}
		{#if cargando}
			<p class="vacio">Cargando tus direcciones...</p>
		{:else if errorLista}
			<div class="malo" role="alert">
				<p>{errorLista}</p>
				<button type="button" onclick={cargarDirecciones}>Reintentar</button>
			</div>
		{:else if direcciones.length === 0}
			<p class="vacio">Todavia no tienes ninguna direccion guardada.</p>
		{:else}
			<ul class="fichas">
				{#each direcciones as d (d.id_direccion)}
					<li>
						<div>
							<p class="linea">{d.ciudad}, {d.departamento}</p>
							<p class="detalle">
								{d.pais}
								{#if d.codigo_postal}
									&mdash; {d.codigo_postal}
								{/if}
							</p>
						</div>
						<button type="button" onclick={() => abrirEditar(d)}>Editar</button>
					</li>
				{/each}
			</ul>
		{/if}
	{:else}
		<form onsubmit={guardar} novalidate>
			{#if errorForm}
				<p class="malo" role="alert">{errorForm}</p>
			{/if}

			{#if paises.length === 0}
				<p class="suave">
					No se pudo cargar la lista de lugares, asi que los campos se escriben a mano.
				</p>
			{/if}

			<div class="pareja">
				<Autocompletar
					id="d-pais"
					etiqueta="Pais"
					opciones={opcionesPais}
					bind:valor={pais}
					bind:elegido={paisElegido}
					alElegir={alElegirPais}
					ayuda="escribelo"
				/>

				<Autocompletar
					id="d-departamento"
					etiqueta={rotuloDivision}
					opciones={opcionesDepartamento}
					bind:valor={departamento}
					bind:elegido={departamentoElegido}
					alElegir={alElegirDepartamento}
					deshabilitado={!paisElegido}
					ayuda="este pais no tiene lista, escribelo"
				/>
			</div>

			<div class="pareja">
				<Autocompletar
					id="d-ciudad"
					etiqueta="Ciudad"
					opciones={opcionesCiudad}
					bind:valor={ciudad}
					bind:elegido={ciudadElegida}
					deshabilitado={!paisElegido || (hayDepartamentos && !departamentoElegido) || buscandoCiudades}
					ayuda="sin lista, escribela"
				/>

				<div class="campo">
					<label for="d-postal">
						Codigo postal <span class="nota">opcional</span>
					</label>
					<input id="d-postal" type="text" autocomplete="off" bind:value={codigoPostal} />
				</div>
			</div>

			{#if buscandoCiudades}
				<p class="suave">Buscando ciudades...</p>
			{/if}

			<div class="botones">
				<button class="principal" type="submit" disabled={guardando}>
					{guardando ? 'Guardando...' : modo === 'nueva' ? 'Agregar' : 'Guardar cambios'}
				</button>
				<button type="button" onclick={cancelar} disabled={guardando}>Cancelar</button>
			</div>
		</form>

		{#if modo === 'editar' && versiones.length > 0}
			<!--
				Cada vez que se guarda un cambio queda una version nueva y ninguna
				se sobrescribe. Se ensenan para que se vea que el historial existe
				de verdad, y porque es lo que un pedido va a recordar: la direccion
				tal como estaba el dia del envio, no como esta hoy.
			-->
			<div class="versiones">
				<h3>Versiones guardadas ({versiones.length})</h3>
				<ol>
					{#each versiones as v (v.id_direccion_historial)}
						<li>
							<span class="cuando">{cuando(v.fecha_creacion)}</span>
							<span class="que">{resumen(v)}</span>
						</li>
					{/each}
				</ol>
			</div>
		{/if}
	{/if}
</section>

<style>
	.direcciones {
		margin-top: 28px;
		padding: 26px 28px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.titulo {
		display: flex;
		align-items: center;
		gap: 14px;
		flex-wrap: wrap;
		margin-bottom: 20px;
	}

	h2 {
		margin: 0;
		margin-right: auto;
		font-size: 1.25rem;
		font-weight: 400;
	}

	.titulo button {
		padding: 8px 16px;
		font-family: inherit;
		font-size: 0.92rem;
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.titulo button:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.vacio,
	.suave {
		margin: 0 0 16px;
		font-size: 0.92rem;
		color: var(--gris);
	}

	.vacio {
		margin-bottom: 0;
	}

	.fichas {
		margin: 0;
		padding: 0;
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.fichas li {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		padding: 14px 16px;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.fichas p {
		margin: 0;
	}

	.linea {
		font-size: 1rem;
		color: var(--tinta);
	}

	.detalle {
		margin-top: 3px;
		font-size: 0.88rem;
		color: var(--gris);
	}

	.fichas button {
		flex-shrink: 0;
		padding: 7px 14px;
		font-family: inherit;
		font-size: 0.9rem;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.fichas button:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.pareja {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 16px;
		margin-bottom: 16px;
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: 7px;
	}

	label {
		font-size: 0.9rem;
		font-weight: 500;
		color: var(--tinta);
	}

	.nota {
		font-weight: 400;
		color: var(--gris);
	}

	input[type='text'] {
		width: 100%;
		padding: 11px 13px;
		font-family: inherit;
		font-size: 1rem;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		transition: border-color var(--t);
	}

	input[type='text']:focus {
		outline: none;
		border-color: var(--indigo);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	.botones {
		display: flex;
		gap: 10px;
		flex-wrap: wrap;
	}

	.botones button {
		padding: 8px 16px;
		font-family: inherit;
		font-size: 0.92rem;
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.botones button:hover:not(:disabled) {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.botones button.principal {
		color: var(--blanco);
		background: var(--indigo);
		border-color: var(--indigo);
	}

	.botones button.principal:hover:not(:disabled) {
		background: var(--indigo-os);
		color: var(--blanco);
	}

	.botones button:disabled {
		opacity: 0.6;
		cursor: progress;
	}

	.malo p {
		margin: 0;
	}

	.malo button {
		flex-shrink: 0;
		padding: 6px 12px;
		font-family: inherit;
		font-size: 0.88rem;
		color: var(--rojo);
		background: var(--blanco);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
		cursor: pointer;
	}

	.malo {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		flex-wrap: wrap;
		margin: 0 0 18px;
		padding: 10px 14px;
		font-size: 0.92rem;
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	.hecho {
		margin: 0 0 18px;
		padding: 10px 14px;
		font-size: 0.92rem;
		color: var(--tinta);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
	}

	.versiones {
		margin-top: 24px;
		padding-top: 18px;
		border-top: 1px solid var(--linea);
	}

	.versiones h3 {
		margin: 0 0 12px;
		font-size: 0.95rem;
		font-weight: 500;
		color: var(--tinta);
	}

	.versiones ol {
		margin: 0;
		padding: 0;
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.versiones li {
		display: flex;
		gap: 14px;
		flex-wrap: wrap;
		font-size: 0.88rem;
	}

	.cuando {
		flex-shrink: 0;
		min-width: 168px;
		color: var(--gris);
		font-variant-numeric: tabular-nums;
	}

	.que {
		color: var(--tinta);
	}

	@media (max-width: 620px) {
		.pareja {
			grid-template-columns: 1fr;
		}
	}
</style>
