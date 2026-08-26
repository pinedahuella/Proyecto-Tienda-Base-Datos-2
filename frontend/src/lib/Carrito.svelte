<script lang="ts">
	import { untrack } from 'svelte';
	import { fade, fly } from 'svelte/transition';
	import type { RespuestaApi } from './api';
	import {
		agregarLinea,
		restarLinea,
		guardarDesmarcadas,
		guardarPedidoAbierto,
		leerDesmarcadas,
		leerPedidoAbierto,
		listarPedidos,
		olvidarPedidoAbierto,
		pedidoCaduco,
		quetzales,
		quitarLinea,
		subtotal,
		totalPedido,
		traerPedido,
		type LineaPedido,
		type PedidoCompleto
	} from './pedido';

	/**
	 * El carrito lateral: el pedido pendiente, deslizado desde la derecha.
	 *
	 * Este componente NO compra. Junta las lineas, deja marcar cuales se
	 * quieren y le pasa la decision al checkout con `alPedirComprar`. La
	 * compra es una sola ruta (`POST /comprador/pedidos/:id/comprar`) que pide
	 * metodo de pago y a veces una tarjeta, y eso no cabe en un panel de 380px.
	 *
	 * Las tres cosas que hay que entender antes de tocarlo:
	 *
	 * 1. Se compra una OFERTA, no un producto: cada linea es un vendedor
	 *    concreto a su precio. Por eso sumar una unidad manda `id_oferta` y no
	 *    la variante -- sumarla por variante compraria a cualquiera.
	 *
	 * 2. El precio quedo CONGELADO al agregar la linea. `precio_unitario` es lo
	 *    que se va a cobrar aunque el vendedor lo haya subido despues, asi que
	 *    no hay que refrescarlo contra el catalogo.
	 *
	 * 3. El backend NO sabe que es una linea "seleccionada": un pedido se
	 *    compra ENTERO. Marcar y desmarcar vive solo en este navegador
	 *    (leerDesmarcadas/guardarDesmarcadas), y al comprar hay que quitar de
	 *    verdad lo desmarcado. De ahi el paso de confirmacion: quitar una linea
	 *    es un DELETE que no se deshace.
	 */

	let {
		abierto = false,
		alCerrar,
		alExpirarSesion,
		alPedirComprar
	}: {
		abierto?: boolean;
		alCerrar?: () => void;
		alExpirarSesion?: () => void;
		alPedirComprar?: (idPedido: string, lineasAComprar: LineaPedido[]) => void;
	} = $props();

	// ---------------------------------------------------------------- estado
	let idPedido = $state<string | null>(null);
	let lineas = $state<LineaPedido[]>([]);
	let cargando = $state(false);
	let error = $state('');

	/**
	 * Los id de linea DESMARCADOS, no los marcados: una linea nueva tiene que
	 * nacer marcada, y guardando lo desmarcado eso sale solo. Es el mismo
	 * criterio de pedido.ts, que es quien lo persiste.
	 */
	let desmarcadas = $state<string[]>([]);

	/**
	 * La linea sobre la que hay una peticion en curso.
	 *
	 * Apaga los botones de TODAS las lineas, no solo los suyos, y es a
	 * proposito: cada accion termina releyendo el pedido entero, asi que
	 * mientras una esta en vuelo lo que hay en pantalla ya no es la verdad y un
	 * segundo clic mandaria un DELETE contra una linea que quiza ya no existe.
	 */
	let ocupada = $state<string | null>(null);
	let errorAccion = $state('');

	/** true mientras se ensena el aviso de "esto va a quitar N lineas". */
	let confirmando = $state(false);
	let quitandoParaComprar = $state(false);

	// ---------------------------------------------------------------- derivados
	let marcadas = $derived(lineas.filter((l) => !desmarcadas.includes(l.id_pedido_producto)));
	let aQuitar = $derived(lineas.filter((l) => desmarcadas.includes(l.id_pedido_producto)));
	let total = $derived(totalPedido(marcadas));
	let todasMarcadas = $derived(lineas.length > 0 && aQuitar.length === 0);

	// ---------------------------------------------------------------- helpers
	/**
	 * true si la sesion se acabo. Apaga la pantalla de carga antes de avisar
	 * porque el que llama vuelve enseguida: sin esto el carrito se quedaria
	 * diciendo "Cargando..." para siempre detras del formulario de entrar.
	 */
	function expiro(r: RespuestaApi<unknown>): boolean {
		if (r.estado === 401) {
			cargando = false;
			ocupada = null;
			quitandoParaComprar = false;
			confirmando = false;
			alExpirarSesion?.();
			return true;
		}
		return false;
	}

	/**
	 * El texto que se ensena cuando algo salio mal.
	 *
	 * Un 0 quiere decir que la peticion ni salio, no que el backend fallara. Y
	 * el caso raro: `ok: true` con el payload en null. Ahi `mensaje` es el de
	 * EXITO ("Pedido obtenido"), asi que pintarlo tal cual dejaria un cartel
	 * rojo diciendo que todo salio bien.
	 */
	function mensajeDe(r: RespuestaApi<unknown>): string {
		if (r.estado === 0) return 'No se pudo conectar con el servidor';
		if (r.ok) return 'El servidor contesto sin los datos del pedido';
		return r.mensaje;
	}

	function cerrar() {
		alCerrar?.();
	}

	// ---------------------------------------------------------------- cargar
	/**
	 * Trae el pedido pendiente.
	 *
	 * Primero el id guardado en este navegador, que es el camino barato. Si no
	 * hay ninguno (o el guardado ya no sirve) se busca el pendiente en
	 * `GET /comprador/pedidos` y se vuelve a guardar: asi el carrito se
	 * recupera solo si se perdio el localStorage, en vez de dejar un pedido con
	 * lineas inalcanzable para siempre.
	 *
	 * `silencioso` es para releer DESPUES de una accion. Sin el, cada +1 cambia
	 * la lista entera por "Cargando..." y el pie desaparece un instante: se
	 * pierde el sitio donde estaba el scroll y parece que el carrito se vacio.
	 * La primera carga si lo ensena, porque ahi no hay nada mas que ensenar.
	 */
	async function cargar(silencioso = false) {
		if (!silencioso) cargando = true;
		error = '';

		/*
		 * `errorAccion` NO se limpia aqui, y es la parte contraintuitiva: quien
		 * recarga despues de un fallo (ver confirmarYComprar) acaba de escribir
		 * ahi POR QUE se detuvo. Limpiarlo dejaria el carrito cambiado a medias
		 * y sin una sola palabra de lo que paso. Lo limpia cada accion al
		 * empezar, y el efecto al abrir el panel.
		 */

		let completo: PedidoCompleto | null = null;
		const guardado = leerPedidoAbierto();

		if (guardado) {
			const r = await traerPedido(guardado);
			if (expiro(r)) return;

			if (pedidoCaduco(r)) {
				// 404: no existe o es de otra persona. En los dos casos lo que hay
				// en este navegador esta caduco; se sigue a buscar el pendiente.
				olvidarPedidoAbierto();
			} else if (!r.ok || !r.payload) {
				error = mensajeDe(r);
				cargando = false;
				return;
			} else if (r.payload.pedido.estado_pedido_nombre !== 'pendiente') {
				// Ya se compro o se cancelo: sigue siendo un pedido valido, pero
				// dejo de ser el carrito. Ensenarlo aqui invitaria a comprarlo otra
				// vez y el backend contestaria 409.
				olvidarPedidoAbierto();
			} else {
				completo = r.payload;
			}
		}

		if (!completo) {
			const rl = await listarPedidos();
			if (expiro(rl)) return;

			if (!rl.ok || !rl.payload) {
				error = mensajeDe(rl);
				cargando = false;
				return;
			}

			const pendiente = rl.payload.find((p) => p.estado_pedido_nombre === 'pendiente');
			if (!pendiente) {
				// No hay carrito abierto. No se crea uno aqui: crear un pedido pide
				// una direccion, y elegirla es del panel, no de este panel lateral.
				idPedido = null;
				lineas = [];
				desmarcadas = [];
				cargando = false;
				return;
			}

			const r2 = await traerPedido(pendiente.id_pedido);
			if (expiro(r2)) return;

			if (!r2.ok || !r2.payload) {
				error = mensajeDe(r2);
				cargando = false;
				return;
			}

			guardarPedidoAbierto(pendiente.id_pedido);
			completo = r2.payload;
		}

		idPedido = completo.pedido.id_pedido;
		lineas = completo.detalles ?? [];

		/*
		 * Se tira lo desmarcado que ya no corresponde a ninguna linea viva.
		 * Sin esto la lista crece sola con cada linea quitada, y el dia que
		 * PostgreSQL reutilizara un id_pedido_producto una linea nueva
		 * apareceria desmarcada sin que nadie la tocara.
		 */
		desmarcadas = leerDesmarcadas().filter((id) =>
			lineas.some((l) => l.id_pedido_producto === id)
		);
		guardarDesmarcadas(desmarcadas);

		cargando = false;
	}

	/*
	 * Se carga al ABRIR, no al montar: el carrito vive montado toda la sesion y
	 * lo que ensena tiene que ser lo de ahora, no lo de la ultima vez.
	 *
	 * La carga va dentro de untrack porque toca `lineas`, `idPedido` y
	 * `desmarcadas`: sin el, escribirlas volveria a disparar este mismo efecto
	 * y el carrito se pediria a si mismo en bucle.
	 */
	$effect(() => {
		if (!abierto) return;
		untrack(() => {
			confirmando = false;
			errorAccion = '';
			cargar();
		});
	});

	/*
	 * Con el panel abierto, la pagina de atras no se desplaza: si lo hiciera,
	 * la rueda del raton sobre el fondo moveria el catalogo y el carrito
	 * pareceria colgado. Se restaura quitando la propiedad, no poniendo
	 * 'visible', para no pisar el overflow-x del layout.
	 */
	$effect(() => {
		if (!abierto) return;
		const previo = document.body.style.overflow;
		document.body.style.overflow = 'hidden';
		return () => {
			document.body.style.overflow = previo;
		};
	});

	// ---------------------------------------------------------------- marcar
	function alternar(id: string) {
		desmarcadas = desmarcadas.includes(id)
			? desmarcadas.filter((x) => x !== id)
			: [...desmarcadas, id];
		guardarDesmarcadas(desmarcadas);
		// El aviso habla de una seleccion concreta ("se van a quitar 2"); si la
		// seleccion cambia, ese numero ya no es el que se confirmo.
		confirmando = false;
	}

	function alternarTodo() {
		desmarcadas = todasMarcadas ? lineas.map((l) => l.id_pedido_producto) : [];
		guardarDesmarcadas(desmarcadas);
		confirmando = false;
	}

	// ---------------------------------------------------------------- acciones
	async function quitar(linea: LineaPedido) {
		if (!idPedido || ocupada !== null) return;

		ocupada = linea.id_pedido_producto;
		errorAccion = '';
		confirmando = false;

		const r = await quitarLinea(idPedido, linea.id_pedido_producto);
		if (expiro(r)) return;

		if (!r.ok) {
			ocupada = null;
			errorAccion = mensajeDe(r);
			return;
		}

		// Se recarga el pedido entero en vez de sacar la fila de la lista: el
		// pedido pudo cambiar por otra pestana, y el total lo manda el backend.
		// `ocupada` se suelta DESPUES de la recarga, no antes: entre el DELETE y
		// la respuesta nueva la lista de pantalla es la vieja, y con los botones
		// vivos un segundo clic borraria por id una linea que ya no esta.
		await cargar(true);
		ocupada = null;
	}

	/**
	 * Suma UNA unidad a la linea.
	 *
	 * `agregarLinea` acumula: manda 1 y el backend deja la cantidad en n+1.
	 * `restarLinea` es su espejo y hace el -1.
	 *
	 * Sigue sin existir una ruta para FIJAR una cantidad: solo se sube y se baja
	 * de a poco. Y bajar hasta 0 no deja una linea en cero, la BORRA -- el
	 * backend lo hace solo y lo avisa con `eliminada`.
	 *
	 * El Number() sobre id_oferta es la unica conversion legitima de un id en
	 * todo el archivo: `agregarLinea` pide un numero porque el backend valida
	 * "entero mayor a 0" en el cuerpo. Va en el cuerpo de la peticion y no se
	 * guarda ni se compara con nada, asi que no arrastra la perdida de
	 * precision que el resto del codigo evita.
	 */
	async function sumarUno(linea: LineaPedido) {
		if (!idPedido || ocupada !== null) return;

		ocupada = linea.id_pedido_producto;
		errorAccion = '';

		const r = await agregarLinea(idPedido, {
			id_oferta: Number(linea.id_oferta),
			cantidad: 1
		});
		if (expiro(r)) return;

		if (!r.ok) {
			ocupada = null;
			// Un 409 aqui es "no hay suficiente stock" o "la oferta se pauso", con
			// el mensaje ya escrito por PostgreSQL: se ensena tal cual. No se dice
			// "agotado" a secas: un 0 seria el backend caido, y son cosas distintas.
			errorAccion = mensajeDe(r);
			return;
		}

		await cargar(true);
		ocupada = null;
	}

	/**
	 * Resta UNA unidad.
	 *
	 * Si la linea queda en 0 el backend la borra entera y contesta
	 * `eliminada: true`. Por eso se recarga el pedido en vez de descontar el
	 * numero en memoria: la linea puede haber dejado de existir.
	 */
	async function restarUno(linea: LineaPedido) {
		if (!idPedido || ocupada !== null) return;

		ocupada = linea.id_pedido_producto;
		errorAccion = '';

		const r = await restarLinea(idPedido, {
			id_oferta: Number(linea.id_oferta),
			cantidad: 1
		});
		if (expiro(r)) return;

		if (!r.ok) {
			ocupada = null;
			errorAccion = mensajeDe(r);
			return;
		}

		await cargar(true);
		ocupada = null;
	}

	// ---------------------------------------------------------------- comprar
	/**
	 * El boton de comprar.
	 *
	 * Si todo esta marcado, se le pasa el pedido al checkout y ya. Si hay algo
	 * desmarcado NO se compra todavia: primero el aviso, porque seguir implica
	 * borrar esas lineas del pedido de verdad.
	 */
	function pedirComprar() {
		if (!idPedido || marcadas.length === 0) return;

		if (aQuitar.length > 0) {
			confirmando = true;
			return;
		}

		alPedirComprar?.(idPedido, [...marcadas]);
	}

	/**
	 * Lo que pasa despues del aviso: se quitan las desmarcadas, una por una, y
	 * recien entonces se manda a comprar.
	 *
	 * Es en serie a proposito y no con Promise.all: si una falla hay que parar
	 * ahi y volver a leer el pedido, no seguir borrando a ciegas.
	 */
	async function confirmarYComprar() {
		if (!idPedido) return;

		// Se fotografia ANTES de tocar nada: `marcadas` es derivado de
		// `desmarcadas` y de `lineas`, y las dos estan a punto de cambiar.
		const compradas = [...marcadas];
		const sobran = [...aQuitar];

		quitandoParaComprar = true;
		errorAccion = '';

		for (const linea of sobran) {
			const r = await quitarLinea(idPedido, linea.id_pedido_producto);
			if (expiro(r)) return;

			if (!r.ok) {
				errorAccion = `No se pudo quitar "${linea.nombre_producto}": ${mensajeDe(r)}`;
				quitandoParaComprar = false;
				confirmando = false;
				// Alguna se pudo haber quitado ya, asi que lo que hay en pantalla
				// dejo de ser verdad: se vuelve a leer antes de dejar seguir. Va en
				// silencio para no tapar el motivo que se acaba de escribir con una
				// pantalla de carga.
				await cargar(true);
				return;
			}
		}

		desmarcadas = [];
		guardarDesmarcadas([]);
		lineas = compradas;
		quitandoParaComprar = false;
		confirmando = false;

		alPedirComprar?.(idPedido, compradas);
	}

	function alTeclear(evento: KeyboardEvent) {
		if (!abierto || evento.key !== 'Escape') return;

		// Escape cancela primero el aviso y solo despues cierra: si cerrara el
		// panel entero, salir del aviso costaria reabrir y volver a marcar.
		if (confirmando) {
			confirmando = false;
			return;
		}
		cerrar();
	}
