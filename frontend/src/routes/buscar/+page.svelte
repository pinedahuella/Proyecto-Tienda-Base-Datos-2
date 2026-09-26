<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import {
		buscarProductos,
		buscarFacetado,
		precioVisible,
		precioSegundo,
		nota,
		marcaDeEstado,
		MINIMO_LETRAS,
		type ResultadoBusqueda,
		type Facetas,
		type Elegidos
	} from '$lib/buscador';
	import { registrarClicBusqueda } from '$lib/eventos';

	/**
	 * La pagina de resultados del buscador, /buscar?q=...
	 *
	 * Es donde cae quien pulsa Enter en la cabecera sin elegir una sugerencia.
	 * Ensena la lista entera (hasta el tope del backend, 50) en vez de las ocho
	 * que caben colgando del campo.
	 *
	 * Por que el texto va en la direccion y no en un estado del componente: asi
	 * una busqueda se puede compartir, guardar y recargar, y el boton de atras
	 * del navegador hace lo que se espera. Es la misma decision que ya toma el
	 * catalogo con sus filtros.
	 *
	 * Esta pagina NO ordena. Lo que llega es lo que Elasticsearch considera mas
	 * parecido, en su orden de relevancia, y reordenarlo aqui seria tirar justo
	 * el trabajo por el que existe el motor.
	 *
	 * Los filtros facetados (Entrega 3) los calcula tambien Elasticsearch, con
	 * agregaciones, y van en la direccion igual que el texto: `cat`, `precio`,
	 * `nota` y `disp`. Si la ruta de facetas todavia no existe en el backend, la
	 * busqueda sale como siempre y el panel no se pinta.
	 */

	/** Lo que pide la direccion. */
	let consulta = $derived(page.url.searchParams.get('q')?.trim() ?? '');

	/**
	 * Si la direccion pide ver tambien lo que no esta activo (`&todo=1`).
	 *
	 * Lo pone el buscador de la cabecera cuando quien busca es admin, para que
	 * "ver todos los resultados" no cambie de criterio a mitad de camino: seria
	 * raro que la lista de arriba enseñe un producto rechazado y la pagina
	 * entera no lo traiga.
	 *
	 * Que este en la url NO da permiso: la ruta de admin pide sesion y rol, y
	 * al que no lo tenga le contesta 403 -- que aqui se pinta como el error que
	 * es. Poner `&todo=1` a mano no abre nada, solo rompe tu propia busqueda.
	 */
	let verTodo = $derived(page.url.searchParams.get('todo') === '1');

	/** Lo elegido en las facetas, leido de la direccion. */
	function lista(clave: string): string[] {
		return (page.url.searchParams.get(clave) ?? '').split(',').filter(Boolean);
	}
	let elegidos = $derived<Elegidos>({
		categoria: lista('cat'),
		precio: lista('precio'),
		calificacion: lista('nota'),
		disponible: page.url.searchParams.get('disp') === '1'
	});
	let hayElegidos = $derived(
		elegidos.categoria.length + elegidos.precio.length + elegidos.calificacion.length > 0 ||
			elegidos.disponible
	);

	let resultados = $state<ResultadoBusqueda[]>([]);
	let facetas = $state<Facetas | null>(null);
	let total = $state(0);
	let error = $state('');
	let cargando = $state(false);

	/** Ya se contesto a la consulta que hay ahora en la direccion. */
	let resuelta = $state('');

	/** Ver el comentario de ultimaConsulta en BuscadorCabecera.svelte. */
	let ultimaConsulta = 0;

	/** El tope del backend. Pedir mas no trae mas, asi que se pide justo eso. */
	const TOPE = 50;

	/**
	 * Buscar cada vez que cambia la direccion.
	 *
	 * Depende de `consulta`, que sale de la url, asi que tambien corre cuando
	 * se llega aqui desde otra busqueda sin recargar la pagina -- que es lo que
	 * pasa al escribir otra cosa en la cabecera estando ya en esta pantalla.
	 * Tambien depende de lo elegido en las facetas, que vive en la misma url.
	 */
	$effect(() => {
		const texto = consulta;
		// Se lee aqui dentro a proposito: es lo que hace que cambiar `&todo=1`
		// en la direccion vuelva a buscar. Leerlo solo dentro del `.then` lo
		// dejaria fuera de las dependencias del efecto.
		const todo = verTodo;
		const filtros = elegidos;
		const mia = ++ultimaConsulta;

		if (texto.length < MINIMO_LETRAS) {
			resultados = [];
			facetas = null;
			error = '';
			cargando = false;
			resuelta = texto;
			return;
		}

		cargando = true;

		// El admin busca por su ruta, que tambien trae lo no activo y no lleva facetas.
		const pedido = todo
			? buscarProductos(texto, TOPE, true).then((s) => ({
					...s,
					facetas: null,
					total: s.resultados.length
				}))
			: buscarFacetado(texto, filtros, TOPE);

		pedido.then((salida) => {
			if (mia !== ultimaConsulta) return;
			resultados = salida.resultados;
			facetas = salida.facetas;
			total = salida.total;
			error = salida.error;
			cargando = false;
			resuelta = texto;
		});
	});

	/** Marca o desmarca una opcion y lo deja en la direccion. */
	function alternar(clave: 'cat' | 'precio' | 'nota', valor: string) {
		const url = new URL(page.url);
		const actual = lista(clave);
		const nueva = actual.includes(valor) ? actual.filter((v) => v !== valor) : [...actual, valor];
		if (nueva.length) url.searchParams.set(clave, nueva.join(','));
		else url.searchParams.delete(clave);
		goto(url, { keepFocus: true, noScroll: true, replaceState: true });
	}

	function alternarDisponible() {
		const url = new URL(page.url);
		if (elegidos.disponible) url.searchParams.delete('disp');
		else url.searchParams.set('disp', '1');
		goto(url, { keepFocus: true, noScroll: true, replaceState: true });
	}

	function limpiar() {
		const url = new URL(page.url);
		for (const clave of ['cat', 'precio', 'nota', 'disp']) url.searchParams.delete(clave);
		goto(url, { keepFocus: true, noScroll: true, replaceState: true });
	}

	/** Como se lee el conteo. Sin "resultado(s)" ni parentesis. */
	let cuantos = $derived.by(() => {
		const n = facetas ? total : resultados.length;
		const texto = n === 1 ? '1 producto encontrado' : `${n} productos encontrados`;
		return facetas && total > resultados.length
			? `${texto}, se ven los ${resultados.length} mas parecidos`
			: texto;
	});
