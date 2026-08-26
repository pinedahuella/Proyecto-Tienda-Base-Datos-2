<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import MarcaMesh from './MarcaMesh.svelte';
	import BotonTema from './BotonTema.svelte';
	import { pedir } from './api';
	import { cerrarSesion, leerSesion, verificarSesion } from './sesion';
	import { carrito } from './estadoCarrito.svelte';

	/**
	 * Cabecera del sitio. Se queda pegada arriba al bajar.
	 *
	 * Lleva el logotipo, que siempre vuelve al catalogo. Cuando hay sesion
	 * aparecen el carrito, "Mis pedidos", "Mi perfil" y salir; cuando no la
	 * hay, el enlace para entrar.
	 *
	 * **La averigua sola si no se la pasan.** Antes la prop era `sesion = null`
	 * y CUATRO de las cinco paginas la montaban sin pasarle nada -- el
	 * catalogo, la ficha, entrar y registro -- asi que todas pintaban "Iniciar
	 * sesion" aunque la cookie estuviera perfecta. Pulsar el logotipo estando
	 * dentro parecia cerrar la sesion: no la cerraba, solo lo aparentaba, y
	 * volver al panel te seguia enseñando tu cuenta.
	 *
	 * Quien SI le pasa `sesion` (el panel, que ya trae el perfil) sigue
	 * mandando: la prop gana y no se hace una segunda consulta.
	 *
	 * **En pantalla chica la navegacion se agrupa tras la hamburguesa.** Antes
	 * el correo se escondia con un @media y ya: eso hacia caber la fila, pero
	 * dejaba a la persona sin saber con que cuenta estaba dentro. Ahora el
	 * correo, "Mi panel" y "Salir" viven en el menu, y lo que NO entra ahi es
	 * el carrito: es la accion principal de una tienda y su burbuja tiene que
	 * verse siempre, asi que se queda fuera, al lado de la hamburguesa.
	 */
	let {
		sesion = undefined,
		alSalir
	}: { sesion?: string | null | undefined; alSalir?: () => void } = $props();

	/** Lo que averiguo por mi cuenta, cuando nadie me pasa la sesion. */
	let propia = $state<string | null>(null);

	/** La prop manda si viene; si no, lo que averigüe yo. */
	let correo = $derived(sesion !== undefined ? sesion : propia);

	onMount(async () => {
		// Si me la pasan, no pregunto: el panel ya hizo esa consulta.
		if (sesion !== undefined) return;

		// Primero lo guardado, para no parpadear mientras se pregunta. Es
		// justo para esto que existe leerSesion(); quien manda es el backend.
		propia = leerSesion();

		try {
			const usuario = await verificarSesion();
			propia = usuario?.correo_electronico ?? null;
			// La burbuja del carrito solo se cuenta si hay alguien dentro: sin
			// sesion, /comprador/pedidos contesta 401 y no hay nada que contar.
			if (usuario) await carrito.recontar();
		} catch {
			// SesionIndeterminada: se cayo el servidor, NO la sesion. Sacar a
			// alguien aqui seria mentirle: se deja lo que ya se sabia.
		}
	});

	/**
	 * Salir cuando la pagina no trae su propio manejador.
	 *
	 * El catalogo y la ficha no tenian ninguno, asi que el boton habria
	 * quedado de adorno.
	 */
	async function salirPorMiCuenta() {
		await pedir('/usuario/logout', { method: 'POST' });
		cerrarSesion();
		propia = null;
		// La cuenta del carrito era de quien se fue. Dejarla puesta le ensena
		// a la siguiente persona una burbuja con cosas que no son suyas.
		carrito.olvidar();
		await goto('/');
	}

	// ------------------------------------------------------- menu de cuenta
	let menuAbierto = $state(false);

	/** La hamburguesa y su menu. Es lo que decide que es "fuera". */
	let caja = $state<HTMLElement | null>(null);
	/** Para devolverle el foco al cerrar con Escape. */
	let botonMenu = $state<HTMLButtonElement | null>(null);

	/**
	 * Cierra y, si se pide, devuelve el foco a la hamburguesa.
	 *
	 * Sin devolverlo, cerrar con Escape deja el foco en un elemento que acaba
	 * de desaparecer de la pantalla y el siguiente Tab arranca desde el
	 * principio del documento.
	 */
	function cerrarMenu(devolverFoco = false) {
		menuAbierto = false;
		if (devolverFoco) botonMenu?.focus();
	}

	function salirDesdeMenu() {
		cerrarMenu();
		(alSalir ?? salirPorMiCuenta)();
	}

	function alTeclear(evento: KeyboardEvent) {
		if (!menuAbierto || evento.key !== 'Escape') return;
		cerrarMenu(true);
	}

	/**
	 * Se escucha `pointerdown` y no `click`: el clic de fuera puede caer sobre
	 * algo que se mueve o desaparece con la misma pulsacion, y entonces el
	 * `click` nunca llega a la ventana y el menu se queda abierto.
	 */
	function alPulsarFuera(evento: PointerEvent) {
		if (!menuAbierto) return;
		const donde = evento.target;
		if (donde instanceof Node && caja?.contains(donde)) return;
		cerrarMenu();
	}

	/**
	 * Tabular mas alla de la ultima opcion tambien cierra: si no, el foco se va
	 * a la pagina de atras y el menu se queda abierto encima, tapandola.
	 *
	 * `relatedTarget` nulo quiere decir que el foco se fue a ninguna parte (un
	 * clic sobre algo que no lo toma); de eso ya se encarga alPulsarFuera, y
	 * cerrar aqui tambien romperia el clic sobre la propia hamburguesa.
	 */
	function alSalirElFoco(evento: FocusEvent) {
		if (!menuAbierto) return;
		const hacia = evento.relatedTarget;
		if (hacia === null || !(hacia instanceof Node)) return;
		if (caja?.contains(hacia)) return;
		cerrarMenu();
	}

	/**
	 * Quien esconde el menu en pantalla grande es el CSS, no este estado: asi
	 * no hay parpadeo en el primer pintado. Pero entonces un menu abierto al
	 * que se le ensancha la ventana queda abierto e invisible, y reaparece al
	 * volver a angostarla. Se cierra al dejar de estar en pantalla chica.
	 *
	 * Es LA MISMA consulta del @media de abajo, palabra por palabra, y se
	 * cierra cuando deja de cumplirse. Con la complementaria escrita a mano
	 * (`min-width: 721px`) quedaba una franja de menos de un pixel donde no se
	 * cumple ninguna de las dos: el ancho de la ventana no siempre es entero
	 * --con zoom o con la escala de Windows no lo es-- y ahi el CSS ya escondia
	 * el menu pero esto no lo cerraba, que es justo el fallo que evita.
	 */
	$effect(() => {
		const consulta = window.matchMedia('(max-width: 720px)');
		const alCambiar = () => {
			if (!consulta.matches) menuAbierto = false;
		};
		consulta.addEventListener('change', alCambiar);
		return () => consulta.removeEventListener('change', alCambiar);
	});
