<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import FotoBusqueda from '$lib/FotoBusqueda.svelte';
	import {
		buscarProductos,
		buscarFacetado,
		precioVisible,
		precioSegundo,
		nota,
		marcaDeEstado,
		MINIMO_LETRAS,
		buscarPorIntencion,
		buscarHibrida,
		filtrarHibrida,
		pareceFrase,
		vale,
		type ResultadoBusqueda,
		type ResultadoIntencion,
		type ResultadoHibrido,
		type Facetas,
		type Elegidos
	} from '$lib/buscador';
	import { registrarClicBusqueda, type FacetasDelClic } from '$lib/eventos';
	import { seguirBusqueda } from '$lib/seguimientos.svelte';

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

	/**
	 * Lo que viaja con el clic a ClickHouse. Solo si las facetas llegaron de
	 * la ruta facetada: si esa ruta dio 404 y se cayo a la busqueda simple, el
	 * clic no fue sobre una busqueda facetada aunque la direccion traiga filtros.
	 */
	function facetasDelClic(): FacetasDelClic | undefined {
		if (!facetas) return undefined;
		return {
			categorias: elegidos.categoria.map(Number).filter(Number.isInteger),
			precios: elegidos.precio,
			calificaciones: elegidos.calificacion,
			disponible: elegidos.disponible
		};
	}

	let resultados = $state<(ResultadoBusqueda | ResultadoHibrido)[]>([]);
	/**
	 * Si la lista de abajo es la de la busqueda hibrida. Lo es cuando no hay
	 * ningun filtro elegido: entiende nombres y frases a la vez. Con un filtro
	 * manda la facetada, que es la unica que sabe filtrar.
	 */
	let esHibrida = $state(false);
	let quisisteDecir = $state<string | null>(null);
	/**
	 * Sin resultados y sin filtros, lo que el backend propone para que la
	 * pagina no quede vacia (2026-10-20, lo pidio el profesor: buscar una locura
	 * tiene que traer al menos un producto). No son resultados: el conteo dice 0
	 * y la busqueda queda registrada como sin resultados.
	 */
	let sugeridos = $state<ResultadoBusqueda[]>([]);
	let facetas = $state<Facetas | null>(null);
	let total = $state(0);
	let error = $state('');
	let cargando = $state(false);

	/** Ya se contesto a la consulta que hay ahora en la direccion. */
	let resuelta = $state('');

	/**
	 * La busqueda por intencion, debajo de la de siempre. Se pide cuando lo
	 * escrito parece una frase o cuando la busqueda por nombre no encontro
	 * nada: "mi ventana esta muy solitaria" no es el nombre de ningun
	 * producto, pero la resena de una maceta puede decir justo eso. Si la ruta
	 * falla no se ensena nada, la busqueda de arriba sigue sirviendo sola.
	 */
	let intencion = $state<ResultadoIntencion[]>([]);
	let buscandoIntencion = $state(false);
	let ultimaIntencion = 0;

	function pedirIntencion(texto: string) {
		const mia = ++ultimaIntencion;
		buscandoIntencion = true;
		buscarPorIntencion(texto, 12).then((salida) => {
			if (mia !== ultimaIntencion) return;
			intencion = salida.resultados.filter(vale).slice(0, 6);
			buscandoIntencion = false;
		});
	}

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
			sugeridos = [];
			facetas = null;
			error = '';
			cargando = false;
			resuelta = texto;
			intencion = [];
			ultimaIntencion++;
			return;
		}

		cargando = true;
		intencion = [];
		ultimaIntencion++;
		// La del admin no: busca para revisar el catalogo, no para comprar.
		const porFrase = !todo && pareceFrase(texto);
		if (porFrase) pedirIntencion(texto);

		// El admin busca por su ruta, que tambien trae lo no activo y no lleva facetas.
		const pedido = todo
			? buscarProductos(texto, TOPE, true).then((s) => ({
					...s,
					facetas: null,
					total: s.resultados.length
				}))
			: buscarFacetado(texto, filtros, TOPE);
		// La hibrida va en paralelo y solo sin filtros. La facetada se pide igual:
		// trae el panel de filtros y registra la busqueda para las tendencias.
		const sinFiltros =
			filtros.categoria.length + filtros.precio.length + filtros.calificacion.length === 0 &&
			!filtros.disponible;
		const hibrida = !todo && sinFiltros ? buscarHibrida(texto, TOPE) : Promise.resolve(null);

		Promise.all([pedido, hibrida]).then(([salida, h]) => {
			if (mia !== ultimaConsulta) return;
			const hibridos = h !== null && h.error === '' ? filtrarHibrida(h.resultados) : [];
			const usarHibrida = hibridos.length > 0;
			esHibrida = usarHibrida;
			resultados = usarHibrida ? hibridos : salida.resultados;
			quisisteDecir = salida.quisiste_decir ?? null;
			sugeridos = salida.sugeridos ?? [];
			facetas = salida.facetas;
			total = salida.total;
			error = salida.error;
			cargando = false;
			resuelta = texto;
			if (!todo && !porFrase && salida.error === '' && salida.resultados.length === 0) {
				pedirIntencion(texto);
			}
		});
	});

	/**
	 * Con una frase la seccion de intencion va ARRIBA de la lista: para "algo
	 * para salir a pedalear" la busqueda por nombre devuelve cincuenta cosas
	 * que solo comparten una palabra, y lo que sirve es lo de las resenas.
	 * Con un nombre ("laptop") no se pide, y si no encuentra nada va abajo.
	 */
	let fraseArriba = $derived(!verTodo && pareceFrase(consulta));

	/** Si un resultado de la hibrida salio solo por el significado y no por las palabras. */
	function soloPorSignificado(r: ResultadoBusqueda | ResultadoHibrido): boolean {
		return esHibrida && 'origen' in r && r.origen.length === 1 && r.origen[0] === 'significado';
	}

	/** Las estrellas de una resena, sin emojis: 4 de 5. */
	function estrellas(n: number): string {
		return `${n} de 5`;
	}

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

	/**
	 * Como se lee el conteo. Sin "resultado(s)" ni parentesis. Con el panel de
	 * filtros a la vista cuenta lo mismo que el panel, tambien con la lista
	 * hibrida: con laptop decia 50 arriba y los filtros sumaban 109 (visto el
	 * 2026-10-20). Solo si la hibrida trae mas que la facetada, por lo que
	 * suma el significado, cuenta la lista.
	 */
	let cuantos = $derived.by(() => {
		const conPanel = facetas !== null && total >= resultados.length;
		const n = conPanel ? total : resultados.length;
		const texto = n === 1 ? '1 producto encontrado' : `${n} productos encontrados`;
		return conPanel && total > resultados.length
			? `${texto}, se ven los ${resultados.length} mas parecidos`
			: texto;
	});

	/**
	 * El aviso de una busqueda sin resultados. Hasta 100 letras (la regla del
	 * backend) y, si se escribe, un precio maximo sobre el precio final.
	 */
	let precioTope = $state('');
	let guardandoAviso = $state(false);
	let avisoBusqueda = $state<{ de: string; texto: string; bien: boolean; entrar?: boolean } | null>(null);

	async function pedirAviso() {
		const de = consulta;
		const tope = precioTope.trim().replace(',', '.');
		if (tope !== '' && !/^\d+(\.\d{1,2})?$/.test(tope)) {
			avisoBusqueda = { de, texto: 'El precio va en numeros, con hasta 2 decimales.', bien: false };
			return;
		}
		guardandoAviso = true;
		const r = await seguirBusqueda(de.trim().slice(0, 100), tope || undefined);
		guardandoAviso = false;
		if (r.estado === 401) {
			avisoBusqueda = { de, texto: 'Para pedir un aviso hace falta entrar.', bien: false, entrar: true };
			return;
		}
		avisoBusqueda = r.ok
			? { de, texto: 'Listo. Te avisamos cuando llegue.', bien: true }
			: { de, texto: r.mensaje, bien: false };
	}
