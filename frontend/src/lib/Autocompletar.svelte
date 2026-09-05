<script lang="ts">
	/**
	 * Un campo de texto que solo acepta lo que esta en su lista.
	 *
	 * Se escribe, salen las coincidencias, y hay que elegir una. Si se escribe
	 * algo que no esta y se sale del campo, se borra y se avisa: asi no entra
	 * una ciudad que no existe ni una que no pertenece al pais elegido.
	 *
	 * Cuando la lista viene vacia el campo se vuelve de texto libre. Eso pasa
	 * en dos casos legitimos: paises sin departamentos, que son 50 de 246, y
	 * paises sin ciudades registradas. Y pasa tambien si la API no contesta.
	 * En los tres casos vale mas dejar escribir que dejar el formulario
	 * bloqueado sin explicar por que, que es como falla el proyecto de hoteles
	 * del que salio esta idea.
	 */

	interface Opcion {
		/** Lo que ve el usuario. */
		texto: string;
		/** Lo que se guarda y lo que se le manda a la API. A veces difieren. */
		valor: string;
	}

	let {
		id,
		etiqueta,
		opciones,
		valor = $bindable(''),
		elegido = $bindable(false),
		alElegir = (_v: string) => {},
		deshabilitado = false,
		ayuda = '',
		opcional = false,
		marcador = '',
		permitirLibre = false,
		mostrarAlEnfocar = false,
		limpiarSiVacio = false,
		compacto = false
	}: {
		id: string;
		etiqueta: string;
		opciones: Opcion[];
		valor?: string;
		elegido?: boolean;
		alElegir?: (v: string) => void;
		deshabilitado?: boolean;
		ayuda?: string;
		opcional?: boolean;
		marcador?: string;
		/**
		 * Lo escrito vale como valor aunque no este en la lista, y las
		 * sugerencias solo ayudan a escribirlo. Es lo que necesita el
		 * buscador de caracteristicas del catalogo: las del catalogo si
		 * estan en la lista, pero una caracteristica personalizada la
		 * escribio quien publico el producto y no hay lista que consultar.
		 */
		permitirLibre?: boolean;
		/** Al enfocar, ensena la lista aunque la caja este vacia (se puede ojear, no solo buscar). */
		mostrarAlEnfocar?: boolean;
		/**
		 * Borrar la caja borra el valor, y se avisa al padre con alElegir('').
		 *
		 * Sin esto, vaciar la caja deja la caja vacia y el valor puesto: la
		 * pantalla dice "ninguna categoria" y la busqueda sigue filtrada por
		 * una. Solo tiene sentido donde "nada" es una respuesta valida --
		 * "todas las categorias" lo es, "sin ciudad" no.
		 */
		limpiarSiVacio?: boolean;
		/** Talla chica, para una barra de filtros en vez de un formulario. */
		compacto?: boolean;
	} = $props();

	/** Cuantas sugerencias se ensenan a la vez. */
	const MAXIMO_SUGERENCIAS = 8;

	let escrito = $state('');
	let sugerencias = $state<Opcion[]>([]);
	let aviso = $state('');
	/** Cual esta marcada con el teclado. -1 es ninguna. */
	let resaltada = $state(-1);

	/** Sin lista no hay nada que sugerir: el campo pasa a texto libre. */
	let libre = $derived(opciones.length === 0);

	/**
	 * La caja tiene que seguir al valor cuando lo cambia el padre: al limpiar la
	 * ciudad porque cambio el pais, y sobre todo al abrir una direccion para
	 * editarla, donde los tres campos llegan ya llenos desde la base.
	 *
	 * Pero solo cuando lo cambia el PADRE. Si el efecto reaccionara tambien a
	 * los cambios que hace este componente, cada tecla reescribiria la caja y
	 * no se podria escribir encima de algo ya elegido. De ahi este apunte, que
	 * a proposito no es reactivo: solo sirve para comparar.
	 */
	let ultimoValorVisto = '';

	$effect(() => {
		const v = valor;
		if (v === ultimoValorVisto) return;
		ultimoValorVisto = v;

		escrito = v === '' ? '' : mostrar(v);
		if (v === '') {
			sugerencias = [];
			aviso = '';
		}
	});

	/**
	 * El texto que le toca a un valor. Difieren en los departamentos.
	 *
	 * Con permitirLibre NO se traduce: ahi lo escrito ES el valor, asi que la
	 * caja tiene que ensenar el valor tal cual. Si ensenara el texto, elegir
	 * "Memoria RAM (GB)" dejaria la caja con la unidad pegada y la siguiente
	 * tecla convertiria ese rotulo en el valor -- una caracteristica que no
	 * existe, y un filtro que no encuentra nada sin decir por que. El rotulo
	 * con la unidad se sigue viendo en la lista de sugerencias, que es donde
	 * sirve.
	 */
	function mostrar(v: string): string {
		if (permitirLibre) return v;
		const o = opciones.find((x) => x.valor === v);
		return o ? o.texto : v;
	}

	/** Las coincidencias de lo escrito. Con la caja vacia, la lista entera si se pidio. */
	function calcular(texto: string): Opcion[] {
		if (libre) return [];
		const q = texto.trim().toLowerCase();
		if (q === '') return mostrarAlEnfocar ? opciones.slice(0, MAXIMO_SUGERENCIAS) : [];
		return opciones.filter((o) => o.texto.toLowerCase().includes(q)).slice(0, MAXIMO_SUGERENCIAS);
	}

	function alEscribir() {
		aviso = '';
		resaltada = -1;

		// Caja vacia y "nada" es una respuesta valida: se avisa al padre en el
		// acto, sin esperar al blur, para que la pantalla no quede ensenando un
		// filtro que ya no esta escrito en ninguna parte.
		if (limpiarSiVacio && escrito.trim() === '') {
			valor = '';
			ultimoValorVisto = '';
			elegido = false;
			sugerencias = calcular('');
			alElegir('');
			return;
		}

		if (libre || permitirLibre) {
			// Lo escrito es el valor. Sin lista (libre) no hay nada que sugerir;
			// con lista (permitirLibre) las sugerencias siguen saliendo, pero
			// solo para ahorrar tecleo, no para obligar a elegir.
			valor = escrito.trim();
			ultimoValorVisto = valor;
			elegido = opciones.some((o) => o.valor === valor);
			sugerencias = calcular(escrito);
			return;
		}

		sugerencias = calcular(escrito);

		// Escribir invalida la eleccion anterior, pero el valor se deja quieto
		// hasta que elija otro o salga del campo. Ver el comentario del efecto.
		elegido = false;
	}

	function alEnfocar() {
		if (!mostrarAlEnfocar) return;
		sugerencias = calcular(escrito);
		resaltada = -1;
	}

	function elegir(o: Opcion) {
		escrito = mostrar(o.valor);
		valor = o.valor;
		ultimoValorVisto = o.valor;
		elegido = true;
		sugerencias = [];
		resaltada = -1;
		aviso = '';
		alElegir(o.valor);
	}

	/**
	 * Flechas para recorrer, Enter para tomar la marcada, Escape para cerrar.
	 * Con 46 caracteristicas en una categoria, bajar con el raton a la octava
	 * sugerencia no es forma de trabajar.
	 */
	function alTeclear(evento: KeyboardEvent) {
		if (evento.key === 'Escape') {
			sugerencias = [];
			resaltada = -1;
			return;
		}

		if (evento.key === 'ArrowDown' || evento.key === 'ArrowUp') {
			if (sugerencias.length === 0) sugerencias = calcular(escrito);
			if (sugerencias.length === 0) return;
			evento.preventDefault();
			const paso = evento.key === 'ArrowDown' ? 1 : -1;
			resaltada = Math.min(sugerencias.length - 1, Math.max(0, resaltada + paso));
			return;
		}

		if (evento.key === 'Enter' && resaltada >= 0 && sugerencias[resaltada]) {
			evento.preventDefault();
			elegir(sugerencias[resaltada]);
		}
	}

	function alSalir() {
		// Se da un respiro para que un clic en una sugerencia gane al blur
		setTimeout(() => {
			sugerencias = [];
			resaltada = -1;
			if (libre || permitirLibre) return;
			if (escrito.trim() && !elegido) {
				aviso = 'Elige una opcion de la lista';
				escrito = '';
				valor = '';
			}
		}, 150);
	}
