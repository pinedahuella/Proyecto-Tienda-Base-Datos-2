<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import { guardarSesion } from '$lib/sesion';
	import { conJson, pedir } from '$lib/api';

	// La pagina de registro manda aqui con ?registrado=1 despues de crear la
	// cuenta: el registro no abre sesion, asi que hay que iniciarla.
	let recienRegistrado = $derived(page.url.searchParams.get('registrado') === '1');

	/**
	 * identificador es el correo O el usuario, indistintamente: el backend
	 * revisa contra los dos y decide cual es. Por eso este campo no valida
	 * formato de correo, solo que traiga algo; si validara, no dejaria entrar
	 * a quien escriba su nombre de usuario.
	 */
	let identificador = $state('');
	let contrasena = $state('');
	let verContrasena = $state(false);
	let entrando = $state(false);
	let errorGeneral = $state('');
	let errores = $state<{ identificador?: string; contrasena?: string }>({});
	let campoIdentificador = $state<HTMLInputElement | null>(null);

	// Foco al cargar, con .focus() y no el atributo `autofocus`: el atributo
	// dispara el aviso de accesibilidad a11y_autofocus (mover el foco sin que
	// la persona lo pida desorienta a quien usa lector de pantalla), y aqui
	// hace falta igual para que el correo quede listo para escribir apenas
	// carga la pagina -- lo usa demo-fraude-login.ps1, que manda las teclas
	// sin poder hacer clic primero.
	onMount(() => {
		campoIdentificador?.focus();
	});

	function validar() {
		const nuevos: typeof errores = {};

		// Los mismos mensajes que devuelve el backend en su 400
		if (!identificador.trim()) {
			nuevos.identificador = 'El correo electronico o el usuario es obligatorio';
		}
		if (!contrasena) {
			nuevos.contrasena = 'La contrasena es obligatoria';
		}

		errores = nuevos;
		return Object.keys(nuevos).length === 0;
	}

	async function entrar(evento: SubmitEvent) {
		evento.preventDefault();
		errorGeneral = '';
		if (!validar()) return;

		entrando = true;

		const respuesta = await pedir<{ correo_electronico: string }>(
			'/usuario/login',
			conJson('POST', { identificador: identificador.trim(), contrasena })
		);

		entrando = false;

		// El 401 sale como aviso general y no debajo de un campo a proposito:
		// el backend manda el mismo mensaje si el identificador no existe, si
		// la contrasena no coincide o si la cuenta esta suspendida, para no
		// delatar cual de las tres fue. Marcar un campo lo delataria igual.
		if (!respuesta.ok || !respuesta.payload) {
			errorGeneral = respuesta.mensaje;
			return;
		}

		// La sesion de verdad es la cookie mesh_token que acaba de dejar el
		// backend, y es httpOnly: no se puede leer desde aqui. Esto solo
		// guarda el correo para que el panel sepa a quien saludar.
		guardarSesion(respuesta.payload.correo_electronico);
		await goto('/panel');
	}
</script>

<svelte:head>
	<title>Mesh · Inicia sesion</title>
</svelte:head>

<Cabecera />

