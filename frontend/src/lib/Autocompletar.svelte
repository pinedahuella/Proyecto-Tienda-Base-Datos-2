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
		opcional = false
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
	} = $props();

	let escrito = $state('');
	let sugerencias = $state<Opcion[]>([]);
	let aviso = $state('');

	/** Sin lista no hay nada que sugerir: el campo pasa a texto libre. */
	let libre = $derived(opciones.length === 0);

	/**
	 * Cuando el padre limpia el valor (por ejemplo la ciudad, porque cambio el
	 * pais), la caja tiene que quedar vacia tambien.
	 *
	 * Por eso escribir NO borra el valor: si lo hiciera, este efecto se
	 * dispararia con cada tecla y borraria lo que la persona esta escribiendo
	 * encima de algo ya elegido. El valor viejo se sostiene hasta que se elige
	 * otro o hasta que se sale del campo sin elegir.
	 */
	$effect(() => {
		if (valor === '') {
			escrito = '';
			sugerencias = [];
			aviso = '';
		}
	});

	function alEscribir() {
		aviso = '';

		if (libre) {
			// Texto libre: lo escrito es el valor, sin lista que consultar
			valor = escrito.trim();
			elegido = escrito.trim().length > 0;
			return;
		}

		const q = escrito.trim().toLowerCase();
		sugerencias = q.length < 1 ? [] : opciones.filter((o) => o.texto.toLowerCase().includes(q)).slice(0, 8);

		// Escribir invalida la eleccion anterior, pero el valor se deja quieto
		// hasta que elija otro o salga del campo. Ver el comentario del efecto.
		elegido = false;
	}

	function elegir(o: Opcion) {
		escrito = o.texto;
		valor = o.valor;
		elegido = true;
		sugerencias = [];
		aviso = '';
		alElegir(o.valor);
	}

	function alSalir() {
		if (libre) return;
		// Se da un respiro para que un clic en una sugerencia gane al blur
		setTimeout(() => {
			sugerencias = [];
			if (escrito.trim() && !elegido) {
				aviso = 'Elige una opcion de la lista';
				escrito = '';
				valor = '';
			}
		}, 150);
	}
</script>

<div class="campo">
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
			bind:value={escrito}
			oninput={alEscribir}
			onblur={alSalir}
			disabled={deshabilitado}
			aria-invalid={aviso ? 'true' : undefined}
		/>

		{#if sugerencias.length > 0}
			<ul>
				{#each sugerencias as o (o.valor)}
					<li>
						<button type="button" onmousedown={(e) => e.preventDefault()} onclick={() => elegir(o)}>
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
		gap: 7px;
	}

	label {
		font-size: 0.9rem;
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
		font-size: 1rem;
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
		font-size: 0.95rem;
		text-align: left;
		color: var(--tinta);
		background: none;
		border: none;
		border-radius: 4px;
		cursor: pointer;
	}

	li button:hover {
		background: var(--indigo-cl);
		color: var(--indigo-os);
	}

	.aviso {
		margin: 0;
		font-size: 0.85rem;
		color: var(--rojo);
	}
</style>
