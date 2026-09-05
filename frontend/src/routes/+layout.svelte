<script lang="ts">
	import { goto } from '$app/navigation';
	import Trama from '$lib/Trama.svelte';
	import CarritoRedis from '$lib/CarritoRedis.svelte';
	import Checkout from '$lib/Checkout.svelte';
	import { carrito } from '$lib/estadoCarrito.svelte';
	import { cerrarSesion, leerSesion } from '$lib/sesion';
	import { olvidarPedidoAbierto, type LineaPedido, type ResultadoCompra } from '$lib/pedido';

	let { children } = $props();

	/**
	 * El carrito y el checkout viven AQUI, no en cada pagina.
	 *
	 * Son uno solo para todo el sitio: se abren desde la ficha al agregar algo,
	 * desde el boton de la cabecera y desde el panel. Montados por pagina,
	 * cambiar de pantalla cerraria el carrito a media compra, y la burbuja de
	 * la cabecera contaria una cosa distinta de la que el panel ensena.
	 */
	let checkoutAbierto = $state(false);
	let idPedidoAComprar = $state<string | null>(null);
	let lineasAComprar = $state<LineaPedido[]>([]);

	/**
	 * El carrito no compra: avisa de que hay que comprar y se aparta.
	 *
	 * Para cuando llega aqui, el carrito ya dejo el pedido con EXACTAMENTE las
	 * lineas marcadas (las demas las quito, con su paso de confirmacion). El
	 * backend compra el pedido entero, asi que las lineas que se pasan sirven
	 * para pintar el resumen del checkout, no para elegir que se cobra.
	 */
	function alPedirComprar(idPedido: string, lineas: LineaPedido[]) {
		// idPedido llega vacio y esta bien: con el carrito en Redis el pedido
		// NO existe todavia -- lo crea POST /carrito/comprar, en la misma
		// transaccion en que lo compra. El checkout va en modo "carrito" y no
		// lo necesita; las lineas siguen sirviendo para pintar el resumen.
		idPedidoAComprar = idPedido || null;
		lineasAComprar = lineas;
		carrito.cerrar();
		checkoutAbierto = true;
	}

	function alComprado(resultado: ResultadoCompra) {
		const comprado = idPedidoAComprar;

		checkoutAbierto = false;
		// Ya no hay id de pedido guardado que olvidar: el carrito vive en Redis
		// y lo borra el propio backend tras el COMMIT de la compra. Se sigue
		// llamando a olvidarPedidoAbierto() una vez para limpiar el localStorage
		// de quien venia del carrito viejo -- si no, esa llave se queda ahi
		// para siempre sin que nada la lea.
		olvidarPedidoAbierto();
		carrito.fijarCuenta(0);
		idPedidoAComprar = null;
		lineasAComprar = [];

		// Y se sale de la pantalla en la que estaba.
		//
		// Antes la compra terminaba aqui: se cerraba el checkout y la persona
		// se quedaba en la misma ficha, enseñando las existencias de ANTES de
		// comprar. El descuento habia pasado en la base, pero en pantalla no
		// se movia nada.
		//
		// El id sale de `resultado` si el backend lo devolvio, y si no del que
		// se mando a comprar: son el mismo pedido, pero el segundo es texto y
		// el primero puede venir como numero (los bigint del proyecto viajan
		// como texto a proposito, asi que no se pasa por Number, se pasa a
		// String).
		const id = resultado.id_pedido != null ? String(resultado.id_pedido) : comprado;
		goto(id ? `/gracias?pedido=${encodeURIComponent(id)}` : '/gracias');
	}

	/**
	 * El carrito contesto 401. Hay que distinguir DOS casos que llegan aqui
	 * por el mismo camino y no son lo mismo.
	 *
	 * Si habia sesion, se vencio: se limpia y se manda a entrar, que es lo que
	 * esta funcion hacia siempre.
	 *
	 * Si NO habia sesion, ese 401 solo dice "no has entrado", que para el
	 * catalogo es lo normal: es publico. Y mandar a /entrar ahi rompia la
	 * tienda entera para cualquiera que no hubiera entrado todavia.
	 * `CarritoRedis` vive en este layout y pide el carrito al montarse, o sea
	 * en TODAS las paginas, asi que abrir la portada te sacaba a /entrar antes
	 * de poder ver un solo producto. Comprobado en el navegador: se abre / y
	 * la direccion termina en /entrar sin haber pulsado nada.
	 *
	 * No se arregla en CarritoRedis a proposito: el que sabe si habia sesion
	 * es el sitio, no el panel del carrito, y el panel ya deja dicho que no
	 * navega por su cuenta.
	 */
	function sesionExpirada() {
		const habiaSesion = leerSesion() !== null;

		cerrarSesion();
		carrito.olvidar();
		checkoutAbierto = false;

		if (habiaSesion) goto('/entrar');
	}
