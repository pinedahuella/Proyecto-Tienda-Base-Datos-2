<script lang="ts">
	import { onMount } from 'svelte';
	import { conJson, mensajeUtil, pedir } from './api';

	/**
	 * Las resenas de un producto, en su ficha.
	 *
	 * Las tres tablas de la parte social existen desde la migracion 011:
	 * `resena`, `comentario` y `likes`. Esta es su pantalla.
	 *
	 *
	 * QUE SE ESTA CALIFICANDO, QUE NO ES OBVIO
	 * ---------------------------------------------------------------
	 * La resena NO es del producto: es de un VENDEDOR sobre ese producto.
	 * El catalogo es compartido y un producto no es de nadie, asi que "esta
	 * laptop es mala" no tiene a quien reclamarle; "Carlos me la mando tarde"
	 * si. Por eso cada resena de aqui abajo dice a quien califica, y por eso
	 * se pueden agrupar por vendedor.
	 *
	 * La consecuencia que hay que tener presente al leer la pantalla: la nota
	 * del producto es el promedio de las de sus vendedores, asi que una queja
	 * de envio cuenta para la nota del producto. Amazon las separa; aqui van
	 * juntas, y esta decidido asi a proposito.
	 *
	 *
	 * EL TEXTO ES UN COMENTARIO, NO UNA COLUMNA DE LA RESENA
	 * ---------------------------------------------------------------
	 * `resena` guarda la calificacion y apunta a su comentario RAIZ, que es
	 * donde viven el texto y la fecha. Las respuestas cuelgan de esa raiz.
	 * Por eso el voto (like/dislike) va contra `id_comentario` y no contra
	 * `id_resena`: asi una misma tabla de votos sirve para la resena y para
	 * las respuestas.
	 *
	 *
	 * LAS CINCO RUTAS, YA CONSTRUIDAS Y PROBADAS
	 * ---------------------------------------------------------------
	 *   GET    /productos/:id/resenas       la lista con sus respuestas
	 *   POST   /resenas                     escribir una
	 *   POST   /resenas/:id/respuestas      contestar
	 *   PUT    /comentarios/:id/voto        votar a favor o en contra
	 *   DELETE /comentarios/:id/voto        quitar el voto
	 *
	 * DOS REGLAS DEL BACKEND que esta pantalla obedece y no endurece:
	 *
	 * 1. Para calificar hay que HABER COMPRADO Y PAGADO ese producto a ese
	 *    vendedor. Por eso el boton de escribir sale de `puede_calificar`, que
	 *    ya viene filtrado, y no de una lista de vendedores armada aqui: si se
	 *    armara aqui, ofreceria vendedores que el servidor va a rechazar.
	 * 2. Contesta CUALQUIERA con sesion, no solo el vendedor calificado.
	 *
	 * Las dos las decidio el backend y estan en su endpoints-resenas.md.
	 *
	 * El estado "todavia no estan conectadas" se queda por si el backend se
	 * cae o alguien corre el frontend sin el: dice eso en vez de "no hay
	 * resenas", que seria mentira teniendo 86 en la base -- y de las caras,
	 * porque nadie sale a buscar un bug que la pantalla afirma que no existe.
	 */

	let {
		idProducto,
		haySesion,
		correoSesion = null,
		alContar = undefined
	}: {
		idProducto: number;
		haySesion: boolean;
		correoSesion?: string | null;
		/**
		 * Se llama con cuantas resenas tiene el producto, cada vez que se
		 * recargan. Lo usa la pestana "Resenas" de la ficha para poner el numero
		 * sin tener que pedir lo mismo dos veces.
		 *
		 * Va el total del RESUMEN y no `resenas.length`, que es solo la pagina
		 * que se esta ensenando. Con paginacion las dos cifras dejan de coincidir
		 * y la pestana diria "10" sobre un producto con 40.
		 *
		 * Es opcional: quien no lo pase no paga nada.
		 */
		alContar?: (total: number) => void;
	} = $props();

	interface Voto {
		/** Lo que voto ESTA cuenta: 1, -1, o null si no voto. */
		mio: number | null;
		a_favor: number;
		en_contra: number;
	}

	interface Respuesta {
		id_comentario: number;
		autor_usuario: string;
		autor_correo: string;
		comentario: string;
		fecha_publicacion: string;
		voto: Voto;
	}

	interface Resena {
		id_resena: number;
		id_comentario: number;
		calificacion: number;
		comentario: string;
		fecha_publicacion: string;
		autor_usuario: string;
		autor_correo: string;
		vendedor_usuario: string;
		vendedor_correo: string;
		vendedor_nombre: string;
		voto: Voto;
		respuestas: Respuesta[];
	}

	interface RespuestaResenas {
		resenas: Resena[];
		resumen: {
			total: number;
			promedio: number;
			/** Cuantas de cada nota, de 1 a 5. Es lo que dibuja las barras. */
			reparto: Record<string, number>;
		};
		/** Los vendedores del producto a los que esta cuenta todavia puede calificar. */
		puede_calificar: { correo: string; usuario: string; nombre: string }[];
	}

	let resenas = $state<Resena[]>([]);
	let resumen = $state<RespuestaResenas['resumen'] | null>(null);
	let puedeCalificar = $state<RespuestaResenas['puede_calificar']>([]);

	let cargando = $state(true);
	let error = $state('');
	let sinConectar = $state(false);

	/**
	 * Las dos preguntas que contestan POR QUE no se puede escribir.
	 *
	 *   GET /productos/:id/comprado  -> { comprado: boolean }
	 *   GET /productos/:id/resenado  -> { resenado: boolean }
	 *
	 * `null` = no se sabe (sin sesion, o el backend todavia no las expone).
	 *
	 * Existen para arreglar un problema concreto de esta pantalla: cuando no se
	 * puede escribir, el boton simplemente NO ESTABA. Una ausencia no explica
	 * nada -- se ve igual que si estuviera roto, y de hecho asi se reporto.
	 * Con estas dos, cada caso dice lo suyo.
	 *
	 * NO reemplazan a `puede_calificar`, que sigue siendo quien decide: es el
	 * unico que sabe a QUE vendedores se puede calificar todavia. `resenado` es
	 * mas grueso -- dice "ya resenaste este producto a ALGUIEN" -- y puede ser
	 * `true` mientras aun queden vendedores por calificar. Usarlo para ocultar
	 * el boton esconderia una accion legitima.
	 */
	let comprado = $state<boolean | null>(null);
	let resenado = $state<boolean | null>(null);

	/**
	 * Que hacer con el area de escribir. Un solo lugar donde se decide, en vez
	 * de tres condiciones repartidas por el marcado que se contradicen sin que
	 * nadie lo note.
	 */
	let estadoEscribir = $derived.by(() => {
		if (!haySesion) return 'sin-sesion';
		if (puedeCalificar.length > 0) return 'puede';
		if (comprado === false) return 'no-comprado';
		if (resenado === true) return 'ya-resenado';
		// Con sesion, sin vendedores calificables y sin saber por que: es lo que
		// pasa mientras el backend no exponga las dos rutas de arriba. No se
		// inventa un motivo -- no se dice nada.
		return 'nada';
	});

	/** El formulario de escribir. Cerrado hasta que se pide. */
	let escribiendo = $state(false);
	let vendedorElegido = $state('');
	let notaElegida = $state(5);
	let textoNuevo = $state('');
	let enviando = $state(false);
	let errorFormulario = $state('');
	let confirmacion = $state('');

	/** A que resena se le esta contestando, por id. */
	let contestando = $state<number | null>(null);
	let textoRespuesta = $state('');

	/** Filtro por nota. null = todas. */
	let filtroNota = $state<number | null>(null);

	let visibles = $derived(
		filtroNota === null ? resenas : resenas.filter((r) => r.calificacion === filtroNota)
	);

	// onMount y no $effect: una sola carga al montar. Con $effect se repite
	// solo, y ademas cada vuelta desmontaria el formulario a medio escribir.
	onMount(cargar);

	async function cargar() {
		cargando = true;
		error = '';
		sinConectar = false;

		const respuesta = await pedir<RespuestaResenas>(`/productos/${idProducto}/resenas`);

		cargando = false;

		// 404 aqui es ambiguo y hay que tratarlo con cuidado: puede ser que la
		// ruta no exista todavia, o que el producto no exista. Se distingue por
		// el mensaje del backend cuando lo hay; si no, se asume ruta pendiente,
		// que es la situacion de hoy.
		if (respuesta.estado === 404) {
			sinConectar = true;
			return;
		}

		if (!respuesta.ok || !respuesta.payload) {
			error = mensajeUtil(respuesta);
			return;
		}

		resenas = respuesta.payload.resenas ?? [];
		resumen = respuesta.payload.resumen ?? null;
		puedeCalificar = respuesta.payload.puede_calificar ?? [];

		// El total, para quien lo haya pedido. Va aqui y no en un $effect para
		// que se avise UNA vez por carga: un $effect sobre `resumen` se
		// dispararia tambien al escribir o borrar una resena, que es justo
		// cuando esta funcion se vuelve a llamar de todos modos.
		//
		// Un cero SI se reporta: "cero resenas" es un dato tan bueno como
		// cuatro, y quien lo pide ya distingue el cero del "todavia no llego"
		// porque su variable arranca en null.
		alContar?.(resumen?.total ?? 0);

		// Si solo hay un vendedor calificable, se elige solo: un select de una
		// sola opcion es un paso que no decide nada.
		if (puedeCalificar.length === 1) vendedorElegido = puedeCalificar[0].correo;

		await cargarPorQue();
	}

	/**
	 * Las dos rutas que explican el porque. Solo con sesion: sin ella contestan
	 * 401 y la respuesta ya se sabe ("inicia sesion").
	 *
	 * Van juntas y DESPUES de la lista, no antes: la lista es lo que la persona
	 * vino a leer y no tiene que esperar por dos booleanos que solo cambian un
	 * texto.
	 *
	 * Si alguna contesta 404 -- porque el backend todavia no la tiene, o porque
	 * no compila -- se queda en `null` y la pantalla no dice nada en vez de
	 * inventar un motivo. Es la misma regla del resto del componente: callar
	 * antes que afirmar algo que no se sabe.
	 */
	async function cargarPorQue() {
		if (!haySesion) {
			comprado = null;
			resenado = null;
			return;
		}

		const [c, r] = await Promise.all([
			pedir<{ comprado: boolean }>(`/productos/${idProducto}/comprado`),
			pedir<{ resenado: boolean }>(`/productos/${idProducto}/resenado`)
		]);

		comprado = c.ok && c.payload ? c.payload.comprado : null;
		resenado = r.ok && r.payload ? r.payload.resenado : null;
	}

	function abrirFormulario() {
		escribiendo = true;
		errorFormulario = '';
		confirmacion = '';
		textoNuevo = '';
		notaElegida = 5;
		if (puedeCalificar.length === 1) vendedorElegido = puedeCalificar[0].correo;
	}

	async function enviar(evento: SubmitEvent) {
		evento.preventDefault();
		errorFormulario = '';

		if (!vendedorElegido) {
			errorFormulario = 'Elige a que vendedor estas calificando';
			return;
		}
		// String(x ?? '') antes de trim: si algun dia esto se llena desde un
		// input numerico, .trim() sobre un numero revienta con "is not a
		// function". Ya paso en este proyecto.
		if (!String(textoNuevo ?? '').trim()) {
			errorFormulario = 'Escribe tu comentario';
			return;
		}

		enviando = true;

		const respuesta = await pedir(
			'/resenas',
			conJson('POST', {
				id_producto: idProducto,
				correo_vendedor: vendedorElegido,
				calificacion: notaElegida,
				comentario: String(textoNuevo).trim()
			})
		);

		enviando = false;

		if (!respuesta.ok) {
			errorFormulario = mensajeUtil(respuesta);
			return;
		}

		confirmacion = respuesta.mensaje || 'Tu resena se publico';
		escribiendo = false;
		await cargar();
	}

	async function responder(resena: Resena) {
		if (!String(textoRespuesta ?? '').trim()) return;

		const respuesta = await pedir(
			`/resenas/${resena.id_resena}/respuestas`,
			conJson('POST', { comentario: String(textoRespuesta).trim() })
		);

		if (!respuesta.ok) {
			error = mensajeUtil(respuesta);
			return;
		}

		contestando = null;
		textoRespuesta = '';
		await cargar();
	}

	/**
	 * Vota, o quita el voto si se vuelve a pulsar el mismo.
	 *
	 * Se pinta el cambio ANTES de que conteste el servidor y se deshace si
	 * falla. Un voto que tarda medio segundo en verse se pulsa dos veces, y la
	 * segunda pulsacion lo quita: el resultado es que "no funciona".
	 */
	async function votar(voto: Voto, idComentario: number, valor: number) {
		const antes = { ...voto };
		const quitando = voto.mio === valor;

		if (quitando) {
			if (valor === 1) voto.a_favor--;
			else voto.en_contra--;
			voto.mio = null;
		} else {
			if (voto.mio === 1) voto.a_favor--;
			if (voto.mio === -1) voto.en_contra--;
			if (valor === 1) voto.a_favor++;
			else voto.en_contra++;
			voto.mio = valor;
		}

		const respuesta = quitando
			? await pedir<Voto>(`/comentarios/${idComentario}/voto`, { method: 'DELETE' })
			: await pedir<Voto>(`/comentarios/${idComentario}/voto`, conJson('PUT', { valor }));

		if (!respuesta.ok) {
			voto.mio = antes.mio;
			voto.a_favor = antes.a_favor;
			voto.en_contra = antes.en_contra;
			error = mensajeUtil(respuesta);
			return;
		}

		// Las dos cuentas de arriba fueron una SUPOSICION para que el boton
		// respondiera al instante. El backend devuelve las de verdad, contadas
		// por el trigger, asi que se pisan con ellas.
		//
		// No es un detalle: si otra persona voto el mismo comentario mientras
		// esta estaba mirando, la suposicion queda corta y no hay nada que la
		// corrija hasta recargar la pagina. Con la respuesta del servidor, cada
		// voto pone el numero al dia de paso.
		if (respuesta.payload) {
			voto.mio = respuesta.payload.mio;
			voto.a_favor = respuesta.payload.a_favor;
			voto.en_contra = respuesta.payload.en_contra;
		}
	}

	function fecha(valor: string): string {
		return new Date(valor).toLocaleDateString('es-GT', {
			day: 'numeric',
			month: 'long',
			year: 'numeric'
		});
	}

	/** Las estrellas como texto. Sin iconos: no hay libreria y no hace falta. */
	function estrellas(n: number): string {
		return '*'.repeat(n) + '.'.repeat(5 - n);
	}

	function cuantasDe(nota: number): number {
		return Number(resumen?.reparto?.[String(nota)] ?? 0);
	}

	function porcentajeDe(nota: number): number {
		if (!resumen || !resumen.total) return 0;
		return Math.round((cuantasDe(nota) / resumen.total) * 100);
	}
