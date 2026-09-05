<script lang="ts">
	import { goto } from '$app/navigation';
	import {
		buscarProductos,
		precioVisible,
		precioSegundo,
		nota,
		MINIMO_LETRAS,
		type ResultadoBusqueda
	} from './buscador';

	/**
	 * El buscador de la cabecera, con su lista de resultados colgando.
	 *
	 * Se escribe y van saliendo productos sin recargar nada. Pulsar uno abre su
	 * ficha; pulsar Enter sin haber elegido ninguno lleva a la pagina de
	 * resultados, /buscar, que ensena la lista entera.
	 *
	 * Va contra GET /buscador/productos, o sea contra Elasticsearch y no contra
	 * el filtro `nombre` del catalogo. No es lo mismo y por eso vale la pena
	 * tenerlo aparte: el del catalogo compara subcadenas, asi que "labtop" no
	 * encuentra nada; este es difuso y sin tildes, asi que "labtop" encuentra
	 * las laptops y "ambar" encuentra "ámbar".
	 *
	 * Lo que NO hace: filtrar. Los filtros (categoria, precio, caracteristicas)
	 * siguen viviendo en el catalogo, que es donde hay sitio para ensenarlos.
	 * Esto es para llegar rapido a un producto que ya sabes que existe.
	 */

	/** Lo escrito. */
	let texto = $state('');

	/** Lo ultimo que devolvio el servidor. */
	let resultados = $state<ResultadoBusqueda[]>([]);

	/** El motivo por el que no hay lista, cuando no la hay. */
	let error = $state('');

	/** Hay una consulta en el aire. */
	let cargando = $state(false);

	/** La lista esta desplegada. */
	let abierto = $state(false);

	/** Cual esta marcada con el teclado. -1 es ninguna. */
	let resaltada = $state(-1);

	/** Ya se busco al menos una vez con el texto que hay ahora. */
	let buscado = $state(false);

	/** La caja entera, que es lo que decide que es "fuera". */
	let caja = $state<HTMLElement | null>(null);

	/** El campo, para devolverle el foco y para vaciarlo. */
	let campo = $state<HTMLInputElement | null>(null);

	/** El temporizador del retardo entre teclas. */
	let retardo: ReturnType<typeof setTimeout> | null = null;

	/**
	 * El numero de la ultima consulta lanzada.
	 *
	 * Sin esto la lista puede quedarse con resultados de otra palabra. Se
	 * escribe "lam" y luego "lampara": son dos consultas, y la primera puede
	 * contestar DESPUES que la segunda -- no van por el mismo camino ni tardan
	 * lo mismo. La que llega tarde pisa a la buena y la pantalla ensena
	 * resultados que no son de lo que hay escrito. Se guarda el numero de cada
	 * una y solo se pinta la ultima.
	 */
	let ultimaConsulta = 0;

	/** Cuantas caben en la lista antes de mandar a la pagina de resultados. */
	const MAXIMO_EN_LISTA = 8;

	/** Milisegundos que se espera a que la persona deje de teclear. */
	const ESPERA = 250;

	/**
	 * Hay algo que ensenar debajo del campo.
	 *
	 * Incluye el estado vacio y el error a proposito: una busqueda que no
	 * encuentra nada tiene que DECIRLO. Cerrar la lista sin mas deja a la
	 * persona pensando que el buscador no funciona.
	 */
	let hayPanel = $derived(
		abierto &&
			texto.trim().length >= MINIMO_LETRAS &&
			(cargando || error !== '' || buscado)
	);

	async function lanzar(consulta: string) {
		const mia = ++ultimaConsulta;
		cargando = true;

		const salida = await buscarProductos(consulta, MAXIMO_EN_LISTA);

		// Llego una vieja: se tira. Ver ultimaConsulta.
		if (mia !== ultimaConsulta) return;

		resultados = salida.resultados;
		error = salida.error;
		cargando = false;
		buscado = true;
		resaltada = -1;
	}

	function alEscribir() {
		if (retardo) clearTimeout(retardo);
		resaltada = -1;
		abierto = true;

		const consulta = texto.trim();
		if (consulta.length < MINIMO_LETRAS) {
			// Se sube el contador para que una consulta que venia en camino no
			// llene la lista despues de haber borrado el texto.
			ultimaConsulta++;
			resultados = [];
			error = '';
			cargando = false;
			buscado = false;
			return;
		}

		retardo = setTimeout(() => lanzar(consulta), ESPERA);
	}

	function alEnfocar() {
		if (texto.trim().length >= MINIMO_LETRAS) abierto = true;
	}

	/** Cierra la lista sin borrar lo escrito. */
	function cerrar() {
		abierto = false;
		resaltada = -1;
	}

	/** Vacia el campo y lo deja listo para escribir otra vez. */
	function limpiar() {
		if (retardo) clearTimeout(retardo);
		ultimaConsulta++;
		texto = '';
		resultados = [];
		error = '';
		cargando = false;
		buscado = false;
		cerrar();
		campo?.focus();
	}

	/** Abre la ficha de un resultado. La ficha es la fuente de verdad. */
	async function abrir(r: ResultadoBusqueda) {
		cerrar();
		await goto(`/producto/${r.id_producto}`);
	}

	/** Manda a la pagina de resultados con lo que haya escrito. */
	async function verTodos() {
		const consulta = texto.trim();
		if (consulta.length < MINIMO_LETRAS) return;
		cerrar();
		await goto(`/buscar?q=${encodeURIComponent(consulta)}`);
	}

	/**
	 * El teclado dentro del campo.
	 *
	 * Enter con algo resaltado abre ese producto; Enter sin nada resaltado va a
	 * la pagina de resultados. Es lo que espera cualquiera que use un buscador:
	 * las flechas eligen, Enter a secas busca.
	 */
	function alTeclearEnCampo(evento: KeyboardEvent) {
		if (evento.key === 'Escape') {
			// Si la lista esta abierta, Escape la cierra. Si ya estaba cerrada,
			// vacia el campo: es el segundo Escape de siempre.
			if (abierto) cerrar();
			else limpiar();
			return;
		}

		if (evento.key === 'Enter') {
			evento.preventDefault();
			const elegida = resultados[resaltada];
			if (elegida) abrir(elegida);
			else verTodos();
			return;
		}

		if (evento.key !== 'ArrowDown' && evento.key !== 'ArrowUp') return;
		if (resultados.length === 0) return;

		evento.preventDefault();
		abierto = true;

		const total = resultados.length;
		const paso = evento.key === 'ArrowDown' ? 1 : -1;

		// Da la vuelta por los dos lados: bajar desde la ultima vuelve a la
		// primera. Frenar en el borde obliga a contar cuantas veces pulsaste.
		//
		// El -1 (ninguna marcada) se trata aparte y no con la misma cuenta: no
		// es una posicion de la lista, es "todavia no hay ninguna". Bajando
		// tiene que dar la primera y subiendo la ultima, y una sola formula con
		// modulo da la penultima en ese segundo caso.
		if (resaltada < 0) resaltada = paso === 1 ? 0 : total - 1;
		else resaltada = (resaltada + paso + total) % total;
	}

	/**
	 * Se escucha `pointerdown` y no `click` por lo mismo que el menu de cuenta
	 * de la cabecera: el clic de fuera puede caer sobre algo que desaparece con
	 * esa misma pulsacion, y entonces el `click` nunca llega a la ventana.
	 */
	function alPulsarFuera(evento: PointerEvent) {
		if (!abierto) return;
		const donde = evento.target;
		if (donde instanceof Node && caja?.contains(donde)) return;
		cerrar();
	}

	/**
	 * Tabular fuera de la caja tambien cierra. Si no, la lista se queda
	 * desplegada tapando la pagina mientras el foco ya anda por otro sitio.
	 */
	function alSalirElFoco(evento: FocusEvent) {
		if (!abierto) return;
		const hacia = evento.relatedTarget;
		if (hacia === null || !(hacia instanceof Node)) return;
		if (caja?.contains(hacia)) return;
		cerrar();
	}
