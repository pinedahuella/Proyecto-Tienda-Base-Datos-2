<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import { conJson, pedir } from '$lib/api';
	import Direcciones from '$lib/Direcciones.svelte';
	import PanelAdmin from '$lib/PanelAdmin.svelte';
	import PanelVendedor from '$lib/PanelVendedor.svelte';
	import Pedido from '$lib/Pedido.svelte';
	import {
		cerrarSesion,
		ID_ROL_ADMIN,
		ID_ROL_VENDEDOR,
		SesionIndeterminada,
		verificarSesion,
		type PerfilUsuario
	} from '$lib/sesion';

	/**
	 * Panel del usuario.
	 *
	 * Se carga en dos pasos, con dos rutas que hacen cosas distintas:
	 *
	 *   GET /usuario/yo   dice si el token sigue sirviendo. Es el candado.
	 *   GET /perfil       trae los datos a mostrar, con el nombre del rol y
	 *                     del estado ademas de sus ids.
	 *
	 * Y deja editar lo que el backend permite editar al propio usuario:
	 *
	 *   PATCH /perfil             nombre y apellido
	 *   PATCH /perfil/contrasena  la contrasena
	 *
	 * PATCH /perfil acepta nombre y apellido, nada mas: el formulario de
	 * edicion tiene exactamente esos dos campos.
	 *
	 * Debajo del perfil se muestra una cosa u otra segun el rol: un admin ve
	 * la gestion de cuentas, y cualquier otro ve su tienda. El perfil lo ven
	 * los dos, porque los dos necesitan poder cambiar su contrasena.
	 */

	let perfil = $state<PerfilUsuario | null>(null);
	let cargando = $state(true);
	let error = $state('');

	let esAdmin = $derived(perfil?.id_rol_usuario === ID_ROL_ADMIN);
	let esVendedor = $derived(perfil?.id_rol_usuario === ID_ROL_VENDEDOR);

	type Modo = 'ver' | 'editar' | 'contrasena';
	let modo = $state<Modo>('ver');
	let confirmacionOk = $state('');

	// Formulario de nombre y apellido
	let eNombre = $state('');
	let eApellido = $state('');
	let guardando = $state(false);
	let errorPerfil = $state('');

	// Formulario de contrasena
	let actual = $state('');
	let nueva = $state('');
	let repetida = $state('');
	let verClaves = $state(false);
	let cambiando = $state(false);
	let errorClave = $state('');

	// onMount y no $effect: esto tiene que correr UNA vez, al abrir el panel.
	// Con $effect se volvia a ejecutar solo (se vieron seis llamadas seguidas en
	// el mismo instante), y como abajo todo cuelga de {#if cargando}, cada
	// vuelta desmontaba y volvia a montar el arbol entero: el formulario de
	// vendedor que estuviera abierto se perdia a media escritura.
	onMount(cargar);

	async function cargar() {
		cargando = true;
		error = '';

		// 1. El candado: si la sesion se acabo, a iniciar sesion de nuevo
		try {
			const sesion = await verificarSesion();
			if (!sesion) {
				await goto('/entrar');
				return;
			}
		} catch (fallo) {
			// No se pudo averiguar (503 o backend apagado). No se saca a nadie:
			// el token puede estar bien y ser el servidor el del problema.
			error = fallo instanceof SesionIndeterminada ? fallo.message : 'No se pudo cargar el panel';
			cargando = false;
			return;
		}

		// 2. Los datos del perfil
		const respuesta = await pedir<PerfilUsuario>('/perfil');

		if (!respuesta.ok || !respuesta.payload) {
			if (await sesionVencida(respuesta.estado)) return;
			error = respuesta.mensaje;
			cargando = false;
			return;
		}

		perfil = respuesta.payload;
		cargando = false;
	}

	/**
	 * Entre una peticion y otra el token puede caducar, o pueden suspender la
	 * cuenta: todas las rutas de perfil lo comprueban en cada llamada. Si eso
	 * pasa, la sesion se acabo de verdad y toca volver a entrar.
	 */
	/** Lo mismo que sesionVencida, para el hijo, que no devuelve el codigo. */
	function expiro() {
		cerrarSesion();
		goto('/entrar');
	}

	async function sesionVencida(estado: number): Promise<boolean> {
		if (estado !== 401) return false;
		cerrarSesion();
		await goto('/entrar');
		return true;
	}

	function abrir(nuevo: Modo) {
		confirmacionOk = '';
		errorPerfil = '';
		errorClave = '';

		if (nuevo === 'editar') {
			// Se parte de lo que hay, para que se edite y no se reescriba todo
			eNombre = perfil?.nombre ?? '';
			eApellido = perfil?.apellido ?? '';
		}
		if (nuevo === 'contrasena') {
			actual = '';
			nueva = '';
			repetida = '';
		}

		modo = nuevo;
	}

	/** PATCH /perfil. Los mensajes son los mismos que devuelve el backend. */
	async function guardarPerfil(evento: SubmitEvent) {
		evento.preventDefault();
		errorPerfil = '';

		if (!eNombre.trim()) {
			errorPerfil = 'El nombre es obligatorio';
			return;
		}
		if (eNombre.trim().length > 100) {
			errorPerfil = 'El nombre no puede tener mas de 100 caracteres';
			return;
		}
		if (eApellido.trim().length > 100) {
			errorPerfil = 'El apellido no puede tener mas de 100 caracteres';
			return;
		}

		guardando = true;

		// El apellido va como texto y no como null aunque quede vacio: el
		// backend usa COALESCE, asi que un null significa "no lo toques" y
		// entonces no habria forma de borrarlo.
		const respuesta = await pedir<PerfilUsuario>(
			'/perfil',
			conJson('PATCH', { nombre: eNombre.trim(), apellido: eApellido.trim() })
		);

		guardando = false;

		if (!respuesta.ok || !respuesta.payload) {
			if (await sesionVencida(respuesta.estado)) return;
			errorPerfil = respuesta.mensaje;
			return;
		}

		// El backend devuelve el perfil ya actualizado, asi que no hace falta
		// volver a pedir /perfil
		perfil = respuesta.payload;
		confirmacionOk = respuesta.mensaje;
		modo = 'ver';
	}

	/** PATCH /perfil/contrasena. Mismas reglas que en el registro. */
	async function cambiarContrasena(evento: SubmitEvent) {
		evento.preventDefault();
		errorClave = '';

		if (!actual) {
			errorClave = 'La contrasena actual es obligatoria';
			return;
		}
		if (!nueva) {
			errorClave = 'La nueva contrasena es obligatoria';
			return;
		}
		if (!repetida) {
			errorClave = 'La confirmacion de la nueva contrasena es obligatoria';
			return;
		}
		if (nueva !== repetida) {
			errorClave = 'Las contrasenas nuevas no coinciden';
			return;
		}
		if (nueva === actual) {
			errorClave = 'La nueva contrasena debe ser diferente a la actual';
			return;
		}
		if (nueva.length < 8) {
			errorClave = 'La contrasena debe tener al menos 8 caracteres';
			return;
		}
		if (!/[A-Z]/.test(nueva)) {
			errorClave = 'La contrasena debe tener al menos una letra mayuscula';
			return;
		}
		if (!/[^A-Za-z0-9]/.test(nueva)) {
			errorClave = 'La contrasena debe tener al menos un caracter especial';
			return;
		}

		cambiando = true;

		const respuesta = await pedir('/perfil/contrasena', {
			...conJson('PATCH', {
				contrasena_actual: actual,
				contrasena_nueva: nueva,
				contrasena_nueva_confirmacion: repetida
			})
		});

		cambiando = false;

		if (!respuesta.ok) {
			if (await sesionVencida(respuesta.estado)) return;
			errorClave = respuesta.mensaje;
			return;
		}

		// Se limpian a mano: son datos sensibles y no tienen por que quedarse
		// en memoria ni reaparecer al abrir el formulario otra vez
		actual = '';
		nueva = '';
		repetida = '';
		confirmacionOk = respuesta.mensaje;
		modo = 'ver';
	}

	/**
	 * La sesion no se cae al cambiar la contrasena: el token ya estaba
	 * firmado y sigue valido hasta que venza. Es el comportamiento del
	 * backend, no un descuido de aqui.
	 */
	async function salir() {
		await pedir('/usuario/logout', { method: 'POST' });
		cerrarSesion();
		await goto('/');
	}

	/**
	 * Las fechas llegan en ISO. fecha_nacimiento es una columna date, pero
	 * PostgreSQL la manda con la hora de la zona, asi que se formatea en la
	 * zona del navegador para que salga el dia correcto.
	 */
	function fecha(valor: string | null): string {
		if (!valor) return 'Sin dato';
		return new Date(valor).toLocaleDateString('es-GT', {
			day: 'numeric',
			month: 'long',
			year: 'numeric'
		});
	}

	/**
	 * Las tarjetas del comprador. Son ceros fijos, no datos: andamiaje de
	 * cuando no habia nada que enseñar.
	 *
	 * "Pedidos" ya no esta: el pedido de verdad se ensena arriba, en el
	 * componente Pedido, y la tarjeta afirmaba "Aun no hay pedidos" justo
	 * debajo de un pedido con lineas y su total. Un cero inventado al lado del
	 * dato de verdad no es andamiaje, es una contradiccion en pantalla.
	 *
	 * Las otras dos siguen siendo ceros fijos, y eso hay que quitarlo tambien
	 * el dia que haya de donde sacarlos.
	 */
	const resumen = [
		{ rotulo: 'Productos', cifra: '0', nota: 'Todavia no has publicado nada.' },
		{ rotulo: 'Inventario', cifra: '0', nota: 'Sin movimientos registrados.' }
	];
