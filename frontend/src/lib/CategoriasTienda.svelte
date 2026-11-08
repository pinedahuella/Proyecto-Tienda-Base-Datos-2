<script lang="ts">
	/**
	 * Las categorias del catalogo, para la tienda (migracion 054):
	 *
	 *   GET   /admin/categorias                     todas, con su paleta
	 *   POST  /admin/categorias                     crear una, debajo de una raiz
	 *   PATCH /admin/categorias/:id                 cambiarle el nombre
	 *   POST  /admin/categorias/:id/caracteristicas agregarle una caracteristica
	 *
	 * Cambiar el nombre no recorre los productos uno por uno: el backend lo
	 * cambia en todos con un solo updateMany de MongoDB. Agregar una
	 * caracteristica no toca ningun producto, y desde ese momento el formulario
	 * de publicar la pregunta.
	 */
	import { onMount } from 'svelte';
	import { conJson, pedir } from './api';

	let { alExpirarSesion }: { alExpirarSesion?: () => void } = $props();

	type TipoDato = 'texto' | 'entero' | 'decimal' | 'booleano' | 'lista';
	interface Caracteristica {
		nombre: string;
		tipo_dato: TipoDato;
		unidad: string | null;
	}
	interface Categoria {
		id_categoria: number;
		nombre: string;
		id_categoria_padre: number | null;
		categoria_padre: string | null;
		es_raiz: boolean;
		productos: number;
		caracteristicas: Caracteristica[];
		caracteristicas_variante: Caracteristica[];
	}
	interface FilaNueva {
		nombre: string;
		tipo_dato: TipoDato;
		unidad: string;
	}

	const NOMBRE_TIPO: Record<TipoDato, string> = {
		texto: 'Texto',
		entero: 'Numero entero',
		decimal: 'Numero con decimales',
		booleano: 'Si o no',
		lista: 'Lista'
	};

	let categorias = $state<Categoria[]>([]);
	let tipos = $state<TipoDato[]>(['texto', 'entero', 'decimal', 'booleano', 'lista']);
	let cargando = $state(true);
	let error = $state('');
	let aviso = $state('');
	let trabajando = $state(false);

	let raices = $derived(categorias.filter((c) => c.es_raiz));
	let hijasDe = (id: number) => categorias.filter((c) => c.id_categoria_padre === id);

	// crear
	let creando = $state(false);
	let nombreNueva = $state('');
	let padreNueva = $state('');
	let deProducto = $state<FilaNueva[]>([]);
	let deVariante = $state<FilaNueva[]>([]);

	// renombrar y agregar, una categoria a la vez
	let renombrando = $state<number | null>(null);
	let nombreEditado = $state('');
	let agregandoA = $state<number | null>(null);
	let filaAgregar = $state<FilaNueva & { para: 'producto' | 'variante' }>({
		nombre: '',
		tipo_dato: 'texto',
		unidad: '',
		para: 'producto'
	});

	function expiro(estado: number): boolean {
		if (estado === 401) {
			alExpirarSesion?.();
			return true;
		}
		return false;
	}

	async function cargar() {
		cargando = true;
		const r = await pedir<{ categorias: Categoria[]; tipos_dato: TipoDato[] }>('/admin/categorias');
		cargando = false;
		if (expiro(r.estado)) return;
		if (!r.ok || !r.payload) {
			error = r.mensaje;
			return;
		}
		categorias = r.payload.categorias;
		tipos = r.payload.tipos_dato;
	}

	function filaVacia(): FilaNueva {
		return { nombre: '', tipo_dato: 'texto', unidad: '' };
	}

	function limpias(filas: FilaNueva[]) {
		return filas
			.filter((f) => f.nombre.trim() !== '')
			.map((f) => ({ nombre: f.nombre.trim(), tipo_dato: f.tipo_dato, unidad: f.unidad.trim() || null }));
	}

	async function crear() {
		error = '';
		aviso = '';
		if (nombreNueva.trim() === '' || padreNueva === '') {
			error = 'Escribe el nombre y elige dentro de que categoria va';
			return;
		}
		trabajando = true;
		const r = await pedir<Categoria>(
			'/admin/categorias',
			conJson('POST', {
				nombre: nombreNueva,
				id_categoria_padre: Number(padreNueva),
				caracteristicas: limpias(deProducto),
				caracteristicas_variante: limpias(deVariante)
			})
		);
		trabajando = false;
		if (expiro(r.estado)) return;
		if (!r.ok || !r.payload) {
			error = r.mensaje;
			return;
		}
		aviso = `Se creo ${r.payload.nombre}, dentro de ${r.payload.categoria_padre}. Ya se puede publicar en ella.`;
		creando = false;
		nombreNueva = '';
		padreNueva = '';
		deProducto = [];
		deVariante = [];
		await cargar();
	}

	async function guardarNombre(c: Categoria) {
		error = '';
		aviso = '';
		trabajando = true;
		const r = await pedir<{ nombre: string; productos_actualizados: number }>(
			`/admin/categorias/${c.id_categoria}`,
			conJson('PATCH', { nombre: nombreEditado })
		);
		trabajando = false;
		if (expiro(r.estado)) return;
		if (!r.ok || !r.payload) {
			error = r.mensaje;
			return;
		}
		const n = r.payload.productos_actualizados;
		aviso = `${c.nombre} ahora se llama ${r.payload.nombre}. ${n} ${n === 1 ? 'producto tomo' : 'productos tomaron'} el nombre nuevo.`;
		renombrando = null;
		await cargar();
	}

	async function agregar(c: Categoria) {
		error = '';
		aviso = '';
		if (filaAgregar.nombre.trim() === '') {
			error = 'Escribe el nombre de la caracteristica';
			return;
		}
		trabajando = true;
		const r = await pedir<{ caracteristica: Caracteristica }>(
			`/admin/categorias/${c.id_categoria}/caracteristicas`,
			conJson('POST', {
				nombre: filaAgregar.nombre.trim(),
				tipo_dato: filaAgregar.tipo_dato,
				unidad: filaAgregar.unidad.trim() || null,
				para: filaAgregar.para
			})
		);
		trabajando = false;
		if (expiro(r.estado)) return;
		if (!r.ok || !r.payload) {
			error = r.mensaje;
			return;
		}
		aviso = `${c.nombre} ahora pregunta ${r.payload.caracteristica.nombre}${filaAgregar.para === 'variante' ? ' en cada variante' : ''}. Los productos que ya estaban no cambian.`;
		agregandoA = null;
		await cargar();
	}

	function textoCaracteristica(c: Caracteristica): string {
		return c.unidad ? `${c.nombre} (${c.unidad})` : c.nombre;
	}

	onMount(cargar);
