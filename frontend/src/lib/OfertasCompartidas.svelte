<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil } from './api';
	import {
		editarCompartida,
		fechaCorta,
		listarCompartidas,
		ponerDescuentoCompartida,
		quetzales,
		quitarDescuentoCompartida,
		textoPermiso,
		type OfertaCompartida
	} from './compartidas';

	/**
	 * "Compartidas": las ofertas de OTRAS cuentas que el ACL de la aplicacion
	 * (migracion 049) me deja ver o cambiar. Las mias siguen en "Ofertas".
	 *
	 * Cada oferta ensena de quien es y que puedo hacer. Los botones salen solo
	 * para lo que el dueno me dio, pero quien decide es el backend: si el
	 * permiso se quito o vencio mientras la pagina estaba abierta, contesta 404
	 * (ya no queda ninguno) o 403 (queda otro, pero no ese), y aqui se dice y se
	 * recarga la lista.
	 */
	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	let ofertas = $state<OfertaCompartida[]>([]);
	let cargando = $state(true);
	let error = $state('');

	/** La oferta con un formulario abierto, y cual. */
	let abierta = $state<string | null>(null);
	let modo = $state<'editar' | 'descuento' | null>(null);
	let precio = $state('');
	let ajuste = $state('');
	let porcentaje = $state('');
	let ocupado = $state(false);
	let errorFila = $state('');
	let hecho = $state('');

	onMount(() => {
		void cargar();
	});

	async function cargar() {
		cargando = true;
		error = '';
		const r = await listarCompartidas();
		cargando = false;
		if (r.estado === 401) return alExpirarSesion();
		if (!r.ok || !Array.isArray(r.payload)) {
			error = mensajeUtil(r);
			return;
		}
		ofertas = r.payload;
	}

	function puede(o: OfertaCompartida, p: string): boolean {
		return o.permisos.some((x) => x.permiso === p);
	}

	function abrir(o: OfertaCompartida, m: 'editar' | 'descuento') {
		if (abierta === o.id_oferta && modo === m) {
			cerrar();
			return;
		}
		abierta = o.id_oferta;
		modo = m;
		precio = '';
		ajuste = '';
		porcentaje = '';
		errorFila = '';
		hecho = '';
	}

	function cerrar() {
		abierta = null;
		modo = null;
		errorFila = '';
	}

	/** Lo comun de las tres acciones: el 401, el 404 o 403 de un permiso que ya no esta y el resto. */
	async function despues(r: { ok: boolean; estado: number; mensaje?: string }, exito: string) {
		ocupado = false;
		if (r.estado === 401) return alExpirarSesion();
		if (r.estado === 404 || r.estado === 403) {
			// Primero la lista y despues el aviso: cargar() limpia el error al empezar.
			cerrar();
			await cargar();
			error = 'Ya no tienes permiso para eso: el dueno lo quito o se vencio.';
			return;
		}
		if (!r.ok) {
			errorFila = mensajeUtil(r);
			return;
		}
		hecho = exito;
		cerrar();
		await cargar();
	}

	async function guardar(o: OfertaCompartida) {
		const cambios: { precio?: string; ajuste_stock?: number } = {};
		const p = String(precio ?? '').trim();
		const a = String(ajuste ?? '').trim();
		if (p !== '') cambios.precio = p;
		if (a !== '') {
			const n = Number(a);
			if (!Number.isInteger(n) || n === 0) {
				errorFila = 'El ajuste es un numero entero distinto de cero, como 5 o -2.';
				return;
			}
			cambios.ajuste_stock = n;
		}
		if (cambios.precio == null && cambios.ajuste_stock == null) {
			errorFila = 'Escribe un precio nuevo o cuantas unidades sumar o restar.';
			return;
		}
		ocupado = true;
		errorFila = '';
		await despues(await editarCompartida(o.id_oferta, cambios), 'Oferta actualizada a nombre de ' + o.dueno.usuario + '.');
	}

	async function ponerDescuento(o: OfertaCompartida) {
		const n = Number(String(porcentaje ?? '').trim());
		if (!Number.isFinite(n) || n < 1 || n > 90) {
			errorFila = 'El descuento va del 1 al 90.';
			return;
		}
		ocupado = true;
		errorFila = '';
		await despues(await ponerDescuentoCompartida(o.id_oferta, n), `Descuento de ${n}% puesto.`);
	}

	async function quitarDescuento(o: OfertaCompartida) {
		ocupado = true;
		errorFila = '';
		await despues(await quitarDescuentoCompartida(o.id_oferta), 'Descuento quitado.');
	}

	function tieneDescuento(o: OfertaCompartida): boolean {
		return o.porcentaje_descuento != null && Number(o.porcentaje_descuento) > 0;
	}
