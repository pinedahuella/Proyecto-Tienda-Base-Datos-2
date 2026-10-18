<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil } from './api';
	import {
		avisos as contador,
		borrarSeguimiento,
		listarAvisos,
		listarSeguimientos,
		marcarAviso,
		type AvisoSeguimiento,
		type Seguimiento
	} from './seguimientos.svelte';

	/**
	 * "Avisos": lo que la cuenta pidio seguir y lo que ya se cumplio.
	 *
	 * Arriba los avisos (la oferta que cumplio cada seguimiento, con su enlace
	 * para ir a comprarla) y abajo los seguimientos que siguen esperando, para
	 * poder quitarlos. Los cumplidos no se listan aparte: cada uno ya esta
	 * arriba como su aviso.
	 *
	 * Se piden en la ficha ("Avisame si baja") y en /buscar ("Avisame cuando
	 * llegue"). Ver seguimientos.svelte.ts.
	 */
	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	let lista = $state<AvisoSeguimiento[]>([]);
	let activos = $state<Seguimiento[]>([]);
	let cargando = $state(true);
	let error = $state('');
	let ocupado = $state<string | null>(null);

	onMount(() => {
		void cargar();
	});

	async function cargar() {
		cargando = true;
		error = '';
		const [rAvisos, rActivos] = await Promise.all([listarAvisos(), listarSeguimientos('activos')]);
		cargando = false;

		if (rAvisos.estado === 401 || rActivos.estado === 401) {
			alExpirarSesion();
			return;
		}
		if (!rAvisos.ok || !rAvisos.payload) {
			error = mensajeUtil(rAvisos);
			return;
		}
		if (!rActivos.ok || !Array.isArray(rActivos.payload)) {
			error = mensajeUtil(rActivos);
			return;
		}
		lista = rAvisos.payload.avisos ?? [];
		activos = rActivos.payload;
		contador.fijar(rAvisos.payload.total_no_leidos);
	}

	async function alternarLeido(a: AvisoSeguimiento) {
		ocupado = a.id_aviso;
		const r = await marcarAviso(a.id_aviso, !a.leido);
		ocupado = null;
		if (r.estado === 401) return alExpirarSesion();
		if (!r.ok) {
			error = mensajeUtil(r);
			return;
		}
		lista = lista.map((x) => (x.id_aviso === a.id_aviso ? { ...x, leido: !a.leido } : x));
		contador.fijar(lista.filter((x) => !x.leido).length);
	}

	async function quitar(s: Seguimiento) {
		ocupado = s.id_seguimiento;
		const r = await borrarSeguimiento(s.id_seguimiento);
		ocupado = null;
		if (r.estado === 401) return alExpirarSesion();
		if (!r.ok) {
			error = mensajeUtil(r);
			return;
		}
		activos = activos.filter((x) => x.id_seguimiento !== s.id_seguimiento);
	}

	function quetzales(valor: string | number | null): string {
		const n = Number(valor ?? 0);
		return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	}

	function fecha(valor: string): string {
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '';
		return d.toLocaleString('es-GT', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
	}

	/** Lo que se habia pedido, en una linea. */
	function queSePidio(s: {
		tipo: string;
		texto: string | null;
		precio_maximo: string | null;
		precio_referencia: string | null;
		solo_tienda: boolean;
	}): string {
		if (s.tipo === 'busqueda') {
			return `"${s.texto ?? ''}"` + (s.precio_maximo ? ` hasta ${quetzales(s.precio_maximo)}` : '');
		}
		return `Que baje de ${quetzales(s.precio_referencia)}` + (s.solo_tienda ? ' en la tienda' : '');
	}

	/**
	 * La oferta que lo cumplio. El precio del aviso es el de ese momento, y la
	 * oferta viene como esta ahora: si cambio, se dicen los dos.
	 */
	function queLlego(a: AvisoSeguimiento): string {
		const hoy = Number(a.oferta.precio_final) !== Number(a.precio_final_aviso)
			? `, hoy a ${quetzales(a.oferta.precio_final)}`
			: '';
		const agotada = a.oferta.stock === 0 || a.oferta.estado !== 'activa' ? '. Ya no esta disponible' : '';
		return `Llego a ${quetzales(a.precio_final_aviso)} con ${a.oferta.vendedor_usuario}${hoy}${agotada}`;
	}
</script>

<section class="avisos">
	<div class="titulo">
		<h2>Avisos</h2>
		<button type="button" class="volver" onclick={cargar} disabled={cargando}>Volver a mirar</button>
	</div>

	<p class="intro">
		Te avisamos una vez cuando llega lo que buscaste o cuando baja un precio que sigues.
	</p>

	{#if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if cargando && lista.length === 0 && activos.length === 0}
		<p class="gris">Cargando tus avisos...</p>
	{:else}
		{#if lista.length === 0}
			<p class="gris">Todavia no tienes avisos.</p>
		{:else}
			<ul class="lista">
				{#each lista as a (a.id_aviso)}
					<li class="aviso" class:no-leido={!a.leido}>
						<div class="cabeza">
							<a class="nombre" href="/producto/{a.oferta.id_producto}">
								{a.oferta.nombre_producto}
							</a>
							<span class="gris">{a.oferta.nombre_variante}</span>
							{#if !a.leido}
								<span class="punto" aria-label="Sin leer"></span>
							{/if}
						</div>
						<p class="nota">{queSePidio(a.seguimiento)}. {queLlego(a)}</p>
						<div class="pie">
							<span class="gris">{fecha(a.fecha_aviso)}</span>
							<button
								type="button"
								class="marcar"
								disabled={ocupado === a.id_aviso}
								onclick={() => alternarLeido(a)}
							>
								{a.leido ? 'Marcar sin leer' : 'Marcar como leido'}
							</button>
						</div>
					</li>
				{/each}
			</ul>
		{/if}

		<h3>Lo que sigues</h3>
		{#if activos.length === 0}
			<p class="gris">
				No sigues nada. Pide un aviso desde la ficha de un producto o desde una busqueda sin
				resultados.
			</p>
		{:else}
			<ul class="lista">
				{#each activos as s (s.id_seguimiento)}
					<li class="aviso">
						<div class="cabeza">
							{#if s.tipo === 'baja_precio' && s.id_producto}
								<a class="nombre" href="/producto/{s.id_producto}">{s.nombre_producto}</a>
								<span class="gris">{s.nombre_variante}</span>
							{:else}
								<span class="nombre">Busqueda</span>
							{/if}
						</div>
						<p class="nota">{queSePidio(s)}</p>
						<div class="pie">
							<span class="gris">Desde {fecha(s.fecha_creacion)}</span>
							<button
								type="button"
								class="marcar"
								disabled={ocupado === s.id_seguimiento}
								onclick={() => quitar(s)}
							>
								Dejar de seguir
							</button>
						</div>
					</li>
				{/each}
			</ul>
		{/if}
	{/if}
</section>

<style>
	.avisos {
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
		flex-wrap: wrap;
		margin-bottom: 8px;
	}

	.titulo h2 {
		font-size: var(--f-xl);
	}

	.volver {
		margin-left: auto;
	}

	h3 {
		margin-top: var(--e5);
		margin-bottom: var(--e2);
		font-size: var(--f-lg);
	}

	.intro,
	.gris {
		color: var(--gris);
	}

	.lista {
		display: grid;
		gap: var(--e3);
		margin-top: var(--e3);
		padding: 0;
		list-style: none;
	}

	.aviso {
		padding: 14px 16px;
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.aviso.no-leido {
		border-color: var(--indigo);
	}

	.cabeza {
		display: flex;
		align-items: baseline;
		flex-wrap: wrap;
		gap: var(--e2);
	}

	.nombre {
		font-weight: 500;
		color: var(--tinta);
	}

	.punto {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--indigo);
	}

	.nota {
		margin-top: var(--e2);
		font-size: var(--f-ms);
		color: var(--texto);
	}

	.pie {
		display: flex;
		align-items: center;
		justify-content: space-between;
		flex-wrap: wrap;
		gap: var(--e3);
		margin-top: var(--e3);
	}

	.marcar {
		padding: 5px 12px;
		font-family: inherit;
		font-size: var(--f-sm);
		color: var(--indigo);
		background: none;
		border: 1px solid var(--indigo);
		border-radius: var(--r);
		cursor: pointer;
	}

	.marcar:disabled {
		opacity: 0.5;
		cursor: default;
	}

	.fallo {
		color: var(--rojo);
	}

	@media (max-width: 620px) {
		.avisos {
			padding: 22px 20px;
		}
	}
</style>
