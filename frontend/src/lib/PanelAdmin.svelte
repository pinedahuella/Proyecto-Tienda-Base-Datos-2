<script lang="ts">
	import { conJson, pedir } from './api';
	import { CORREO_TIENDA, type UsuarioSesion } from './sesion';

	/**
	 * Panel de administracion: la lista de cuentas y sus dos catalogos.
	 *
	 *   GET   /admin/usuarios      todas las cuentas menos la propia
	 *   GET   /admin/roles         para el select de rol
	 *   GET   /admin/estados       para el select de estado
	 *   PATCH /admin/usuarios/:id  guarda el cambio
	 *
	 * Los selects se llenan desde los catalogos y no con opciones escritas
	 * aqui: asi los ids salen de la base y no hay forma de que se
	 * desincronicen si algun dia se agrega un rol o un estado.
	 *
	 * Esto no es el permiso, es la pantalla. El permiso lo pone el backend:
	 * estas rutas responden 403 a cualquiera que no sea admin, aunque llegue
	 * a ellas por su cuenta.
	 */

	interface RolUsuario {
		id_rol_usuario: number;
		rol_usuario_nombre: string;
	}

	interface EstadoUsuario {
		id_estado_usuario: number;
		estado_usuario_nombre: string;
	}

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	let usuarios = $state<UsuarioSesion[]>([]);
	let roles = $state<RolUsuario[]>([]);
	let estados = $state<EstadoUsuario[]>([]);

	let cargando = $state(true);
	let error = $state('');

	// El id de la fila que se esta guardando, y el error o el visto bueno de
	// cada fila. Van por id y no como una sola variable para que dos cambios
	// seguidos en filas distintas no se pisen el mensaje.
	let guardando = $state<string | null>(null);
	let mensajes = $state<Record<string, { texto: string; malo: boolean }>>({});

	$effect(() => {
		cargar();
	});

	async function cargar() {
		cargando = true;
		error = '';
		mensajes = {};

		// Las tres en paralelo: no dependen una de otra
		const [lista, cats, ests] = await Promise.all([
			pedir<UsuarioSesion[]>('/admin/usuarios'),
			pedir<RolUsuario[]>('/admin/roles'),
			pedir<EstadoUsuario[]>('/admin/estados')
		]);

		if (lista.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!lista.ok || !cats.ok || !ests.ok) {
			// Se muestra el primero que fallo; los tres traen el mismo formato
			error = [lista, cats, ests].find((r) => !r.ok)?.mensaje ?? 'No se pudo cargar el panel';
			cargando = false;
			return;
		}

		usuarios = lista.payload ?? [];
		roles = cats.payload ?? [];
		estados = ests.payload ?? [];
		cargando = false;
	}

	/**
	 * Guarda el cambio de un select. Se manda solo el campo que cambio: el
	 * backend deja igual todo lo que venga en null.
	 */
	async function cambiar(
		usuario: UsuarioSesion,
		campo: 'id_rol_usuario' | 'id_estado_usuario',
		valor: number
	) {
		guardando = usuario.id_usuario;
		mensajes = { ...mensajes, [usuario.id_usuario]: { texto: '', malo: false } };

		const respuesta = await pedir<UsuarioSesion>(
			`/admin/usuarios/${usuario.id_usuario}`,
			conJson('PATCH', { [campo]: valor })
		);

		guardando = null;

		if (respuesta.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!respuesta.ok || !respuesta.payload) {
			mensajes = {
				...mensajes,
				[usuario.id_usuario]: { texto: respuesta.mensaje, malo: true }
			};
			// Se vuelve a pedir la lista para que el select no quede mostrando
			// un valor que la base no acepto
			await recargarLista();
			return;
		}

		// El backend devuelve la fila ya actualizada: se reemplaza esa y no se
		// vuelve a pedir la lista entera
		const actualizado = respuesta.payload;
		usuarios = usuarios.map((u) => (u.id_usuario === actualizado.id_usuario ? actualizado : u));
		mensajes = {
			...mensajes,
			[usuario.id_usuario]: { texto: respuesta.mensaje, malo: false }
		};
	}

	async function recargarLista() {
		const lista = await pedir<UsuarioSesion[]>('/admin/usuarios');
		if (lista.ok && lista.payload) usuarios = lista.payload;
	}

	function nombreCompleto(u: UsuarioSesion): string {
		return u.apellido ? `${u.nombre} ${u.apellido}` : u.nombre;
	}

	function fecha(valor: string | null): string {
		if (!valor) return 'Sin dato';
		return new Date(valor).toLocaleDateString('es-GT', {
			day: 'numeric',
			month: 'short',
			year: 'numeric'
		});
	}
</script>

