<script lang="ts">
	import { onMount } from 'svelte';
	import { conJson, pedir } from './api';

	/**
	 * Las propuestas de productos al catalogo compartido.
	 *
	 * Un componente con DOS caras, igual que OfertasVendedor: es la misma cosa
	 * mirada desde los dos lados del mostrador, y partirla en dos archivos habria
	 * duplicado el tipo, la pastilla de estado y el bloque de rechazos.
	 *
	 *   la tienda (o un admin)  ve la COLA: lo que falta por aprobar, de otros
	 *   un vendedor normal      ve LAS SUYAS, con el motivo si se las devolvieron
	 *
	 * Por que existe: el catalogo es compartido y hasta ahora solo la tienda podia
	 * meter entradas, para que dos vendedores no subieran la misma laptop dos
	 * veces. Ahora un vendedor propone, nace `en_revision` y no circula, y la
	 * tienda aprueba o rechaza diciendo por que.
	 */

	let {
		alExpirarSesion,
		administraLaTienda = false
	}: { alExpirarSesion: () => void; administraLaTienda?: boolean } = $props();

	// ---------------------------------------------------------------- tipos

	/** Un rechazo. Son varios por propuesta: corregir y reenviar deja otra fila. */
	interface Rechazo {
		id_rechazo_producto: string;
		razon_rechazo: string;
		fecha_rechazo: string;
	}

	/**
	 * Lo que devuelven las tres rutas GET de propuestas.
	 *
	 * `producto` es el documento de MongoDB entero, y de ahi sale el estado: la
	 * propuesta NO tiene estado propio (ver docs/base-de-datos.md, "Los
	 * historiales no llevan estado"). `vendedor` solo viene en las vistas de la
	 * tienda; en "las mias" se omite, porque ya se sabe quien soy.
	 */
	interface Propuesta {
		id_propuesta_producto: string;
		id_producto: number;
		fecha_propuesta: string;
		fecha_aprobacion: string | null;
		comentario_aprobacion: string | null;
		producto: {
			_id: number;
			nombre: string;
			descripcion: string | null;
			estado: string;
			categoria?: { nombre?: string } | null;
			variantes?: { nombre_variante: string }[];
		} | null;
		rechazos: Rechazo[];
		vendedor?: {
			id_usuario: string;
			usuario: string;
			nombre: string;
			apellido: string | null;
		};
	}

	// ---------------------------------------------------------------- estado

	let propuestas = $state<Propuesta[]>([]);
	let cargando = $state(true);
	let error = $state('');
	let aviso = $state('');

	/** El id del producto que se esta rechazando, para pedirle el motivo. */
	let rechazando = $state<number | null>(null);
	let razon = $state('');
	/** El id del que se esta mandando, para bloquear solo esa fila. */
	let trabajando = $state<number | null>(null);
	/** El id cuyos rechazos estan desplegados. Uno a la vez, como en las ofertas. */
	let motivosDe = $state<number | null>(null);

	// ---------------------------------------------------------------- cargar

	/** Un 401 aqui significa que la sesion se acabo de verdad. */
	function expiro(estado: number): boolean {
		if (estado !== 401) return false;
		alExpirarSesion();
		return true;
	}

	/**
	 * La ruta cambia con quien mira, pero la forma del payload es la misma, asi
	 * que el resto del componente no se entera.
	 */
	async function cargar() {
		error = '';
		cargando = true;

		const ruta = administraLaTienda
			? '/vendedor/productos/propuestas/sin-aprobar'
			: '/vendedor/productos/propuestas';
		const r = await pedir<Propuesta[]>(ruta);
		cargando = false;

		if (expiro(r.estado)) return;

		if (r.ok && r.payload) {
			propuestas = r.payload;
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	// Con onMount y nunca con $effect: un $effect que carga se dispara varias
	// veces y desmonta el arbol a media escritura.
	onMount(cargar);

	// ---------------------------------------------------------------- acciones

	/** Aprueba o rechaza. Al confirmar, la fila se va de la cola sin recargarla. */
	async function revisar(p: Propuesta, decision: 'aprobar' | 'rechazar') {
		if (decision === 'rechazar' && !razon.trim()) {
			error = 'La razon del rechazo es obligatoria';
			return;
		}

		error = '';
		aviso = '';
		trabajando = p.id_producto;

		const cuerpo = decision === 'aprobar' ? { decision } : { decision, razon: razon.trim() };
		const r = await pedir<unknown>(
			`/vendedor/productos/${p.id_producto}/revision`,
			conJson('PATCH', cuerpo)
		);
		trabajando = null;

		if (expiro(r.estado)) return;

		if (r.ok) {
			propuestas = propuestas.filter((x) => x.id_producto !== p.id_producto);
			rechazando = null;
			razon = '';
			const quien = p.vendedor?.nombre ?? 'el vendedor';
			aviso =
				decision === 'aprobar'
					? `"${nombreDe(p)}" ya esta en el catalogo`
					: `Rechazaste "${nombreDe(p)}" y ${quien} ya puede corregirlo`;
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	/** El vendedor vuelve a mandar a revision una que le rechazaron. */
	async function reenviar(p: Propuesta) {
		error = '';
		aviso = '';
		trabajando = p.id_producto;

		const r = await pedir<unknown>(
			`/vendedor/productos/${p.id_producto}/reenviar`,
			conJson('PATCH', {})
		);
		trabajando = null;

		if (expiro(r.estado)) return;

		if (r.ok) {
			aviso = `"${nombreDe(p)}" volvio a la cola de revision`;
			await cargar();
		} else {
			error = r.estado === 0 ? 'No se pudo conectar con el servidor' : r.mensaje;
		}
	}

	// ---------------------------------------------------------------- ayudas

	function nombreDe(p: Propuesta): string {
		return p.producto?.nombre ?? `Producto ${p.id_producto}`;
	}

	/**
	 * El estado sale del documento del producto y viene en crudo del enum, con
	 * guion bajo. Se traduce para leerlo, pero la clase CSS usa el valor crudo.
	 */
	function estadoLegible(estado: string | undefined): string {
		if (estado === 'en_revision') return 'en revision';
		return estado ?? 'sin estado';
	}

	function cuando(iso: string): string {
		return new Date(iso).toLocaleString('es-GT', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}
</script>

<section class="propuestas">
	<div class="titulo">
		<div>
			<h2>{administraLaTienda ? 'Productos por revisar' : 'Mis propuestas al catalogo'}</h2>
			<p class="sub">
				{#if administraLaTienda}
					Productos que otros vendedores quieren meter al catalogo compartido. Hasta que los
					apruebes no se ven en la tienda. Al rechazar hay que decir por que: el vendedor lo lee
					y corrige.
				{:else}
					Los productos que propusiste. El catalogo es compartido, asi que la tienda los revisa
					antes de que circulen; una vez aprobados cualquiera puede ofertarlos, tambien vos.
				{/if}
			</p>
		</div>
		<div class="acciones-titulo">
			<button type="button" class="enlace" onclick={cargar} disabled={cargando}>Actualizar</button>
		</div>
	</div>

	{#if aviso}
		<p class="hecho" role="status">{aviso}</p>
	{/if}
	{#if error}
		<p class="malo" role="alert">{error}</p>
	{/if}

	{#if cargando && propuestas.length === 0}
		<p class="quieto">Cargando...</p>
	{:else if propuestas.length === 0}
		<p class="quieto">
			{#if administraLaTienda}
				No hay productos esperando revision.
			{:else}
				Todavia no has propuesto ningun producto.
			{/if}
		</p>
	{:else}
		<ul class="lista">
			{#each propuestas as p (p.id_propuesta_producto)}
				<li class="fila">
					<div class="datos">
						<h3>{nombreDe(p)}</h3>
						<p class="menor">
							{p.producto?.categoria?.nombre ?? 'sin categoria'}
							{#if p.producto?.variantes?.length}
								&middot; {p.producto.variantes.length} presentacion{p.producto.variantes.length === 1
									? ''
									: 'es'}
							{/if}
						</p>
						{#if administraLaTienda && p.vendedor}
							<p class="menor">
								Lo propone {p.vendedor.nombre}
								{p.vendedor.apellido ?? ''} ({p.vendedor.usuario}) &middot; {cuando(
									p.fecha_propuesta
								)}
							</p>
						{:else}
							<p class="menor">Propuesto el {cuando(p.fecha_propuesta)}</p>
						{/if}
					</div>

					<div class="medio">
						<span
							class="chip"
							class:espera={p.producto?.estado === 'en_revision'}
							class:negado={p.producto?.estado === 'rechazado'}
							class:activo={p.producto?.estado === 'activo'}
						>
							{estadoLegible(p.producto?.estado)}
						</span>
					</div>

					<div class="acciones">
						{#if administraLaTienda}
							<button
								type="button"
								class="principal"
								disabled={trabajando === p.id_producto}
								onclick={() => revisar(p, 'aprobar')}
							>
								Aprobar
							</button>
							<button
								type="button"
								class="peligro"
								disabled={trabajando === p.id_producto}
								onclick={() => {
									rechazando = rechazando === p.id_producto ? null : p.id_producto;
									razon = '';
									error = '';
								}}
							>
								{rechazando === p.id_producto ? 'Cancelar' : 'Rechazar'}
							</button>
						{:else if p.producto?.estado === 'rechazado'}
							<button
								type="button"
								class="principal"
								disabled={trabajando === p.id_producto}
								onclick={() => reenviar(p)}
							>
								Reenviar a revision
							</button>
						{/if}

						{#if p.rechazos.length > 0}
							<button
								type="button"
								class="enlace"
								onclick={() => (motivosDe = motivosDe === p.id_producto ? null : p.id_producto)}
							>
								{motivosDe === p.id_producto ? 'Ocultar' : `Ver ${p.rechazos.length} rechazo${p.rechazos.length === 1 ? '' : 's'}`}
							</button>
						{/if}
					</div>

					{#if motivosDe === p.id_producto}
						<div class="motivos">
							<ul>
								{#each p.rechazos as r (r.id_rechazo_producto)}
									<li>
										<p>{r.razon_rechazo}</p>
										<span class="menor">{cuando(r.fecha_rechazo)}</span>
									</li>
								{/each}
							</ul>
							{#if !administraLaTienda}
								<p class="menor">
									Corregi lo que te piden y volve a mandarlo con "Reenviar a revision".
								</p>
							{/if}
						</div>
					{/if}

					{#if rechazando === p.id_producto}
						<!-- El motivo es obligatorio: el backend responde 400 sin el, y es lo
						     unico que el vendedor va a leer para saber que corregir. -->
						<div class="edicion">
							<label>
								Por que se rechaza
								<input
									type="text"
									maxlength="500"
									placeholder="Ya existe en el catalogo como Audifonos Sonata"
									bind:value={razon}
								/>
							</label>
							<button
								type="button"
								class="peligro"
								disabled={trabajando === p.id_producto || !razon.trim()}
								onclick={() => revisar(p, 'rechazar')}
							>
								Rechazar y avisarle
							</button>
						</div>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
</section>

<style>
	.propuestas {
		margin-top: 2rem;
	}

	.titulo {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: var(--e4);
		flex-wrap: wrap;
		margin-bottom: 1rem;
	}

	h2 {
		margin: 0 0 4px;
	}

	.sub {
		margin: 0;
		max-width: 62ch;
		color: var(--gris);
	}

	.acciones-titulo {
		display: flex;
		gap: var(--e2);
		align-items: center;
	}

	.lista {
		display: flex;
		flex-direction: column;
		gap: var(--e3);
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.fila {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: var(--e4);
		padding: 1rem 1.1rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.datos {
		flex: 1 1 18rem;
	}

	.datos h3 {
		margin: 0 0 2px;
		font-size: var(--f-md);
	}

	.menor {
		margin: 0;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.acciones {
		display: flex;
		gap: var(--e2);
		align-items: center;
		flex-wrap: wrap;
	}

	.chip {
		display: inline-block;
		padding: 2px 10px;
		border-radius: 999px;
		font-size: var(--f-xs);
		background: var(--panel);
		color: var(--gris);
	}

	.chip.activo {
		background: var(--indigo-cl);
		color: var(--indigo);
	}

	/* `en_revision` es neutro a proposito: no es ni bueno ni malo, es que
	   todavia no lo miraron. */
	.chip.espera {
		background: var(--panel);
		color: var(--gris);
	}

	.chip.negado {
		background: var(--rojo-cl);
		color: var(--rojo);
	}

	.motivos,
	.edicion {
		flex-basis: 100%;
		margin: 8px 0 0;
		padding: 12px 14px;
		border-radius: var(--r);
	}

	.motivos {
		background: var(--rojo-cl);
	}

	.edicion {
		background: var(--panel);
		display: flex;
		gap: var(--e3);
		align-items: flex-end;
		flex-wrap: wrap;
	}

	.edicion label {
		flex: 1 1 22rem;
		display: grid;
		gap: var(--e1);
	}

	.motivos ul {
		margin: 0 0 8px;
		padding: 0;
		list-style: none;
		display: grid;
		gap: var(--e2);
	}

	.motivos li p {
		margin: 0;
	}

	.quieto {
		color: var(--gris);
	}

	.hecho,
	.malo {
		margin: 0 0 12px;
		padding: 10px 14px;
		border-radius: var(--r);
	}

	.hecho {
		background: var(--indigo-cl);
		color: var(--indigo);
	}

	.malo {
		background: var(--rojo-cl);
		color: var(--rojo);
	}
</style>