<main>
	<div class="env columnas">
		<section class="acceso">
			<h1>Inicia sesion</h1>
			<p class="entrada">Entra para ver tus pedidos y administrar tu tienda.</p>

			{#if recienRegistrado}
				<p class="creada" role="status">Tu cuenta quedo creada. Ya puedes entrar.</p>
			{/if}

			{#if errorGeneral}
				<p class="aviso" role="alert">{errorGeneral}</p>
			{/if}

			<form onsubmit={entrar} novalidate>
				<div class="campo">
					<label for="identificador">Correo electronico o usuario</label>
					<!-- type text y no email: aqui tambien vale el nombre de usuario,
					     y con type email el navegador rechazaria uno sin arroba -->
					<input
						id="identificador"
						type="text"
						autocomplete="username"
						bind:this={campoIdentificador}
						placeholder="tu@correo.com o tu usuario"
						bind:value={identificador}
						aria-invalid={errores.identificador ? 'true' : undefined}
						aria-describedby={errores.identificador ? 'error-identificador' : undefined}
					/>
					{#if errores.identificador}
						<p class="error" id="error-identificador">{errores.identificador}</p>
					{/if}
				</div>

				<div class="campo">
					<label for="contrasena">Contrasena</label>
					<div class="con-ojo">
						<input
							id="contrasena"
							type={verContrasena ? 'text' : 'password'}
							autocomplete="current-password"
							placeholder="Al menos 8 caracteres"
							bind:value={contrasena}
							aria-invalid={errores.contrasena ? 'true' : undefined}
							aria-describedby={errores.contrasena ? 'error-contrasena' : undefined}
						/>
						<button
							type="button"
							class="ojo"
							onclick={() => (verContrasena = !verContrasena)}
							aria-label={verContrasena ? 'Ocultar la contrasena' : 'Mostrar la contrasena'}
							title={verContrasena ? 'Ocultar' : 'Mostrar'}
						>
							{#if verContrasena}
								<!-- ojo tachado: la contrasena esta a la vista -->
								<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true">
									<path d="M3 3l18 18" stroke-linecap="round" />
									<path
										d="M10.6 5.2A9.6 9.6 0 0 1 12 5c5 0 9 4.5 10 7a15 15 0 0 1-3.3 4.2M6.4 6.5C4.2 8 2.6 10.1 2 12c1 2.5 5 7 10 7a9.7 9.7 0 0 0 4.4-1"
										stroke-linecap="round"
									/>
									<path d="M9.9 10a3 3 0 0 0 4.2 4.2" stroke-linecap="round" />
								</svg>
							{:else}
								<!-- ojo abierto: la contrasena esta oculta -->
								<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true">
									<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7Z" stroke-linejoin="round" />
									<circle cx="12" cy="12" r="3" />
								</svg>
							{/if}
						</button>
					</div>
					{#if errores.contrasena}
						<p class="error" id="error-contrasena">{errores.contrasena}</p>
					{/if}
				</div>

				<button class="entrar" type="submit" disabled={entrando}>
					{entrando ? 'Entrando' : 'Entrar'}
				</button>
			</form>

			<p class="pie-form">No tienes cuenta? <a href="/registro">Crea una</a></p>
		</section>

	</div>
</main>

<Pie />

<style>
	main {
		display: flex;
		align-items: center;
		justify-content: center;
		padding-top: 56px;
		padding-bottom: 56px;
	}

	.columnas {
		display: flex;
		justify-content: center;
	}

	/* ── formulario ── */

	/* Fondo solido: la trama de la pagina queda detras, no debajo del texto */
	.acceso {
		width: 100%;
		max-width: 400px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		padding: 36px 34px 34px;
	}

	.acceso h1 {
		margin-bottom: 8px;
	}

	.entrada {
		margin-bottom: 30px;
		color: var(--gris);
	}

	form {
		display: flex;
		flex-direction: column;
		gap: var(--e4);
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
	}

	label {
		font-size: var(--f-base);
		font-weight: 500;
		color: var(--tinta);
	}

	input {
		width: 100%;
		padding: 11px 13px;
		font-family: inherit;
		font-size: var(--f-md);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		transition: border-color var(--t);
	}

	input::placeholder {
		color: var(--gris-2);
	}

	input:hover {
		border-color: var(--gris-2);
	}

	input:focus {
		outline: none;
		border-color: var(--indigo);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	input[aria-invalid='true'] {
		border-color: var(--rojo);
	}

	/* El ojo va dentro del campo, por eso el input reserva espacio a la derecha */
	.con-ojo {
		position: relative;
	}

	.con-ojo input {
		padding-right: 44px;
	}

	.ojo {
		position: absolute;
		right: 6px;
		top: 50%;
		transform: translateY(-50%);
		width: 32px;
		height: 32px;
		display: grid;
		place-items: center;
		background: none;
		border: 0;
		border-radius: var(--r);
		color: var(--gris);
		cursor: pointer;
		transition: color var(--t);
	}

	.ojo:hover {
		color: var(--indigo);
	}

	.ojo svg {
		width: 19px;
		height: 19px;
	}

	.error {
		font-size: var(--f-ms);
		color: var(--rojo);
	}

	/* Error que no pertenece a ningun campo: credenciales incorrectas, 503,
	   500 o el backend apagado */
	.aviso {
		margin-bottom: 20px;
		padding: 11px 14px;
		font-size: var(--f-base);
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	/* Aviso de que la cuenta se creo, al volver del registro */
	.creada {
		margin-bottom: 20px;
		padding: 11px 14px;
		font-size: var(--f-base);
		color: var(--tinta);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
	}

	.pie-form {
		margin-top: 22px;
		font-size: var(--f-base);
		color: var(--gris);
	}

	.pie-form a {
		color: var(--indigo);
		font-weight: 500;
	}

	/* El boton principal usa el color de la marca, que es lo que se ve en los
	   dos temas. El texto va del color de la superficie para que contraste. */
	.entrar {
		margin-top: 4px;
		padding: 12px 20px;
		font-family: inherit;
		font-size: var(--f-md);
		font-weight: 500;
		color: var(--blanco);
		background: var(--indigo);
		border: 0;
		border-radius: var(--r);
		cursor: pointer;
		transition: background var(--t);
	}

	.entrar:hover:not(:disabled) {
		background: var(--indigo-os);
	}

	.entrar:disabled {
		opacity: 0.6;
		cursor: progress;
	}

	@media (max-width: 620px) {
		main {
			padding-top: 34px;
			padding-bottom: 34px;
		}
		.acceso {
			padding: 28px 22px 26px;
		}
	}
</style>