</script>

<section class="resenas">
	<div class="titulo">
		<h2>Resenas</h2>
		{#if resumen && resumen.total > 0}
			<span class="etiqueta">{resumen.total} {resumen.total === 1 ? 'resena' : 'resenas'}</span>
		{/if}
		{#if estadoEscribir === 'puede' && !sinConectar && !cargando && !escribiendo}
			<div class="acciones">
				<button type="button" onclick={abrirFormulario}>Escribir una resena</button>
			</div>
		{/if}
	</div>

	<p class="intro">
		Cada resena califica a <strong>un vendedor</strong> sobre este producto, no al producto en
		si: el catalogo es compartido y lo que se juzga es a quien te lo vendio.
	</p>

	<!-- Por que no se puede escribir. Antes de esto el boton simplemente no
	     aparecia, y una ausencia no explica nada: se ve igual que si la pantalla
	     estuviera rota. Cada caso dice lo suyo, y el caso 'nada' -- cuando no se
	     sabe el motivo -- no dice nada, que es mejor que inventarlo. -->
	{#if !sinConectar && !cargando && !escribiendo}
		{#if estadoEscribir === 'sin-sesion'}
			<p class="porque-no">
				<a href="/entrar">Inicia sesion</a> para escribir una resena.
			</p>
		{:else if estadoEscribir === 'no-comprado'}
			<p class="porque-no">
				Solo puedes resenar a un vendedor al que le compraste este producto. Cuando lo
				compres y se pague, vas a poder calificarlo.
			</p>
		{:else if estadoEscribir === 'ya-resenado'}
			<p class="porque-no">
				Ya resenaste a todos los vendedores de este producto a los que les compraste. Se
				puede escribir una resena por vendedor.
			</p>
		{/if}
	{/if}

	{#if confirmacion}
		<p class="hecho" role="status">{confirmacion}</p>
	{/if}

	{#if cargando}
		<p class="gris">Cargando las resenas...</p>
	{:else if sinConectar}
		<!-- Ni "no hay resenas" ni un error: la ruta falta. Decirlo con
		     precision evita que alguien de por vacio un producto que si tiene
		     resenas en la base. -->
		<div class="pendiente">
			<h3>Las resenas todavia no estan conectadas</h3>
			<p>
				Las tablas existen desde la migracion <code>011</code> y hay resenas sembradas, pero el
				backend todavia no expone <code>GET /productos/:id/resenas</code>.
			</p>
			<p class="gris">La forma exacta que espera esta pantalla esta en <code>docs/BACKEND-PENDIENTE.md</code>.</p>
		</div>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else}
		{#if resumen && resumen.total > 0}
			<div class="resumen">
				<div class="promedio">
					<span class="numero">{resumen.promedio.toFixed(1)}</span>
					<span class="de">de 5</span>
					<span class="barras-estrellas">{estrellas(Math.round(resumen.promedio))}</span>
				</div>

				<!-- Las barras son tambien el filtro. Pulsar una nota deja solo
				     esas; volver a pulsarla quita el filtro. -->
				<ul class="reparto">
					{#each [5, 4, 3, 2, 1] as nota}
						{@const cuantas = cuantasDe(nota)}
						<li>
							<button
								type="button"
								class="fila-nota"
								class:activa={filtroNota === nota}
								disabled={cuantas === 0}
								onclick={() => (filtroNota = filtroNota === nota ? null : nota)}
							>
								<span class="etiqueta-nota">{nota}</span>
								<span class="barra"><span class="relleno" style:width="{porcentajeDe(nota)}%"
									></span></span>
								<span class="cuantas">{cuantas}</span>
							</button>
						</li>
					{/each}
				</ul>
			</div>
		{/if}

		{#if escribiendo}
			<form class="formulario" onsubmit={enviar} novalidate>
				<h3>Tu resena</h3>

				{#if errorFormulario}
					<p class="malo" role="alert">{errorFormulario}</p>
				{/if}

				<div class="campo">
					<label for="r-vendedor">A que vendedor calificas</label>
					<select id="r-vendedor" bind:value={vendedorElegido}>
						<option value="">Elige uno</option>
						{#each puedeCalificar as v (v.correo)}
							<option value={v.correo}>{v.nombre} ({v.usuario})</option>
						{/each}
					</select>
					<p class="ayuda">
						Solo salen los vendedores de este producto que todavia no has calificado: se puede
						escribir una resena por vendedor y producto.
					</p>
				</div>

				<div class="campo">
					<span class="etiqueta-campo">Tu nota</span>
					<div class="notas">
						{#each [1, 2, 3, 4, 5] as n}
							<button
								type="button"
								class="nota-boton"
								class:elegida={notaElegida === n}
								onclick={() => (notaElegida = n)}
								aria-label="{n} de 5"
							>
								{n}
							</button>
						{/each}
					</div>
				</div>

				<div class="campo">
					<label for="r-texto">Tu comentario</label>
					<textarea id="r-texto" rows="4" bind:value={textoNuevo}></textarea>
				</div>

				<div class="botones">
					<button class="principal" type="submit" disabled={enviando}>
						{enviando ? 'Publicando' : 'Publicar resena'}
					</button>
					<button type="button" onclick={() => (escribiendo = false)}>Cancelar</button>
				</div>
			</form>
		{/if}

		{#if resenas.length === 0}
			<p class="gris vacio">
				Este producto todavia no tiene resenas.
				{#if haySesion && puedeCalificar.length > 0}
					Se la puedes escribir vos.
				{:else if !haySesion}
					<a href="/entrar">Inicia sesion</a> para escribir la primera.
				{/if}
			</p>
		{:else}
			{#if filtroNota !== null}
				<p class="filtro-activo">
					Mostrando solo las de {filtroNota}
					{filtroNota === 1 ? 'estrella' : 'estrellas'}.
					<button type="button" onclick={() => (filtroNota = null)}>Ver todas</button>
				</p>
			{/if}

			<ul class="lista">
				{#each visibles as resena (resena.id_resena)}
					<li class="resena">
						<div class="cabeza">
							<span class="estrellas">{estrellas(resena.calificacion)}</span>
							<span class="autor">{resena.autor_usuario}</span>
							<!-- Marcar la propia no es decoracion: cuando ya calificaste a
							     todos los vendedores del producto, `puede_calificar` viene
							     vacio y el boton de escribir DESAPARECE sin decir por que.
							     Esta pastilla es la respuesta a esa pregunta. -->
							{#if correoSesion && correoSesion === resena.autor_correo}
								<span class="tuya">tu resena</span>
							{/if}
							<span class="gris">sobre</span>
							<span class="vendedor">{resena.vendedor_nombre}</span>
							<span class="gris fecha">{fecha(resena.fecha_publicacion)}</span>
						</div>

						<p class="texto">{resena.comentario}</p>

						<div class="pie-resena">
							<button
								type="button"
								class="voto"
								class:activo={resena.voto.mio === 1}
								disabled={!haySesion}
								onclick={() => votar(resena.voto, resena.id_comentario, 1)}
							>
								Util ({resena.voto.a_favor})
							</button>
							<button
								type="button"
								class="voto"
								class:activo={resena.voto.mio === -1}
								disabled={!haySesion}
								onclick={() => votar(resena.voto, resena.id_comentario, -1)}
							>
								No util ({resena.voto.en_contra})
							</button>

							<!-- Contesta CUALQUIERA con sesion, no solo el vendedor
							     calificado. Es la regla que eligio el backend y esta
							     escrita en endpoints-resenas.md; aqui se sigue, no se
							     endurece: un frontend mas estricto que el servidor esconde
							     una funcionalidad que existe, y nadie encuentra por que.
							     Antes esto exigia ser el vendedor y le apagaba el boton a
							     todo el mundo menos a uno. -->
							{#if haySesion}
								<button
									type="button"
									class="contestar"
									onclick={() => {
										contestando = contestando === resena.id_resena ? null : resena.id_resena;
										textoRespuesta = '';
									}}
								>
									{contestando === resena.id_resena ? 'Cancelar' : 'Responder'}
								</button>
							{/if}
						</div>

						{#if contestando === resena.id_resena}
							<div class="responder">
								<textarea rows="2" bind:value={textoRespuesta} placeholder="Tu respuesta"
								></textarea>
								<button type="button" class="principal" onclick={() => responder(resena)}>
									Publicar respuesta
								</button>
							</div>
						{/if}

						{#if resena.respuestas.length > 0}
							<ul class="hilo">
								{#each resena.respuestas as r (r.id_comentario)}
									<li>
										<div class="cabeza-respuesta">
											<span class="autor">{r.autor_usuario}</span>
											<span class="gris fecha">{fecha(r.fecha_publicacion)}</span>
										</div>
										<p class="texto">{r.comentario}</p>
										<div class="pie-resena">
											<button
												type="button"
												class="voto"
												class:activo={r.voto.mio === 1}
												disabled={!haySesion}
												onclick={() => votar(r.voto, r.id_comentario, 1)}
											>
												Util ({r.voto.a_favor})
											</button>
										</div>
									</li>
								{/each}
							</ul>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}
	{/if}
</section>

<style>
	.resenas {
		padding: 26px 28px;
		margin-top: 28px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.titulo {
		display: flex;
		align-items: center;
		gap: 10px;
		flex-wrap: wrap;
		margin-bottom: 8px;
	}

	.titulo h2 {
		font-size: 1.3rem;
		margin-right: 4px;
	}

	.etiqueta {
		padding: 3px 11px;
		font-size: 0.82rem;
		color: var(--gris);
		background: var(--panel);
		border-radius: 999px;
	}

	.acciones {
		margin-left: auto;
	}

	.intro {
		max-width: 620px;
		margin-bottom: 20px;
		color: var(--gris);
		font-size: 0.94rem;
	}

	/* El motivo por el que no se puede escribir. Va en la caja del panel y no
	   como texto suelto: es informacion sobre una accion que falta, no una
	   nota al pie. */
	.porque-no {
		max-width: 620px;
		margin-bottom: 20px;
		padding: 10px 14px;
		font-size: 0.92rem;
		color: var(--gris);
		background: var(--panel);
		border-radius: var(--r);
	}

	.porque-no a {
		color: var(--indigo);
	}

	.gris {
		color: var(--gris);
	}

	.vacio {
		padding: 18px 0;
	}

	code {
		padding: 1px 6px;
		font-size: 0.88em;
		background: var(--panel);
		border-radius: 4px;
	}

	button {
		font-family: inherit;
		cursor: pointer;
	}

	.acciones button,
	.botones button,
	.fallo button,
	.filtro-activo button,
	.contestar {
		padding: 8px 16px;
		font-size: 0.92rem;
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		transition:
			border-color var(--t),
			color var(--t);
	}

	.acciones button:hover,
	.botones button:hover,
	.contestar:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.principal {
		color: var(--blanco) !important;
		background: var(--indigo) !important;
		border-color: var(--indigo) !important;
	}

	button:disabled {
		opacity: 0.55;
		cursor: not-allowed;
	}

	.hecho {
		margin-bottom: 18px;
		padding: 10px 14px;
		font-size: 0.92rem;
		color: var(--tinta);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
	}

	.malo {
		margin-bottom: 14px;
		padding: 10px 14px;
		font-size: 0.92rem;
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	.pendiente {
		padding: 22px 24px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.pendiente h3 {
		font-size: 1.05rem;
		margin-bottom: 8px;
	}

	.pendiente p {
		max-width: 620px;
		margin-bottom: 8px;
		font-size: 0.94rem;
	}

	.fallo {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 20px;
		flex-wrap: wrap;
		padding: 14px 18px;
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	/* -- el resumen con sus barras -- */

	.resumen {
		display: grid;
		grid-template-columns: auto 1fr;
		align-items: center;
		gap: 28px;
		padding: 18px 20px;
		margin-bottom: 22px;
		background: var(--panel);
		border-radius: var(--r2);
	}

	.promedio {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 2px;
	}

	.promedio .numero {
		font-size: 2.2rem;
		font-weight: 500;
		line-height: 1;
		color: var(--tinta);
	}

	.promedio .de {
		font-size: 0.82rem;
		color: var(--gris);
	}

	.barras-estrellas,
	.estrellas {
		font-family: ui-monospace, monospace;
		letter-spacing: 2px;
		color: var(--indigo);
	}

	.reparto {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	/* La fila entera es el boton del filtro: el area pulsable es toda la
	   barra y no solo el numero. */
	.fila-nota {
		display: flex;
		align-items: center;
		gap: 10px;
		width: 100%;
		padding: 3px 6px;
		background: none;
		border: 1px solid transparent;
		border-radius: var(--r);
		font-size: 0.88rem;
		color: var(--gris);
	}

	.fila-nota:hover:not(:disabled) {
		border-color: var(--linea);
	}

	.fila-nota.activa {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.etiqueta-nota {
		width: 12px;
		text-align: right;
	}

	.barra {
		flex: 1;
		height: 7px;
		background: var(--blanco);
		border-radius: 999px;
		overflow: hidden;
	}

	.relleno {
		display: block;
		height: 100%;
		background: var(--indigo);
	}

	.cuantas {
		width: 26px;
		text-align: right;
	}

	.filtro-activo {
		display: flex;
		align-items: center;
		gap: 12px;
		flex-wrap: wrap;
		margin-bottom: 16px;
		font-size: 0.92rem;
		color: var(--gris);
	}

	/* -- el formulario -- */

	.formulario {
		display: flex;
		flex-direction: column;
		gap: 16px;
		padding: 20px 22px;
		margin-bottom: 24px;
		border: 1px solid var(--indigo);
		border-radius: var(--r2);
	}

	.formulario h3 {
		font-size: 1.05rem;
	}

	.campo {
		display: flex;
		flex-direction: column;
		gap: 7px;
	}

	label,
	.etiqueta-campo {
		font-size: 0.92rem;
		font-weight: 500;
		color: var(--tinta);
	}

	select,
	textarea {
		width: 100%;
		padding: 11px 13px;
		font-family: inherit;
		font-size: 1rem;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		resize: vertical;
	}

	select:focus,
	textarea:focus {
		outline: none;
		border-color: var(--indigo);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	.ayuda {
		font-size: 0.86rem;
		color: var(--gris);
	}

	.notas {
		display: flex;
		gap: 8px;
	}

	.nota-boton {
		width: 42px;
		height: 42px;
		font-size: 1rem;
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.nota-boton.elegida {
		color: var(--blanco);
		background: var(--indigo);
		border-color: var(--indigo);
	}

	.botones {
		display: flex;
		gap: 10px;
		flex-wrap: wrap;
	}

	/* -- la lista -- */

	.lista {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 20px;
	}

	.resena {
		padding-bottom: 20px;
		border-bottom: 1px solid var(--linea);
	}

	.lista > .resena:last-child {
		padding-bottom: 0;
		border-bottom: 0;
	}

	.cabeza,
	.cabeza-respuesta {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
		margin-bottom: 8px;
		font-size: 0.9rem;
	}

	.autor {
		font-weight: 500;
		color: var(--tinta);
	}

	.vendedor {
		font-weight: 500;
		color: var(--indigo);
	}

	.tuya {
		padding: 2px 9px;
		font-size: 0.78rem;
		color: var(--indigo);
		background: var(--indigo-cl);
		border-radius: 999px;
	}

	.fecha {
		margin-left: auto;
		font-size: 0.85rem;
	}

	.texto {
		max-width: 720px;
		margin-bottom: 10px;
		color: var(--texto);
		overflow-wrap: anywhere;
	}

	.pie-resena {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
	}

	.voto {
		padding: 5px 12px;
		font-size: 0.85rem;
		color: var(--gris);
		background: none;
		border: 1px solid var(--linea);
		border-radius: 999px;
	}

	.voto:hover:not(:disabled) {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.voto.activo {
		color: var(--indigo);
		background: var(--indigo-cl);
		border-color: var(--indigo);
	}

	.contestar {
		margin-left: auto;
		padding: 5px 12px;
		font-size: 0.85rem;
	}

	.responder {
		display: flex;
		gap: 10px;
		align-items: flex-start;
		margin-top: 12px;
	}

	.responder textarea {
		flex: 1;
	}

	.responder button {
		padding: 10px 16px;
		font-size: 0.9rem;
		border: 1px solid var(--indigo);
		border-radius: var(--r);
		white-space: nowrap;
	}

	/* El hilo va indentado con una linea a la izquierda: se lee como "cuelga
	   de la resena de arriba" sin necesidad de repetir a quien contesta. */
	.hilo {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 14px;
		margin: 14px 0 0 16px;
		padding-left: 16px;
		border-left: 2px solid var(--linea);
	}

	@media (max-width: 620px) {
		.resenas {
			padding: 22px 20px;
		}
		.acciones {
			margin-left: 0;
			width: 100%;
		}
		.resumen {
			grid-template-columns: 1fr;
			gap: 16px;
		}
		.fecha {
			margin-left: 0;
		}
		.contestar {
			margin-left: 0;
		}
		.responder {
			flex-direction: column;
		}
	}
</style>