</script>

<svelte:head>
	<title>{consulta ? `${consulta} en Mesh` : 'Buscar en Mesh'}</title>
</svelte:head>

<Cabecera />

<main class="env">
	<header class="titulo">
		<h1>
			{#if consulta}Resultados de {consulta}{:else}Buscar{/if}
		</h1>

		{#if !cargando && error === '' && consulta.length >= MINIMO_LETRAS && resuelta === consulta}
			<p class="cuenta">{cuantos}</p>
		{/if}
	</header>

	{#if consulta.length < MINIMO_LETRAS}
		<p class="vacio">
			Escribe al menos {MINIMO_LETRAS} letras en el buscador de arriba.
		</p>
	{:else if cargando && !facetas}
		<p class="vacio">Buscando</p>
	{:else if error !== ''}
		<div class="malo">
			<p>{error}</p>
			<!-- Un 503 aqui casi siempre es Elasticsearch apagado, y el catalogo
			     sigue funcionando porque lee de MongoDB. Decirlo evita que
			     parezca que se cayo la tienda entera. -->
			<p class="letra-chica">
				El catalogo sigue disponible aunque el buscador no responda.
			</p>
			<a class="boton" href="/">Ir al catalogo</a>
		</div>
	{:else if resultados.length === 0 && !hayElegidos}
		<div class="malo suave">
			<p>No hay productos que se parezcan a {consulta}.</p>
			<p class="letra-chica">
				El buscador tolera errores de tecleo y no distingue tildes, asi que si
				esto sale es que ese producto no esta en el catalogo.
			</p>
			<a class="boton" href="/">Ver todo el catalogo</a>
		</div>
	{:else}
		<div class="con-filtros" class:sin-panel={!facetas}>
			{#if facetas}
				<aside class="filtros" aria-label="Filtros">
					<div class="grupo">
						<h2>Categoria</h2>
						<div class="opciones">
							{#each facetas.categoria as o (o.clave)}
								<label
									class="opcion"
									class:vacia={o.cantidad === 0 && !elegidos.categoria.includes(o.clave)}
								>
									<input
										type="checkbox"
										checked={elegidos.categoria.includes(o.clave)}
										onchange={() => alternar('cat', o.clave)}
									/>
									<span>{o.nombre}</span>
									<span class="n">{o.cantidad}</span>
								</label>
							{/each}
						</div>
					</div>

					<div class="grupo">
						<h2>Precio</h2>
						<div class="opciones">
							{#each facetas.precio as o (o.clave)}
								<label
									class="opcion"
									class:vacia={o.cantidad === 0 && !elegidos.precio.includes(o.clave)}
								>
									<input
										type="checkbox"
										checked={elegidos.precio.includes(o.clave)}
										onchange={() => alternar('precio', o.clave)}
									/>
									<span>{o.nombre}</span>
									<span class="n">{o.cantidad}</span>
								</label>
							{/each}
						</div>
					</div>

					<div class="grupo">
						<h2>Calificacion</h2>
						<div class="opciones">
							{#each facetas.calificacion as o (o.clave)}
								<label
									class="opcion"
									class:vacia={o.cantidad === 0 && !elegidos.calificacion.includes(o.clave)}
								>
									<input
										type="checkbox"
										checked={elegidos.calificacion.includes(o.clave)}
										onchange={() => alternar('nota', o.clave)}
									/>
									<span>{o.nombre}</span>
									<span class="n">{o.cantidad}</span>
								</label>
							{/each}
						</div>
					</div>

					<div class="grupo">
						<h2>Existencias</h2>
						<div class="opciones">
							<label class="opcion">
								<input type="checkbox" checked={elegidos.disponible} onchange={alternarDisponible} />
								<span>Solo disponibles</span>
								<span class="n">{facetas.disponible}</span>
							</label>
						</div>
					</div>

					{#if hayElegidos}
						<button type="button" class="limpiar" onclick={limpiar}>Quitar filtros</button>
					{/if}
				</aside>
			{/if}

			<div class="resultados">
				{#if resultados.length === 0}
					<div class="malo suave">
						<p>Nada coincide con esos filtros.</p>
						<button type="button" class="boton" onclick={limpiar}>Quitar filtros</button>
					</div>
				{:else}
					<ul class="lista">
						{#each resultados as r, i (r.id_producto)}
							<li>
								<a
									class="fila"
									href="/producto/{r.id_producto}?origen=buscador"
									onclick={() => {
										if (!verTodo) registrarClicBusqueda(consulta, r.id_producto, i + 1);
									}}
								>
									<span class="texto">
										<span class="nombre">{r.nombre}</span>
										<span class="bajo">
											{#if r.categoria}<span class="cat">{r.categoria}</span>{/if}
											{#if marcaDeEstado(r)}
												<span class="estado">{marcaDeEstado(r)}</span>
											{/if}
											{#if nota(r)}<span class="dato">{nota(r)}</span>{/if}
											<span class="dato" class:agotado={r.stock_total <= 0}>
												{r.stock_total > 0 ? `${r.stock_total} disponibles` : 'Sin existencias'}
											</span>
										</span>
									</span>

									<span class="cifras">
										{#if precioVisible(r)}
											<span class="precio">{precioVisible(r)}</span>
										{:else}
											<span class="sin-precio">Sin precio</span>
										{/if}
										{#if precioSegundo(r)}
											<span class="segundo">desde {precioSegundo(r)} con otro vendedor</span>
										{/if}
									</span>
								</a>
							</li>
						{/each}
					</ul>

					{#if !facetas}
						<p class="nota-pie">
							El buscador ordena por parecido. Para filtrar por categoria, precio o
							caracteristicas esta <a href="/">el catalogo</a>.
						</p>
					{/if}
				{/if}
			</div>
		</div>
	{/if}
</main>

<Pie />

<style>
	main {
		min-height: 60vh;
		padding: 2rem 24px 3.5rem;
	}

	.titulo {
		margin-bottom: 1.5rem;
	}

	h1 {
		margin: 0;
		font-size: var(--f-xl);
		font-weight: 600;
		color: var(--tinta);
		/* Lo que se busco puede ser larguisimo si alguien pega un parrafo. */
		overflow-wrap: anywhere;
	}

	.cuenta {
		margin: 0.35rem 0 0;
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.vacio {
		padding: 2rem 0;
		font-size: var(--f-base);
		color: var(--gris);
	}

	.malo {
		max-width: 34rem;
		padding: 1.5rem;
		background: var(--rojo-cl);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	/* No encontrar nada no es un fallo: no se pinta de rojo. */
	.malo.suave {
		background: var(--panel);
	}

	.malo p {
		margin: 0 0 0.5rem;
		color: var(--tinta);
	}

	.letra-chica {
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.boton {
		display: inline-block;
		margin-top: 0.6rem;
		padding: 8px 16px;
		text-decoration: none;
		font: inherit;
		font-size: var(--f-base);
		color: var(--sobre-indigo);
		background: var(--indigo);
		border: none;
		border-radius: var(--r);
		cursor: pointer;
		transition: background var(--t);
	}

	.boton:hover {
		background: var(--indigo-os);
	}

	.con-filtros {
		display: grid;
		grid-template-columns: 15rem minmax(0, 1fr);
		gap: 1.75rem;
		align-items: start;
	}

	.con-filtros.sin-panel {
		grid-template-columns: minmax(0, 1fr);
	}

	.filtros {
		display: flex;
		flex-direction: column;
		gap: 1.2rem;
	}

	.grupo h2 {
		margin: 0 0 0.45rem;
		font-size: var(--f-ms);
		font-weight: 600;
		color: var(--tinta);
	}

	.opciones {
		display: flex;
		flex-direction: column;
		gap: 0.3rem;
	}

	.opcion {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		font-size: var(--f-ms);
		color: var(--tinta);
		cursor: pointer;
	}

	.opcion .n {
		margin-left: auto;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.opcion.vacia {
		color: var(--gris);
	}

	.limpiar {
		align-self: flex-start;
		padding: 0;
		font: inherit;
		font-size: var(--f-ms);
		color: var(--indigo);
		background: none;
		border: none;
		cursor: pointer;
		text-decoration: underline;
	}

	.lista {
		margin: 0;
		padding: 0;
		list-style: none;
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
	}

	.lista li + li {
		border-top: 1px solid var(--linea);
	}

	.fila {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		padding: 0.9rem 1.1rem;
		text-decoration: none;
		color: var(--tinta);
		background: var(--blanco);
		transition: background var(--t);
	}

	.fila:hover {
		background: var(--indigo-cl);
	}

	.texto {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		min-width: 0;
	}

	.nombre {
		font-size: var(--f-md);
		line-height: 1.35;
	}

	.bajo {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: var(--e1) var(--e3);
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.cat {
		color: var(--indigo);
	}

	.dato.agotado {
		color: var(--rojo);
	}

	/* Solo con `&todo=1`, o sea solo para un admin: es la unica busqueda que
	   trae productos que no estan activos. */
	.estado {
		padding: 1px 7px;
		font-size: var(--f-xs);
		color: var(--rojo);
		border: 1px solid var(--rojo);
		border-radius: 999px;
	}

	.cifras {
		flex: none;
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: var(--e1);
		text-align: right;
	}

	.precio {
		font-size: var(--f-md);
		font-weight: 600;
	}

	.sin-precio {
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.segundo {
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.nota-pie {
		margin-top: 1.2rem;
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.nota-pie a {
		color: var(--indigo);
	}

	@media (max-width: 620px) {
		main {
			padding: 1.5rem 16px 2.5rem;
		}

		/* En telefono el precio se va debajo del nombre: en una sola fila, un
		   nombre de producto de verdad deja el precio en dos digitos por linea. */
		.fila {
			flex-direction: column;
			align-items: flex-start;
			gap: var(--e2);
		}

		.cifras {
			align-items: flex-start;
			text-align: left;
		}

		/* En telefono los filtros van arriba y cada grupo se desliza de lado, sin
		   esconderse detras de un boton. */
		.con-filtros {
			grid-template-columns: minmax(0, 1fr);
			gap: 1rem;
		}

		.filtros {
			gap: 0.8rem;
		}

		.opciones {
			flex-direction: row;
			overflow-x: auto;
			gap: 0.5rem;
			padding-bottom: 0.25rem;
		}

		.opcion {
			flex: none;
			padding: 6px 10px;
			border: 1px solid var(--linea);
			border-radius: 999px;
		}
	}
</style>
