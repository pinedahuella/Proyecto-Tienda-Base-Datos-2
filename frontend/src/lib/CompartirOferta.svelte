<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil } from './api';
	import {
		PERMISOS,
		darPermisos,
		fechaCorta,
		leerPermisos,
		quitarPermiso,
		textoPermiso,
		textoRegistro,
		type EntradaPermiso,
		type PermisoOferta,
		type RegistroPermiso
	} from './compartidas';

	/**
	 * Compartir una oferta propia: el ACL de la aplicacion visto por su dueno
	 * (migracion 049). Se abre colgado de la fila, como el panel del descuento.
	 *
	 * Arriba, a quien se le da que (por correo, con permisos sueltos y hasta
	 * cuando). En medio, quien tiene acceso hoy, cada permiso con su boton para
	 * quitarlo. Abajo, el registro: quien dio o quito que, lo que hicieron con la
	 * oferta y los intentos que se negaron.
	 */
	let {
		idOferta,
		alExpirarSesion,
		alCerrar
	}: { idOferta: string; alExpirarSesion: () => void; alCerrar: () => void } = $props();

	const PLAZOS = [
		{ valor: '', texto: 'Sin vencer' },
		{ valor: '3600', texto: 'Una hora' },
		{ valor: '86400', texto: 'Un dia' },
		{ valor: '604800', texto: 'Una semana' }
	];

	let permisos = $state<EntradaPermiso[]>([]);
	let registro = $state<RegistroPermiso[]>([]);
	let cargando = $state(true);
	let error = $state('');
	let hecho = $state('');

	let correo = $state('');
	let elegidos = $state<PermisoOferta[]>(['ver']);
	let plazo = $state('');
	let dando = $state(false);
	let quitando = $state<string | null>(null);
	let verRegistro = $state(false);
	let registroEntero = $state(false);
	/** Las 10 mas nuevas, o todas las que trae el backend (hasta 30). */
	let registroVisible = $derived(registroEntero ? registro : registro.slice(0, 10));

	/** Las entradas agrupadas por cuenta, para una fila por persona. */
	let porCuenta = $derived.by(() => {
		const grupos = new Map<string, { correo: string; usuario: string; entradas: EntradaPermiso[] }>();
		for (const e of permisos) {
			const g = grupos.get(e.receptor.id_usuario) ?? {
				correo: e.receptor.correo,
				usuario: e.receptor.usuario,
				entradas: []
			};
			g.entradas.push(e);
			grupos.set(e.receptor.id_usuario, g);
		}
		return [...grupos.values()];
	});

	onMount(() => {
		void cargar();
	});

	function aplicar(r: { ok: boolean; estado: number; payload: { permisos: EntradaPermiso[]; registro: RegistroPermiso[] } | null; mensaje?: string }): boolean {
		if (r.estado === 401) {
			alExpirarSesion();
			return false;
		}
		if (!r.ok || !r.payload) {
			error = mensajeUtil(r);
			return false;
		}
		permisos = r.payload.permisos;
		registro = r.payload.registro;
		return true;
	}

	async function cargar() {
		cargando = true;
		error = '';
		const r = await leerPermisos(idOferta);
		cargando = false;
		aplicar(r);
	}

	function alternar(p: PermisoOferta) {
		elegidos = elegidos.includes(p) ? elegidos.filter((x) => x !== p) : [...elegidos, p];
	}

	async function dar(evento: SubmitEvent) {
		evento.preventDefault();
		error = '';
		hecho = '';
		if (correo.trim() === '') {
			error = 'Escribe el correo de la cuenta.';
			return;
		}
		if (elegidos.length === 0) {
			error = 'Elige al menos un permiso.';
			return;
		}
		const vence = plazo === '' ? null : new Date(Date.now() + Number(plazo) * 1000).toISOString();
		dando = true;
		const r = await darPermisos(idOferta, correo.trim(), elegidos, vence);
		dando = false;
		if (aplicar(r)) {
			hecho = `Listo, ${correo.trim()} ya tiene ${elegidos.map((p) => textoPermiso(p).toLowerCase()).join(', ')}.`;
			correo = '';
			elegidos = ['ver'];
			plazo = '';
		}
	}

	async function quitar(e: EntradaPermiso) {
		error = '';
		hecho = '';
		quitando = e.id_permiso_oferta;
		const r = await quitarPermiso(idOferta, e.id_permiso_oferta);
		quitando = null;
		if (aplicar(r)) {
			hecho = `Se le quito ${textoPermiso(e.permiso).toLowerCase()} a ${e.receptor.usuario}.`;
		}
	}
</script>

