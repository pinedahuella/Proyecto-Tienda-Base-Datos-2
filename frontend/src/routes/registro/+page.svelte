<script lang="ts">
	import { goto } from '$app/navigation';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import { conJson, pedir } from '$lib/api';

	/**
	 * Panel de registro. Manda POST /usuario/registro.
	 *
	 * Las reglas de abajo son las mismas que valida el backend, con los
	 * mismos mensajes, para que el usuario no llene todo y hasta el final se
	 * entere de que la contrasena no servia. El backend igual las vuelve a
	 * revisar: esta copia es comodidad, no seguridad, y si alguna regla
	 * cambia alla hay que cambiarla aqui.
	 */

	let correo = $state('');
	let usuario = $state('');
	let nombre = $state('');
	let apellido = $state('');
	let contrasena = $state('');
	let fechaNacimiento = $state('');

	let verContrasena = $state(false);
	let enviando = $state(false);
	let errorGeneral = $state('');

	type Campo = 'correo' | 'usuario' | 'nombre' | 'apellido' | 'contrasena' | 'fecha';
	let errores = $state<Partial<Record<Campo, string>>>({});

	// La fecha limite para tener 18 anos hoy. Se le pasa al input como max
	// para que el calendario no deje elegir una fecha que el backend va a
	// rechazar. Se calcula con setFullYear y no restando dias, por los anos
	// bisiestos.
	const maximaFechaNacimiento = (() => {
		const limite = new Date();
		limite.setFullYear(limite.getFullYear() - 18);
		return limite.toISOString().slice(0, 10);
	})();

	function validar(): boolean {
		const nuevos: Partial<Record<Campo, string>> = {};

		if (!correo.trim()) {
			nuevos.correo = 'El correo electronico es obligatorio';
		} else if (correo.trim().length > 255) {
			nuevos.correo = 'El correo electronico no puede tener mas de 255 caracteres';
		} else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(correo.trim())) {
			nuevos.correo = 'El correo electronico no es valido';
		}

		if (!usuario.trim()) {
			nuevos.usuario = 'El usuario es obligatorio';
		} else if (usuario.trim().length > 50) {
			nuevos.usuario = 'El usuario no puede tener mas de 50 caracteres';
		}

		if (!nombre.trim()) {
			nuevos.nombre = 'El nombre es obligatorio';
		} else if (nombre.trim().length > 100) {
			nuevos.nombre = 'El nombre no puede tener mas de 100 caracteres';
		}

		if (apellido.trim().length > 100) {
			nuevos.apellido = 'El apellido no puede tener mas de 100 caracteres';
		}

		if (!contrasena) {
			nuevos.contrasena = 'La contrasena es obligatoria';
		} else if (contrasena.length < 8) {
			nuevos.contrasena = 'La contrasena debe tener al menos 8 caracteres';
		} else if (!/[A-Z]/.test(contrasena)) {
			nuevos.contrasena = 'La contrasena debe tener al menos una letra mayuscula';
		} else if (!/[^A-Za-z0-9]/.test(contrasena)) {
			nuevos.contrasena = 'La contrasena debe tener al menos un caracter especial';
		}

		if (fechaNacimiento && fechaNacimiento > maximaFechaNacimiento) {
			nuevos.fecha = 'El usuario debe ser mayor de 18 anos';
		}

		errores = nuevos;
		return Object.keys(nuevos).length === 0;
	}

	/**
	 * Pregunta si el correo o el usuario ya estan tomados, cuando la persona
	 * sale del campo. Existe para avisar antes de que llene todo el resto y
	 * el registro le rebote con un 409.
	 *
	 * Si la consulta falla no se dice nada: es solo un aviso adelantado, y el
	 * registro va a dar el error de verdad igual. Molestar aqui con un error
	 * de red sobraria.
	 */
	async function revisarDisponibilidad(campo: 'correo' | 'usuario') {
		const valor = campo === 'correo' ? correo.trim() : usuario.trim();
		if (!valor || errores[campo]) return;

		const respuesta = await pedir<{ correo_existente: boolean; usuario_existente: boolean }>(
			`/usuario/registros-existentes?${campo}=${encodeURIComponent(valor)}`
		);
		if (!respuesta.ok || !respuesta.payload) return;

		const tomado =
			campo === 'correo' ? respuesta.payload.correo_existente : respuesta.payload.usuario_existente;

		if (tomado) {
			errores = {
				...errores,
				[campo]:
					campo === 'correo'
						? 'El correo electronico ya esta registrado'
						: 'El usuario ya esta registrado'
			};
		}
	}

	/**
	 * El backend manda el motivo en "mensaje", no un campo. Se busca a que
	 * campo pertenece por lo que dice, para pintarlo junto al input en vez de
	 * como un error suelto arriba. Lo que no se reconoce (503, 500, red) se
	 * muestra como error general.
	 */
	function repartirError(mensaje: string) {
		const texto = mensaje.toLowerCase();

		if (texto.includes('correo') && texto.includes('usuario')) {
			errores = {
				...errores,
				correo: 'El correo electronico ya esta registrado',
				usuario: 'El usuario ya esta registrado'
			};
			return;
		}
		if (texto.includes('correo')) {
			errores = { ...errores, correo: mensaje };
			return;
		}
		if (texto.includes('usuario') && !texto.includes('registrar')) {
			errores = { ...errores, usuario: mensaje };
			return;
		}
		if (texto.includes('contrasena')) {
			errores = { ...errores, contrasena: mensaje };
			return;
		}
		if (texto.includes('apellido')) {
			errores = { ...errores, apellido: mensaje };
			return;
		}
		if (texto.includes('fecha')) {
			errores = { ...errores, fecha: mensaje };
			return;
		}
		if (texto.includes('nombre')) {
			errores = { ...errores, nombre: mensaje };
			return;
		}

		errorGeneral = mensaje;
	}

	async function registrar(evento: SubmitEvent) {
		evento.preventDefault();
		errorGeneral = '';
		if (!validar()) return;

		enviando = true;

		// Los opcionales van en null y no en cadena vacia: el backend los
		// trata como "no vino" solo si son null o "", y null es lo que de
		// verdad se guarda en la columna.
		const respuesta = await pedir(
			'/usuario/registro',
			conJson('POST', {
				correo_electronico: correo.trim(),
				usuario: usuario.trim(),
				nombre: nombre.trim(),
				apellido: apellido.trim() || null,
				contrasena,
				fecha_nacimiento: fechaNacimiento || null
			})
		);

		enviando = false;

		if (!respuesta.ok) {
			repartirError(respuesta.mensaje);
			return;
		}

		// El registro no abre sesion (no devuelve cookie), asi que toca
		// iniciarla. Se avisa por la URL para que la pagina de acceso pueda
		// decir que la cuenta quedo creada.
		await goto('/?registrado=1');
	}