</script>

<svelte:window onkeydown={alTeclear} />

{#if abierto}
	<!-- El fondo es un <button> y no un <div> con onclick: hace falta que se
	     pueda cerrar con el teclado, y un boton ya trae Enter, Espacio y el
	     foco sin escribir nada a mano. -->
	<button
		type="button"
		class="fondo"
		aria-label="Cerrar el carrito"
		onclick={cerrar}
		transition:fade={{ duration: 150 }}
	></button>

	<!-- Un <div> y no un <aside>: el rol de dialogo sobre un elemento que ya
	     tiene significado propio es contradictorio, y el lector de pantalla se
	     queda con uno de los dos. -->
	<div
		class="carrito"
		role="dialog"
		aria-modal="true"
		aria-label="Tu carrito"
		transition:fly={{ x: 400, duration: 220 }}
	>
		<header class="cabeza">
			<div>
				<h2>Tu carrito</h2>
				<p class="menor">
					{#if lineas.length === 0}
						Sin lineas
					{:else}
						{lineas.length}
						{lineas.length === 1 ? 'linea' : 'lineas'}
					{/if}
				</p>
			</div>
			<button type="button" class="cerrar" aria-label="Cerrar el carrito" onclick={cerrar}>
				&times;
			</button>
		</header>

		<div class="cuerpo">
			<!-- Fuera de las ramas de abajo a proposito: una accion puede dejar el
			     carrito vacio (quitar la ultima linea, o pararse a medio camino en
			     el aviso de comprar). Si el mensaje viviera dentro de la rama "hay
			     lineas", el motivo del fallo desapareceria justo en el caso en que
			     mas falta hace. -->
			{#if errorAccion}
				<p class="malo" role="alert">{errorAccion}</p>
			{/if}

			{#if cargando}
				<p class="quieto">Cargando tu carrito...</p>
			{:else if error}
				<p class="malo" role="alert">{error}</p>
				<!-- Con `onclick={cargar}` el navegador pasaria el MouseEvent como
				     primer argumento, o sea `silencioso` a true: se reintentaria sin
				     ninguna senal de que algo esta pasando. -->
				<button type="button" onclick={() => cargar()}>Reintentar</button>
			{:else if idPedido === null || lineas.length === 0}
				<div class="vacio">
					<p class="quieto">Tu carrito esta vacio.</p>
					<p class="menor">
						Se compra la oferta de un vendedor concreto, asi que la linea se agrega desde la
						ficha del producto.
					</p>
					<a class="enlace" href="/" onclick={cerrar}>Ver el catalogo</a>
				</div>
			{:else}
				<div class="todo">
					<label class="marcatodo">
						<input type="checkbox" checked={todasMarcadas} onchange={alternarTodo} />
						{todasMarcadas ? 'Desmarcar todo' : 'Marcar todo'}
					</label>
					<span class="menor">{marcadas.length} de {lineas.length}</span>
				</div>

				<ul class="lista">
					{#each lineas as linea (linea.id_pedido_producto)}
						{@const marcada = !desmarcadas.includes(linea.id_pedido_producto)}
						<li class="linea" class:apagada={!marcada}>
							<input
								type="checkbox"
								class="marca"
								checked={marcada}
								onchange={() => alternar(linea.id_pedido_producto)}
								aria-label={`Comprar ${linea.nombre_producto} ${linea.nombre_variante}`}
							/>

							<div class="datos">
								<h3>{linea.nombre_producto}</h3>
								<p class="menor">{linea.nombre_variante}</p>
								<p class="menor">Vendido por {linea.nombre_vendedor}</p>

								<p class="cuentas">
									<span class="menor">
										{quetzales(Number(linea.precio_unitario))} x {linea.cantidad}
									</span>
									<strong>{quetzales(subtotal(linea))}</strong>
								</p>

								<div class="acciones">
									<button
										type="button"
										onclick={() => restarUno(linea)}
										disabled={ocupada !== null}
										title="Resta una unidad. Al llegar a 0 la linea se quita sola."
									>
										-1
									</button>
									<button
										type="button"
										onclick={() => sumarUno(linea)}
										disabled={ocupada !== null}
										title="Suma una unidad"
									>
										+1
									</button>
									<button
										type="button"
										class="quitar"
										onclick={() => quitar(linea)}
										disabled={ocupada !== null}
									>
										Quitar
									</button>
								</div>
							</div>
						</li>
					{/each}
				</ul>

				<!-- Dicho una vez y a la vista, no escondido en un tooltip. -->
				<p class="nota menor">
					Con <strong>+1</strong> y <strong>-1</strong> se sube y se baja de a una unidad. Al
					llegar a 0, la linea se quita sola del pedido.
				</p>
			{/if}
		</div>

		{#if !cargando && !error && idPedido !== null && lineas.length > 0}
			<footer class="pie">
				{#if confirmando}
					<!-- El aviso del punto delicado: el backend compra el pedido
					     ENTERO, asi que comprar solo una parte obliga a BORRAR el
					     resto de verdad. Nunca se quita nada sin pasar por aqui. -->
					<div class="aviso" role="alert">
						<p class="titulo">
							Para comprar solo lo marcado hay que quitar
							{aQuitar.length}
							{aQuitar.length === 1 ? 'linea' : 'lineas'} del pedido
						</p>
						<p class="menor">
							Un pedido se compra completo: no hay forma de pagar una parte y dejar el resto
							guardado. <strong>Quitarlas no se puede deshacer</strong>; para recuperarlas
							habria que volver a agregarlas desde la ficha.
						</p>
						<ul class="menor sobran">
							{#each aQuitar as linea (linea.id_pedido_producto)}
								<li>{linea.nombre_producto} - {linea.nombre_variante}</li>
							{/each}
						</ul>
						<div class="acciones">
							<button
								type="button"
								class="principal"
								onclick={confirmarYComprar}
								disabled={quitandoParaComprar}
							>
								{quitandoParaComprar ? 'Quitando...' : `Quitar ${aQuitar.length} y comprar`}
							</button>
							<button
								type="button"
								onclick={() => (confirmando = false)}
								disabled={quitandoParaComprar}
							>
								Mejor no
							</button>
						</div>
					</div>
				{:else}
					<div class="total">
						<div>
							<span class="menor">
								{marcadas.length} de {lineas.length}
								{lineas.length === 1 ? 'linea marcada' : 'lineas marcadas'}
							</span>
							<strong class="grande">{quetzales(total)}</strong>
						</div>
						<button
							type="button"
							class="principal comprar"
							onclick={pedirComprar}
							disabled={marcadas.length === 0 || ocupada !== null}
						>
							Comprar
						</button>
					</div>

					{#if marcadas.length === 0}
						<p class="menor">Marca al menos una linea para poder comprar.</p>
					{/if}
				{/if}
			</footer>
		{/if}
	</div>
{/if}

<style>
	/* ---------- el armazon ---------- */

	.fondo {
		position: fixed;
		inset: 0;
		z-index: 60;
		/* No hay variable de sombra en la paleta, asi que el velo se mezcla a
		   partir de una que ya sea oscura. En el tema claro esa es --tinta (el
		   texto principal, casi negro). */
		background: color-mix(in srgb, var(--tinta) 45%, transparent);
		border: 0;
		/* La regla `button` de mas abajo le pondria el relleno y las esquinas
		   redondeadas de un boton normal, y esto cubre la pantalla entera: las
		   esquinas dejarian ver cuatro mordiscos de la pagina sin velo. */
		border-radius: 0;
		padding: 0;
		cursor: pointer;
	}

	/* El velo es la unica cosa del componente que NO puede salir de la misma
	   variable en los dos temas: --tinta significa "el texto principal", y en
	   oscuro eso es casi blanco. Con la regla de arriba a secas, abrir el
	   carrito de noche ACLARABA la pagina de atras en vez de apagarla. --off es
	   el fondo del sitio, que ahi si es lo mas oscuro que hay. */
	:global(html[data-tema='oscuro']) .fondo {
		background: color-mix(in srgb, var(--off) 70%, transparent);
	}

	.carrito {
		position: fixed;
		top: 0;
		right: 0;
		bottom: 0;
		z-index: 61;
		display: flex;
		flex-direction: column;
		width: 380px;
		max-width: 100%;
		background: var(--blanco);
		border-left: 1px solid var(--linea);
		color: var(--texto);
	}

	@media (max-width: 620px) {
		.carrito {
			width: 100%;
		}
	}

	.cabeza {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: 0.75rem;
		padding: 1rem 1.1rem;
		border-bottom: 1px solid var(--linea);
	}

	h2 {
		font-size: 1.15rem;
		font-weight: 600;
		color: var(--tinta);
	}

	.cerrar {
		padding: 0 0.5rem;
		font-size: 1.5rem;
		line-height: 1.2;
		background: transparent;
		border: 1px solid transparent;
	}

	/* El unico que se desplaza: el total y el boton de comprar se quedan
	   pegados abajo aunque la lista sea larga. */
	.cuerpo {
		flex: 1;
		overflow-y: auto;
		padding: 1rem 1.1rem;
	}

	.pie {
		padding: 0.9rem 1.1rem;
		background: var(--off);
		border-top: 1px solid var(--linea);
	}

	/* ---------- la lista ---------- */

	.todo {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.5rem;
		padding-bottom: 0.7rem;
		border-bottom: 1px solid var(--linea);
	}

	.marcatodo {
		display: flex;
		align-items: center;
		gap: 0.45rem;
		font-size: 0.88rem;
		color: var(--tinta);
		cursor: pointer;
	}

	.lista {
		list-style: none;
	}

	.linea {
		display: flex;
		align-items: flex-start;
		gap: 0.6rem;
		padding: 0.85rem 0;
		border-bottom: 1px solid var(--linea);
	}

	/* La desmarcada se ve apagada pero no se esconde: sigue estando en el
	   pedido, y esa es justo la informacion que hace falta para entender el
	   aviso de antes de comprar. */
	.linea.apagada {
		opacity: 0.55;
	}

	.marca {
		margin-top: 0.25rem;
		flex: none;
	}

	.datos {
		flex: 1;
		min-width: 0;
	}

	h3 {
		font-size: 0.95rem;
		font-weight: 600;
		color: var(--tinta);
	}

	.cuentas {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 0.5rem;
		margin-top: 0.35rem;
	}

	.cuentas strong {
		color: var(--tinta);
	}

	.acciones {
		display: flex;
		flex-wrap: wrap;
		gap: 0.4rem;
		margin-top: 0.5rem;
	}

	.nota {
		margin-top: 0.8rem;
	}

	/* ---------- el pie ---------- */

	.total {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.75rem;
	}

	.total div {
		display: flex;
		flex-direction: column;
	}

	.grande {
		font-size: 1.25rem;
		color: var(--tinta);
	}

	.comprar {
		padding: 0.6rem 1.4rem;
		font-size: 0.95rem;
	}

	.aviso .titulo {
		color: var(--tinta);
		margin-bottom: 0.35rem;
	}

	.aviso {
		padding: 0.75rem 0.85rem;
		background: var(--panel);
		border: 1px solid var(--rojo);
		border-radius: var(--r2);
	}

	.sobran {
		margin: 0.5rem 0 0 1.1rem;
	}

	/* ---------- lo comun ---------- */

	.menor {
		font-size: 0.85rem;
		color: var(--gris);
	}

	.quieto {
		padding: 1rem 0;
		color: var(--gris);
		font-size: 0.9rem;
	}

	.malo {
		padding: 0.6rem 0.8rem;
		margin-bottom: 0.8rem;
		background: var(--panel);
		color: var(--rojo);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
		font-size: 0.88rem;
	}

	.vacio {
		padding-top: 1rem;
	}

	.enlace {
		display: inline-block;
		margin-top: 0.9rem;
		color: var(--indigo);
	}

	button {
		padding: 0.4rem 0.75rem;
		background: var(--blanco);
		color: var(--tinta);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		font: inherit;
		font-size: 0.85rem;
		cursor: pointer;
		transition: border-color var(--t);
	}

	button:hover:not(:disabled) {
		border-color: var(--indigo);
	}

	button:disabled {
		opacity: 0.55;
		cursor: default;
	}

	.principal {
		background: var(--indigo);
		color: var(--blanco);
		border-color: var(--indigo);
	}

	.principal:hover:not(:disabled) {
		background: var(--indigo-os);
		border-color: var(--indigo-os);
	}

	.quitar:hover:not(:disabled) {
		border-color: var(--rojo);
		color: var(--rojo);
	}
</style>
