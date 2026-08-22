<script lang="ts">
	import { conJson, pedir } from './api';

	/**
	 * Las direcciones de envio del usuario.
	 *
	 *   POST  /direccion-usuario      crea una
	 *   PATCH /direccion-usuario/:id  edita pais, departamento, ciudad o codigo postal
	 *
	 * Esas son las dos rutas que existen, y son las dos que usa esta pantalla.
	 * No hay una ruta para consultar las direcciones de un usuario, asi que la
	 * lista se arma con lo que devuelve el POST y al recargar la pagina empieza
	 * vacia otra vez. Por eso el texto lo dice, en vez de ensenar una lista
	 * vacia como si el usuario no tuviera ninguna.
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

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	let direcciones = $state<Direccion[]>([]);

	type Modo = 'lista' | 'nueva' | 'editar';
	let modo = $state<Modo>('lista');
	let editando = $state<string | null>(null);

	let pais = $state('');
	let departamento = $state('');
	let ciudad = $state('');
	let codigoPostal = $state('');

	let guardando = $state(false);
	let errorForm = $state('');
	let hecho = $state('');

	function limpiar() {
		pais = '';
		departamento = '';
		ciudad = '';
		codigoPostal = '';
		errorForm = '';
	}

	function abrirNueva() {
		limpiar();
		hecho = '';
		editando = null;
		modo = 'nueva';
	}

	function abrirEditar(d: Direccion) {
		// Se parte de lo que hay, para que se edite y no se reescriba todo
		pais = d.pais;
		departamento = d.departamento;
		ciudad = d.ciudad;
		codigoPostal = d.codigo_postal ?? '';
		errorForm = '';
		hecho = '';
		editando = d.id_direccion;
		modo = 'editar';
	}

	function cancelar() {
		limpiar();
		editando = null;
		modo = 'lista';
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
		if (pais.trim().length > 100) {
			errorForm = 'El pais no puede tener mas de 100 caracteres';
			return false;
		}
		if (!departamento.trim()) {
			errorForm = 'El departamento es obligatorio';
			return false;
		}
		if (departamento.trim().length > 100) {
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

		const cuerpo = {
			pais: pais.trim(),
			departamento: departamento.trim(),
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
		{#if direcciones.length === 0}
			<p class="vacio">
				Aqui apareceran las direcciones que agregues en esta sesion.
			</p>
		{:else}
			<ul>
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

			<div class="pareja">
				<div class="campo">
					<label for="d-pais">Pais</label>
					<input id="d-pais" type="text" bind:value={pais} />
				</div>
				<div class="campo">
					<label for="d-departamento">Departamento</label>
					<input id="d-departamento" type="text" bind:value={departamento} />
				</div>
			</div>

			<div class="pareja">
				<div class="campo">
					<label for="d-ciudad">Ciudad</label>
					<input id="d-ciudad" type="text" bind:value={ciudad} />
				</div>
				<div class="campo">
					<label for="d-postal">
						Codigo postal <span class="opcional">opcional</span>
					</label>
					<input id="d-postal" type="text" bind:value={codigoPostal} />
				</div>
			</div>

			<div class="botones">
				<button class="principal" type="submit" disabled={guardando}>
					{guardando ? 'Guardando...' : modo === 'nueva' ? 'Agregar' : 'Guardar cambios'}
				</button>
				<button type="button" onclick={cancelar} disabled={guardando}>Cancelar</button>
			</div>
		</form>
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

	.vacio {
		margin: 0;
		font-size: 0.95rem;
		color: var(--gris);
	}

	ul {
		margin: 0;
		padding: 0;
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	li {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		padding: 14px 16px;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	li p {
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

	li button {
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

	li button:hover {
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

	.opcional {
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

	.malo {
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

	@media (max-width: 620px) {
		.pareja {
			grid-template-columns: 1fr;
		}
	}
</style>
