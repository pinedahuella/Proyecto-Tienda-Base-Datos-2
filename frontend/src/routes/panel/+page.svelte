<script lang="ts">
	import { onMount } from 'svelte';
	import { afterNavigate, goto } from '$app/navigation';
	import Cabecera from '$lib/Cabecera.svelte';
	import Pie from '$lib/Pie.svelte';
	import { conJson, pedir } from '$lib/api';
	import Direcciones from '$lib/Direcciones.svelte';
	import PanelAdmin from '$lib/PanelAdmin.svelte';
	import PanelVendedor from '$lib/PanelVendedor.svelte';
	import OfertasVendedor from '$lib/OfertasVendedor.svelte';
	import BuscarOfertas from '$lib/BuscarOfertas.svelte';
	import ReglasDescuento from '$lib/ReglasDescuento.svelte';
	import ReglasPeriodo from '$lib/ReglasPeriodo.svelte';
	import PropuestasProducto from '$lib/PropuestasProducto.svelte';
	import PanelFraude from '$lib/PanelFraude.svelte';
	import AlertasFraudeUsuario from '$lib/AlertasFraudeUsuario.svelte';
	import AvisosSeguimiento from '$lib/AvisosSeguimiento.svelte';
	import PanelTendencias from '$lib/PanelTendencias.svelte';
	import DemoFraude from '$lib/DemoFraude.svelte';
	import PanelComandos from '$lib/PanelComandos.svelte';
	import PanelReportes from '$lib/PanelReportes.svelte';
	import {
		cerrarSesion,
		CORREO_TIENDA,
		esCuentaDesarrollador,
		ID_ROL_ADMIN,
		ID_ROL_VENDEDOR,
		SesionIndeterminada,
		verificarSesion,
		type PerfilUsuario
	} from '$lib/sesion';

	/**
	 * Panel del usuario.
	 *
	 * Se carga en dos pasos, con dos rutas que hacen cosas distintas:
	 *
	 *   GET /usuario/yo   dice si el token sigue sirviendo. Es el candado.
	 *   GET /perfil       trae los datos a mostrar, con el nombre del rol y
	 *                     del estado ademas de sus ids.
	 *
	 * Y deja editar lo que el backend permite editar al propio usuario:
	 *
	 *   PATCH /perfil             nombre y apellido
	 *   PATCH /perfil/contrasena  la contrasena
	 *
	 * PATCH /perfil acepta nombre y apellido, nada mas: el formulario de
	 * edicion tiene exactamente esos dos campos.
	 *
	 * Debajo del perfil se muestra una cosa u otra segun el rol: un admin ve
	 * la gestion de cuentas, y cualquier otro ve su tienda. El perfil lo ven
	 * los dos, porque los dos necesitan poder cambiar su contrasena.
	 */

	let perfil = $state<PerfilUsuario | null>(null);
	let cargando = $state(true);
	let error = $state('');

	let esAdmin = $derived(perfil?.id_rol_usuario === ID_ROL_ADMIN);
	let esVendedor = $derived(perfil?.id_rol_usuario === ID_ROL_VENDEDOR);

	/**
	 * Solo las cuentas `desarrollador*` ven la pestana Comandos. El admin NO: es una
	 * herramienta de quien desarrolla, y el panel de administracion es para gestionar
	 * la tienda (pedido de Meme, 2026-09-20).
	 * En el backend son vendedores comunes: esto solo decide que se pinta, ver
	 * `esCuentaDesarrollador` en sesion.ts.
	 */
	let esDesarrollador = $derived(esCuentaDesarrollador(perfil?.correo_electronico));
	let veComandos = $derived(esDesarrollador);
	const COMANDOS: Seccion = {
		id: 'comandos',
		nombre: 'Comandos',
		pie: 'Arrancar el sistema, cargar productos con semilla y lanzar demos'
	};

	/**
	 * Quien administra el catalogo compartido: la cuenta de la tienda, o un
	 * admin.
	 *
	 * El rol no basta: los cinco vendedores tienen `id_rol_usuario` 2 y solo
	 * uno administra. Sin esta distincion, a los cuatro `ventas.*` se les
	 * pintaba el panel del catalogo con su boton de publicar, y como el
	 * backend les contesta 404 en `/vendedor/productos`, les salia el mensaje
	 * de esa ruta -- "No existe un producto con ese id" -- en rojo nada mas
	 * cargar; el boton ademas les dejaba llenar el formulario entero para
	 * fallar al enviarlo.
	 *
	 * El admin va junto con la tienda y no aparte, porque el backend los trata
	 * igual: `exigirTiendaOAdmin()` deja pasar a los dos en `/vendedor/productos`,
	 * y en `/vendedor/ofertas` el `resolverIdEfectivo()` del commit `bd12cd4`
	 * cambia el id del admin por el de la tienda, asi que las dos cuentas ven y
	 * editan exactamente lo mismo. Un solo interruptor, un solo camino.
	 */
	let administraLaTienda = $derived(
		perfil?.correo_electronico === CORREO_TIENDA || perfil?.id_rol_usuario === ID_ROL_ADMIN
	);

	// ══════════════════════════════════════════════════════════
	// Las secciones del panel
	//
	// El panel era UNA COLUMNA con todo apilado. Medido en el navegador con la
	// cuenta de admin: 7732 pixeles de alto. El de la tienda, 5531. Para llegar
	// a la manipulacion de resenas, que es lo ultimo, habia que pasar por el
	// perfil, las direcciones, las cuentas, los reportes, veinte ofertas y una
	// pagina del catalogo. Y eso con 1105 productos; con un catalogo de verdad
	// no se acaba nunca.
	//
	// Ahora se ensena UNA a la vez. No es un indice de anclas: un indice que
	// solo hace scroll no reduce nada, se siguen viendo las demas por el rabillo
	// del ojo. La elegida es la unica que se pinta.
	//
	// Se montan PEREZOSAMENTE y despues se quedan montadas: la primera vez que
	// entras a una seccion pide sus datos, y volver a ella ya no pide nada. Con
	// un `{#if}` a secas, cada ida y vuelta repetiria la consulta y perderia lo
	// que hubiera escrito a medias en un formulario.
	// ══════════════════════════════════════════════════════════

	interface Seccion {
		id: string;
		nombre: string;
		/** Una linea de que se hace aqui, para la cabecera de la seccion. */
		pie: string;
	}

	/**
	 * Que secciones tiene esta cuenta, EN ORDEN DE USO, no de construccion.
	 *
	 * Un vendedor abre el panel para mirar sus ofertas mil veces mas que para
	 * cambiarse el apellido, asi que las ofertas van primeras y la cuenta al
	 * final. Al admin le pasa lo mismo con los reportes.
	 */
	let todasLasSecciones = $derived.by<Seccion[]>(() => {
		if (!perfil) return [];

		if (esAdmin) {
			return [
				{ id: 'reportes', nombre: 'Reportes', pie: 'Como van las ventas y los pedidos' },
				{ id: 'ofertas', nombre: 'Ofertas', pie: 'Precio, existencias y estado de lo que vende la tienda' },
				{ id: 'reglas', nombre: 'Reglas', pie: 'Descuentos que se activan solos, por ventas rapidas o por fecha' },
				{ id: 'catalogo', nombre: 'Catalogo', pie: 'Alta, edicion e historial de los productos' },
				{ id: 'propuestas', nombre: 'Propuestas', pie: 'Lo que otros vendedores quieren meter al catalogo' },
				{ id: 'cuentas', nombre: 'Cuentas', pie: 'Los usuarios del sistema, su rol y su estado' },
				// Se llamaba "Resenas". Desde el 2026-09-10 lleva tambien los intentos de
				// entrada sospechosos, y nadie los iria a buscar bajo ese nombre.
				{ id: 'fraude', nombre: 'Fraude', pie: 'Resenas en anillo, intentos de entrada y compras sospechosas' },
				{ id: 'tendencias', nombre: 'Tendencias', pie: 'Lo mas visto, comprado y buscado en los ultimos dias' },
				// Distinta de "Fraude": esa es EN VIVO contra el grafo y solo la ve
				// un admin; esta es "a mi cuenta le paso algo" y la ve cualquiera --
				// GET /perfil/alertas-fraude, filtrado a la sesion de quien pregunta.
				{ id: 'avisos', nombre: 'Avisos', pie: 'Lo que pediste que te avisemos cuando llegue o baje de precio' },
				{ id: 'alertas', nombre: 'Alertas', pie: 'Avisos de seguridad sobre tu propia cuenta' },
				{ id: 'cuenta', nombre: 'Mi cuenta', pie: 'Tus datos, tu contrasena y tus direcciones' }
			];
		}

		if (esVendedor) {
			return [
				{ id: 'ofertas', nombre: 'Ofertas', pie: 'A que precio vendes cada variante y cuantas te quedan' },
				{ id: 'reglas', nombre: 'Reglas', pie: 'Descuentos que se activan solos, por ventas rapidas o por fecha' },
				administraLaTienda
					? { id: 'catalogo', nombre: 'Catalogo', pie: 'Alta, edicion e historial de los productos' }
					: { id: 'catalogo', nombre: 'Proponer', pie: 'Mandale al catalogo un producto que falte' },
				{ id: 'propuestas', nombre: 'Propuestas', pie: 'Como van las que mandaste' },
				...(veComandos ? [COMANDOS] : []),
				{ id: 'avisos', nombre: 'Avisos', pie: 'Lo que pediste que te avisemos cuando llegue o baje de precio' },
				{ id: 'alertas', nombre: 'Alertas', pie: 'Avisos de seguridad sobre tu propia cuenta' },
				{ id: 'cuenta', nombre: 'Mi cuenta', pie: 'Tus datos, tu contrasena y tus direcciones' }
			];
		}

		// Un comprador tiene poco que gestionar: su cuenta, sus alertas y por donde seguir.
		return [
			...(veComandos ? [COMANDOS] : []),
			{ id: 'avisos', nombre: 'Avisos', pie: 'Lo que pediste que te avisemos cuando llegue o baje de precio' },
			{ id: 'alertas', nombre: 'Alertas', pie: 'Avisos de seguridad sobre tu propia cuenta' },
			{ id: 'cuenta', nombre: 'Mi cuenta', pie: 'Tus datos, tu contrasena y tus direcciones' }
		];
	});

	/** Cual se esta mirando. Vacio quiere decir "todavia no se ha decidido". */
	let seccion = $state('');

	/**
	 * DOS ambitos para el admin: lo PERSONAL y lo de ADMINISTRAR.
	 *
	 * El admin tenia todo en una sola barra, con Alertas y Mi cuenta al lado de
	 * Reportes y Fraude, y desde "Mi perfil" caia en los reportes. Se confundian
	 * dos cosas distintas. Ahora "Mi perfil" (header) abre Alertas y Mi cuenta,
	 * y "Admin" (header) abre lo de administrar el sistema. El ambito sale de la
	 * seccion que se mira, asi que el enlace directo y el boton de atras siguen
	 * funcionando sin estado nuevo.
	 *
	 * Solo aplica al admin: el vendedor y el comprador tienen sus secciones como
	 * siempre. Lo del vendedor (ofertas, propuestas) es SU trabajo, no un ambito
	 * aparte.
	 */
	const PERSONALES = new Set(['avisos', 'alertas', 'cuenta']);

	/**
	 * Tres ambitos, cada uno con su boton en la cabecera (pedido de Meme, 2026-09-25):
	 *   perfil      Alertas y Mi cuenta. Lo personal, igual para todos los roles.
	 *   desarrollo  Solo Comandos, en las cuentas `desarrollador*`.
	 *   trabajo     Lo demas: administrar (admin) o vender (vendedor).
	 * Antes solo el admin tenia su trabajo separado; el vendedor veia sus ofertas
	 * mezcladas con su cuenta en una sola barra, y "Mi perfil" caia en Ofertas.
	 * El ambito sale de la seccion que se mira, asi que el enlace directo y el
	 * boton de atras siguen funcionando sin estado nuevo. El comprador no tiene
	 * trabajo que separar: su panel es solo lo personal.
	 */
	type Ambito = 'perfil' | 'desarrollo' | 'trabajo';
	const ambitoDe = (id: string): Ambito =>
		PERSONALES.has(id) ? 'perfil' : id === 'comandos' ? 'desarrollo' : 'trabajo';
	let tieneTrabajo = $derived(esAdmin || esVendedor);
	let ambito = $derived.by<Ambito>(() => {
		if (seccion && todasLasSecciones.some((s) => s.id === seccion)) return ambitoDe(seccion);
		return tieneTrabajo ? 'trabajo' : 'perfil';
	});
	let enPerfil = $derived(ambito === 'perfil');
	let enDesarrollo = $derived(ambito === 'desarrollo');

	let secciones = $derived(todasLasSecciones.filter((s) => ambitoDe(s.id) === ambito));

	/**
	 * La elegida de verdad.
	 *
	 * Si lo guardado no existe para esta cuenta se cae a la primera. Pasa al
	 * recargar con `?s=cuentas` siendo vendedor, o al cambiar de cuenta en la
	 * misma pestana: sin esto quedaba una pantalla en blanco sin decir por que.
	 */
	let seccionViva = $derived(
		secciones.some((s) => s.id === seccion) ? seccion : (secciones[0]?.id ?? '')
	);

	let seccionActual = $derived(secciones.find((s) => s.id === seccionViva) ?? null);

	/**
	 * Las que ya se abrieron alguna vez. Es lo que hace el montaje perezoso.
	 *
	 * Se guarda tambien la que esta viva ahora aunque nadie la haya pulsado:
	 * la primera seccion se abre sola al entrar.
	 */
	let visitadas = $state(new Set<string>());

	$effect(() => {
		const id = seccionViva;
		if (!id || visitadas.has(id)) return;
		// Un Set nuevo y no `.add`: Svelte 5 no vigila lo de dentro de un Set.
		visitadas = new Set([...visitadas, id]);
	});

	/**
	 * Cambiar de seccion se guarda en la direccion (`?s=`).
	 *
	 * Asi recargar te deja donde estabas, el boton de atras del navegador hace
	 * lo que se espera, y se puede mandar un enlace directo a "Resenas" en vez
	 * de decirle a alguien que baje hasta el final. Es la misma decision que ya
	 * toman el catalogo con sus filtros y el buscador con su `?q=`.
	 */
	function irA(id: string) {
		seccion = id;
		const url = new URL(window.location.href);
		url.searchParams.set('s', id);
		history.replaceState(history.state, '', url);
	}

	/**
	 * Un enlace de FUERA del panel a `/panel?s=alertas` (la campanita de
	 * Cabecera, "Ver todas") caia en el vacio: como el destino es la MISMA
	 * ruta, SvelteKit no vuelve a montar el componente ni a correr `onMount`
	 * -- solo actualiza la URL, y `seccion` se habia leido una sola vez, ahi
	 * arriba. La direccion cambiaba a `?s=alertas` y la pantalla se quedaba
	 * en la pestana de antes.
	 *
	 * `afterNavigate` corre en CUALQUIER navegacion que SI pasa por el router
	 * de SvelteKit (un `<a>`, `goto()`, atras/adelante), asi que aqui se
	 * vuelve a leer `?s=` y se corrige. No estorba a `irA`: esa usa
	 * `history.replaceState` a mano, que no pasa por el router y por eso
	 * nunca dispara esto -- las dos conviven sin pisarse.
	 */
	afterNavigate(() => {
		const deLaUrl = new URL(window.location.href).searchParams.get('s') ?? '';
		if (deLaUrl !== seccion) seccion = deLaUrl;
	});

	/**
	 * La linea de bienvenida, segun el rol.
	 *
	 * Ninguna afirma cuantas cosas tiene la persona: el panel no lo sabe
	 * todavia cuando pinta esto, y prometer "tu primer producto" a quien ya
	 * vende dos docenas fue exactamente el fallo anterior.
	 */
	let saludo = $derived(
		enDesarrollo
			? 'Herramientas para desarrollar y ensenar Mesh: arrancar el sistema, cargar productos con semilla y lanzar las demos. Tus ofertas estan en Vendedor y tu cuenta en Mi perfil.'
			: esAdmin
			? enPerfil
				? 'Tus datos, tus direcciones y los avisos de seguridad de tu cuenta. Lo de administrar el sistema esta en el boton Admin de arriba.'
				: 'Desde aqui gestionas las cuentas y los catalogos del sistema. Tus datos personales estan en Mi perfil.'
			: esVendedor
				? enPerfil
					? 'Tus datos, tus direcciones y los avisos de seguridad de tu cuenta. Tus ofertas estan en el boton Vendedor de arriba.'
					: 'Aqui llevas tus ofertas: a que precio vendes cada variante y cuantas unidades te quedan. Tus datos personales estan en Mi perfil.'
				: 'Aqui estan los datos de tu cuenta y tus direcciones de entrega. Tus pedidos tienen su propia pagina.'
	);

	type Modo = 'ver' | 'editar' | 'contrasena';
	let modo = $state<Modo>('ver');
	let confirmacionOk = $state('');

	// Formulario de nombre y apellido
	let eNombre = $state('');
	let eApellido = $state('');
	let guardando = $state(false);
	let errorPerfil = $state('');

	// Formulario de contrasena
	let actual = $state('');
	let nueva = $state('');
	let repetida = $state('');
	let verClaves = $state(false);
	let cambiando = $state(false);
	let errorClave = $state('');

	// onMount y no $effect: esto tiene que correr UNA vez, al abrir el panel.
	// Con $effect se volvia a ejecutar solo (se vieron seis llamadas seguidas en
	// el mismo instante), y como abajo todo cuelga de {#if cargando}, cada
	// vuelta desmontaba y volvia a montar el arbol entero: el formulario de
	// vendedor que estuviera abierto se perdia a media escritura.
	onMount(() => {
		// La seccion que pida la direccion, si pide alguna. Se lee ANTES de
		// cargar el perfil: `seccionViva` la ignora mientras no exista para
		// esta cuenta, asi que ponerla pronto no rompe nada y evita el
		// parpadeo de abrir la primera y saltar luego a la buena.
		seccion = new URL(window.location.href).searchParams.get('s') ?? '';
		cargar();
	});

	async function cargar() {
		cargando = true;
		error = '';

		// 1. El candado: si la sesion se acabo, a iniciar sesion de nuevo
		try {
			const sesion = await verificarSesion();
			if (!sesion) {
				await goto('/entrar');
				return;
			}
		} catch (fallo) {
			// No se pudo averiguar (503 o backend apagado). No se saca a nadie:
			// el token puede estar bien y ser el servidor el del problema.
			error = fallo instanceof SesionIndeterminada ? fallo.message : 'No se pudo cargar el panel';
			cargando = false;
			return;
		}

		// 2. Los datos del perfil
		const respuesta = await pedir<PerfilUsuario>('/perfil');

		if (!respuesta.ok || !respuesta.payload) {
			if (await sesionVencida(respuesta.estado)) return;
			error = respuesta.mensaje;
			cargando = false;
			return;
		}

		perfil = respuesta.payload;
		cargando = false;
	}

	/**
	 * Entre una peticion y otra el token puede caducar, o pueden suspender la
	 * cuenta: todas las rutas de perfil lo comprueban en cada llamada. Si eso
	 * pasa, la sesion se acabo de verdad y toca volver a entrar.
	 */
	/** Lo mismo que sesionVencida, para el hijo, que no devuelve el codigo. */
	function expiro() {
		cerrarSesion();
		goto('/entrar');
	}

	async function sesionVencida(estado: number): Promise<boolean> {
		if (estado !== 401) return false;
		cerrarSesion();
		await goto('/entrar');
		return true;
	}

	function abrir(nuevo: Modo) {
		confirmacionOk = '';
		errorPerfil = '';
		errorClave = '';

		if (nuevo === 'editar') {
			// Se parte de lo que hay, para que se edite y no se reescriba todo
			eNombre = perfil?.nombre ?? '';
			eApellido = perfil?.apellido ?? '';
		}
		if (nuevo === 'contrasena') {
			actual = '';
			nueva = '';
			repetida = '';
		}

		modo = nuevo;
	}

	/**
	 * La salida rapida de "Alertas": lleva a Mi cuenta con el formulario de
	 * contrasena ya abierto, en vez de dejar a la persona buscando donde se
	 * cambia. Es la misma pantalla de siempre, solo que sin los dos clics de
	 * en medio.
	 */
	function cambiarContrasenaRapido() {
		irA('cuenta');
		abrir('contrasena');
		setTimeout(() => document.getElementById("c-actual")?.focus(), 250);
	}

	/** PATCH /perfil. Los mensajes son los mismos que devuelve el backend. */
	async function guardarPerfil(evento: SubmitEvent) {
		evento.preventDefault();
		errorPerfil = '';

		if (!eNombre.trim()) {
			errorPerfil = 'El nombre es obligatorio';
			return;
		}
		if (eNombre.trim().length > 100) {
			errorPerfil = 'El nombre no puede tener mas de 100 caracteres';
			return;
		}
		if (eApellido.trim().length > 100) {
			errorPerfil = 'El apellido no puede tener mas de 100 caracteres';
			return;
		}

		guardando = true;

		// El apellido va como texto y no como null aunque quede vacio: el
		// backend usa COALESCE, asi que un null significa "no lo toques" y
		// entonces no habria forma de borrarlo.
		const respuesta = await pedir<PerfilUsuario>(
			'/perfil',
			conJson('PATCH', { nombre: eNombre.trim(), apellido: eApellido.trim() })
		);

		guardando = false;

		if (!respuesta.ok || !respuesta.payload) {
			if (await sesionVencida(respuesta.estado)) return;
			errorPerfil = respuesta.mensaje;
			return;
		}

		// El backend devuelve el perfil ya actualizado, asi que no hace falta
		// volver a pedir /perfil
		perfil = respuesta.payload;
		confirmacionOk = respuesta.mensaje;
		modo = 'ver';
	}

	/** PATCH /perfil/contrasena. Mismas reglas que en el registro. */
	async function cambiarContrasena(evento: SubmitEvent) {
		evento.preventDefault();
		errorClave = '';

		if (!actual) {
			errorClave = 'La contrasena actual es obligatoria';
			return;
		}
		if (!nueva) {
			errorClave = 'La nueva contrasena es obligatoria';
			return;
		}
		if (!repetida) {
			errorClave = 'La confirmacion de la nueva contrasena es obligatoria';
			return;
		}
		if (nueva !== repetida) {
			errorClave = 'Las contrasenas nuevas no coinciden';
			return;
		}
		if (nueva === actual) {
			errorClave = 'La nueva contrasena debe ser diferente a la actual';
			return;
		}
		if (nueva.length < 8) {
			errorClave = 'La contrasena debe tener al menos 8 caracteres';
			return;
		}
		if (!/[A-Z]/.test(nueva)) {
			errorClave = 'La contrasena debe tener al menos una letra mayuscula';
			return;
		}
		if (!/[^A-Za-z0-9]/.test(nueva)) {
			errorClave = 'La contrasena debe tener al menos un caracter especial';
			return;
		}

		cambiando = true;

		const respuesta = await pedir('/perfil/contrasena', {
			...conJson('PATCH', {
				contrasena_actual: actual,
				contrasena_nueva: nueva,
				contrasena_nueva_confirmacion: repetida
			})
		});

		cambiando = false;

		if (!respuesta.ok) {
			if (await sesionVencida(respuesta.estado)) return;
			errorClave = respuesta.mensaje;
			return;
		}

		// Se limpian a mano: son datos sensibles y no tienen por que quedarse
		// en memoria ni reaparecer al abrir el formulario otra vez
		actual = '';
		nueva = '';
		repetida = '';
		confirmacionOk = respuesta.mensaje;
		modo = 'ver';
	}

	/**
	 * La sesion no se cae al cambiar la contrasena: el token ya estaba
	 * firmado y sigue valido hasta que venza. Es el comportamiento del
	 * backend, no un descuido de aqui.
	 */
	async function salir() {
		await pedir('/usuario/logout', { method: 'POST' });
		cerrarSesion();
		await goto('/');
	}

	/**
	 * Las fechas llegan en ISO. fecha_nacimiento es una columna date, pero
	 * PostgreSQL la manda con la hora de la zona, asi que se formatea en la
	 * zona del navegador para que salga el dia correcto.
	 */
	function fecha(valor: string | null): string {
		if (!valor) return 'Sin dato';
		return new Date(valor).toLocaleDateString('es-GT', {
			day: 'numeric',
			month: 'long',
			year: 'numeric'
		});
	}

	/**
	 * Las tarjetas del comprador. Son ceros fijos, no datos: andamiaje de
	 * cuando no habia nada que enseñar.
	 *
	 * "Pedidos" ya no esta: el pedido de verdad se ensena arriba, en el
	 * componente Pedido, y la tarjeta afirmaba "Aun no hay pedidos" justo
	 * debajo de un pedido con lineas y su total. Un cero inventado al lado del
	 * dato de verdad no es andamiaje, es una contradiccion en pantalla.
	 *
	 * Las otras dos siguen siendo ceros fijos, y eso hay que quitarlo tambien
	 * el dia que haya de donde sacarlos.
	 */
