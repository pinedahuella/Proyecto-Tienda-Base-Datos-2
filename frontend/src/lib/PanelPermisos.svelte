<script lang="ts">
	import { fechaCorta } from './compartidas';
	import {
		darPermiso,
		leerMatriz,
		leerRegistro,
		nombreRol,
		quitarPermiso,
		type MatrizPermisos,
		type PermisoDeLaMatriz,
		type RegistroPermiso
	} from './permisos';

	/**
	 * El ACL de funcionalidades visto por el admin (migracion 050, ADR-26).
	 *
	 * Arriba la matriz: cada permiso con una casilla por rol. Marcar o
	 * desmarcar cambia una fila de rol_permiso y vale desde la peticion
	 * siguiente de esa cuenta, sin reiniciar nada. Las casillas protegidas
	 * (cuenta.ver, y permisos.* del admin) no se pueden quitar: sin ellas no
	 * abre la sesion o nadie podria devolverlas.
	 *
	 * Abajo el registro: cada intento negado con su ruta, y cada cambio.
	 *
	 * Esto es la pantalla. El permiso lo pone el backend: un rol sin el permiso
	 * recibe 403 aunque llame a la ruta directo, sin pasar por aqui.
	 */

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	let matriz = $state<MatrizPermisos | null>(null);
	let registro = $state<RegistroPermiso[]>([]);
	let cargando = $state(true);
	let error = $state('');
	let aviso = $state<{ texto: string; malo: boolean } | null>(null);
	/** La casilla que se esta guardando, como "rol:permiso". */
	let guardando = $state<string | null>(null);

	let totalPermisos = $derived(matriz?.modulos.reduce((n, m) => n + m.permisos.length, 0) ?? 0);

	$effect(() => {
		cargar();
	});

	async function cargar() {
		cargando = true;
		error = '';
		const [m, r] = await Promise.all([leerMatriz(), leerRegistro()]);
		cargando = false;
		if (m.estado === 401 || r.estado === 401) {
			alExpirarSesion();
			return;
		}
		if (!m.ok || !m.payload) {
			error = m.mensaje;
			return;
		}
		matriz = m.payload;
		registro = r.ok && r.payload ? r.payload : [];
	}

	async function recargarRegistro() {
		const r = await leerRegistro();
		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}
		if (r.ok && r.payload) registro = r.payload;
	}

	async function cambiar(p: PermisoDeLaMatriz, idRol: number, tener: boolean) {
		guardando = `${idRol}:${p.id_permiso}`;
		aviso = null;
		const respuesta = tener ? await darPermiso(idRol, p.id_permiso) : await quitarPermiso(idRol, p.id_permiso);
		guardando = null;
		if (respuesta.estado === 401) {
			alExpirarSesion();
			return;
		}
		if (!respuesta.ok) {
			aviso = { texto: respuesta.mensaje, malo: true };
			// La casilla vuelve a lo que diga la base.
			await cargar();
			return;
		}
		p.roles = tener
			? [...p.roles, idRol].sort((a, b) => a - b)
			: p.roles.filter((r) => r !== idRol);
		aviso = { texto: respuesta.mensaje, malo: false };
		await recargarRegistro();
	}

	function textoAccion(r: RegistroPermiso): string {
		if (r.accion === 'negado') return 'Negado';
		return r.accion === 'otorgar' ? 'Dado' : 'Quitado';
	}

	function quien(r: RegistroPermiso): string {
		return r.actor.usuario ?? r.actor.correo ?? `cuenta ${r.actor.id_usuario}`;
	}
</script>