</script>

<svelte:window onkeydown={alTeclear} onpointerdown={alPulsarFuera} />

<header>
	<div class="env barra">
		<MarcaMesh href="/" />

		<div class="cuenta">
			{#if correo}
				<!-- El carrito se abre desde cualquier pagina: el panel es uno solo
				     y vive en el layout, aqui solo esta el boton que lo llama. -->
				<button
					type="button"
					class="salir carro"
					onclick={() => carrito.alternar()}
					aria-label="Ver mi carrito"
				>
					Carrito
					{#if carrito.cuenta > 0}
						<span class="burbuja">{carrito.cuenta}</span>
					{/if}
				</button>

				<!-- En pantalla grande, la fila de siempre.

				     El correo NO va aqui: ocupaba el sitio de una accion y no es una.
				     Quien quiera saber con que cuenta esta dentro lo mira en su
				     perfil, que es donde vive esa informacion. -->
				<div class="fila">
					<a class="salir" href="/pedidos">Mis pedidos</a>
					<!-- Sin esto, desde el catalogo no habia forma de volver al panel
					     mas que escribiendo la direccion a mano. -->
					<a class="salir" href="/panel">Mi perfil</a>
					<button type="button" class="salir" onclick={alSalir ?? salirPorMiCuenta}>Salir</button>
				</div>

				<!-- Y en pantalla chica, lo mismo detras de la hamburguesa. El menu
				     se pinta siempre y se ensena con una clase, no con un {#if}: asi
				     el id al que apunta aria-controls existe tambien cerrado, que es
				     lo que el lector de pantalla necesita para anunciar que controla
				     el boton. -->
				<div class="envoltura" bind:this={caja} onfocusout={alSalirElFoco}>
					<button
						type="button"
						class="hamburguesa"
						bind:this={botonMenu}
						aria-label={menuAbierto ? 'Cerrar el menu de mi cuenta' : 'Abrir el menu de mi cuenta'}
						aria-expanded={menuAbierto}
						aria-controls="menu-cuenta"
						onclick={() => (menuAbierto = !menuAbierto)}
					>
						<svg
							viewBox="0 0 24 24"
							fill="none"
							stroke="currentColor"
							stroke-width="1.7"
							aria-hidden="true"
						>
							<path d="M4 7h16M4 12h16M4 17h16" stroke-linecap="round" />
						</svg>
					</button>

					<div id="menu-cuenta" class="menu" class:abierto={menuAbierto}>
						<a class="opcion" href="/pedidos" onclick={() => cerrarMenu()}>Mis pedidos</a>
						<a class="opcion" href="/panel" onclick={() => cerrarMenu()}>Mi perfil</a>
						<button type="button" class="opcion" onclick={salirDesdeMenu}>Salir</button>
					</div>
				</div>
			{:else}
				<!-- Sin sesion no hay nada que agrupar: dos cosas caben en cualquier
				     pantalla, y un menu para una sola opcion seria un clic de mas. -->
				<a class="salir" href="/entrar">Iniciar sesion</a>
			{/if}
			<BotonTema />
		</div>
	</div>
</header>

<style>
	header {
		position: sticky;
		top: 0;
		z-index: 90;
		background: var(--blanco);
		border-bottom: 1px solid var(--linea);
	}

	.barra {
		display: flex;
		align-items: center;
		gap: 1.5rem;
		height: 68px;
	}

	.cuenta {
		margin-left: auto;
		display: flex;
		align-items: center;
		gap: 1rem;
	}

	/* Mismo gap que .cuenta: envolver los tres no debe mover ni un pixel de lo
	   que ya se veia en pantalla grande. */
	.fila {
		display: flex;
		align-items: center;
		gap: 1rem;
	}

	.salir {
		display: inline-block;
		text-decoration: none;
		padding: 8px 16px;
		font-family: inherit;
		font-size: 0.95rem;
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.salir:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	/* El boton del carrito lleva la burbuja pegada arriba a la derecha, asi
	   que necesita ser el contexto de posicion de esa burbuja. */
	.carro {
		position: relative;
	}

	.burbuja {
		position: absolute;
		top: -7px;
		right: -7px;
		min-width: 19px;
		height: 19px;
		padding: 0 5px;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		font-size: 0.72rem;
		line-height: 1;
		color: var(--blanco);
		background: var(--indigo);
		border-radius: 999px;
	}

	/* ---------- la hamburguesa y su menu ---------- */

	/* De aqui cuelga el menu, y es tambien lo que decide que es "fuera". */
	.envoltura {
		display: none;
		position: relative;
	}

	/* Cuadrada como el boton de tema, para que la pareja se lea como una. */
	.hamburguesa {
		width: 38px;
		height: 38px;
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

	.hamburguesa:hover,
	.hamburguesa[aria-expanded='true'] {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.hamburguesa svg {
		width: 20px;
		height: 20px;
	}

	.menu {
		display: none;
		position: absolute;
		top: calc(100% + 10px);
		right: 0;
		/* 15rem, no 12: con 12 un correo corriente se partia a la mitad de una
		   palabra ("...@mesh.co / m"), y este es el unico sitio donde en telefono
		   se ve con que cuenta estas. Medido a 320px, que es la pantalla mas
		   angosta que se sigue usando, el menu entero todavia entra. */
		min-width: 15rem;
		/* Uno mas largo si se parte, pero nunca se sale: el menu cuelga del borde
		   derecho, asi que sin tope creceria hacia fuera de la pantalla. */
		max-width: 72vw;
		padding: 0.35rem;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		/* Quien separa el menu de lo que tapa es el borde; esto es solo un halo
		   que suaviza el corte. Va con una variable del tema y no con un negro
		   translucido porque un negro sobre el fondo oscuro no se ve. Ojo con
		   leerlo como una sombra de verdad: --panel es opaco, asi que en el
		   tema oscuro queda mas claro que el fondo, no mas oscuro. */
		box-shadow: 0 8px 20px var(--panel);
	}

	.menu.abierto {
		display: flex;
		flex-direction: column;
	}

	.opcion {
		display: block;
		width: 100%;
		padding: 0.55rem 0.65rem;
		text-align: left;
		text-decoration: none;
		font-family: inherit;
		font-size: 0.95rem;
		color: var(--tinta);
		background: none;
		border: 0;
		border-radius: var(--r);
		cursor: pointer;
		transition:
			background var(--t),
			color var(--t);
	}

	.opcion:hover {
		background: var(--indigo-cl);
		color: var(--indigo);
	}

	/* En telefono la navegacion se agrupa: solo quedan sueltos el carrito y el
	   tema, que son de un toque y no admiten un paso intermedio. */
	@media (max-width: 720px) {
		.fila {
			display: none;
		}

		.envoltura {
			display: block;
		}

		.barra {
			height: 60px;
			gap: 0.75rem;
		}

		.cuenta {
			gap: 0.6rem;
		}

		.salir {
			padding: 7px 12px;
			font-size: 0.9rem;
		}
	}
</style>