</script>

<svelte:head>
	<title>{consulta ? `${consulta} en Mesh` : 'Buscar en Mesh'}</title>
</svelte:head>

{#snippet seccionIntencion()}

{#if consulta.length >= MINIMO_LETRAS && (intencion.length > 0 || buscandoIntencion)}

	<section class="intencion" class:arriba={fraseArriba} aria-label="Lo que cuentan otros compradores">

		<h2>Lo que cuentan otros compradores</h2>

		<p class="sub">Productos cuyas resenas hablan de lo que buscas, aunque no usen tus palabras.</p>

		{#if buscandoIntencion && intencion.length === 0}

			<p class="vacio">Leyendo resenas</p>

		{:else}

			<ul class="tarjetas">

				{#each intencion as r (r.id_producto)}

					<li>

						<a class="tarjeta" href="/producto/{r.id_producto}">

							<FotoBusqueda src={r.imagen} tipo="ancha" />

							<span class="nombre">{r.nombre}</span>

							{#if r.categoria}<span class="cat">{r.categoria}</span>{/if}

							{#if r.motivo}

								<blockquote>

									<span class="cita">{r.motivo.comentario}</span>

									<span class="quien">Le dio {estrellas(r.motivo.calificacion)}</span>

								</blockquote>

							{:else}

								<span class="quien">Por su descripcion</span>

							{/if}

							{#if precioVisible(r)}<span class="precio">{precioVisible(r)}</span>{/if}

						</a>

					</li>

				{/each}

			</ul>

		{/if}

	</section>

{/if}

{/snippet}



<Cabecera />

<main class="env">
	<header class="titulo">
		<h1>
			{#if consulta}Resultados de {consulta}{:else}Buscar{/if}
		</h1>

		{#if !cargando && error === '' && consulta.length >= MINIMO_LETRAS && resuelta === consulta}
			<p class="cuenta">{cuantos}</p>
			<!-- Con una frase no: el corrector cambia palabra por palabra y medido el
			     04-10 "algo para escuchar musica mientras corro" salia como "alba pesa
			     escuchar musica mientras cuero". La lista ya la resuelve el significado. -->
			{#if quisisteDecir && quisisteDecir !== consulta.toLowerCase() && !pareceFrase(consulta)}
				<p class="quisiste">
					Tal vez quisiste decir
					<a href="/buscar?q={encodeURIComponent(quisisteDecir)}">{quisisteDecir}</a>
				</p>
			{/if}
		{/if}
	</header>

	{#if fraseArriba}
		{@render seccionIntencion()}
	{/if}

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
	{:else if resultados.length === 0 && !hayElegidos && (intencion.length > 0 || buscandoIntencion)}
		<!-- La busqueda por nombre no encontro nada pero la de intencion si:
		     se ensena solo esta, sin el aviso de "no hay productos". -->
	{:else if resultados.length === 0 && !hayElegidos}
		<!-- Texto a la izquierda y acciones a la derecha, a todo el ancho: en una
		     columna de 34rem quedaba media pagina vacia (Meme, 20-10). -->
		<div class="malo suave sin-nada">
			<div class="sin-nada-texto">
				<p>No hay productos que se parezcan a {consulta}.</p>
				<p class="letra-chica">
					El buscador tolera errores de tecleo y no distingue tildes, asi que si
					esto sale es que ese producto no esta en el catalogo.
				</p>
			</div>
			<!-- "Avisame cuando llegue" (seguimientos de ofertas, 2026-10-17): se
			     guarda la busqueda y avisa UNA vez cuando llegue una oferta que
			     tenga todas sus palabras. -->
			<div class="seguir">
				{#if avisoBusqueda && avisoBusqueda.de === consulta}
					<p class:bien={avisoBusqueda.bien} role="status">
						{avisoBusqueda.texto}
						{#if avisoBusqueda.entrar}<a href="/entrar">Iniciar sesion</a>{/if}
					</p>
				{:else}
					<label class="tope">
						Hasta Q
						<input type="text" inputmode="decimal" placeholder="sin tope" bind:value={precioTope} />
					</label>
					<button type="button" class="boton" disabled={guardandoAviso} onclick={pedirAviso}>
						{guardandoAviso ? 'Guardando...' : 'Avisame cuando llegue'}
					</button>
				{/if}
				<a class="boton otro" href="/">Ver todo el catalogo</a>
			</div>
		</div>
		{#if sugeridos.length > 0}
			<!-- Los sugeridos no llevan ?origen=buscador ni registran el clic: no son
			     resultados de esta busqueda y mezclarlos ensuciaria las tendencias. -->
			<section class="sugeridos" aria-labelledby="t-sugeridos">
				<h2 id="t-sugeridos">Te pueden interesar</h2>
				<ul class="lista">
					{#each sugeridos as r (r.id_producto)}
						<li>
							<a class="fila" href="/producto/{r.id_producto}">
								<FotoBusqueda src={r.imagen} />
								<span class="texto">
									<span class="nombre">{r.nombre}</span>
									<span class="bajo">
										{#if r.categoria}<span class="cat">{r.categoria}</span>{/if}
										{#if r.hay_descuento}<span class="descuento">Con descuento</span>{/if}
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
								</span>
							</a>
						</li>
					{/each}
				</ul>
			</section>
		{/if}
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
										if (!verTodo) registrarClicBusqueda(consulta, r.id_producto, i + 1, facetasDelClic());
									}}
								>
									<FotoBusqueda src={r.imagen} />
									<span class="texto">
										<span class="nombre">{r.nombre}</span>
										<span class="bajo">
											{#if r.categoria}<span class="cat">{r.categoria}</span>{/if}
											{#if marcaDeEstado(r)}
												<span class="estado">{marcaDeEstado(r)}</span>
											{/if}
											{#if r.hay_descuento}<span class="descuento">Con descuento</span>{/if}
											{#if soloPorSignificado(r)}<span class="significado">Por lo que buscas</span>{/if}
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

	{#if !fraseArriba}
		{@render seccionIntencion()}
	{/if}
</main>

<Pie />

<style>
	.sugeridos {
		margin-top: 2rem;
	}

	.sugeridos h2 {
		margin: 0 0 0.75rem;
		font-size: var(--f-lg);
		font-weight: 600;
	}

	.intencion {
		margin-top: 2.5rem;
		padding-top: 1.5rem;
		border-top: 1px solid var(--linea);
	}

	.intencion.arriba {
		margin: 0 0 2rem;
		padding: 0 0 1.75rem;
		border-top: none;
		border-bottom: 1px solid var(--linea);
	}

	.intencion h2 {
		margin: 0;
		font-size: var(--f-lg);
		font-weight: 600;
		color: var(--tinta);
	}

	.intencion .sub {
		margin: 0.35rem 0 1.25rem;
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.tarjetas {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
		gap: 14px;
		margin: 0;
		padding: 0;
		list-style: none;
	}

	.tarjeta {
		display: flex;
		flex-direction: column;
		gap: 6px;
		height: 100%;
		padding: 16px;
		color: inherit;
		text-decoration: none;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.tarjeta:hover {
		border-color: var(--tinta);
	}

	.tarjeta .nombre {
		font-weight: 600;
		color: var(--tinta);
	}

	.tarjeta .cat,
	.tarjeta .quien {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.tarjeta blockquote {
		display: flex;
		flex-direction: column;
		gap: 4px;
		margin: 4px 0 0;
		padding-left: 10px;
		border-left: 2px solid var(--linea);
	}

	.tarjeta .cita {
		font-size: var(--f-ms);
		color: var(--tinta);
		overflow-wrap: anywhere;
	}

	.tarjeta .precio {
		margin-top: auto;
		font-weight: 600;
		color: var(--tinta);
	}

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

	.significado {
		font-size: var(--f-sm);
		color: var(--indigo);
	}

	.quisiste {
		margin: 0.35rem 0 0;
		font-size: var(--f-base);
		color: var(--tinta);
	}

	.quisiste a {
		font-weight: 600;
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
		flex: 1;
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

	/* Los mismos colores que la etiqueta de descuento del catalogo. */
	.descuento {
		padding: 1px 7px;
		font-size: var(--f-xs);
		font-weight: 600;
		color: var(--descuento-tinta);
		background: var(--descuento-fondo);
		border: 1px solid var(--descuento-linea);
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
		   nombre de producto de verdad deja el precio en dos digitos por linea.
		   La foto se queda a la izquierda de los dos. */
		.fila {
			display: grid;
			grid-template-columns: auto minmax(0, 1fr);
			align-items: start;
			gap: var(--e2) var(--e3);
		}

		.cifras {
			grid-column: 2;
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

	.seguir {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 0.6rem;
		margin: 1rem 0;
	}

	.seguir .tope {
		display: flex;
		align-items: center;
		gap: 0.4rem;
		font-size: var(--f-sm);
	}

	.seguir .tope input {
		width: 7rem;
	}

	.seguir .bien {
		color: var(--indigo);
	}

	.sin-nada {
		display: grid;
		grid-template-columns: minmax(0, 1fr) auto;
		align-items: center;
		gap: 1rem 2rem;
		max-width: none;
		padding: 1.25rem 1.5rem;
	}

	.sin-nada-texto p:last-child {
		margin-bottom: 0;
	}

	.sin-nada .seguir {
		justify-content: flex-end;
		margin: 0;
	}

	.sin-nada .seguir .boton {
		margin-top: 0;
	}

	.boton.otro {
		color: var(--indigo);
		background: none;
		border: 1px solid var(--indigo);
	}

	.boton.otro:hover {
		background: var(--indigo-cl);
	}

	/* Los sugeridos en tarjetas, tres por fila: en filas de lado a lado el
	   precio quedaba lejos del nombre. */
	.sugeridos .lista {
		display: grid;
		grid-template-columns: repeat(3, minmax(0, 1fr));
		gap: 0.75rem;
		border: none;
		border-radius: 0;
		overflow: visible;
	}

	.sugeridos .lista li + li {
		border-top: none;
	}

	.sugeridos .fila {
		flex-direction: column;
		align-items: stretch;
		justify-content: flex-start;
		gap: var(--e2);
		height: 100%;
		box-sizing: border-box;
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.sugeridos .cifras {
		align-items: flex-start;
		margin-top: auto;
		text-align: left;
	}

	@media (max-width: 900px) {
		.sin-nada {
			grid-template-columns: minmax(0, 1fr);
		}

		.sin-nada .seguir {
			justify-content: flex-start;
		}

		.sugeridos .lista {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}

	/* En telefono los sugeridos se deslizan de lado. */
	@media (max-width: 620px) {
		.sin-nada {
			padding: 1.1rem;
		}

		.sugeridos .lista {
			display: flex;
			overflow-x: auto;
			scroll-snap-type: x mandatory;
			padding-bottom: 0.25rem;
		}

		.sugeridos .lista li {
			flex: none;
			width: 78%;
			scroll-snap-align: start;
		}
	}
</style>