</script>

<section class="compartidas">
	<div class="titulo">
		<div>
			<h2>Compartidas contigo</h2>
			<p class="menor">Lo que cambies queda a nombre de su dueno, con tu nombre en su registro.</p>
		</div>
		<button type="button" class="enlace" onclick={cargar} disabled={cargando}>Actualizar</button>
	</div>

	{#if error}
		<p class="malo" role="alert">{error}</p>
	{/if}
	{#if hecho}
		<p class="hecho">{hecho}</p>
	{/if}

	{#if cargando && ofertas.length === 0}
		<p class="quieto">Buscando...</p>
	{:else if ofertas.length === 0}
		<p class="quieto">Nadie te ha compartido una oferta todavia.</p>
	{:else}
		<ul class="lista">
			{#each ofertas as o (o.id_oferta)}
				<li class="fila">
					<div class="cosa">
						{#if o.imagen}
							<img src={o.imagen} alt="" loading="lazy" />
						{/if}
						<div class="nombre">
							<strong>{o.producto ?? 'Producto ' + o.id_producto}</strong>
							<span class="menor">{o.variante ?? ''}</span>
							<span class="menor">De <strong>{o.dueno.usuario}</strong> · {o.estado}</span>
						</div>
					</div>

					<div class="numeros">
						<strong class="precio">{quetzales(o.precio_final)}</strong>
						{#if tieneDescuento(o)}
							<span class="menor"><s>{quetzales(o.precio)}</s> -{Number(o.porcentaje_descuento)}%</span>
						{/if}
						<span class="menor">{o.stock} unidades</span>
					</div>

					<div class="puedes">
						{#each o.permisos as p (p.permiso)}
							<span class="chip" title={p.fecha_vencimiento ? 'Hasta ' + fechaCorta(p.fecha_vencimiento) : 'Sin vencer'}>
								{textoPermiso(p.permiso)}
							</span>
						{/each}
					</div>

					<div class="acciones">
						{#if puede(o, 'editar')}
							<button type="button" class:principal={!(abierta === o.id_oferta && modo === 'editar')} onclick={() => abrir(o, 'editar')}>
								{abierta === o.id_oferta && modo === 'editar' ? 'Cerrar' : 'Editar'}
							</button>
						{/if}
						{#if puede(o, 'descuento')}
							<button type="button" onclick={() => abrir(o, 'descuento')}>
								{abierta === o.id_oferta && modo === 'descuento' ? 'Cerrar' : 'Descuento'}
							</button>
						{/if}
						{#if !puede(o, 'editar') && !puede(o, 'descuento')}
							<span class="menor">Solo puedes verla</span>
						{/if}
					</div>

					{#if abierta === o.id_oferta}
						<div class="panel">
							{#if modo === 'editar'}
								<div class="campos">
									<label>
										Precio nuevo
										<input type="text" inputmode="decimal" bind:value={precio} placeholder={o.precio} />
									</label>
									<label>
										Sumar o restar unidades
										<input type="text" inputmode="numeric" bind:value={ajuste} placeholder="5 o -2" />
									</label>
								</div>
								<p class="menor nota">El estado de la oferta solo lo cambia {o.dueno.usuario}.</p>
								{#if errorFila}<p class="malo" role="alert">{errorFila}</p>{/if}
								<div class="acciones">
									<button type="button" class="principal" onclick={() => guardar(o)} disabled={ocupado}>{ocupado ? 'Guardando...' : 'Guardar'}</button>
									<button type="button" onclick={cerrar} disabled={ocupado}>Cancelar</button>
								</div>
							{:else if modo === 'descuento'}
								{#if tieneDescuento(o)}
									<p class="nota">Tiene {Number(o.porcentaje_descuento)}% de descuento.</p>
									{#if errorFila}<p class="malo" role="alert">{errorFila}</p>{/if}
									<div class="acciones">
										<button type="button" class="principal" onclick={() => quitarDescuento(o)} disabled={ocupado}>{ocupado ? 'Quitando...' : 'Quitar descuento'}</button>
										<button type="button" onclick={cerrar} disabled={ocupado}>Dejarlo</button>
									</div>
								{:else}
									<div class="campos">
										<label>
											Descuento (%)
											<input type="text" inputmode="decimal" bind:value={porcentaje} placeholder="Del 1 al 90" maxlength="5" />
										</label>
									</div>
									{#if errorFila}<p class="malo" role="alert">{errorFila}</p>{/if}
									<div class="acciones">
										<button type="button" class="principal" onclick={() => ponerDescuento(o)} disabled={ocupado}>{ocupado ? 'Aplicando...' : 'Aplicar descuento'}</button>
										<button type="button" onclick={cerrar} disabled={ocupado}>Cancelar</button>
									</div>
								{/if}
							{/if}
						</div>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
</section>

<style>
	.compartidas {
		margin-top: 2rem;
	}

	.titulo {
		display: flex;
		align-items: flex-end;
		justify-content: space-between;
		gap: var(--e4);
		margin-bottom: 1.25rem;
	}

	h2 {
		font-size: var(--f-xl);
	}

	.menor {
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.quieto {
		color: var(--gris);
		padding: 1.5rem 0;
	}

	.malo {
		color: var(--rojo);
		margin: 0.5rem 0;
	}

	.hecho {
		color: var(--indigo);
		background: var(--indigo-cl);
		padding: 0.6rem 0.9rem;
		border-radius: var(--r2);
		margin-bottom: 1rem;
	}

	.lista {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: var(--e3);
	}

	.fila {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: var(--e3);
		padding: 0.9rem 1rem;
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.cosa {
		display: flex;
		align-items: center;
		gap: var(--e3);
		flex: 1 1 16rem;
		min-width: 0;
	}

	.cosa img {
		width: 56px;
		height: 56px;
		object-fit: cover;
		border-radius: var(--r);
		background: var(--panel);
		flex-shrink: 0;
	}

	.nombre {
		display: flex;
		flex-direction: column;
		min-width: 0;
	}

	.numeros {
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: var(--e1);
	}

	.precio {
		font-size: var(--f-md);
	}

	.puedes {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e1);
	}

	.chip {
		display: inline-block;
		padding: 2px 10px;
		font-size: var(--f-xs);
		letter-spacing: 0.03em;
		text-transform: uppercase;
		border-radius: 999px;
		background: var(--indigo-cl);
		color: var(--indigo);
	}

	.acciones {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: var(--e2);
	}

	.panel {
		flex-basis: 100%;
		border-top: 1px solid var(--linea);
		padding-top: 0.9rem;
	}

	.campos {
		display: flex;
		flex-wrap: wrap;
		gap: var(--e3);
	}

	.campos label {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.campos input {
		min-width: 9rem;
	}

	.nota {
		margin: 0.7rem 0;
	}

	@media (max-width: 600px) {
		.titulo {
			flex-direction: column;
			align-items: flex-start;
		}

		.numeros {
			align-items: flex-start;
		}

		.campos label,
		.campos input {
			width: 100%;
		}
	}
</style>