<section class="permisos">
	<div class="titulo">
		<h2>Permisos por rol</h2>
		{#if matriz}
			<span class="cuantas">{totalPermisos} permisos</span>
		{/if}
	</div>
	<p class="gris intro">
		Cada ruta del backend pide uno de estos permisos. Si el rol no lo tiene, la respuesta es 403, tambien
		al llamar la ruta directo.
	</p>

	{#if cargando && !matriz}
		<p class="gris">Cargando los permisos...</p>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if matriz}
		{#if aviso}
			<p class="aviso" class:malo={aviso.malo} role="status">{aviso.texto}</p>
		{/if}

		<div class="tabla">
			<table>
				<thead>
					<tr>
						<th class="col-permiso">Permiso</th>
						{#each matriz.roles as rol (rol.id_rol_usuario)}
							<th class="col-rol">{nombreRol(rol.rol)}</th>
						{/each}
					</tr>
				</thead>
				<tbody>
					{#each matriz.modulos as modulo (modulo.modulo)}
						<tr class="modulo">
							<th colspan={matriz.roles.length + 1} scope="rowgroup">
								<span class="nombre-modulo">{modulo.modulo}</span>
								<span class="gris">{modulo.descripcion}</span>
							</th>
						</tr>
						{#each modulo.permisos as p (p.id_permiso)}
							<tr>
								<td class="col-permiso">
									<code>{p.codigo}</code>
									<span class="descripcion">{p.descripcion}</span>
								</td>
								{#each matriz.roles as rol (rol.id_rol_usuario)}
									{@const tiene = p.roles.includes(rol.id_rol_usuario)}
									{@const protegido = tiene && p.protegido_para.includes(rol.id_rol_usuario)}
									<td class="col-rol">
										<input
											type="checkbox"
											checked={tiene}
											disabled={protegido || guardando !== null}
											title={protegido ? 'No se puede quitar' : undefined}
											aria-label="{nombreRol(rol.rol)} {p.codigo}"
											onchange={(e) => cambiar(p, rol.id_rol_usuario, e.currentTarget.checked)}
										/>
									</td>
								{/each}
							</tr>
						{/each}
					{/each}
				</tbody>
			</table>
		</div>

		<div class="titulo registro-titulo">
			<h3>Lo ultimo que paso</h3>
			<button type="button" class="secundario" onclick={recargarRegistro}>Actualizar</button>
		</div>
		{#if registro.length === 0}
			<p class="gris">Nadie ha intentado nada sin permiso.</p>
		{:else}
			<div class="tabla">
				<table class="registro">
					<thead>
						<tr>
							<th>Cuando</th>
							<th>Que</th>
							<th>Quien</th>
							<th>Rol</th>
							<th>Permiso</th>
							<th>Ruta</th>
						</tr>
					</thead>
					<tbody>
						{#each registro as r (r.id_auditoria_permiso)}
							<tr class:negado={r.accion === 'negado'}>
								<td class="nowrap">{fechaCorta(r.fecha)}</td>
								<td class="nowrap"><span class="etiqueta">{textoAccion(r)}</span></td>
								<td>{quien(r)}</td>
								<td>{nombreRol(r.rol)}</td>
								<td><code>{r.codigo}</code></td>
								<td>{#if r.ruta}<code>{r.metodo} {r.ruta}</code>{/if}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	{/if}
</section>

<style>
	.permisos {
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

	.registro-titulo {
		margin-top: 32px;
		justify-content: space-between;
	}

	.registro-titulo h3 {
		font-size: var(--f-lg);
	}

	.cuantas {
		padding: 3px 11px;
		font-size: var(--f-sm);
		color: var(--gris);
		background: var(--panel);
		border-radius: 999px;
	}

	.gris {
		color: var(--gris);
	}

	.intro {
		margin-bottom: 18px;
		font-size: var(--f-sm);
	}

	.fallo {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		flex-wrap: wrap;
		padding: 16px 18px;
		color: var(--rojo);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	.fallo button {
		padding: 8px 16px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--blanco);
		background: var(--indigo);
		border: 0;
		border-radius: var(--r);
		cursor: pointer;
	}

	.secundario {
		padding: 6px 14px;
		font-family: inherit;
		font-size: var(--f-sm);
		color: var(--indigo);
		background: transparent;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	.aviso {
		margin-bottom: 14px;
		padding: 10px 14px;
		font-size: var(--f-sm);
		color: var(--texto);
		background: var(--panel);
		border-radius: var(--r);
	}

	.aviso.malo {
		color: var(--rojo);
		background: var(--rojo-cl);
	}

	/* En pantalla angosta la tabla se desliza sola, sin estirar la pagina */
	.tabla {
		overflow-x: auto;
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: var(--f-base);
	}

	th {
		padding: 0 12px 10px;
		text-align: left;
		font-size: var(--f-sm);
		font-weight: 500;
		color: var(--gris);
		border-bottom: 1px solid var(--linea);
		white-space: nowrap;
	}

	td {
		padding: 9px 12px;
		color: var(--texto);
		border-bottom: 1px solid var(--linea);
		vertical-align: middle;
	}

	.col-rol {
		width: 96px;
		text-align: center;
	}

	.col-rol input {
		width: 18px;
		height: 18px;
		accent-color: var(--indigo);
		cursor: pointer;
	}

	.col-rol input:disabled {
		cursor: not-allowed;
	}

	.col-permiso {
		min-width: 240px;
	}

	.modulo th {
		padding: 18px 12px 8px;
		color: var(--texto);
		background: transparent;
		white-space: normal;
	}

	.nombre-modulo {
		margin-right: 10px;
		font-size: var(--f-base);
		font-weight: 600;
		text-transform: capitalize;
	}

	code {
		font-size: var(--f-sm);
		color: var(--indigo);
	}

	.descripcion {
		display: block;
		margin-top: 2px;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.registro td {
		font-size: var(--f-sm);
	}

	.nowrap {
		white-space: nowrap;
	}

	.etiqueta {
		padding: 2px 9px;
		font-size: var(--f-xs);
		background: var(--panel);
		border-radius: 999px;
	}

	tr.negado .etiqueta {
		color: var(--rojo);
		background: var(--rojo-cl);
	}

	@media (max-width: 600px) {
		.permisos {
			padding: 18px 16px;
		}

		.col-rol {
			width: 64px;
		}

		.col-permiso {
			min-width: 180px;
		}
	}
</style>