</script>

<svelte:head>
	<title>Mesh · Crear cuenta</title>
</svelte:head>

<Cabecera />

<main>
	<div class="env centrado">
		<section class="acceso">
			<h1>Crea tu cuenta</h1>
			<p class="entrada">Con una cuenta puedes comprar y abrir tu propia tienda.</p>

			{#if errorGeneral}
				<p class="aviso" role="alert">{errorGeneral}</p>
			{/if}

			<form onsubmit={registrar} novalidate>
				<div class="campo">
					<label for="correo">Correo electronico</label>
					<input
						id="correo"
						type="email"
						autocomplete="email"
						placeholder="tu@correo.com"
						bind:value={correo}
						onblur={() => revisarDisponibilidad('correo')}
						aria-invalid={errores.correo ? 'true' : undefined}
						aria-describedby={errores.correo ? 'error-correo' : undefined}
					/>
					{#if errores.correo}
						<p class="error" id="error-correo">{errores.correo}</p>
					{/if}
				</div>

				<div class="campo">
					<label for="usuario">Usuario</label>
					<input
						id="usuario"
						type="text"
						autocomplete="username"
						placeholder="Como te van a ver los demas"
						bind:value={usuario}
						onblur={() => revisarDisponibilidad('usuario')}
						aria-invalid={errores.usuario ? 'true' : undefined}
						aria-describedby={errores.usuario ? 'error-usuario' : undefined}
					/>
					{#if errores.usuario}
						<p class="error" id="error-usuario">{errores.usuario}</p>
					{/if}
				</div>

				<div class="pareja">
					<div class="campo">
						<label for="nombre">Nombre</label>
						<input
							id="nombre"
							type="text"
							autocomplete="given-name"
							bind:value={nombre}
							aria-invalid={errores.nombre ? 'true' : undefined}
							aria-describedby={errores.nombre ? 'error-nombre' : undefined}
						/>
						{#if errores.nombre}
							<p class="error" id="error-nombre">{errores.nombre}</p>
						{/if}
					</div>

					<div class="campo">
						<label for="apellido">Apellido <span class="opcional">opcional</span></label>
						<input
							id="apellido"
							type="text"
							autocomplete="family-name"
							bind:value={apellido}
							aria-invalid={errores.apellido ? 'true' : undefined}
							aria-describedby={errores.apellido ? 'error-apellido' : undefined}
						/>
						{#if errores.apellido}
							<p class="error" id="error-apellido">{errores.apellido}</p>
						{/if}
					</div>
				</div>

				<div class="campo">
					<label for="contrasena">Contrasena</label>
					<div class="con-ojo">
						<input
							id="contrasena"
							type={verContrasena ? 'text' : 'password'}
							autocomplete="new-password"
							placeholder="Al menos 8 caracteres"
							bind:value={contrasena}
							aria-invalid={errores.contrasena ? 'true' : undefined}
							aria-describedby={errores.contrasena ? 'error-contrasena' : 'reglas-contrasena'}
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
								<svg
									viewBox="0 0 24 24"
									fill="none"
									stroke="currentColor"
									stroke-width="1.7"
									aria-hidden="true"
								>
									<path d="M3 3l18 18" stroke-linecap="round" />
									<path
										d="M10.6 5.2A9.6 9.6 0 0 1 12 5c5 0 9 4.5 10 7a15 15 0 0 1-3.3 4.2M6.4 6.5C4.2 8 2.6 10.1 2 12c1 2.5 5 7 10 7a9.7 9.7 0 0 0 4.4-1"
										stroke-linecap="round"
									/>
									<path d="M9.9 10a3 3 0 0 0 4.2 4.2" stroke-linecap="round" />
								</svg>
							{:else}
								<!-- ojo abierto: la contrasena esta oculta -->
								<svg
									viewBox="0 0 24 24"
									fill="none"
									stroke="currentColor"
									stroke-width="1.7"
									aria-hidden="true"
								>
									<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7Z" stroke-linejoin="round" />
									<circle cx="12" cy="12" r="3" />
								</svg>
							{/if}
						</button>
					</div>
					{#if errores.contrasena}
						<p class="error" id="error-contrasena">{errores.contrasena}</p>
					{:else}
						<p class="ayuda" id="reglas-contrasena">
							Minimo 8 caracteres, una mayuscula y un caracter especial.
						</p>
					{/if}
				</div>

				<div class="campo">
					<label for="fecha">Fecha de nacimiento <span class="opcional">opcional</span></label>
					<input
						id="fecha"
						type="date"
						max={maximaFechaNacimiento}
						bind:value={fechaNacimiento}
						aria-invalid={errores.fecha ? 'true' : undefined}
						aria-describedby={errores.fecha ? 'error-fecha' : undefined}
					/>
					{#if errores.fecha}
						<p class="error" id="error-fecha">{errores.fecha}</p>
					{/if}
				</div>

				<button class="entrar" type="submit" disabled={enviando}>
					{enviando ? 'Creando la cuenta' : 'Crear cuenta'}
				</button>
			</form>

			<p class="pie-form">Ya tienes cuenta? <a href="/">Inicia sesion</a></p>
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

	.centrado {
		display: flex;
		justify-content: center;
	}

	/* Fondo solido: la trama de la pagina queda detras, no debajo del texto */
	.acceso {
		width: 100%;
		max-width: 480px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		padding: 36px 34px 34px;
	}

	.acceso h1 {
		margin-bottom: 8px;
	}

	.entrada {
		margin-bottom: 26px;
		color: var(--gris);
	}

	/* Error que no pertenece a ningun campo: 503, 500 o el backend apagado */
	.aviso {
		margin-bottom: 20px;
		padding: 11px 14px;
		font-size: 0.92rem;
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	form {
		display: flex;
		flex-direction: column;
		gap: 18px;
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: 7px;
	}

	/* Nombre y apellido comparten fila; en pantalla angosta se apilan */
	.pareja {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 18px;
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

	input {
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
		font-size: 0.88rem;
		color: var(--rojo);
	}

	.ayuda {
		font-size: 0.88rem;
		color: var(--gris);
	}

	/* El boton principal usa el color de la marca, que es lo que se ve en los
	   dos temas. El texto va del color de la superficie para que contraste. */
	.entrar {
		margin-top: 4px;
		padding: 12px 20px;
		font-family: inherit;
		font-size: 1rem;
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

	.pie-form {
		margin-top: 22px;
		font-size: 0.92rem;
		color: var(--gris);
	}

	.pie-form a {
		color: var(--indigo);
		font-weight: 500;
	}

	@media (max-width: 620px) {
		main {
			padding-top: 34px;
			padding-bottom: 34px;
		}
		.acceso {
			padding: 28px 22px 26px;
		}
		.pareja {
			grid-template-columns: 1fr;
		}
	}
</style>
