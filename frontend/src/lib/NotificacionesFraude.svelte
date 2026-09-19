<script lang="ts">
	import { onMount } from 'svelte';
	import { conJson, pedir } from './api';

	/**
	 * La campanita de la cabecera: lo mismo que ve la pestana "Alertas" del
	 * panel (`AlertasFraudeUsuario.svelte`, `GET`/`PATCH /perfil/alertas-fraude`),
	 * pero visible desde CUALQUIER pagina y sin tener que entrar al panel a
	 * buscarla.
	 *
	 * Se pidio porque la pestana del panel, aunque funciona, no "avisa": una
	 * alerta ahi solo se ve si alguien entra al panel y pulsa esa pestana en
	 * particular. Una campanita con numero es la forma de siempre de decir
	 * "tienes algo pendiente" sin que la persona tenga que ir a buscarlo.
	 *
	 * No sustituye a la pestana del panel -- esa sigue siendo la vista
	 * completa, paginada. Esta es el aviso rapido: las mas recientes, y un
	 * enlace a "Ver todas".
	 */

	interface AlertaPropia {
		id_alerta_fraude: string;
		tipo_alerta: string;
		clave: string;
		fecha_creacion: string;
		fecha_lectura: string | null;
	}

	interface AlertasPropiasPaginadas {
		alertas: AlertaPropia[];
		total_alertas: number;
	}

	/** Frases cortas, para una fila angosta -- no la misma redaccion larga de la pestana del panel. */
	const QUE_PASO: Record<string, string> = {
		fuerza_bruta_ip: 'Muchos intentos fallidos desde una IP',
		fuerza_bruta_cuenta: 'Varios intentos fallidos con tu cuenta',
		multi_cuenta_ip: 'Tu cuenta se probo junto con otras',
		ip_rotacion_cuenta: 'Tu cuenta se probo desde varias IPs',
		toma_cuenta: 'Entraste desde una IP nueva',
		viaje_imposible: 'Viaje imposible entre dos entradas',
		fuerza_bruta_cuenta_lenta: 'Fallos repetidos contra tu cuenta',
		multi_cuenta_ip_lenta: 'Tu cuenta se probo junto con otras',
		ip_rotacion_cuenta_lenta: 'Tu cuenta se probo desde varias IPs'
	};

	/**
	 * Suficiente para contar bien las no leidas en un uso normal, sin pedir la
	 * lista entera. Si un dia hay mas de 20 sin leer, el numero de la burbuja
	 * se queda corto -- mismo limite que ya acepta el resto del proyecto en
	 * listas chicas (ver `identificadores`, tope 20, en `PanelFraude`).
	 */
	const LIMITE = 20;
	/** Cuantas se pintan en el desplegable. El resto se ve en "Ver todas". */
	const VISIBLES = 5;

	let alertas = $state<AlertaPropia[]>([]);
	let abierto = $state(false);
	let cargando = $state(false);

	let noLeidas = $derived(alertas.filter((a) => a.fecha_lectura === null).length);

	let caja = $state<HTMLElement | null>(null);
	let botonCampana = $state<HTMLButtonElement | null>(null);

	onMount(() => {
		void cargar();
	});

	async function cargar() {
		cargando = true;
		const r = await pedir<AlertasPropiasPaginadas>(`/perfil/alertas-fraude?pagina=1&limite=${LIMITE}`);
		cargando = false;

		// Sin sesion, o el servidor no contesto: no es esta campanita la que
		// tiene que avisar de eso -- Cabecera y el resto del sitio ya se
		// encargan de la sesion. Aqui simplemente se queda sin numero.
		if (!r.ok || !r.payload) return;

		alertas = r.payload.alertas ?? [];
	}

	function alternar() {
		abierto = !abierto;
		// Se refresca al abrir: si se marco algo leido desde otra pestana del
		// navegador, o desde /panel?s=alertas, esto lo recoge.
		if (abierto) void cargar();
	}

	function cerrar(devolverFoco = false) {
		abierto = false;
		if (devolverFoco) botonCampana?.focus();
	}

	async function marcarLeida(a: AlertaPropia) {
		if (a.fecha_lectura) return;
		const r = await pedir<AlertaPropia>(
			`/perfil/alertas-fraude/${a.id_alerta_fraude}`,
			conJson('PATCH', {})
		);
		if (r.ok && r.payload) {
			alertas = alertas.map((x) => (x.id_alerta_fraude === a.id_alerta_fraude ? r.payload! : x));
		}
	}

	function alTeclear(evento: KeyboardEvent) {
		if (!abierto || evento.key !== 'Escape') return;
		cerrar(true);
	}

	/** Mismo criterio que el menu de cuenta de Cabecera: pointerdown, no click, por si lo de adentro desaparece con el mismo gesto. */
	function alPulsarFuera(evento: PointerEvent) {
		if (!abierto) return;
		const donde = evento.target;
		if (donde instanceof Node && caja?.contains(donde)) return;
		cerrar();
	}

	function fechaCorta(valor: string): string {
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '';
		return d.toLocaleString('es-GT', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
	}
</script>

<svelte:window onkeydown={alTeclear} onpointerdown={alPulsarFuera} />

<div class="envoltura" bind:this={caja}>
	<button
		type="button"
		class="campana"
		bind:this={botonCampana}
		aria-label={noLeidas > 0 ? `${noLeidas} alertas de seguridad sin leer` : 'Alertas de seguridad'}
		aria-expanded={abierto}
		aria-controls="menu-notificaciones"
		onclick={alternar}
	>
		<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true">
			<path
				d="M12 3a5 5 0 0 0-5 5v3.1c0 .5-.16 1-.46 1.4L5 15h14l-1.54-2.5a2.4 2.4 0 0 1-.46-1.4V8a5 5 0 0 0-5-5Z"
				stroke-linecap="round"
				stroke-linejoin="round"
			/>
			<path d="M9.5 18a2.5 2.5 0 0 0 5 0" stroke-linecap="round" />
		</svg>
		{#if noLeidas > 0}
			<span class="burbuja">{noLeidas}</span>
		{/if}
	</button>

	<div id="menu-notificaciones" class="menu" class:abierto>
		<div class="titulo">Alertas de seguridad</div>

		{#if cargando && alertas.length === 0}
			<p class="vacio">Buscando...</p>
		{:else if alertas.length === 0}
			<p class="vacio">No hay ninguna alerta en tu cuenta.</p>
		{:else}
			<ul class="lista">
				{#each alertas.slice(0, VISIBLES) as a (a.id_alerta_fraude)}
					<li class="fila" class:no-leida={!a.fecha_lectura}>
						<div class="texto">
							<span class="que-paso">{QUE_PASO[a.tipo_alerta] ?? a.tipo_alerta}</span>
							<span class="fecha">{fechaCorta(a.fecha_creacion)}</span>
						</div>
						{#if !a.fecha_lectura}
							<button type="button" class="marcar" onclick={() => marcarLeida(a)}>
								Marcar leida
							</button>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}

		<a class="ver-todas" href="/panel?s=alertas" onclick={() => cerrar()}>Ver todas</a>
	</div>
</div>

<style>
	.envoltura {
		position: relative;
	}

	/* Misma caja que .hamburguesa de Cabecera: cuadrada, sin relleno del boton
	   generico (que lo deja como un punto). */
	.campana {
		position: relative;
		width: 38px;
		height: 38px;
		padding: 0;
		display: grid;
		place-items: center;
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		color: var(--tinta);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.campana:hover,
	.campana[aria-expanded='true'] {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.campana svg {
		width: 19px;
		height: 19px;
	}

	/* La misma burbuja del carrito (.burbuja en Cabecera), copiada: el CSS de
	   Svelte tiene ambito, asi que aqui hace falta su propia copia. */
	.burbuja {
		position: absolute;
		top: -6px;
		right: -6px;
		min-width: 18px;
		height: 18px;
		padding: 0 4px;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		font-size: var(--f-xs);
		line-height: 1;
		color: var(--blanco);
		background: var(--rojo);
		border-radius: 999px;
	}

	.menu {
		display: none;
		position: absolute;
		top: calc(100% + 10px);
		right: 0;
		width: 20rem;
		max-width: 84vw;
		padding: 0.5rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		box-shadow: var(--sombra);
		z-index: 95;
	}

	.menu.abierto {
		display: block;
	}

	.titulo {
		padding: 0.4rem 0.5rem 0.6rem;
		font-size: var(--f-ms);
		font-weight: 500;
		color: var(--tinta);
		border-bottom: 1px solid var(--linea);
	}

	.vacio {
		padding: 0.9rem 0.5rem;
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.lista {
		list-style: none;
		display: flex;
		flex-direction: column;
		max-height: 60vh;
		overflow-y: auto;
	}

	.fila {
		display: flex;
		align-items: center;
		gap: var(--e2);
		padding: 0.55rem 0.5rem;
		border-bottom: 1px solid var(--linea);
	}

	.fila:last-child {
		border-bottom: 0;
	}

	/* Un puntito indigo, no un fondo entero: la fila no leida se distingue sin
	   competir con el texto. */
	.fila.no-leida {
		position: relative;
	}

	.fila.no-leida::before {
		content: '';
		flex-shrink: 0;
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--indigo);
	}

	.fila:not(.no-leida) {
		padding-left: calc(0.5rem + 7px + var(--e2));
	}

	.texto {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.que-paso {
		font-size: var(--f-sm);
		color: var(--tinta);
		overflow-wrap: anywhere;
	}

	.fecha {
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.marcar {
		flex-shrink: 0;
		padding: 3px 8px;
		font-family: inherit;
		font-size: var(--f-xs);
		color: var(--indigo);
		background: none;
		border: 1px solid var(--indigo);
		border-radius: var(--r);
		cursor: pointer;
	}

	.ver-todas {
		display: block;
		margin-top: 0.4rem;
		padding: 0.5rem;
		text-align: center;
		text-decoration: none;
		font-size: var(--f-ms);
		color: var(--indigo);
		border-top: 1px solid var(--linea);
	}

	.ver-todas:hover {
		background: var(--indigo-cl);
		border-radius: var(--r);
	}

	@media (max-width: 720px) {
		.menu {
			width: 18rem;
		}
	}
</style>