<section class="admin">
	<div class="titulo">
		<h2>Cuentas</h2>
		{#if !cargando && !error}
			<span class="cuantas">
				{usuarios.length}
				{usuarios.length === 1 ? 'cuenta' : 'cuentas'}
			</span>
		{/if}
	</div>

	{#if cargando}
		<p class="gris">Cargando las cuentas...</p>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if usuarios.length === 0}
		<!-- La lista excluye al admin que consulta, por eso puede salir vacia
		     aunque exista su propia cuenta -->
		<p class="gris">Todavia no hay otras cuentas registradas.</p>
	{:else}
		<div class="tabla">
			<table>
				<thead>
					<tr>
						<th>Usuario</th>
						<th>Correo</th>
						<th>Nombre</th>
						<th>Rol</th>
						<th>Estado</th>
						<th>Registro</th>
					</tr>
				</thead>
				<tbody>
					{#each usuarios as usuario (usuario.id_usuario)}
						{@const esTienda = usuario.correo_electronico === CORREO_TIENDA}
						<tr class:protegida={esTienda}>
							<td class="fuerte">{usuario.usuario}</td>
							<td>{usuario.correo_electronico}</td>
							<td>{nombreCompleto(usuario)}</td>
							<td>
								<!--
									La cuenta de la tienda no se edita desde aqui: el backend
									la rechaza con un 400 ("No se puede editar la cuenta de la
									tienda desde aqui"). Se apaga el control en vez de dejar
									intentarlo y recibir el error -- es la misma cuenta cuyo
									precio se ensena en todo el catalogo y bajo la que caen
									las ofertas que publica un admin, asi que cambiarle el rol
									o desactivarla romperia media tienda.
								-->
								<select
									aria-label="Rol de {usuario.usuario}"
									value={usuario.id_rol_usuario}
									disabled={esTienda || guardando === usuario.id_usuario}
									onchange={(e) =>
										cambiar(usuario, 'id_rol_usuario', Number(e.currentTarget.value))}
								>
									{#each roles as rol}
										<option value={rol.id_rol_usuario}>{rol.rol_usuario_nombre}</option>
									{/each}
								</select>
							</td>
							<td>
								<select
									aria-label="Estado de {usuario.usuario}"
									value={usuario.id_estado_usuario}
									disabled={esTienda || guardando === usuario.id_usuario}
									onchange={(e) =>
										cambiar(usuario, 'id_estado_usuario', Number(e.currentTarget.value))}
								>
									{#each estados as estado}
										<option value={estado.id_estado_usuario}>
											{estado.estado_usuario_nombre}
										</option>
									{/each}
								</select>
							</td>
							<td class="gris">
								{fecha(usuario.fecha_creacion)}
								{#if esTienda}
									<span class="nota-tienda">la cuenta de la tienda no se edita</span>
								{/if}
							</td>
						</tr>
						{#if mensajes[usuario.id_usuario]?.texto}
							<tr class="mensaje">
								<td colspan="6" class:malo={mensajes[usuario.id_usuario].malo}>
									{mensajes[usuario.id_usuario].texto}
								</td>
							</tr>
						{/if}
					{/each}
				</tbody>
			</table>
		</div>

		<p class="nota">
			Tu propia cuenta no aparece en la lista: no se edita desde aqui.
		</p>
	{/if}
</section>

<style>
	.admin {
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
		margin-bottom: 20px;
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

	.gris {
		color: var(--gris);
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

	/* La tabla se desplaza sola en pantalla angosta, en vez de estirar la
	   pagina y sacar una barra horizontal en todo el sitio */
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
		padding: 12px;
		color: var(--texto);
		border-bottom: 1px solid var(--linea);
		white-space: nowrap;
	}

	.fuerte {
		color: var(--tinta);
		font-weight: 500;
	}

	select {
		padding: 7px 10px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	select:focus {
		outline: none;
		border-color: var(--indigo);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	select:disabled {
		opacity: 0.6;
		cursor: progress;
	}

	/* La fila del mensaje va pegada debajo de la que se acaba de cambiar */
	.mensaje td {
		padding-top: 0;
		padding-bottom: 12px;
		font-size: var(--f-ms);
		color: var(--indigo);
		border-bottom: 1px solid var(--linea);
		white-space: normal;
	}

	.mensaje td.malo {
		color: var(--rojo);
	}

	.nota {
		margin-top: 16px;
		font-size: var(--f-ms);
		color: var(--gris);
	}

	@media (max-width: 620px) {
		.admin {
			padding: 22px 20px;
		}
	}

	.protegida {
		background: var(--panel);
	}

	.nota-tienda {
		display: block;
		font-size: var(--f-xs);
		color: var(--gris);
	}
</style>
