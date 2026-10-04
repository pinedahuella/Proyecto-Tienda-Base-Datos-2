<script lang="ts">
	import { onMount } from 'svelte';
	import { pedir } from './api';

	/**
	 * La campana del ADMIN. Es otra distinta de `NotificacionesFraude.svelte`,
	 * que es la de todas las cuentas (las alertas de login sobre la propia
	 * cuenta): esta solo la pinta `Cabecera` cuando la sesion es de un admin, y
	 * avisa de lo que hay que revisar en el panel de fraude.
	 *
	 * Hoy son los anillos de resenas pendientes
	 * (`GET /admin/fraude/alertas-resenas?estado=pendiente`). No tiene "marcar
	 * leida" propio: un anillo deja de contar cuando el admin lo marca revisado
	 * o descartado en el panel.
	 */

	interface AnilloPendiente {
		id_anillo_fraude: string;
		/** Ver `TipoAnillo` en PanelFraude.svelte: 1 a 3 de la 019, 4 a 10 de la 023. */
		tipo:
			| 'mutuo'
			| 'ciclo'
			| 'reiterado'
			| 'cadena_abierta'
			| 'satelites'
			| 'persistente'
			| 'anillo_en_el_tiempo'
			| 'favor_devuelto'
			| 'coordinados'
			| 'reputacion_expres'
			| 'resenas_repetidas'
			| 'anillo_de_texto'
			| 'notas_incoherentes_cuenta'
			| 'notas_incoherentes_producto'
			| 'notas_incoherentes_vendedor'
			| 'resenas_parecidas_vendedor'
			| 'resenas_parecidas_producto'
			| 'resena_positiva_cancelada'
			| 'resenas_negativas_canceladas_vendedor';
		cuentas: { usuario: string }[];
		fecha_creacion: string;
	}

	interface AnillosPendientesPaginados {
		anillos: AnilloPendiente[];
		total_anillos: number;
	}

	const QUE_PASO: Record<AnilloPendiente['tipo'], string> = {
		mutuo: 'Anillo de resenas, se califican entre si',
		ciclo: 'Anillo de resenas en ciclo',
		reiterado: 'Anillo de resenas sobre los mismos productos',
		cadena_abierta: 'Cadena de calificaciones entre cuentas',
		satelites: 'Cuentas que solo califican a un vendedor',
		persistente: 'Una cuenta califica siempre al mismo vendedor',
		anillo_en_el_tiempo: 'Anillo de resenas que vuelve con el tiempo',
		favor_devuelto: 'Dos cuentas se devuelven la nota en horas',
		coordinados: 'Dos cuentas califican juntas lo mismo',
		reputacion_expres: 'Vendedor nuevo con resenas de cuentas nuevas',
		resenas_repetidas: 'Una cuenta escribe la misma resena una y otra vez',
		anillo_de_texto: 'Varias cuentas escriben casi la misma resena al mismo vendedor',
		notas_incoherentes_cuenta: 'Una cuenta pone estrellas que contradicen lo que escribe',
		notas_incoherentes_producto: 'Un producto con muchas notas que contradicen su texto',
		notas_incoherentes_vendedor: 'Un vendedor con muchas notas que contradicen su texto',
		resenas_parecidas_vendedor: 'Un vendedor con muchas resenas copiadas de otras cuentas',
		resenas_parecidas_producto: 'Un producto con muchas resenas copiadas de otras cuentas',
		resena_positiva_cancelada: 'Una cuenta reseno con buena nota y despues cancelo la compra',
		resenas_negativas_canceladas_vendedor: 'Un vendedor con muchas resenas malas de compras que se cancelaron'
	};

	const LIMITE = 20;
	const VISIBLES = 5;

	let anillos = $state<AnilloPendiente[]>([]);
	let total = $state(0);
	let abierto = $state(false);
	let cargando = $state(false);

	let caja = $state<HTMLElement | null>(null);
	let botonCampana = $state<HTMLButtonElement | null>(null);

	onMount(() => {
		void cargar();
	});

	async function cargar() {
		cargando = true;
		const r = await pedir<AnillosPendientesPaginados>(
			`/admin/fraude/alertas-resenas?estado=pendiente&pagina=1&limite=${LIMITE}`
		);
		cargando = false;

		// Sin sesion o sin permiso: esta campana no avisa de eso, se queda sin numero.
		if (!r.ok || !r.payload) return;

		anillos = r.payload.anillos ?? [];
		total = r.payload.total_anillos ?? anillos.length;
	}

	function alternar() {
		abierto = !abierto;
		if (abierto) void cargar();
	}

	function cerrar(devolverFoco = false) {
		abierto = false;
		if (devolverFoco) botonCampana?.focus();
	}

	function alTeclear(evento: KeyboardEvent) {
		if (!abierto || evento.key !== 'Escape') return;
		cerrar(true);
	}

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
		aria-label={total > 0 ? `${total} avisos de admin por revisar` : 'Avisos de admin'}
		aria-expanded={abierto}
		aria-controls="menu-avisos-admin"
		onclick={alternar}
	>
		<!-- Un escudo con una marca, para no confundirla con la campana general. -->
		<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true">
			<path
				d="M12 3 5 6v5.5c0 4.2 2.9 7.6 7 9 4.1-1.4 7-4.8 7-9V6l-7-3Z"
				stroke-linecap="round"
				stroke-linejoin="round"
			/>
			<path d="M12 8.5v4" stroke-linecap="round" />
			<circle cx="12" cy="15.4" r="0.6" fill="currentColor" />
		</svg>
		{#if total > 0}
			<span class="burbuja">{total}</span>
		{/if}
	</button>

	<div id="menu-avisos-admin" class="menu" class:abierto>
		<div class="titulo">Avisos de admin</div>

		{#if cargando && anillos.length === 0}
			<p class="vacio">Buscando...</p>
		{:else if anillos.length === 0}
			<p class="vacio">No hay nada pendiente por revisar.</p>
		{:else}
			<ul class="lista">
				{#each anillos.slice(0, VISIBLES) as n (n.id_anillo_fraude)}
					<li class="fila">
						<div class="texto">
							<span class="que-paso">{QUE_PASO[n.tipo] ?? n.tipo}</span>
							<span class="fecha">
								{n.cuentas.map((c) => c.usuario).join(', ')} · {fechaCorta(n.fecha_creacion)}
							</span>
						</div>
						<a class="revisar" href="/panel?s=fraude&t=resenas" onclick={() => cerrar()}>Revisar</a>
					</li>
				{/each}
			</ul>
		{/if}

		<a class="ver-todas" href="/panel?s=fraude&t=resenas" onclick={() => cerrar()}>Ir al panel de fraude</a>
	</div>
</div>

<style>
	.envoltura {
		position: relative;
	}

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

	.fila::before {
		content: '';
		flex-shrink: 0;
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--indigo);
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
		overflow-wrap: anywhere;
	}

	.revisar {
		flex-shrink: 0;
		padding: 3px 8px;
		font-size: var(--f-xs);
		text-decoration: none;
		color: var(--indigo);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
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
