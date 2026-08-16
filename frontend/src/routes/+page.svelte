<script lang="ts">
	import { goto } from '$app/navigation';
	import Telar from '$lib/Telar.svelte';
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
		await new Promise((r) => setTimeout(r, 450));
		guardarSesion(correo.trim());
		await goto('/panel');
	}
</script>

<svelte:head>
	<title>Mesh · Inicia sesion</title>
</svelte:head>

<Telar />

<!-- Orillo: el borde tejido de la tela, donde va la marca del taller -->
<div class="orillo" aria-hidden="true">
	<span>MESH — MERCADO INDEPENDIENTE — GT</span>
</div>

<main>
	<a class="marca" href="/">
		Mesh<span class="punto"></span>
	</a>

	<section class="tarjeta">
		<p class="antetitulo">Tu cuenta</p>
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
				<div class="fila-etiqueta">
					<label for="contrasena">Contrasena</label>
					<button type="button" class="ojo" onclick={() => (verContrasena = !verContrasena)}>
						{verContrasena ? 'Ocultar' : 'Mostrar'}
					</button>
				</div>
				<input
					id="contrasena"
					type={verContrasena ? 'text' : 'password'}
					autocomplete="current-password"
					placeholder="Al menos 8 caracteres"
					bind:value={contrasena}
					aria-invalid={errores.contrasena ? 'true' : undefined}
					aria-describedby={errores.contrasena ? 'error-contrasena' : undefined}
				/>
				{#if errores.contrasena}
					<p class="error" id="error-contrasena">{errores.contrasena}</p>
				{/if}
			</div>

			<button class="entrar" type="submit" disabled={entrando}>
				{entrando ? 'Entrando' : 'Entrar'}
			</button>

			<a class="olvide" href="/">Olvide mi contrasena</a>
		</form>

		<p class="pie">
			Primera vez en Mesh?
			<a href="/">Crea tu cuenta</a>
		</p>
	</section>
</main>

<style>
	.orillo {
		position: fixed;
		left: 0;
		top: 0;
		bottom: 0;
		width: 42px;
		display: flex;
		align-items: center;
		justify-content: center;
		border-right: 1px solid var(--telar);
		background: linear-gradient(180deg, transparent, rgba(43, 53, 99, 0.16), transparent);
		z-index: 2;
	}

	.orillo span {
		writing-mode: vertical-rl;
		transform: rotate(180deg);
		font-family: var(--letra-dato);
		font-size: 10px;
		letter-spacing: 0.28em;
		color: #5a6796;
		white-space: nowrap;
	}

	main {
		position: relative;
		z-index: 1;
		min-height: 100vh;
		padding: 32px 24px 32px 74px;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 34px;
	}

	.marca {
		font-family: var(--letra-titulo);
		font-weight: 700;
		font-size: 21px;
		letter-spacing: -0.03em;
		color: var(--crudo);
		text-decoration: none;
		display: inline-flex;
		align-items: baseline;
		gap: 4px;
		animation: subir 0.7s 0.85s both cubic-bezier(0.2, 0.7, 0.3, 1);
	}

	/* El punto dorado: el mismo hilo del telar, hecho firma */
	.punto {
		width: 5px;
		height: 5px;
		border-radius: 50%;
		background: var(--oro);
	}

	.tarjeta {
		position: relative;
		width: 100%;
		max-width: 396px;
		padding: 38px 34px 30px;
		background: var(--tinta-alta);
		border: 1px solid var(--telar);
		/* Textura de tafetan: la misma trama de la pagina, dentro de la tarjeta */
		background-image:
			repeating-linear-gradient(90deg, rgba(43, 53, 99, 0.24) 0 1px, transparent 1px 7px),
			repeating-linear-gradient(0deg, rgba(43, 53, 99, 0.18) 0 1px, transparent 1px 7px);
		box-shadow:
			0 1px 0 rgba(200, 212, 240, 0.05) inset,
			0 30px 70px -30px rgba(0, 0, 0, 0.85);
		animation: subir 0.8s 0.95s both cubic-bezier(0.2, 0.7, 0.3, 1);
	}

	/* Un solo borde dorado, arriba: el remate del tejido */
	.tarjeta::before {
		content: '';
		position: absolute;
		top: -1px;
		left: 34px;
		width: 54px;
		height: 2px;
		background: var(--oro);
	}

	.antetitulo {
		margin: 0 0 10px;
		font-family: var(--letra-dato);
		font-size: 10px;
		letter-spacing: 0.24em;
		text-transform: uppercase;
		color: #6f7cad;
	}

	h1 {
		margin: 0 0 8px;
		font-family: var(--letra-titulo);
		font-weight: 600;
		font-size: clamp(29px, 6vw, 35px);
		line-height: 1.06;
		letter-spacing: -0.035em;
		color: var(--crudo);
	}

	.entrada {
		margin: 0 0 26px;
		color: #97a3ca;
		font-size: 14px;
	}

	form {
		display: flex;
		flex-direction: column;
		gap: 17px;
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: 7px;
	}

	.fila-etiqueta {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 12px;
	}

	label {
		font-family: var(--letra-dato);
		font-size: 10px;
		letter-spacing: 0.16em;
		text-transform: uppercase;
		color: #8e9ac4;
	}

	input {
		width: 100%;
		padding: 12px 13px;
		font-family: var(--letra);
		font-size: 15px;
		color: var(--crudo);
		background: var(--tinta);
		border: 1px solid var(--telar);
		border-radius: 3px;
		transition:
			border-color 0.18s ease,
			background 0.18s ease;
	}

	input::placeholder {
		color: #566288;
	}

	input:hover {
		border-color: var(--hilo);
	}

	input:focus {
		outline: none;
		border-color: var(--oro);
		background: #0a0f20;
	}

	input[aria-invalid='true'] {
		border-color: #b4574d;
	}

	.ojo {
		background: none;
		border: none;
		padding: 0;
		cursor: pointer;
		font-family: var(--letra-dato);
		font-size: 10px;
		letter-spacing: 0.14em;
		text-transform: uppercase;
		color: #6f7cad;
		transition: color 0.16s ease;
	}

	.ojo:hover {
		color: var(--oro);
	}

	.error {
		margin: 0;
		font-size: 12.5px;
		color: #e08b81;
	}

	.entrar {
		margin-top: 7px;
		padding: 13px 18px;
		font-family: var(--letra);
		font-size: 14.5px;
		font-weight: 600;
		letter-spacing: 0.01em;
		color: var(--tinta);
		background: var(--oro);
		border: none;
		border-radius: 3px;
		cursor: pointer;
		transition:
			transform 0.16s cubic-bezier(0.2, 0.7, 0.3, 1),
			background 0.16s ease;
	}

	.entrar:hover:not(:disabled) {
		background: #f0bc57;
		transform: translateY(-1px);
	}

	.entrar:active:not(:disabled) {
		transform: translateY(0);
	}

	.entrar:disabled {
		opacity: 0.62;
		cursor: progress;
	}

	.olvide {
		align-self: center;
		font-size: 13px;
		color: #8e9ac4;
		text-decoration: none;
		border-bottom: 1px solid transparent;
		transition: color 0.16s ease;
	}

	.olvide:hover {
		color: var(--crudo);
		border-bottom-color: var(--hilo);
	}

	.pie {
		margin: 26px 0 0;
		padding-top: 19px;
		border-top: 1px solid var(--telar);
		text-align: center;
		font-size: 13.5px;
		color: #7f8bb5;
	}

	.pie a {
		color: var(--crudo);
		text-decoration: none;
		border-bottom: 1px solid var(--oro);
		padding-bottom: 1px;
	}

	.pie a:hover {
		color: var(--oro);
	}

	@keyframes subir {
		from {
			opacity: 0;
			transform: translateY(14px);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	@media (max-width: 560px) {
		.orillo {
			display: none;
		}
		main {
			padding: 26px 18px;
		}
		.tarjeta {
			padding: 30px 22px 24px;
		}
		.tarjeta::before {
			left: 22px;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.marca,
		.tarjeta {
			animation: none;
		}
		.entrar:hover:not(:disabled) {
			transform: none;
		}
	}
</style>