</script>

<svelte:window onpointerdown={alPulsarFuera} />

<!-- role="search" para que un lector de pantalla pueda saltar aqui directo. -->
<div class="buscador" bind:this={caja} onfocusout={alSalirElFoco} role="search">
	<div class="campo">
		<svg class="lupa" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
			<circle cx="11" cy="11" r="7" />
			<path d="m20 20-3.6-3.6" stroke-linecap="round" />
		</svg>

		<input
			bind:this={campo}
			bind:value={texto}
			oninput={alEscribir}
			onfocus={alEnfocar}
			onkeydown={alTeclearEnCampo}
			type="text"
			placeholder="Buscar productos"
			aria-label="Buscar productos"
			autocomplete="off"
			spellcheck="false"
			role="combobox"
			aria-expanded={hayPanel}
			aria-controls="lista-buscador"
			aria-autocomplete="list"
			aria-activedescendant={resaltada >= 0 ? `resultado-${resaltada}` : undefined}
		/>

		{#if texto !== ''}
			<button type="button" class="borrar" onclick={limpiar} aria-label="Borrar la busqueda">
				<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
					<path d="M6 6l12 12M18 6L6 18" stroke-linecap="round" />
				</svg>
			</button>
		{/if}
	</div>

	<!-- La lista se pinta solo cuando hay algo que decir, y por eso el campo
	     lleva aria-expanded: es lo que le dice al lector de pantalla que ahora
	     hay resultados debajo, sin depender de que el id exista. -->
	{#if hayPanel}
		<div class="lista" id="lista-buscador" role="listbox" aria-label="Resultados de la busqueda">
			{#if cargando && resultados.length === 0}
				<p class="aviso">Buscando</p>
			{:else if error !== ''}
				<p class="aviso malo">{error}</p>
			{:else if resultados.length === 0}
				<p class="aviso">No hay productos que se parezcan a eso</p>
			{:else}
				{#each resultados as r, i (r.id_producto)}
					<button
						type="button"
						class="fila"
						class:marcada={i === resaltada}
						id="resultado-{i}"
						role="option"
						aria-selected={i === resaltada}
						onmouseenter={() => (resaltada = i)}
						onclick={() => abrir(r)}
					>
						<span class="texto">
							<span class="nombre">{r.nombre}</span>
							<span class="bajo">
								{#if r.categoria}<span class="cat">{r.categoria}</span>{/if}
								{#if nota(r)}<span class="dato">{nota(r)}</span>{/if}
								{#if r.stock_total <= 0}<span class="dato agotado">Sin existencias</span>{/if}
							</span>
						</span>

						<span class="cifras">
							{#if precioVisible(r)}
								<span class="precio">{precioVisible(r)}</span>
							{/if}
							{#if precioSegundo(r)}
								<span class="segundo">desde {precioSegundo(r)}</span>
							{/if}
						</span>
					</button>
				{/each}

				<!-- Con la lista llena hay motivo para creer que hay mas fuera, asi
				     que se ofrece la pagina de resultados. Con menos de las que
				     caben ya se estan viendo todas y el enlace sobraria. -->
				{#if resultados.length >= MAXIMO_EN_LISTA}
					<button type="button" class="todos" onclick={verTodos}>
						Ver todos los resultados de {texto.trim()}
					</button>
				{/if}
			{/if}
		</div>
	{/if}
</div>

<style>
	/* Ocupa lo que le den. Cuanto sitio es eso lo decide la cabecera, que es
	   quien sabe con que comparte la fila: aqui dentro no se puede saber si al
	   lado hay un carrito, una hamburguesa o nada. */
	.buscador {
		position: relative;
		width: 100%;
	}

	.campo {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		height: 38px;
		padding: 0 0.7rem;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		transition:
			border-color var(--t),
			background var(--t);
	}

	.campo:focus-within {
		border-color: var(--indigo);
		background: var(--blanco);
	}

	.lupa {
		width: 17px;
		height: 17px;
		flex: none;
		stroke-width: 1.8;
		color: var(--gris);
	}

	.campo input {
		flex: 1;
		min-width: 0;
		border: 0;
		background: none;
		outline: none;
		font-family: inherit;
		font-size: 0.93rem;
		color: var(--tinta);
	}

	.campo input::placeholder {
		color: var(--gris-2);
	}

	.borrar {
		flex: none;
		width: 22px;
		height: 22px;
		display: grid;
		place-items: center;
		padding: 0;
		background: none;
		border: 0;
		border-radius: 999px;
		color: var(--gris);
		cursor: pointer;
		transition: color var(--t);
	}

	.borrar:hover {
		color: var(--tinta);
	}

	.borrar svg {
		width: 14px;
		height: 14px;
		stroke-width: 2;
	}

	.lista {
		position: absolute;
		top: calc(100% + 8px);
		left: 0;
		right: 0;
		z-index: 100;
		padding: 0.3rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		/* Igual que el menu de cuenta: quien separa es el borde, esto solo
		   suaviza el corte, y va con una variable del tema porque un negro
		   translucido no se ve sobre el fondo oscuro. */
		box-shadow: 0 8px 20px var(--panel);
		/* En un portatil bajo, ocho filas se salen de la pantalla, asi que hay
		   tope. El numero esta MEDIDO, no elegido: cada fila mide 54px y con el
		   boton de "ver todos" la lista llena mide 481px. Con los 30rem (480px)
		   que habia antes se pasaba por UN pixel y salia una barra de
		   desplazamiento para nada, en el caso mas normal de todos. 34rem deja
		   holgura sin llegar a tapar la pagina. */
		max-height: min(70vh, 34rem);
		overflow-y: auto;
	}

	.aviso {
		margin: 0;
		padding: 0.85rem 0.7rem;
		font-size: 0.9rem;
		color: var(--gris);
	}

	.aviso.malo {
		color: var(--rojo);
	}

	.fila {
		width: 100%;
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.9rem;
		padding: 0.55rem 0.65rem;
		text-align: left;
		font-family: inherit;
		background: none;
		border: 0;
		border-radius: var(--r);
		color: var(--tinta);
		cursor: pointer;
		transition: background var(--t);
	}

	/* Una sola clase para el raton y para el teclado: si el hover pintara por
	   su cuenta, mover el raton sin querer dejaria dos filas marcadas y
	   ninguna de las dos seria la que abre el Enter. */
	.fila.marcada {
		background: var(--indigo-cl);
	}

	.texto {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
	}

	.nombre {
		font-size: 0.93rem;
		line-height: 1.3;
		/* Un nombre largo se corta en una linea: dos filas de distinta altura
		   hacen que la lista salte al bajar con las flechas. */
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.bajo {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		font-size: 0.78rem;
		color: var(--gris);
		overflow: hidden;
		white-space: nowrap;
	}

	.cat {
		color: var(--indigo);
	}

	.dato.agotado {
		color: var(--rojo);
	}

	.cifras {
		flex: none;
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		gap: 1px;
	}

	.precio {
		font-size: 0.9rem;
		font-weight: 600;
	}

	.segundo {
		font-size: 0.74rem;
		color: var(--gris);
	}

	.todos {
		width: 100%;
		margin-top: 0.25rem;
		padding: 0.6rem;
		font-family: inherit;
		font-size: 0.86rem;
		color: var(--indigo);
		background: none;
		border: 0;
		border-top: 1px solid var(--linea);
		border-radius: 0 0 var(--r) var(--r);
		cursor: pointer;
		transition: background var(--t);
		/* Lo que se escribio puede ser largo; el boton no crece por eso. */
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.todos:hover {
		background: var(--indigo-cl);
	}

	/* En pantalla chica el buscador se queda; lo que hace la cabecera es
	   bajarlo a su propia fila, porque compartiendola con el carrito y la
	   hamburguesa no le queda ancho ni para el marcador. Aqui solo se encoge
	   un poco para que la fila sea mas baja. */
	@media (max-width: 720px) {
		.campo {
			height: 34px;
			padding: 0 0.55rem;
		}

		.campo input {
			font-size: 0.88rem;
		}
	}
</style>
