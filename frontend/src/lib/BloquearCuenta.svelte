<script lang="ts" module>
	import { verificarSesion } from './sesion';

	/**
	 * Quien esta en sesion, preguntado UNA vez para toda la pantalla y no una por
	 * cada boton: un panel de fraude puede pintar decenas de cuentas.
	 */
	let propia: Promise<string | null> | null = null;
	function quienSoy(): Promise<string | null> {
		propia ??= verificarSesion()
			.then((u) => u?.id_usuario ?? null)
			.catch(() => null);
		return propia;
	}
</script>

<script lang="ts">
	import { onMount } from 'svelte';
	import { conJson, mensajeUtil, pedir } from './api';

	/**
	 * El boton rapido de "bloquear esta cuenta" que se pone junto al nombre de
	 * una cuenta sospechosa, en las alertas y en los anillos del panel de
	 * fraude. Sin el, el admin tenia que anotar el nombre, ir a Cuentas, buscarlo
	 * y cambiarle el estado a mano.
	 *
	 *   PATCH /admin/usuarios/:id   { id_estado_usuario: 3 }   suspender
	 *   PATCH /admin/usuarios/:id   { id_estado_usuario: 1 }   deshacer
	 *
	 * Bloquear es SUSPENDER (estado 3). El backend ya cierra la sesion de una
	 * cuenta suspendida y no la deja entrar, y lo puede deshacer el propio admin
	 * desde aqui o desde Cuentas. No se borra nada.
	 *
	 * Son DOS pasos a proposito, el boton y una confirmacion en la misma linea.
	 * Suspender a alguien por un clic mal dado es peor que un clic de mas.
	 */
	let {
		idUsuario,
		usuario,
		alExpirarSesion
	}: { idUsuario: string; usuario: string; alExpirarSesion?: () => void } = $props();

	const ACTIVO = 1;
	const SUSPENDIDO = 3;

	// El backend no deja a un admin editar su propia cuenta, asi que el boton
	// no se ofrece ahi. Se decide al montar y, mientras no se sabe, no se pinta.
	let soyYo = $state<boolean | null>(null);
	onMount(async () => {
		soyYo = (await quienSoy()) === idUsuario;
	});

	type Paso = 'reposo' | 'confirmar' | 'trabajando' | 'bloqueada';
	let paso = $state<Paso>('reposo');
	let error = $state('');

	async function cambiar(estado: number): Promise<boolean> {
		error = '';
		paso = 'trabajando';
		const r = await pedir(`/admin/usuarios/${idUsuario}`, conJson('PATCH', { id_estado_usuario: estado }));
		if (r.estado === 401) {
			alExpirarSesion?.();
			return false;
		}
		if (!r.ok) {
			error = mensajeUtil(r);
			return false;
		}
		return true;
	}

	async function bloquear() {
		paso = (await cambiar(SUSPENDIDO)) ? 'bloqueada' : 'reposo';
	}

	async function deshacer() {
		paso = (await cambiar(ACTIVO)) ? 'reposo' : 'bloqueada';
	}
</script>

{#if soyYo === false}
<span class="bloqueo">
	{#if paso === 'reposo'}
		<button type="button" class="bloquear" onclick={() => (paso = 'confirmar')} title="Suspender la cuenta {usuario}">
			Bloquear
		</button>
	{:else if paso === 'confirmar'}
		<span class="pregunta">Suspender a {usuario}?</span>
		<button type="button" class="si" onclick={bloquear}>Si, bloquear</button>
		<button type="button" class="no" onclick={() => (paso = 'reposo')}>No</button>
	{:else if paso === 'trabajando'}
		<span class="pregunta">Guardando</span>
	{:else}
		<span class="hecho">Cuenta suspendida</span>
		<button type="button" class="no" onclick={deshacer}>Deshacer</button>
	{/if}
	{#if error}
		<span class="error" role="alert">{error}</span>
	{/if}
</span>
{/if}

<style>
	.bloqueo {
		display: inline-flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 6px;
		margin-left: 4px;
		font-size: var(--f-sm);
	}

	button {
		padding: 2px 9px;
		font-family: inherit;
		font-size: var(--f-sm);
		background: none;
		border-radius: var(--r);
		cursor: pointer;
	}

	.bloquear,
	.si {
		color: var(--rojo, #b23b3b);
		border: 1px solid var(--rojo, #b23b3b);
	}

	.si {
		background: var(--rojo, #b23b3b);
		color: #fff;
	}

	.no {
		color: var(--tinta);
		border: 1px solid var(--linea);
	}

	.pregunta,
	.hecho {
		color: var(--tinta);
	}

	.hecho {
		font-weight: 600;
	}

	.error {
		color: var(--rojo, #b23b3b);
	}
</style>