</script>

<div class="campo" class:compacto>
	<label for={id}>
		{etiqueta}
		{#if opcional}<span class="nota">opcional</span>{/if}
		{#if libre && !deshabilitado && ayuda}<span class="nota">{ayuda}</span>{/if}
	</label>

	<div class="caja">
		<input
			{id}
			type="text"
			autocomplete="off"
			placeholder={marcador}
			bind:value={escrito}
			oninput={alEscribir}
			onfocus={alEnfocar}
			onkeydown={alTeclear}
			onblur={alSalir}
			disabled={deshabilitado}
			role="combobox"
			aria-autocomplete="list"
			aria-controls={id + '-lista'}
			aria-expanded={sugerencias.length > 0}
			aria-invalid={aviso ? 'true' : undefined}
		/>

		{#if sugerencias.length > 0}
			<ul id={id + '-lista'}>
				{#each sugerencias as o, i (o.valor)}
					<li>
						<button
							type="button"
							class:resaltada={i === resaltada}
							onmousedown={(e) => e.preventDefault()}
							onclick={() => elegir(o)}
						>
							{o.texto}
						</button>
					</li>
				{/each}
			</ul>
		{/if}
	</div>

	{#if aviso}
		<p class="aviso">{aviso}</p>
	{/if}
</div>

<style>
	.campo {
		display: flex;
		flex-direction: column;
		gap: var(--e2);
	}

	label {
		font-size: var(--f-ms);
		font-weight: 500;
		color: var(--tinta);
	}

	.nota {
		font-weight: 400;
		color: var(--gris);
	}

	.caja {
		position: relative;
	}

	input {
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

	input:focus {
		outline: none;
		border-color: var(--indigo);
		box-shadow: 0 0 0 3px var(--indigo-cl);
	}

	input:disabled {
		color: var(--gris);
		background: var(--off);
		cursor: not-allowed;
	}

	input[aria-invalid='true'] {
		border-color: var(--rojo);
	}

	ul {
		position: absolute;
		z-index: 5;
		top: calc(100% + 4px);
		left: 0;
		right: 0;
		margin: 0;
		padding: 4px;
		list-style: none;
		max-height: 232px;
		overflow-y: auto;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		box-shadow: 0 6px 18px rgba(0, 0, 0, 0.09);
	}

	li button {
		display: block;
		width: 100%;
		padding: 8px 10px;
		font-family: inherit;
		font-size: var(--f-base);
		text-align: left;
		color: var(--tinta);
		background: none;
		border: none;
		border-radius: 4px;
		cursor: pointer;
	}

	li button:hover,
	li button.resaltada {
		background: var(--indigo-cl);
		color: var(--indigo-os);
	}

	/* ---------- talla chica, para la barra de filtros ---------- */

	.compacto {
		gap: var(--e1);
	}

	.compacto label {
		font-size: var(--f-sm);
		font-weight: 400;
		color: var(--gris);
	}

	.compacto input {
		padding: 9px 11px;
		font-size: var(--f-base);
	}

	.compacto input:focus {
		box-shadow: none;
	}

	.aviso {
		margin: 0;
		font-size: var(--f-sm);
		color: var(--rojo);
	}
</style>