</script>

<section class="categorias">
	<div class="cabeza">
		<p class="sub">
			Crear categorias, cambiarles el nombre y agregarles caracteristicas. Cambiar el nombre lo
			cambia en todos sus productos de una vez.
		</p>
		{#if !creando}
			<button type="button" class="principal" onclick={() => ((creando = true), (deProducto = [filaVacia()]), (deVariante = []))}>
				Nueva categoria
			</button>
		{/if}
	</div>

	{#if aviso}<p class="ok" role="status">{aviso}</p>{/if}
	{#if error}<p class="malo" role="alert">{error}</p>{/if}

	{#if creando}
		<div class="tarjeta forma">
			<h3>Nueva categoria</h3>
			<div class="dos">
				<label>
					Nombre
					<input type="text" maxlength="100" bind:value={nombreNueva} placeholder="Por ejemplo Jardin" />
				</label>
				<label>
					Dentro de
					<select bind:value={padreNueva}>
						<option value="">Elegi una...</option>
						{#each raices as r (r.id_categoria)}
							<option value={String(r.id_categoria)}>{r.nombre}</option>
						{/each}
					</select>
				</label>
			</div>

			{#each [{ titulo: 'Lo que pregunta de cada producto', filas: deProducto, poner: (f: FilaNueva[]) => (deProducto = f) }, { titulo: 'Lo que distingue a cada variante', filas: deVariante, poner: (f: FilaNueva[]) => (deVariante = f) }] as bloque (bloque.titulo)}
				<p class="menor">{bloque.titulo}</p>
				{#each bloque.filas as fila, i (i)}
					<div class="fila-caracteristica">
						<input type="text" maxlength="100" placeholder="Nombre" bind:value={fila.nombre} aria-label="Nombre de la caracteristica" />
						<select bind:value={fila.tipo_dato} aria-label="Tipo">
							{#each tipos as t (t)}<option value={t}>{NOMBRE_TIPO[t]}</option>{/each}
						</select>
						<input type="text" maxlength="20" placeholder="Unidad, si tiene" bind:value={fila.unidad} aria-label="Unidad" />
						<button type="button" onclick={() => bloque.poner(bloque.filas.filter((_, k) => k !== i))}>Quitar</button>
					</div>
				{/each}
				<button type="button" class="enlace" onclick={() => bloque.poner([...bloque.filas, filaVacia()])}>Agregar una</button>
			{/each}

			<div class="botones">
				<button type="button" class="principal" disabled={trabajando} onclick={crear}>
					{trabajando ? 'Creando...' : 'Crear la categoria'}
				</button>
				<button type="button" onclick={() => (creando = false)}>Cancelar</button>
			</div>
		</div>
	{/if}

	{#if cargando}
		<p class="quieto">Trayendo las categorias...</p>
	{:else}
		{#each raices as raiz (raiz.id_categoria)}
			<div class="grupo">
				<h3>{raiz.nombre}</h3>
				<div class="hijas">
					{#each hijasDe(raiz.id_categoria) as c (c.id_categoria)}
						<article class="tarjeta">
							{#if renombrando === c.id_categoria}
								<div class="en-linea">
									<input type="text" maxlength="100" bind:value={nombreEditado} aria-label="Nombre nuevo" />
									<button type="button" class="principal" disabled={trabajando} onclick={() => guardarNombre(c)}>Guardar</button>
									<button type="button" onclick={() => (renombrando = null)}>Cancelar</button>
								</div>
							{:else}
								<h4>{c.nombre}</h4>
							{/if}
							<p class="menor">{c.productos} {c.productos === 1 ? 'producto' : 'productos'}</p>
							{#if c.caracteristicas.length > 0}
								<p class="chips">
									{#each c.caracteristicas as x (x.nombre)}<span>{textoCaracteristica(x)}</span>{/each}
								</p>
							{/if}
							{#if c.caracteristicas_variante.length > 0}
								<p class="chips variante">
									{#each c.caracteristicas_variante as x (x.nombre)}<span>{textoCaracteristica(x)}</span>{/each}
								</p>
							{/if}

							{#if agregandoA === c.id_categoria}
								<div class="fila-caracteristica">
									<input type="text" maxlength="100" placeholder="Nombre" bind:value={filaAgregar.nombre} aria-label="Nombre de la caracteristica" />
									<select bind:value={filaAgregar.tipo_dato} aria-label="Tipo">
										{#each tipos as t (t)}<option value={t}>{NOMBRE_TIPO[t]}</option>{/each}
									</select>
									<input type="text" maxlength="20" placeholder="Unidad" bind:value={filaAgregar.unidad} aria-label="Unidad" />
									<select bind:value={filaAgregar.para} aria-label="Para">
										<option value="producto">Del producto</option>
										<option value="variante">De cada variante</option>
									</select>
								</div>
								<div class="botones">
									<button type="button" class="principal" disabled={trabajando} onclick={() => agregar(c)}>Agregar</button>
									<button type="button" onclick={() => (agregandoA = null)}>Cancelar</button>
								</div>
							{:else if renombrando !== c.id_categoria}
								<div class="botones">
									<button type="button" onclick={() => ((renombrando = c.id_categoria), (agregandoA = null), (nombreEditado = c.nombre))}>
										Cambiar nombre
									</button>
									<button
										type="button"
										onclick={() => (
											(agregandoA = c.id_categoria),
											(renombrando = null),
											(filaAgregar = { nombre: '', tipo_dato: 'texto', unidad: '', para: 'producto' })
										)}
									>
										Agregar caracteristica
									</button>
								</div>
							{/if}
						</article>
					{:else}
						<p class="quieto">Todavia no tiene categorias adentro.</p>
					{/each}
				</div>
			</div>
		{/each}
	{/if}
</section>

<style>
	.categorias {
		display: flex;
		flex-direction: column;
		gap: var(--e3);
	}

	.cabeza {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e3);
		flex-wrap: wrap;
	}

	.sub,
	.menor {
		margin: 0;
		color: var(--gris);
		font-size: var(--f-sm);
	}

	.tarjeta {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 1rem 1.1rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.forma h3,
	.grupo h3 {
		margin: 0;
		font-size: var(--f-lg, 1.15rem);
	}

	.tarjeta h4 {
		margin: 0;
		font-size: var(--f-base);
	}

	.dos {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
		gap: var(--e3);
	}

	label {
		display: flex;
		flex-direction: column;
		gap: 4px;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	input,
	select {
		padding: 7px 10px;
		font: inherit;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	button {
		padding: 6px 12px;
		font: inherit;
		font-size: var(--f-sm);
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	button:hover:not(:disabled) {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	button:disabled {
		opacity: 0.55;
		cursor: default;
	}

	button.principal {
		color: var(--blanco);
		background: var(--indigo);
		border-color: var(--indigo);
	}

	button.principal:hover:not(:disabled) {
		color: var(--blanco);
	}

	button.enlace {
		align-self: flex-start;
		padding: 2px 0;
		border: none;
		color: var(--indigo);
		font-weight: 600;
	}

	.fila-caracteristica {
		display: grid;
		grid-template-columns: 2fr 1.4fr 1fr auto;
		gap: 6px;
	}

	.botones,
	.en-linea {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
	}

	.en-linea input {
		flex: 1;
		min-width: 160px;
	}

	.grupo {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
	}

	.hijas {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
		gap: var(--e3);
	}

	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
		margin: 0;
	}

	.chips span {
		padding: 2px 8px;
		font-size: var(--f-xs);
		background: var(--panel);
		border-radius: 999px;
	}

	.chips.variante span {
		background: var(--indigo-cl);
		color: var(--indigo);
	}

	.ok {
		margin: 0;
		padding: 10px 12px;
		font-size: var(--f-sm);
		color: var(--g3);
		background: color-mix(in srgb, var(--g3) 12%, transparent);
		border-radius: var(--r);
	}

	.malo {
		margin: 0;
		padding: 10px 12px;
		font-size: var(--f-sm);
		color: var(--rojo);
		background: var(--rojo-cl);
		border-radius: var(--r);
	}

	.quieto {
		margin: 0;
		color: var(--gris);
		font-size: var(--f-sm);
	}

	@media (max-width: 640px) {
		.fila-caracteristica {
			grid-template-columns: 1fr 1fr;
		}
	}
</style>