</script>

<!-- La trama va fija detras de todo: es el fondo de la marca -->
<Trama />

<!-- Columna: cabecera, contenido que crece, y pie siempre hasta abajo -->
<div class="sitio">
	{@render children()}
</div>

<!-- El carrito de la Entrega 2: vive en Redis. Reemplazo a Carrito.svelte,
     que leia una fila de `pedido` en `pendiente` de PostgreSQL con su id en
     localStorage. Ya no hay id que guardar: el carrito es de la CUENTA. -->
<CarritoRedis
	abierto={carrito.abierto}
	alCerrar={() => carrito.cerrar()}
	alExpirarSesion={sesionExpirada}
	{alPedirComprar}
/>

<Checkout
	abierto={checkoutAbierto}
	idPedido={idPedidoAComprar}
	lineas={lineasAComprar}
	modo="carrito"
	alCerrar={() => (checkoutAbierto = false)}
	{alComprado}
	alExpirarSesion={sesionExpirada}
/>

<style>
	/* ══════════════════════════════════════════════════════════
	   MESH

	   Fondo claro con la trama azul de la marca, tinta calida (no
	   negro puro), titulares grandes en peso ligero, cuerpo de 16px.
	   El indigo es el tinte del comercio textil desde hace siglos, y
	   Mesh es un tejido: de ahi sale toda la paleta.
	   ══════════════════════════════════════════════════════════ */

	:global(:root) {
		/* El tema de Mesh lo manda data-tema, no el sistema operativo, y hay que
		   decirselo a Chrome: lo que el navegador pinta por su cuenta -- el fondo
		   de los campos autocompletados, los iconos nativos, la barra de scroll --
		   sale del color-scheme, no de la paleta de abajo. Sin esta linea Chrome
		   asumia "claro" siempre, asi que con la app en oscuro autocompletaba con
		   su azul palido (rgb(232,240,254)) debajo de un texto casi blanco
		   (--tinta) y no se veia lo que uno escribia. Con color-scheme puesto,
		   Chrome usa su fondo oscuro y el problema desaparece de raiz, en TODOS
		   los estados de autocompletado -- incluida la vista previa del
		   desplegable de sugerencias, que ninguna regla de CSS puede alcanzar. */
		color-scheme: light;

		--tinta: #16181f;
		--texto: #3a3e49;
		/* Los grises estan medidos contra el fondo, no elegidos a ojo: con los
		   anteriores el texto secundario quedaba en 2.7 de contraste y se perdia.
		   El minimo legible es 4.5. */
		--gris: #545965;
		--gris-2: #676c78;
		--linea: #e3e1dc;
		--panel: #f5f3ef;
		--off: #faf9f6;
		--blanco: #ffffff;

		--indigo: #2f3a8f;
		--indigo-os: #242d72;
		--indigo-cl: #e8ebf7;

		--rojo: #b3352c;
		--rojo-cl: #fbeceb;

		/* El texto que va ENCIMA del indigo. En claro el indigo es oscuro y
		   lleva letra blanca; en oscuro el indigo se aclara para verse sobre
		   el fondo, asi que la letra tiene que oscurecerse o el boton
		   principal queda ilegible. Por eso es una variable y no un blanco
		   fijo: es el unico color que se invierte entre los dos temas. */
		--sobre-indigo: #ffffff;
		--sobre-rojo: #ffffff;

		/* La trama va apenas por encima del fondo. Si se sube mas, los hilos
		   cruzan por detras de las letras y el texto se vuelve dificil de leer. */
		--hilo: #e6eaf6;

		--ancho: 1185px;
		--r: 6px;
		--r2: 10px;
		--t: 0.18s ease;

		/* La sombra de lo que FLOTA por encima de la pagina: la lista del
		   buscador y los menus.
		   Hacia falta una de verdad. Lo que habia era `box-shadow` con --panel,
		   que es un color OPACO del tema y no una sombra: en claro casi no se
		   distinguia del fondo y en oscuro quedaba mas claro que la pagina, o
		   sea un halo al reves. Sin elevacion, un panel flotante se lee como un
		   segundo recuadro pegado debajo del primero en vez de como algo que
		   esta encima -- que es justo lo que se veia mal en el buscador. */
		--sombra: 0 16px 36px rgba(22, 24, 31, 0.16), 0 2px 6px rgba(22, 24, 31, 0.07);
	}

	/* Tema oscuro. Los nombres significan lo mismo: --tinta es siempre el texto
	   principal y --blanco la superficie de las tarjetas. Asi ningun componente
	   necesita saber en que tema esta. */
	:global(html[data-tema='oscuro']) {
		color-scheme: dark;

		--tinta: #edeff7;
		--texto: #bcc2d2;
		--gris: #a6adc0;
		--gris-2: #949bb0;
		--linea: #262c45;
		--panel: #161b31;
		--off: #0f1428;
		--blanco: #141a33;

		--indigo: #8a9ae4;
		--indigo-os: #a3b0ec;
		--indigo-cl: #1c2447;

		--rojo: #e08b81;
		--rojo-cl: #2e1b1a;

		/* Se invierten: aqui el indigo y el rojo son claros. */
		--sobre-indigo: #10142a;
		--sobre-rojo: #2a1210;

		/* Mas negra y mas cerrada que en claro: sobre un fondo oscuro una
		   sombra suave no se ve, y lo que separa al panel flotante de la
		   pagina deja de existir. */
		--sombra: 0 18px 40px rgba(0, 0, 0, 0.6), 0 2px 8px rgba(0, 0, 0, 0.45);

		--hilo: #191f3a;
	}

	:global(*),
	:global(*::before),
	:global(*::after) {
		box-sizing: border-box;
		margin: 0;
		padding: 0;
	}

	:global(body) {
		font-family:
			'Segoe UI', system-ui, -apple-system, Roboto, 'Helvetica Neue', Arial, sans-serif;
		font-size: 16px;
		line-height: 1.5;
		color: var(--texto);
		background: var(--off);
		-webkit-font-smoothing: antialiased;
		/* La trama es fija y mide 100% del ancho: sin esto, cuando aparece la
		   barra de desplazamiento vertical se cuela un desplazamiento lateral. */
		overflow-x: hidden;
	}

	/* El pie queda hasta abajo aunque la pagina tenga poco contenido */
	.sitio {
		position: relative;
		z-index: 1;
		display: flex;
		flex-direction: column;
		min-height: 100vh;
	}

	:global(.sitio > main) {
		flex: 1;
	}

	/* Titulares grandes en peso 400: eso es lo que da el aire */
	:global(h1),
	:global(h2),
	:global(h3),
	:global(h4) {
		font-weight: 400;
		color: var(--tinta);
		letter-spacing: 0;
	}
	:global(h1) {
		font-size: clamp(2rem, 3.4vw, 2.75rem);
		line-height: 1.15;
	}
	:global(h2) {
		font-size: clamp(1.4rem, 2.2vw, 1.85rem);
		line-height: 1.2;
	}
	:global(h3) {
		font-size: 1.15rem;
		line-height: 1.4;
		font-weight: 500;
	}

	:global(a) {
		color: inherit;
	}

	/* ══════════════════════════════════════════════════════════
	   CONTROLES

	   Un <button> del navegador NO hereda la tipografia: sale en
	   Arial 13.3px con su caja gris. Medido en el panel: 185 de 192
	   botones salian asi. No era que nadie estilara nada -- 15 de los
	   21 componentes lo hacian -- sino que cada uno cubria lo suyo y
	   nadie cubria el resto; OfertasVendedor, con 13 botones, no
	   tenia ni una regla. Esto lo arregla de raiz.

	   La base es la que ya usaba `.salir` de Cabecera.svelte, que es
	   el boton que se veia bien: esa era la forma de la casa, solo
	   que estaba escrita en un archivo y no en todos.

	   La regla BASE cede ante el componente a proposito: Svelte
	   compila un `button` con ambito a `button.svelte-xxxx` (0,1,1)
	   y `:global(button)` es (0,0,1). Asi solo rellena lo que nadie
	   definio -- y el unico que no definia NADA era OfertasVendedor.

	   Las VARIANTES son al reves: tienen que ganar siempre, o la
	   misma clase se ve distinta segun donde caiga. `.principal`
	   suelto seria (0,1,1) y perderia contra las 14 reglas del tipo
	   `.acciones button` (0,2,0) que hay repartidas por el proyecto,
	   asi que la clase va DOBLADA -- `.principal.principal` es
	   (0,2,1) y les gana. Es el truco de siempre para subir
	   especificidad sin recurrir a !important, que no deja salida.
	   ══════════════════════════════════════════════════════════ */

	:global(button),
	:global(.boton) {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 0.45rem;
		padding: 8px 16px;
		font-family: inherit;
		font-size: 0.95rem;
		line-height: 1.2;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		text-decoration: none;
		white-space: nowrap;
		transition:
			border-color var(--t),
			background var(--t),
			color var(--t);
	}

	:global(button:hover:not(:disabled)),
	:global(.boton:hover) {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	:global(button:active:not(:disabled)),
	:global(.boton:active) {
		transform: translateY(1px);
	}

	/* La accion principal de cada pantalla: relleno solido. */
	:global(button.principal.principal),
	:global(.boton.principal.principal) {
		color: var(--sobre-indigo);
		background: var(--indigo);
		border-color: var(--indigo);
	}
	:global(button.principal.principal:hover:not(:disabled)),
	:global(.boton.principal.principal:hover) {
		color: var(--sobre-indigo);
		background: var(--indigo-os);
		border-color: var(--indigo-os);
	}

	/* La alternativa de al lado: misma caja, sin relleno. */
	:global(button.secundario.secundario),
	:global(.boton.secundario.secundario) {
		color: var(--tinta);
		background: none;
	}

	/* Cancelar, cerrar, retirar. Se rellena solo al pasar por encima:
	   un boton rojo permanente grita mas de lo que hace falta. */
	:global(button.peligro.peligro),
	:global(.boton.peligro.peligro) {
		color: var(--rojo);
		background: none;
		border-color: var(--rojo);
	}
	:global(button.peligro.peligro:hover:not(:disabled)),
	:global(.boton.peligro.peligro:hover) {
		color: var(--sobre-rojo);
		background: var(--rojo);
		border-color: var(--rojo);
	}

	/* Sin caja: para acciones de tercera fila y para iconos. */
	:global(button.fantasma.fantasma),
	:global(.boton.fantasma.fantasma) {
		padding: 6px 8px;
		color: var(--gris);
		background: none;
		border-color: transparent;
	}
	:global(button.fantasma.fantasma:hover:not(:disabled)),
	:global(.boton.fantasma.fantasma:hover) {
		color: var(--indigo);
		background: var(--indigo-cl);
		border-color: transparent;
	}

	/* Un boton que se lee como enlace: "Reintentar", "Ver mas".
	   Ya se usaba en 5 componentes y solo estaba DEFINIDO en 3 --
	   como el CSS de Svelte tiene ambito, en OfertasVendedor y en
	   Pedido la clase no existia y esos dos salian con caja. */
	:global(button.enlace.enlace),
	:global(.boton.enlace.enlace) {
		padding: 0;
		color: var(--indigo);
		background: none;
		border: none;
		text-decoration: underline;
		text-underline-offset: 3px;
	}
	:global(button.enlace.enlace:hover:not(:disabled)),
	:global(.boton.enlace.enlace:hover) {
		color: var(--indigo-os);
	}

	:global(button:disabled) {
		opacity: 0.5;
		cursor: not-allowed;
	}

	/* Los campos, con la misma caja que los botones: si no, un
	   formulario mezcla dos alturas y dos radios distintos. */
	:global(input),
	:global(select),
	:global(textarea) {
		font-family: inherit;
		font-size: 0.95rem;
		line-height: 1.4;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		padding: 8px 11px;
		transition:
			border-color var(--t),
			box-shadow var(--t);
	}

	:global(textarea) {
		resize: vertical;
	}

	:global(input:hover:not(:disabled)),
	:global(select:hover:not(:disabled)),
	:global(textarea:hover:not(:disabled)) {
		border-color: var(--gris-2);
	}

	:global(input:focus),
	:global(select:focus),
	:global(textarea:focus) {
		border-color: var(--indigo);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	/* El foco de un campo ya se ve con el borde y el halo de arriba;
	   el anillo de :focus-visible encima se veria doble. */
	:global(input:focus-visible),
	:global(select:focus-visible),
	:global(textarea:focus-visible) {
		outline: none;
	}

	:global(input:disabled),
	:global(select:disabled),
	:global(textarea:disabled) {
		opacity: 0.55;
		cursor: not-allowed;
	}

	/* Las casillas y los radios NO llevan la caja de arriba: son
	   cuadrados chicos y el padding los deforma. Solo el color. */
	:global(input[type='checkbox']),
	:global(input[type='radio']) {
		width: auto;
		padding: 0;
		border: none;
		background: none;
		accent-color: var(--indigo);
		cursor: pointer;
	}

	/* Los iconos propios de Chrome de input[type=date] y [type=search] salian
	   negros sobre fondo oscuro. Aqui se les ponia `color-scheme: light dark`,
	   que los ataba a la preferencia del SISTEMA OPERATIVO en vez de al tema de
	   la app: con Windows en claro y Mesh en oscuro, volvian a salir negros.
	   Ya no hace falta la excepcion -- color-scheme se hereda, y la raiz ahora
	   declara el que de verdad corresponde al tema puesto. */

	:global(img),
	:global(svg) {
		max-width: 100%;
		display: block;
	}

	:global(:focus-visible) {
		outline: 2px solid var(--indigo);
		outline-offset: 3px;
	}

	/* Contenedor unico de todo el sitio */
	:global(.env) {
		width: 100%;
		max-width: var(--ancho);
		margin: 0 auto;
		padding: 0 24px;
	}

	@media (max-width: 620px) {
		:global(.env) {
			padding: 0 16px;
		}
	}

	/* Chrome pinta de blanco los campos que autocompleta, y en tema oscuro eso
	   dejaba letra clara sobre fondo blanco: no se veia lo que se escribia.

	   Los CUATRO estados, no solo el base: Chrome vuelve a pintar su fondo al
	   pasar el raton, al enfocar y al pulsar, asi que cubrir solo
	   `:-webkit-autofill` arregla el campo hasta que alguien lo toca.

	   La transicion larguisima es el remedio conocido para lo mismo: el fondo
	   de autofill se aplica con una transicion, y estirarla tanto hace que
	   nunca llegue. El caret va aparte porque no lo cubre text-fill-color, y
	   sin el el cursor se pierde sobre el fondo oscuro. */
	:global(input:-webkit-autofill),
	:global(input:-webkit-autofill:hover),
	:global(input:-webkit-autofill:focus),
	:global(input:-webkit-autofill:active),
	:global(textarea:-webkit-autofill),
	:global(select:-webkit-autofill) {
		-webkit-text-fill-color: var(--tinta);
		-webkit-box-shadow: 0 0 0 1000px var(--blanco) inset;
		box-shadow: 0 0 0 1000px var(--blanco) inset;
		caret-color: var(--tinta);
		transition: background-color 100000s ease-in-out 0s;
	}
</style>
