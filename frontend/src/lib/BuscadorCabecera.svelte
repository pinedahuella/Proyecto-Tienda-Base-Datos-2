<script lang="ts">
	import { untrack } from 'svelte';
	import { goto } from '$app/navigation';
	import {
		buscarProductos,
		precioVisible,
		precioSegundo,
		nota,
		marcaDeEstado,
		MINIMO_LETRAS,
		type ResultadoBusqueda
	} from './buscador';
	import { registrarClicBusqueda } from './eventos';

	/**
	 * Buscar tambien lo que no esta activo. Solo tiene sentido para un admin:
	 * la ruta que lo permite le contesta 403 a cualquier otro, la tienda
	 * incluida. Quien lo decide es la cabecera, que es quien sabe el rol.
	 */
	let { verTodo = false }: { verTodo?: boolean } = $props();

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

	async function lanzar(consulta: string, todo = verTodo) {
		const mia = ++ultimaConsulta;
		cargando = true;

		const salida = await buscarProductos(consulta, MAXIMO_EN_LISTA, todo);

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

	/**
	 * El rol llega TARDE, y eso cambia con que ruta hay que buscar.
	 *
	 * La cabecera pregunta quien esta dentro con una peticion, asi que durante
	 * los primeros instantes de la pagina `verTodo` todavia es false aunque
	 * quien mire sea admin. Si en ese hueco ya se escribio algo, la busqueda
	 * salio por la ruta publica y devolvio solo lo activo: un admin que teclea
	 * rapido veia una lista distinta de la que vera un segundo despues, sin
	 * ninguna pista de por que.
	 *
	 * Cuando el rol llega, se repite la busqueda que hay en pantalla. Solo
	 * depende de `verTodo`: lo demas se lee con untrack para que escribir no
	 * dispare esto ademas del retardo normal, que serian dos peticiones por
	 * tecla.
	 */
	$effect(() => {
		const todo = verTodo;
		untrack(() => {
			if (!buscado && !cargando) return;
			const consulta = texto.trim();
			if (consulta.length < MINIMO_LETRAS) return;
			lanzar(consulta, todo);
		});
	});

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

	/**
	 * Abre la ficha de un resultado. La ficha es la fuente de verdad.
	 *
	 * `posicion` es 1-based (el primero de la lista es 1, no 0) porque asi lo
	 * pide `POST /eventos/busqueda-clic` -- es el lugar en el que estaba en
	 * ESTA lista, no un indice de arreglo. No se manda en la busqueda de
	 * admin (`verTodo`): las mismas razones que ya evitan el `sesion` en
	 * `buscador.ts` aplican aqui.
	 */
	async function abrir(r: ResultadoBusqueda, posicion: number) {
		if (!verTodo) registrarClicBusqueda(texto.trim(), r.id_producto, posicion);
		cerrar();
		await goto(`/producto/${r.id_producto}?origen=buscador`);
	}

	/** Manda a la pagina de resultados con lo que haya escrito. */
	async function verTodos() {
		const consulta = texto.trim();
		if (consulta.length < MINIMO_LETRAS) return;
		cerrar();
		await goto(`/buscar?q=${encodeURIComponent(consulta)}${verTodo ? '&todo=1' : ''}`);
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
			if (elegida) abrir(elegida, resaltada + 1);
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
	<!-- `abierta` le quita las esquinas de abajo y el borde inferior al campo:
	     con la lista desplegada los dos son UNA pieza, no un recuadro flotando
	     debajo de otro recuadro. -->
	<div class="campo" class:abierta={hayPanel}>
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
						onclick={() => abrir(r, i + 1)}
					>
						<span class="texto">
							<span class="nombre">{r.nombre}</span>
							<span class="bajo">
								{#if r.categoria}<span class="cat">{r.categoria}</span>{/if}
								{#if marcaDeEstado(r)}
									<span class="estado">{marcaDeEstado(r)}</span>
								{/if}
								{#if r.hay_descuento}<span class="descuento">Con descuento</span>{/if}
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
		position: relative;
		/* Por encima de la lista, para que su borde de abajo tape la union y
		   los dos se lean como una sola pieza. */
		z-index: 101;
		display: flex;
		align-items: center;
		gap: var(--e2);
		height: 38px;
		padding: 0 0.7rem;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		transition:
			border-color var(--t),
			background var(--t);
	}

	/* El foco se marca en la CAJA, que es lo que la persona ve como el control.
	   El halo va aqui y no en el input, para que sea un solo objeto que se
	   ilumina y no dos rectangulos, uno dentro del otro. */
	.campo:focus-within {
		border-color: var(--indigo);
		background: var(--blanco);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	/* Con la lista abierta el halo se quita: ahi el campo ya no es un control
	   suelto sino la tapa del panel, y un anillo alrededor de la tapa la
	   volveria a separar de la lista. */
	.campo.abierta:focus-within {
		box-shadow: none;
	}

	/* Con la lista abierta, el campo es la TAPA de la lista: pierde las
	   esquinas de abajo, se queda sin borde inferior y pasa a fondo blanco.
	   Sin esto se veian dos rectangulos sueltos, uno encima del otro. */
	.campo.abierta {
		background: var(--blanco);
		border-color: var(--indigo);
		border-bottom-color: transparent;
		border-bottom-left-radius: 0;
		border-bottom-right-radius: 0;
	}

	.lupa {
		width: 17px;
		height: 17px;
		flex: none;
		stroke-width: 1.8;
		color: var(--gris);
	}

	/* El input renuncia a TODA la caja que el layout le da a los campos.
	   ESTE ES EL RECUADRO DENTRO DEL RECUADRO.

	   `+layout.svelte` le pone a cada `input` del proyecto borde, esquinas,
	   relleno de 8px 11px y, al enfocar, `box-shadow: 0 0 0 3px` -- un halo
	   redondeado. Eso esta bien en un formulario, donde el input ES la caja.
	   Aqui la caja es `.campo`, y el input va dentro: al hacer clic aparecia
	   un segundo rectangulo redondeado flotando dentro del primero, que es
	   exactamente lo que se veia mal.

	   Antes solo se quitaba el borde. Habia que quitar tambien el relleno, las
	   esquinas y sobre todo la sombra del foco, en el estado normal y en el
	   enfocado -- si no, la regla global gana cuando el campo tiene el foco,
	   que es justo el momento en el que se mira. */
	.campo input,
	.campo input:hover,
	.campo input:focus {
		flex: 1;
		min-width: 0;
		padding: 0;
		border: 0;
		border-radius: 0;
		background: none;
		box-shadow: none;
		outline: none;
		font-family: inherit;
		font-size: var(--f-base);
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

	/* Cuelga PEGADA al campo, sin hueco: `top: 100%` y no `100% + 8px`. El
	   hueco de antes es lo que la convertia en un segundo cuadro suelto. */
	.lista {
		position: absolute;
		top: 100%;
		left: 0;
		right: 0;
		z-index: 100;
		padding: 0.25rem 0 0;
		background: var(--blanco);
		border: 1px solid var(--indigo);
		border-top: 0;
		border-radius: 0 0 var(--r) var(--r);
		/* Una sombra de verdad, del tema. Es lo que dice "esto esta ENCIMA de
		   la pagina"; sin ella el panel se leia como un recuadro mas. */
		box-shadow: var(--sombra);
		/* En un portatil bajo, ocho filas se salen de la pantalla, asi que hay
		   tope. El numero esta MEDIDO, no elegido: con las filas de ahora la
		   lista llena mide algo menos de 30rem, y 32rem deja holgura sin
		   llegar a tapar la pagina. */
		max-height: min(70vh, 32rem);
		overflow-y: auto;
		/* Para que las esquinas de abajo recorten de verdad la ultima fila. */
		overscroll-behavior: contain;
	}

	.aviso {
		margin: 0;
		padding: 0.85rem 0.85rem 1rem;
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.aviso.malo {
		color: var(--rojo);
	}

	/* Sin esquinas redondeadas y de borde a borde: una fila con su propio
	   recuadro dentro del panel es otra caja dentro de otra caja. La marca de
	   seleccion es una banda, no una tarjeta. */
	.fila {
		position: relative;
		width: 100%;
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		padding: 0.5rem 0.85rem;
		text-align: left;
		font-family: inherit;
		background: none;
		border: 0;
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

	/* Una barra en el canto izquierdo de la marcada. Con solo el fondo, en
	   tema oscuro el --indigo-cl es muy cercano al panel y desde lejos no se
	   sabia cual iba a abrir el Enter. */
	.fila.marcada::before {
		content: '';
		position: absolute;
		left: 0;
		top: 0;
		bottom: 0;
		width: 3px;
		background: var(--indigo);
	}

	.texto {
		display: flex;
		flex-direction: column;
		gap: var(--e1);
		min-width: 0;
	}

	.nombre {
		font-size: var(--f-base);
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
		gap: var(--e2);
		font-size: var(--f-xs);
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

	/* Solo sale en la busqueda de admin, que es la unica que trae productos que
	   no estan activos. Va con caja porque "rechazado" en texto plano, entre la
	   categoria y la nota, se lee como una palabra mas de la fila. */
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
	}

	.precio {
		font-size: var(--f-ms);
		font-weight: 600;
	}

	.segundo {
		font-size: var(--f-xs);
		color: var(--gris);
	}

	/* El pie del panel, no un enlace suelto: banda propia, pegado abajo y del
	   ancho entero. Asi se lee como parte de la misma pieza. */
	.todos {
		width: 100%;
		margin-top: 0.25rem;
		padding: 0.62rem 0.85rem;
		text-align: left;
		font-family: inherit;
		font-size: var(--f-ms);
		font-weight: 500;
		color: var(--indigo);
		background: var(--off);
		border: 0;
		border-top: 1px solid var(--linea);
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

		/* Los tres estados, como arriba: con solo `.campo input` la regla del
		   bloque de arriba para `:focus` (mas especifica) le devolvia el
		   tamano de escritorio en cuanto se tocaba el campo, y la letra
		   pegaba un salto justo al empezar a escribir. */
		.campo input,
		.campo input:hover,
		.campo input:focus {
			font-size: var(--f-ms);
		}
	}
</style>