</script>

<svelte:head>
	<title>Mesh · Panel</title>
</svelte:head>

<Cabecera sesion={perfil?.correo_electronico ?? null} alSalir={salir} />

<main>
	<div class="env">
		<!-- Solo la PRIMERA carga tapa la pantalla. Si se recarga el perfil con
		     el panel ya abierto, se deja lo que hay: si no, se desmonta todo lo
		     de abajo y lo que estuviera escrito a medias se pierde. -->
		{#if cargando && !perfil}
			<p class="cargando">Cargando tu panel...</p>
		{:else if error}
			<div class="aviso" role="alert">
				<p>{error}</p>
				<button type="button" onclick={cargar}>Reintentar</button>
			</div>
		{:else if perfil}
			<div class="saludo">
				<h1>Hola, {perfil.nombre}</h1>
				<p>Tu tienda esta lista. Publica tu primer producto para que aparezca en el catalogo.</p>
			</div>

			<section class="perfil">
				<div class="titulo">
					<h2>Tu perfil</h2>
					<span class="etiqueta">{perfil.rol_usuario_nombre}</span>
					<span class="etiqueta estado">{perfil.estado_usuario_nombre}</span>

					{#if modo === 'ver'}
						<div class="acciones">
							<button type="button" onclick={() => abrir('editar')}>Editar datos</button>
							<button type="button" onclick={() => abrir('contrasena')}>Cambiar contrasena</button>
						</div>
					{/if}
				</div>

				{#if confirmacionOk}
					<p class="hecho" role="status">{confirmacionOk}</p>
				{/if}

				{#if modo === 'ver'}
					<dl>
						<div>
							<dt>Usuario</dt>
							<dd>{perfil.usuario}</dd>
						</div>
						<div>
							<dt>Correo electronico</dt>
							<dd>{perfil.correo_electronico}</dd>
						</div>
						<div>
							<dt>Nombre</dt>
							<dd>{perfil.nombre}</dd>
						</div>
						<div>
							<dt>Apellido</dt>
							<dd>{perfil.apellido || 'Sin dato'}</dd>
						</div>
						<div>
							<dt>Fecha de nacimiento</dt>
							<dd>{fecha(perfil.fecha_nacimiento)}</dd>
						</div>
						<div>
							<dt>Cuenta creada</dt>
							<dd>{fecha(perfil.fecha_creacion)}</dd>
						</div>
					</dl>
				{:else if modo === 'editar'}
					<!-- Nombre y apellido: es lo que acepta PATCH /perfil -->
					<form onsubmit={guardarPerfil} novalidate>
						{#if errorPerfil}
							<p class="malo" role="alert">{errorPerfil}</p>
						{/if}

						<div class="pareja">
							<div class="campo">
								<label for="e-nombre">Nombre</label>
								<input id="e-nombre" type="text" bind:value={eNombre} />
							</div>
							<div class="campo">
								<label for="e-apellido">Apellido <span class="opcional">opcional</span></label>
								<input id="e-apellido" type="text" bind:value={eApellido} />
							</div>
						</div>

						<div class="botones">
							<button class="principal" type="submit" disabled={guardando}>
								{guardando ? 'Guardando' : 'Guardar cambios'}
							</button>
							<button type="button" onclick={() => abrir('ver')}>Cancelar</button>
						</div>
					</form>
				{:else}
					<form onsubmit={cambiarContrasena} novalidate>
						{#if errorClave}
							<p class="malo" role="alert">{errorClave}</p>
						{/if}

						<div class="campo">
							<label for="c-actual">Contrasena actual</label>
							<input
								id="c-actual"
								type={verClaves ? 'text' : 'password'}
								autocomplete="current-password"
								bind:value={actual}
							/>
						</div>

						<div class="pareja">
							<div class="campo">
								<label for="c-nueva">Nueva contrasena</label>
								<input
									id="c-nueva"
									type={verClaves ? 'text' : 'password'}
									autocomplete="new-password"
									bind:value={nueva}
								/>
							</div>
							<div class="campo">
								<label for="c-repetida">Repite la nueva</label>
								<input
									id="c-repetida"
									type={verClaves ? 'text' : 'password'}
									autocomplete="new-password"
									bind:value={repetida}
								/>
							</div>
						</div>

						<label class="mostrar">
							<input type="checkbox" bind:checked={verClaves} />
							Mostrar las contrasenas
						</label>

						<p class="ayuda">
							Minimo 8 caracteres, una mayuscula y un caracter especial. Tiene que ser distinta de
							la actual.
						</p>

						<div class="botones">
							<button class="principal" type="submit" disabled={cambiando}>
								{cambiando ? 'Guardando' : 'Cambiar contrasena'}
							</button>
							<button type="button" onclick={() => abrir('ver')}>Cancelar</button>
						</div>
					</form>
				{/if}
			</section>

			<Direcciones alExpirarSesion={expiro} />

			<!-- Va para todos, no solo para el rol comprador: /comprador/pedidos
			     solo exige sesion, asi que un vendedor o un admin compran igual. -->
			<Pedido alExpirarSesion={expiro} />

			{#if esAdmin}
				<PanelAdmin alExpirarSesion={expiro} />
			{:else if esVendedor}
				<PanelVendedor alExpirarSesion={expiro} />
			{:else}
				<div class="resumen">
					{#each resumen as tarjeta}
						<article>
							<h3>{tarjeta.rotulo}</h3>
							<p class="cifra">{tarjeta.cifra}</p>
							<p class="nota">{tarjeta.nota}</p>
						</article>
					{/each}
				</div>

				<section class="invitacion">
					<h2>Tu tienda esta vacia por ahora</h2>
					<p>
						Cuando publiques tu primer producto, los pedidos y los movimientos de inventario
						empiezan a aparecer aqui.
					</p>
				</section>
			{/if}
		{/if}
	</div>
</main>

<Pie />

<style>
	main {
		padding-top: 48px;
		min-height: 50vh;
	}

	.cargando {
		color: var(--gris);
	}

	/* El backend no respondio: no se saca al usuario, se le deja reintentar */
	.aviso {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 20px;
		flex-wrap: wrap;
		padding: 18px 20px;
		color: var(--rojo);
		background: var(--blanco);
		border: 1px solid var(--rojo);
		border-radius: var(--r2);
	}

	.aviso button {
		padding: 9px 18px;
		font-family: inherit;
		font-size: 0.95rem;
		color: var(--blanco);
		background: var(--indigo);
		border: 0;
		border-radius: var(--r);
		cursor: pointer;
	}

	.saludo {
		max-width: 560px;
		margin-bottom: 36px;
	}

	.saludo h1 {
		margin-bottom: 10px;
	}

	.saludo p {
		color: var(--gris);
	}

	/* ── perfil ── */

	.perfil {
		padding: 26px 28px;
		margin-bottom: 28px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.titulo {
		display: flex;
		align-items: center;
		gap: 10px;
		flex-wrap: wrap;
		margin-bottom: 22px;
	}

	.titulo h2 {
		font-size: 1.3rem;
		margin-right: 4px;
	}

	/* El rol y el estado vienen con nombre desde /perfil, no con el id */
	.etiqueta {
		padding: 3px 11px;
		font-size: 0.82rem;
		color: var(--indigo);
		background: var(--indigo-cl);
		border-radius: 999px;
	}

	.etiqueta.estado {
		color: var(--gris);
		background: var(--panel);
	}

	.acciones {
		margin-left: auto;
		display: flex;
		gap: 10px;
		flex-wrap: wrap;
	}

	.acciones button,
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

	.acciones button:hover,
	.botones button:hover {
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

	.hecho {
		margin-bottom: 18px;
		padding: 10px 14px;
		font-size: 0.92rem;
		color: var(--tinta);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
	}

	.malo {
		margin-bottom: 18px;
		padding: 10px 14px;
		font-size: 0.92rem;
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	dl {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
		gap: 20px 28px;
	}

	dt {
		font-size: 0.85rem;
		color: var(--gris);
		margin-bottom: 3px;
	}

	dd {
		color: var(--tinta);
		overflow-wrap: anywhere;
	}

	/* ── formularios del perfil ── */

	form {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.pareja {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 16px;
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: 7px;
	}

	label {
		font-size: 0.92rem;
		font-weight: 500;
		color: var(--tinta);
	}

	.opcional {
		font-weight: 400;
		color: var(--gris-2);
	}

	input[type='text'],
	input[type='password'] {
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

	input[type='text']:focus,
	input[type='password']:focus {
		outline: none;
		border-color: var(--indigo);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	.mostrar {
		display: flex;
		align-items: center;
		gap: 8px;
		font-weight: 400;
		color: var(--gris);
		cursor: pointer;
	}

	.ayuda {
		font-size: 0.88rem;
		color: var(--gris);
	}

	.botones {
		display: flex;
		gap: 10px;
		flex-wrap: wrap;
		margin-top: 2px;
	}

	/* ── resumen ── */

	.resumen {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
		gap: 20px;
		margin-bottom: 28px;
	}

	.resumen article {
		padding: 22px 24px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.resumen h3 {
		font-size: 0.95rem;
		font-weight: 500;
		color: var(--gris);
		margin-bottom: 10px;
	}

	.cifra {
		font-size: 2.4rem;
		line-height: 1;
		color: var(--tinta);
		margin-bottom: 8px;
	}

	.nota {
		font-size: 0.92rem;
		color: var(--gris-2);
	}

	.invitacion {
		padding: 30px 32px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.invitacion h2 {
		font-size: 1.3rem;
		margin-bottom: 6px;
	}

	.invitacion p {
		max-width: 560px;
		color: var(--texto);
	}

	@media (max-width: 620px) {
		main {
			padding-top: 32px;
		}
		.saludo {
			margin-bottom: 26px;
		}
		.perfil {
			padding: 22px 20px;
		}
		.acciones {
			margin-left: 0;
			width: 100%;
		}
		.pareja {
			grid-template-columns: 1fr;
		}
		.invitacion {
			padding: 24px 20px;
		}
	}
</style>
