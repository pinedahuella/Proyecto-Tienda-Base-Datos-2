<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import {
		buscarProductos,
		precioVisible,
		precioSegundo,
		nota,
		marcaDeEstado,
		MINIMO_LETRAS,
		type ResultadoBusqueda
	} from '$lib/buscador';

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
	 * Esta pagina NO filtra ni ordena. Lo que llega es lo que Elasticsearch
	 * considera mas parecido, en su orden de relevancia, y reordenarlo aqui
	 * seria tirar justo el trabajo por el que existe el motor. Quien quiera
	 * filtrar por categoria o por precio tiene el catalogo, y desde aqui se
	 * llega con un enlace.
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

	let resultados = $state<ResultadoBusqueda[]>([]);
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
	 */
	$effect(() => {
		const texto = consulta;
		// Se lee aqui dentro a proposito: es lo que hace que cambiar `&todo=1`
		// en la direccion vuelva a buscar. Leerlo solo dentro del `.then` lo
		// dejaria fuera de las dependencias del efecto.
		const todo = verTodo;
		const mia = ++ultimaConsulta;

		if (texto.length < MINIMO_LETRAS) {
			resultados = [];
			error = '';
			cargando = false;
			resuelta = texto;
			return;
		}

		cargando = true;

		buscarProductos(texto, TOPE, todo).then((salida) => {
			if (mia !== ultimaConsulta) return;
			resultados = salida.resultados;
			error = salida.error;
			cargando = false;
			resuelta = texto;
		});
	});

	/** Como se lee el conteo. Sin "resultado(s)" ni parentesis. */
	let cuantos = $derived(
		resultados.length === 1 ? '1 producto encontrado' : `${resultados.length} productos encontrados`
	);

	async function abrir(r: ResultadoBusqueda) {
		await goto(`/producto/${r.id_producto}`);
	}
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
	{:else if cargando}
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
	{:else if resultados.length === 0}
		<div class="malo suave">
			<p>No hay productos que se parezcan a {consulta}.</p>
			<p class="letra-chica">
				El buscador tolera errores de tecleo y no distingue tildes, asi que si
				esto sale es que ese producto no esta en el catalogo.
			</p>
			<a class="boton" href="/">Ver todo el catalogo</a>
		</div>
	{:else}
		<ul class="lista">
			{#each resultados as r (r.id_producto)}
				<li>
					<a class="fila" href="/producto/{r.id_producto}">
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

		<p class="nota-pie">
			El buscador ordena por parecido y no trae filtros. Para filtrar por
			categoria, precio o caracteristicas esta
			<a href="/">el catalogo</a>.
		</p>
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
		font-size: 1.5rem;
		font-weight: 600;
		color: var(--tinta);
		/* Lo que se busco puede ser larguisimo si alguien pega un parrafo. */
		overflow-wrap: anywhere;
	}

	.cuenta {
		margin: 0.35rem 0 0;
		font-size: 0.9rem;
		color: var(--gris);
	}

	.vacio {
		padding: 2rem 0;
		font-size: 0.95rem;
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
		font-size: 0.87rem;
		color: var(--gris);
	}

	.boton {
		display: inline-block;
		margin-top: 0.6rem;
		padding: 8px 16px;
		text-decoration: none;
		font-size: 0.92rem;
		color: var(--sobre-indigo);
		background: var(--indigo);
		border-radius: var(--r);
		transition: background var(--t);
	}

	.boton:hover {
		background: var(--indigo-os);
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
		gap: 1.2rem;
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
		gap: 3px;
		min-width: 0;
	}

	.nombre {
		font-size: 1rem;
		line-height: 1.35;
	}

	.bajo {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.15rem 0.8rem;
		font-size: 0.82rem;
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
		font-size: 0.74rem;
		color: var(--rojo);
		border: 1px solid var(--rojo);
		border-radius: 999px;
	}

	.cifras {
		flex: none;
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 2px;
		text-align: right;
	}

	.precio {
		font-size: 1.02rem;
		font-weight: 600;
	}

	.sin-precio {
		font-size: 0.88rem;
		color: var(--gris);
	}

	.segundo {
		font-size: 0.78rem;
		color: var(--gris);
	}

	.nota-pie {
		margin-top: 1.2rem;
		font-size: 0.87rem;
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
			gap: 0.5rem;
		}

		.cifras {
			align-items: flex-start;
			text-align: left;
		}
	}
</style>
