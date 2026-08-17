<script lang="ts">
	import { goto } from '$app/navigation';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import { guardarSesion } from '$lib/sesion';

	let correo = $state('');
	let contrasena = $state('');
	let verContrasena = $state(false);
	let entrando = $state(false);
	let errores = $state<{ correo?: string; contrasena?: string }>({});

	function validar() {
		const nuevos: typeof errores = {};

		if (!correo.trim()) {
			nuevos.correo = 'Escribe tu correo.';
		} else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(correo.trim())) {
			nuevos.correo = 'Ese correo no tiene un formato valido.';
		}

		if (!contrasena) {
			nuevos.contrasena = 'Escribe tu contrasena.';
		} else if (contrasena.length < 8) {
			nuevos.contrasena = 'La contrasena necesita al menos 8 caracteres.';
		}

		errores = nuevos;
		return Object.keys(nuevos).length === 0;
	}

	async function entrar(evento: SubmitEvent) {
		evento.preventDefault();
		if (!validar()) return;

		entrando = true;
		// TODO: aqui va la llamada al backend cuando exista el endpoint de login.
		await new Promise((r) => setTimeout(r, 400));
		guardarSesion(correo.trim());
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

			<form onsubmit={entrar} novalidate>
				<div class="campo">
					<label for="correo">Correo electronico</label>
					<input
						id="correo"
						type="email"
						autocomplete="email"
						placeholder="tu@correo.com"
						bind:value={correo}
						aria-invalid={errores.correo ? 'true' : undefined}
						aria-describedby={errores.correo ? 'error-correo' : undefined}
					/>
					{#if errores.correo}
						<p class="error" id="error-correo">{errores.correo}</p>
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
		gap: 18px;
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