</script>

<svelte:head>
	<title>Mesh · Panel</title>
</svelte:head>

<Cabecera sesion={perfil?.correo_electronico ?? null} {esAdmin} {esVendedor} alSalir={salir} />

<main>
	<div class="env">
		<!-- Solo la PRIMERA carga tapa la pantalla. Si se recarga el perfil con
		     el panel ya abierto, se deja lo que hay: si no, se desmonta todo lo
		     de abajo y lo que estuviera escrito a medias se pierde. -->
		{#if cargando && !perfil}
			<p class="cargando">Cargando tu panel...</p>
		{:else if error}
			<div class="aviso" role="alert">
				<p>{error}</p>
				<button type="button" onclick={cargar}>Reintentar</button>
			</div>
		{:else if perfil}
			<div class="saludo">
				{#if enDesarrollo}
					<p class="ambito">Desarrollador</p>
				{:else if esAdmin || esVendedor}
					<p class="ambito">{enPerfil ? 'Mi perfil' : esAdmin ? 'Administracion' : 'Vendedor'}</p>
				{/if}
				<h1>Hola, {perfil.nombre}</h1>
				<!-- Uno por rol. Antes era un texto fijo -- "Tu tienda esta lista.
				     Publica tu primer producto" -- que salia igual para los tres:
				     le hablaba de su tienda a un comprador, y le pedia publicar
				     su PRIMER producto a un vendedor con dos docenas de ofertas
				     vivas. Y en este modelo un vendedor no publica productos: el
				     catalogo es compartido y crearlo es solo de la tienda. -->
				<p>{saludo}</p>
			</div>

			<!-- Una seccion a la vez. Ver el bloque de "Las secciones del panel"
			     arriba: esto no es un indice de anclas, la que no esta elegida no
			     se pinta. Con una sola seccion la barra sobra, asi que no sale. -->
			{#if secciones.length > 1}
				<nav class="mapa" aria-label="Secciones del panel">
					{#each secciones as s (s.id)}
						<button
							type="button"
							class="paso"
							class:viva={s.id === seccionViva}
							aria-current={s.id === seccionViva ? 'page' : undefined}
							onclick={() => irA(s.id)}
						>
							{s.nombre}
						</button>
					{/each}
				</nav>

				{#if seccionActual}
					<p class="que-es">{seccionActual.pie}</p>
				{/if}
			{/if}

			<div class="hoja" class:oculta={seccionViva !== 'cuenta'}>
			<section class="perfil">
				<div class="titulo">
					<h2>Tu perfil</h2>
					<span class="etiqueta">{perfil.rol_usuario_nombre}</span>
					<span class="etiqueta estado">{perfil.estado_usuario_nombre}</span>

					{#if modo === 'ver'}
						<div class="acciones">
							<button type="button" onclick={() => abrir('editar')}>Editar datos</button>
							<button type="button" onclick={() => abrir('contrasena')}>Cambiar contrasena</button>
						</div>
					{/if}
				</div>

				{#if confirmacionOk}
					<p class="hecho" role="status">{confirmacionOk}</p>
				{/if}

				{#if modo === 'ver'}
					<dl>
						<div>
							<dt>Usuario</dt>
							<dd>{perfil.usuario}</dd>
						</div>
						<div>
							<dt>Correo electronico</dt>
							<dd>{perfil.correo_electronico}</dd>
						</div>
						<div>
							<dt>Nombre</dt>
							<dd>{perfil.nombre}</dd>
						</div>
						<div>
							<dt>Apellido</dt>
							<dd>{perfil.apellido || 'Sin dato'}</dd>
						</div>
						<div>
							<dt>Fecha de nacimiento</dt>
							<dd>{fecha(perfil.fecha_nacimiento)}</dd>
						</div>
						<div>
							<dt>Cuenta creada</dt>
							<dd>{fecha(perfil.fecha_creacion)}</dd>
						</div>
					</dl>
				{:else if modo === 'editar'}
					<!-- Nombre y apellido: es lo que acepta PATCH /perfil -->
					<form onsubmit={guardarPerfil} novalidate>
						{#if errorPerfil}
							<p class="malo" role="alert">{errorPerfil}</p>
						{/if}

						<div class="pareja">
							<div class="campo">
								<label for="e-nombre">Nombre</label>
								<input id="e-nombre" type="text" bind:value={eNombre} />
							</div>
							<div class="campo">
								<label for="e-apellido">Apellido <span class="opcional">opcional</span></label>
								<input id="e-apellido" type="text" bind:value={eApellido} />
							</div>
						</div>

						<div class="botones">
							<button class="principal" type="submit" disabled={guardando}>
								{guardando ? 'Guardando' : 'Guardar cambios'}
							</button>
							<button type="button" onclick={() => abrir('ver')}>Cancelar</button>
						</div>
					</form>
				{:else}
					<form onsubmit={cambiarContrasena} novalidate>
						{#if errorClave}
							<p class="malo" role="alert">{errorClave}</p>
						{/if}

						<div class="campo">
							<label for="c-actual">Contrasena actual</label>
							<input
								id="c-actual"
								type={verClaves ? 'text' : 'password'}
								autocomplete="current-password"
								bind:value={actual}
							/>
						</div>

						<div class="pareja">
							<div class="campo">
								<label for="c-nueva">Nueva contrasena</label>
								<input
									id="c-nueva"
									type={verClaves ? 'text' : 'password'}
									autocomplete="new-password"
									bind:value={nueva}
								/>
							</div>
							<div class="campo">
								<label for="c-repetida">Repite la nueva</label>
								<input
									id="c-repetida"
									type={verClaves ? 'text' : 'password'}
									autocomplete="new-password"
									bind:value={repetida}
								/>
							</div>
						</div>

						<label class="mostrar">
							<input type="checkbox" bind:checked={verClaves} />
							Mostrar las contrasenas
						</label>

						<p class="ayuda">
							Minimo 8 caracteres, una mayuscula y un caracter especial. Tiene que ser distinta de
							la actual.
						</p>

						<div class="botones">
							<button class="principal" type="submit" disabled={cambiando}>
								{cambiando ? 'Guardando' : 'Cambiar contrasena'}
							</button>
							<button type="button" onclick={() => abrir('ver')}>Cancelar</button>
						</div>
					</form>
				{/if}
			</section>

			<Direcciones alExpirarSesion={expiro} />

			{#if !esAdmin && !esVendedor}
				<!-- Lo que ve un comprador, dentro de su misma hoja: son dos
				     enlaces, no una seccion, y darles pestana propia seria una
				     pestana para dos frases.

				     Aqui hubo antes dos tarjetas -- "Productos 0" e "Inventario 0" --
				     con las cifras escritas a mano: cosas de vendedor ensenadas a un
				     comprador, y dos ceros que no salian de ninguna consulta. -->
				<div class="salidas">
					<section class="invitacion">
						<h2>Tus pedidos</h2>
						<p>
							Lo que llevas en el carrito ahora y todo lo que compraste antes, con su
							detalle.
						</p>
						<a class="ir" href="/pedidos">Ver mis pedidos</a>
					</section>

					<section class="invitacion">
						<h2>Que quieres comprar hoy</h2>
						<p>
							Recorre el catalogo y agrega al carrito. Antes de pagar hace falta una
							direccion de entrega: se agrega aqui arriba, en "Tus direcciones".
						</p>
						<a class="ir" href="/">Ver el catalogo</a>
					</section>
				</div>
			{/if}
			</div>

			<!-- Comun a las tres cuentas -- admin, vendedor y comprador. A
			     diferencia de "Fraude" (PanelFraude, EN VIVO contra el grafo,
			     solo admin), esto es "a MI cuenta le paso algo" y lo ve
			     cualquiera: GET /perfil/alertas-fraude ya filtra por la sesion. -->
			<!-- Los avisos del "avisame" (seguimientos de ofertas, 2026-10-17). Comun a
			     todas las cuentas: comprar no es privilegio de ningun rol. -->
			<div class="hoja" class:oculta={seccionViva !== 'avisos'}>
				{#if visitadas.has('avisos')}
					<AvisosSeguimiento alExpirarSesion={expiro} />
				{/if}
			</div>

			<div class="hoja" class:oculta={seccionViva !== 'alertas'}>
				{#if visitadas.has('alertas')}
					<AlertasFraudeUsuario alExpirarSesion={expiro} alCambiarContrasena={cambiarContrasenaRapido} />
				{/if}
			</div>

			{#if veComandos}
				<div class="hoja" class:oculta={seccionViva !== 'comandos'}>
					<!-- El panel de comandos de desarrollo, incrustado. Lo ve el admin y
					     las cuentas desarrollador; ver PanelComandos.svelte. -->
					{#if visitadas.has('comandos')}
						<PanelComandos />
					{/if}
				</div>
			{/if}

			<!-- De aqui para abajo, una hoja por seccion.

			     El `{#if visitadas.has(...)}` es el montaje perezoso: entrar al
			     panel ya no dispara las consultas de las SIETE secciones a la vez,
			     solo las de la que se abre. Y una vez montada se queda, escondida
			     con `oculta`, asi que volver a ella no vuelve a pedir nada ni
			     pierde lo que hubiera escrito a medias. -->
			{#if esAdmin}
				<div class="hoja" class:oculta={seccionViva !== 'reportes'}>
					<!-- Los dos reportes de admin: ventas y reservaciones. Van
					     PRIMEROS porque son de lectura y de un vistazo: se abre el
					     panel para ver como va el dinero mas veces de las que se
					     entra a editar una oferta. Son SOLO de admin y no de la
					     tienda, que recibe 403. -->
					{#if visitadas.has('reportes')}
						<PanelReportes alExpirarSesion={expiro} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'ofertas'}>
					{#if visitadas.has('ofertas')}
						<BuscarOfertas alExpirarSesion={expiro} {administraLaTienda} />
						<OfertasVendedor alExpirarSesion={expiro} {administraLaTienda} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'reglas'}>
					<!-- Las reglas de descuento automatico (56ce5f8, migracion 021)
					     y las de periodo (migracion 022). Mismo candado que las
					     ofertas: vendedor o admin, cada uno las suyas, el admin las
					     de la tienda. -->
					{#if visitadas.has('reglas')}
						<ReglasDescuento alExpirarSesion={expiro} />
						<ReglasPeriodo alExpirarSesion={expiro} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'catalogo'}>
					<!-- El admin administra el catalogo Y gestiona cuentas: desde el
					     commit `bd12cd4` el backend le abre las mismas rutas que a la
					     tienda, asi que se le pintan las mismas pantallas. -->
					{#if visitadas.has('catalogo')}
						<PanelVendedor alExpirarSesion={expiro} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'propuestas'}>
					{#if visitadas.has('propuestas')}
						<PropuestasProducto alExpirarSesion={expiro} {administraLaTienda} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'cuentas'}>
					{#if visitadas.has('cuentas')}
						<PanelAdmin alExpirarSesion={expiro} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'fraude'}>
					<!-- La manipulacion de resenas es SOLO del admin y no de la
					     tienda: el enunciado la pide "visible para el equipo
					     administrativo", y la tienda es un vendedor mas. Ensenarle a
					     un vendedor quien lo esta calificando de forma sospechosa le
					     entrega justo la lista de cuentas que no deberia poder mirar.

					     Antes vivia al FINAL de la columna, a 7000 pixeles de la
					     cabecera. Ahora es una pestana como las demas y se llega
					     tambien por enlace directo, /panel?s=fraude. -->
					{#if visitadas.has('fraude')}
						<PanelFraude alExpirarSesion={expiro} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'demo'}>
					{#if visitadas.has('demo')}
						<DemoFraude alExpirarSesion={expiro} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'tendencias'}>
					<!-- Los seis rankings de ClickHouse (vistas, carrito, compras,
					     devoluciones, busquedas y clics de busqueda). Es SOLO del
					     admin: las rutas GET /admin/eventos/* llevan el mismo candado.
					     El fraude por IP ya no vive aqui, lo cubre la pestana Fraude. -->
					{#if visitadas.has('tendencias')}
						<PanelTendencias alExpirarSesion={expiro} />
					{/if}
				</div>
			{:else if esVendedor}
				<div class="hoja" class:oculta={seccionViva !== 'ofertas'}>
					<!-- Las ofertas van PRIMERO y aparte de los productos: en el modelo
					     multi-vendedor el producto es del catalogo compartido y no es de
					     nadie, mientras que la oferta -- precio, existencias y estado --
					     si es del vendedor. Es lo suyo, asi que va arriba. -->
					{#if visitadas.has('ofertas')}
						<BuscarOfertas alExpirarSesion={expiro} {administraLaTienda} />
						<OfertasVendedor alExpirarSesion={expiro} {administraLaTienda} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'reglas'}>
					<!-- Las reglas de descuento automatico (56ce5f8, migracion 021)
					     y las de periodo (migracion 022). Mismo candado que las
					     ofertas: vendedor o admin, cada uno las suyas, el admin las
					     de la tienda. -->
					{#if visitadas.has('reglas')}
						<ReglasDescuento alExpirarSesion={expiro} />
						<ReglasPeriodo alExpirarSesion={expiro} />
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'catalogo'}>
					{#if visitadas.has('catalogo')}
						{#if administraLaTienda}
							<!-- Solo la tienda (o un admin). Las cinco rutas de
							     /vendedor/productos exigen esa cuenta o ese rol, no el rol
							     de vendedor a secas: a los demas vendedores el backend les
							     contesta 404 y el panel salia con ese error. -->
							<PanelVendedor alExpirarSesion={expiro} />
						{:else}
							<!-- El mismo panel, en modo propuesta: solo el formulario, mandado a
							     /vendedor/productos/propuestas. Un vendedor normal no puede
							     administrar el catalogo, pero si proponerle entradas. -->
							<PanelVendedor alExpirarSesion={expiro} modo="propuesta" />
						{/if}
					{/if}
				</div>

				<div class="hoja" class:oculta={seccionViva !== 'propuestas'}>
					<!-- Las propuestas SI son de todos los vendedores, y el componente
					     cambia de cara solo: la tienda ve la cola de lo que le mandaron y
					     un vendedor normal ve las suyas con el motivo del rechazo. -->
					{#if visitadas.has('propuestas')}
						<PropuestasProducto alExpirarSesion={expiro} {administraLaTienda} />
					{/if}
				</div>
			{/if}
		{/if}
	</div>
</main>

<Pie />

<style>
	main {
		padding-top: 48px;
		min-height: 50vh;
	}

	.cargando {
		color: var(--gris);
	}

	/* El backend no respondio: no se saca al usuario, se le deja reintentar */
	.aviso {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		flex-wrap: wrap;
		padding: 18px 20px;
		color: var(--rojo);
		background: var(--blanco);
		border: 1px solid var(--rojo);
		border-radius: var(--r2);
	}

	.aviso button {
		padding: 9px 18px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--blanco);
		background: var(--indigo);
		border: 0;
		border-radius: var(--r);
		cursor: pointer;
	}

	.saludo {
		max-width: 560px;
		margin-bottom: 22px;
	}

	.saludo .ambito {
		margin-bottom: 4px;
		font-size: var(--f-sm);
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--indigo);
	}

	.saludo h1 {
		margin-bottom: 10px;
	}

	.saludo p {
		color: var(--gris);
	}

	/* ── la barra de secciones ── */

	/* Se queda pegada arriba, debajo de la cabecera: dentro de una seccion
	   larga --el catalogo son veinte filas-- si la barra se va con el scroll
	   hay que volver hasta arriba solo para cambiar de pestana. El 68 es el
	   alto de la cabecera, que tambien es pegajosa. */
	.mapa {
		position: sticky;
		top: 68px;
		z-index: 20;
		display: flex;
		flex-wrap: wrap;
		gap: var(--e1);
		margin-bottom: 6px;
		padding: 4px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.paso {
		padding: 9px 15px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--texto);
		background: none;
		border: 0;
		border-radius: var(--r);
		cursor: pointer;
		white-space: nowrap;
		transition:
			background var(--t),
			color var(--t);
	}

	.paso:hover {
		color: var(--indigo);
		background: var(--indigo-cl);
	}

	/* La activa RELLENA, no solo con el borde. Con el borde a secas hay que
	   buscar cual esta elegida, y en una barra de siete no se encuentra. */
	.paso.viva {
		color: var(--sobre-indigo);
		background: var(--indigo);
		font-weight: 500;
	}

	.paso.viva:hover {
		background: var(--indigo-os);
	}

	.que-es {
		margin-bottom: 22px;
		padding-left: 4px;
		font-size: var(--f-ms);
		color: var(--gris);
	}

	/* Escondida, no desmontada: ver el comentario del marcado. El !important
	   es porque lo de dentro trae su propio display (las hojas llevan grid y
	   flex) y sin el la regla la pierde. */
	.hoja.oculta {
		display: none !important;
	}

	/* ── perfil ── */

	.perfil {
		padding: 26px 28px;
		margin-bottom: 28px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.titulo {
		display: flex;
		align-items: center;
		gap: var(--e2);
		flex-wrap: wrap;
		margin-bottom: 22px;
	}

	.titulo h2 {
		font-size: var(--f-xl);
		margin-right: 4px;
	}

	/* El rol y el estado vienen con nombre desde /perfil, no con el id */
	.etiqueta {
		padding: 3px 11px;
		font-size: var(--f-sm);
		color: var(--indigo);
		background: var(--indigo-cl);
		border-radius: 999px;
	}

	.etiqueta.estado {
		color: var(--gris);
		background: var(--panel);
	}

	.acciones {
		margin-left: auto;
		display: flex;
		gap: var(--e2);
		flex-wrap: wrap;
	}

	.acciones button,
	.botones button {
		padding: 8px 16px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			border-color var(--t),
			color var(--t);
	}

	.acciones button:hover,
	.botones button:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.botones button.principal {
		color: var(--blanco);
		background: var(--indigo);
		border-color: var(--indigo);
	}

	.botones button.principal:hover:not(:disabled) {
		background: var(--indigo-os);
		color: var(--blanco);
	}

	.botones button:disabled {
		opacity: 0.6;
		cursor: progress;
	}

	.hecho {
		margin-bottom: 18px;
		padding: 10px 14px;
		font-size: var(--f-base);
		color: var(--tinta);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
	}

	.malo {
		margin-bottom: 18px;
		padding: 10px 14px;
		font-size: var(--f-base);
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	dl {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
		gap: var(--e4) var(--e5);
	}

	dt {
		font-size: var(--f-sm);
		color: var(--gris);
		margin-bottom: 3px;
	}

	dd {
		color: var(--tinta);
		overflow-wrap: anywhere;
	}

	/* ── formularios del perfil ── */

	form {
		display: flex;
		flex-direction: column;
		gap: var(--e4);
	}

	.pareja {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: var(--e4);
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
	}

	label {
		font-size: var(--f-base);
		font-weight: 500;
		color: var(--tinta);
	}

	.opcional {
		font-weight: 400;
		color: var(--gris-2);
	}

	input[type='text'],
	input[type='password'] {
		width: 100%;
		padding: 11px 13px;
		font-family: inherit;
		font-size: var(--f-md);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		transition: border-color var(--t);
	}

	input[type='text']:focus,
	input[type='password']:focus {
		outline: none;
		border-color: var(--indigo);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	.mostrar {
		display: flex;
		align-items: center;
		gap: var(--e2);
		font-weight: 400;
		color: var(--gris);
		cursor: pointer;
	}

	.ayuda {
		font-size: var(--f-ms);
		color: var(--gris);
	}

	.botones {
		display: flex;
		gap: var(--e2);
		flex-wrap: wrap;
		margin-top: 2px;
	}


	.invitacion {
		padding: 30px 32px;
		height: 100%;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.invitacion h2 {
		font-size: var(--f-xl);
		margin-bottom: 6px;
	}

	.invitacion p {
		max-width: 560px;
		margin-bottom: 18px;
		color: var(--texto);
	}

	/* El enlace al catalogo: es la unica salida de esta tarjeta, asi que se
	   pinta como boton y no como texto subrayado. */
	/* Dos columnas que se vuelven una en pantalla chica. `align-items:
	   stretch` es lo que las deja de la misma altura aunque un texto sea mas
	   largo que el otro; sin eso, la mas corta queda flotando. */
	.salidas {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
		align-items: stretch;
		/* Separadas de lo de arriba y entre si. Con el gap de 20px que tenian y
		   sin margen propio quedaban pegadas a la seccion de direcciones y se
		   leian como parte de ella. Las secciones de esta pagina van a 28px,
		   asi que estas siguen esa medida y no una suya. */
		margin-top: 28px;
		gap: var(--e5);
	}

	/* La tarjeta es una columna para que el boton se pegue abajo con
	   margin-top:auto: asi los dos botones quedan a la misma altura aunque el
	   texto de arriba no mida lo mismo. */
	.salidas .invitacion {
		display: flex;
		flex-direction: column;
	}

	.salidas .invitacion .ir {
		margin-top: auto;
		align-self: flex-start;
	}

	.ir {
		display: inline-block;
		margin-top: 16px;
		padding: 10px 20px;
		font-size: var(--f-base);
		color: var(--blanco);
		background: var(--indigo);
		border-radius: var(--r);
		text-decoration: none;
	}

	@media (max-width: 620px) {
		main {
			padding-top: 32px;
		}
		.saludo {
			margin-bottom: 26px;
		}
		.perfil {
			padding: 22px 20px;
		}
		.acciones {
			margin-left: 0;
			width: 100%;
		}
		.pareja {
			grid-template-columns: 1fr;
		}
		.invitacion {
			padding: 24px 20px;
		}
	}
</style>