<div class="compartir">
	<div class="cabeza">
		<h4>Compartir esta oferta</h4>
		<button type="button" class="enlace" onclick={alCerrar}>Cerrar</button>
	</div>
	<p class="menor">
		Otra cuenta de vendedor puede verla o cambiarla por ti, sin tu contrasena. Lo que no le des, no
		lo puede hacer.
	</p>

	<form class="dar" onsubmit={dar} novalidate>
		<label class="correo">
			Correo de la cuenta
			<input type="email" bind:value={correo} placeholder="ventas.sur@mesh.com" autocomplete="off" />
		</label>
		<fieldset class="permisos">
			<legend>Puede</legend>
			{#each PERMISOS as p (p.valor)}
				<label class="permiso" title={p.ayuda}>
					<input type="checkbox" checked={elegidos.includes(p.valor)} onchange={() => alternar(p.valor)} />
					{p.texto}
				</label>
			{/each}
		</fieldset>
		<label>
			Hasta cuando
			<select bind:value={plazo}>
				{#each PLAZOS as p (p.valor)}
					<option value={p.valor}>{p.texto}</option>
				{/each}
			</select>
		</label>
		<button type="submit" class="principal" disabled={dando}>{dando ? 'Dando...' : 'Dar permiso'}</button>
	</form>

	{#if error}
		<p class="malo" role="alert">{error}</p>
	{/if}
	{#if hecho}
		<p class="bien">{hecho}</p>
	{/if}

	{#if cargando}
		<p class="menor">Buscando quien tiene acceso...</p>
	{:else if porCuenta.length === 0}
		<p class="menor">Nadie mas tiene acceso a esta oferta.</p>
	{:else}
		<ul class="cuentas">
			{#each porCuenta as c (c.correo)}
				<li>
					<div class="quien">
						<strong>{c.usuario}</strong>
						<span class="menor">{c.correo}</span>
					</div>
					<div class="chips">
						{#each c.entradas as e (e.id_permiso_oferta)}
							<span class="chip" class:vencido={!e.vigente}>
								{textoPermiso(e.permiso)}
								{#if e.fecha_vencimiento}
									<span class="vence">{e.vigente ? 'hasta' : 'vencio'} {fechaCorta(e.fecha_vencimiento)}</span>
								{/if}
								<button
									type="button"
									class="quitar"
									aria-label="Quitar {textoPermiso(e.permiso)} a {c.usuario}"
									title="Quitar"
									onclick={() => quitar(e)}
									disabled={quitando === e.id_permiso_oferta}>x</button
								>
							</span>
						{/each}
					</div>
				</li>
			{/each}
		</ul>
	{/if}

	{#if registro.length > 0}
		<button type="button" class="enlace" onclick={() => (verRegistro = !verRegistro)}>
			{verRegistro ? 'Ocultar el registro' : `Ver el registro (${registro.length})`}
		</button>
		{#if verRegistro}
			<ol class="registro">
				{#each registroVisible as r, i (i)}
					<li class:negado={r.accion === 'negado'}>
						<span>{textoRegistro(r)}</span>
						<span class="menor">{fechaCorta(r.fecha)}</span>
					</li>
				{/each}
			</ol>
			{#if registro.length > 10}
				<button type="button" class="enlace" onclick={() => (registroEntero = !registroEntero)}>
					{registroEntero ? 'Ver solo las ultimas 10' : 'Ver las ' + registro.length}
				</button>
			{/if}
		{/if}
	{/if}
</div>

<style>
	.compartir {
		flex-basis: 100%;
		width: 100%;
		margin-top: 0.6rem;
		padding: 0.9rem 1rem;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		background: var(--panel);
	}

	.cabeza {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: var(--e3);
	}

	h4 {
		margin: 0;
		font-size: var(--f-md);
	}

	.menor {
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.malo {
		color: var(--rojo);
		margin: 0.5rem 0;
	}

	.bien {
		color: var(--indigo);
		margin: 0.5rem 0;
	}

	.dar {
		display: flex;
		flex-wrap: wrap;
		align-items: flex-end;
		gap: var(--e3);
		margin: 0.8rem 0 0.4rem;
	}

	.dar label {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.correo {
		flex: 1 1 14rem;
	}

	.permisos {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e3);
		margin: 0;
		padding: 0;
		border: 0;
	}

	.permisos legend {
		font-size: var(--f-ms);
		color: var(--gris);
		margin-bottom: var(--e1);
		padding: 0;
	}

	.dar .permiso {
		flex-direction: row;
		align-items: center;
		gap: 6px;
		color: inherit;
	}

	.cuentas {
		list-style: none;
		margin: 0.8rem 0 0.4rem;
		padding: 0;
		display: grid;
		gap: var(--e2);
	}

	.cuentas li {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: var(--e2);
		padding: 0.5rem 0;
		border-top: 1px solid var(--linea);
	}

	.quien {
		display: flex;
		flex-direction: column;
	}

	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e2);
	}

	.chip {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 2px 4px 2px 10px;
		font-size: var(--f-ms);
		border-radius: 999px;
		background: var(--indigo-cl);
		color: var(--indigo);
	}

	.chip.vencido {
		background: var(--blanco);
		color: var(--gris);
		text-decoration: line-through;
	}

	.vence {
		font-size: var(--f-xs);
	}

	.quitar {
		min-width: 0;
		width: 22px;
		height: 22px;
		padding: 0;
		border-radius: 999px;
		line-height: 1;
		font-size: var(--f-xs);
	}

	.registro {
		list-style: none;
		margin: 0.5rem 0 0;
		padding: 0;
		display: grid;
		gap: 4px;
	}

	.registro li {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		gap: var(--e2);
		font-size: var(--f-ms);
	}

	.registro li.negado span:first-child {
		color: var(--rojo);
	}

	@media (max-width: 600px) {
		.dar > * {
			flex: 1 1 100%;
		}
	}
</style>
