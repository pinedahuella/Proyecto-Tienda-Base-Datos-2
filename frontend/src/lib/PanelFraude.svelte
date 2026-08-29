<script lang="ts">
	import { onMount } from 'svelte';
	import { pedir } from './api';

	/**
	 * Panel de manipulacion de resenas. Es una pantalla que pide el enunciado
	 * de la Entrega 2, textual:
	 *
	 *   "Panel, visible para el equipo administrativo, que senale patrones de
	 *    posible manipulacion de resenas -- por ejemplo, conjuntos de cuentas
	 *    que se califican entre si de forma reiterada sobre los mismos
	 *    productos"
	 *
	 * Lo que ensena NO se calcula aqui ni en PostgreSQL: sale del grafo de
	 * Neo4j, que es la familia que el equipo eligio implementar. La consulta
	 * vive en neo4j/002_fraude.cypher y el backend la expone.
	 *
	 *
	 * LA RUTA QUE ESTE PANEL ESPERA -- todavia no existe
	 * ---------------------------------------------------------------
	 * El backend es de Jose David y aqui no se toca. Este componente ya esta
	 * escrito contra la ruta que hace falta, para que el dia que exista solo
	 * haya que levantarla:
	 *
	 *   GET /admin/fraude/anillos
	 *
	 * La forma exacta del payload esta en docs/BACKEND-PENDIENTE.md y en la
	 * interfaz `Anillo` de aqui abajo. Mientras la ruta no exista, la pantalla
	 * NO se rompe ni miente: dice que el analisis todavia no esta conectado y
	 * deja ver un ejemplo para poder revisar el diseno.
	 *
	 *
	 * POR QUE EL VACIO ES UN RESULTADO Y NO UN ERROR
	 * ---------------------------------------------------------------
	 * Esto es lo mas facil de hacer mal en esta pantalla.
	 *
	 * El conjunto de datos sembrado NO tiene anillo: se comprobo y da 0 pares
	 * que se califiquen mutuamente y 0 autocalificaciones. Asi que la consulta
	 * de fraude, corriendo perfectamente, devuelve CERO. Eso es lo correcto.
	 *
	 * Una pantalla que ante cero resultados dice "no hay datos" o se queda en
	 * blanco hace pensar que esta rota, y a quien la revise le va a parecer
	 * que la consulta no funciona. Por eso el estado vacio de aqui abajo dice
	 * lo contrario: cuantas cuentas y cuantas resenas se ANALIZARON para
	 * llegar a ese cero. Un cero con denominador es un resultado; un cero solo
	 * es una duda.
	 */

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	/** Una cuenta dentro de un grupo sospechoso. */
	interface CuentaSenalada {
		id_usuario: number;
		usuario: string;
		correo_electronico: string;
		nombre: string;
		apellido: string;
	}

	/** Una resena concreta que forma parte del patron. */
	interface ResenaSenalada {
		id_resena: number;
		autor: string;
		vendedor: string;
		producto: string;
		calificacion: number;
		fecha: string;
	}

	/**
	 * Un grupo de cuentas con un patron anomalo.
	 *
	 * `tipo` dice QUE forma tiene el patron, y no es cosmetico: cada forma se
	 * detecta con una consulta distinta y significa una cosa distinta. Se
	 * guarda para poder explicarle a quien mira POR QUE esas cuentas estan
	 * juntas en la lista, en vez de darle una lista de nombres sin motivo.
	 */
	interface Anillo {
		id: string;
		tipo: 'ciclo' | 'mutuo' | 'reiterado' | 'direccion';
		/** Cuantos saltos tiene el camino que las une. Es el dato que hace que esto sea un grafo y no una tabla. */
		saltos: number;
		cuentas: CuentaSenalada[];
		productos: { id_producto: number; nombre: string }[];
		resenas: ResenaSenalada[];
		/** Frases cortas, ya redactadas por el backend, que explican la sospecha. */
		senales: string[];
	}

	interface RespuestaFraude {
		anillos: Anillo[];
		/** El denominador. Sin esto, un cero no se puede interpretar. */
		analizado: {
			cuentas: number;
			resenas: number;
			relaciones: number;
		};
	}

	const NOMBRE_TIPO: Record<Anillo['tipo'], string> = {
		ciclo: 'Ciclo de calificaciones',
		mutuo: 'Se califican entre si',
		reiterado: 'Reiteracion sobre los mismos productos',
		direccion: 'Cuentas que comparten direccion'
	};

	const EXPLICACION_TIPO: Record<Anillo['tipo'], string> = {
		ciclo: 'A califica a B, B a C y C vuelve a A. Un comprador normal no recibe de vuelta la calificacion que da: el camino se cierra solo cuando las cuentas se estan sosteniendo entre ellas.',
		mutuo: 'Las dos cuentas se calificaron la una a la otra. Puede ser legitimo una vez; deja de serlo cuando se repite.',
		reiterado:
			'Las mismas cuentas se califican una y otra vez sobre los mismos productos. Es la frase exacta del enunciado, y es la senal mas dificil de producir por casualidad.',
		direccion:
			'Cuentas distintas registradas en la misma direccion normalizada. Por si solo no prueba nada -- una familia comparte casa -- pero junto con calificaciones cruzadas deja de ser coincidencia.'
	};

	let anillos = $state<Anillo[]>([]);
	let analizado = $state<RespuestaFraude['analizado'] | null>(null);

	let cargando = $state(true);
	let error = $state('');
	/** La ruta todavia no existe en el backend. Es un estado propio, no un error. */
	let sinConectar = $state(false);
	/** Si se esta viendo el ejemplo en vez de datos de verdad. Se avisa en pantalla, siempre. */
	let viendoEjemplo = $state(false);

	/** Que tarjeta esta desplegada. Una a la vez: son largas. */
	let abierta = $state<string | null>(null);

	// onMount y no $effect: esto corre UNA vez al montar el panel. Con $effect
	// se repite solo -- en este mismo proyecto se vieron seis llamadas en el
	// mismo instante con un console.trace.
	onMount(cargar);

	async function cargar() {
		cargando = true;
		error = '';
		sinConectar = false;
		viendoEjemplo = false;

		const respuesta = await pedir<RespuestaFraude>('/admin/fraude/anillos');

		cargando = false;

		if (respuesta.estado === 401) {
			alExpirarSesion();
			return;
		}

		// 404 quiere decir que la ruta no existe todavia, y eso NO es un fallo
		// del panel ni de la sesion: es trabajo pendiente del backend. Se
		// distingue a proposito de un error de verdad, porque el mensaje que
		// hay que ensenar es completamente distinto.
		if (respuesta.estado === 404) {
			sinConectar = true;
			return;
		}

		if (!respuesta.ok || !respuesta.payload) {
			error = respuesta.mensaje;
			return;
		}

		anillos = respuesta.payload.anillos ?? [];
		analizado = respuesta.payload.analizado ?? null;
	}

	/**
	 * Datos de ejemplo para poder revisar el diseno de la pantalla mientras la
	 * ruta no existe.
	 *
	 * Van detras de un boton y NUNCA se cargan solos: una pantalla que ensena
	 * datos inventados sin decirlo es peor que una pantalla vacia. Mientras
	 * estan puestos, arriba se ve un aviso que no se puede quitar.
	 */
	function verEjemplo() {
		viendoEjemplo = true;
		sinConectar = false;
		error = '';
		analizado = { cuentas: 14, resenas: 98, relaciones: 294 };
		anillos = [
			{
				id: 'ejemplo-1',
				tipo: 'ciclo',
				saltos: 6,
				cuentas: [
					{
						id_usuario: 101,
						usuario: 'ventas_altiplano',
						correo_electronico: 'ventas.altiplano@mesh.com',
						nombre: 'Rodrigo',
						apellido: 'Similox'
					},
					{
						id_usuario: 102,
						usuario: 'ventas_bocacosta',
						correo_electronico: 'ventas.bocacosta@mesh.com',
						nombre: 'Ileana',
						apellido: 'Chavarria'
					},
					{
						id_usuario: 103,
						usuario: 'ventas_izabal',
						correo_electronico: 'ventas.izabal@mesh.com',
						nombre: 'Byron',
						apellido: 'Melgar'
					}
				],
				productos: [
					{ id_producto: 12, nombre: 'Laptop Ambar Campus 14' },
					{ id_producto: 34, nombre: 'Audifonos Cenzontle Pro' }
				],
				resenas: [
					{
						id_resena: 901,
						autor: 'ventas_altiplano',
						vendedor: 'ventas_bocacosta',
						producto: 'Laptop Ambar Campus 14',
						calificacion: 5,
						fecha: '2026-05-11T14:02:00.000Z'
					},
					{
						id_resena: 902,
						autor: 'ventas_bocacosta',
						vendedor: 'ventas_izabal',
						producto: 'Laptop Ambar Campus 14',
						calificacion: 5,
						fecha: '2026-05-11T14:09:00.000Z'
					},
					{
						id_resena: 903,
						autor: 'ventas_izabal',
						vendedor: 'ventas_altiplano',
						producto: 'Audifonos Cenzontle Pro',
						calificacion: 5,
						fecha: '2026-05-11T14:15:00.000Z'
					}
				],
				senales: [
					'Las tres calificaciones son de 5 estrellas',
					'Las tres se escribieron en un intervalo de 13 minutos',
					'Ninguna de las tres cuentas compro el producto que califico'
				]
			},
			{
				id: 'ejemplo-2',
				tipo: 'direccion',
				saltos: 2,
				cuentas: [
					{
						id_usuario: 104,
						usuario: 'compras_zona4',
						correo_electronico: 'compras.zona4@mesh.com',
						nombre: 'Marta',
						apellido: 'Ixcot'
					},
					{
						id_usuario: 105,
						usuario: 'compras_zona4b',
						correo_electronico: 'compras.zona4b@mesh.com',
						nombre: 'Marta',
						apellido: 'Ixcot'
					}
				],
				productos: [{ id_producto: 12, nombre: 'Laptop Ambar Campus 14' }],
				resenas: [
					{
						id_resena: 904,
						autor: 'compras_zona4',
						vendedor: 'ventas_altiplano',
						producto: 'Laptop Ambar Campus 14',
						calificacion: 5,
						fecha: '2026-05-11T14:20:00.000Z'
					},
					{
						id_resena: 905,
						autor: 'compras_zona4b',
						vendedor: 'ventas_altiplano',
						producto: 'Laptop Ambar Campus 14',
						calificacion: 5,
						fecha: '2026-05-11T14:22:00.000Z'
					}
				],
				senales: [
					'Las dos cuentas tienen la misma direccion normalizada',
					'Las dos calificaron al mismo vendedor con 5 estrellas',
					'Las dos cuentas se crearon el mismo dia'
				]
			}
		];
	}

	function alternar(id: string) {
		abierta = abierta === id ? null : id;
	}

	function fecha(valor: string): string {
		return new Date(valor).toLocaleString('es-GT', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}

	function nombreCompleto(c: CuentaSenalada): string {
		return [c.nombre, c.apellido].filter(Boolean).join(' ') || c.usuario;
	}
</script>

<section class="fraude">
	<div class="titulo">
		<h2>Manipulacion de resenas</h2>
		{#if !cargando && !sinConectar && !error}
			<span class="etiqueta" class:limpio={anillos.length === 0}>
				{anillos.length}
				{anillos.length === 1 ? 'grupo senalado' : 'grupos senalados'}
			</span>
		{/if}
		{#if !cargando}
			<div class="acciones">
				<button type="button" onclick={cargar}>Volver a analizar</button>
			</div>
		{/if}
	</div>

	<p class="intro">
		Grupos de cuentas cuyo patron de calificaciones no se explica por el uso normal de la
		tienda. Se calcula recorriendo el grafo de relaciones entre cuentas, resenas y productos,
		no consultando una tabla.
	</p>

	{#if viendoEjemplo}
		<!-- No se puede cerrar. Mientras haya datos inventados en pantalla,
		     tiene que decirlo: la alternativa es que alguien lea estos nombres
		     como si fueran cuentas de verdad. -->
		<p class="ejemplo-aviso" role="status">
			Estas viendo <strong>datos de ejemplo</strong>, no cuentas reales. Sirven para revisar el
			diseno de la pantalla mientras el analisis no esta conectado.
			<button type="button" onclick={cargar}>Volver a lo real</button>
		</p>
	{/if}

	{#if cargando}
		<p class="gris">Analizando el grafo de resenas...</p>
	{:else if sinConectar}
		<!-- Ni error ni vacio: es trabajo que falta, y decirlo con precision
		     ahorra que alguien salga a buscar un bug que no existe. -->
		<div class="pendiente">
			<h3>El analisis todavia no esta conectado</h3>
			<p>
				Esta pantalla espera la ruta <code>GET /admin/fraude/anillos</code>, que corre la
				consulta de varios saltos contra Neo4j. El backend todavia no la expone.
			</p>
			<p class="gris">
				La forma exacta que espera esta en <code>docs/BACKEND-PENDIENTE.md</code>. Las
				consultas ya estan escritas en <code>neo4j/002_fraude.cypher</code>.
			</p>
			<button type="button" onclick={verEjemplo}>Ver con datos de ejemplo</button>
		</div>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if anillos.length === 0}
		<!-- El vacio con su denominador. Ver la nota larga de arriba. -->
		<div class="limpio-caja">
			<h3>No se encontro ningun patron anomalo</h3>
			{#if analizado}
				<p>
					Se recorrieron <strong>{analizado.cuentas}</strong> cuentas,
					<strong>{analizado.resenas}</strong> resenas y
					<strong>{analizado.relaciones}</strong> relaciones del grafo sin encontrar ciclos de
					calificacion, pares mutuos ni reiteracion sobre los mismos productos.
				</p>
				<p class="gris">
					Un resultado vacio aqui significa que el analisis corrio y no hallo nada, no que
					falten datos.
				</p>
			{:else}
				<p class="gris">El analisis corrio y no devolvio ningun grupo.</p>
			{/if}
		</div>
	{:else}
		<ul class="lista">
			{#each anillos as anillo (anillo.id)}
				{@const desplegada = abierta === anillo.id}
				<li class="anillo" class:desplegada>
					<button type="button" class="cabeza" onclick={() => alternar(anillo.id)}>
						<span class="tipo tipo-{anillo.tipo}">{NOMBRE_TIPO[anillo.tipo]}</span>

						<span class="cuentas-resumen">
							{#each anillo.cuentas as cuenta, i (cuenta.id_usuario)}
								<span class="cuenta">{cuenta.usuario}</span>{#if i < anillo.cuentas.length - 1}<span
										class="flecha">-&gt;</span
									>{/if}
							{/each}
							{#if anillo.tipo === 'ciclo'}
								<span class="flecha">-&gt;</span>
								<span class="cuenta cierra">{anillo.cuentas[0].usuario}</span>
							{/if}
						</span>

						<span class="saltos">{anillo.saltos} saltos</span>
						<span class="chevron" aria-hidden="true">{desplegada ? '-' : '+'}</span>
					</button>

					{#if desplegada}
						<div class="detalle">
							<p class="porque">{EXPLICACION_TIPO[anillo.tipo]}</p>

							<div class="columnas">
								<div>
									<h4>Cuentas ({anillo.cuentas.length})</h4>
									<ul class="simple">
										{#each anillo.cuentas as cuenta (cuenta.id_usuario)}
											<li>
												<span class="fuerte">{cuenta.usuario}</span>
												<span class="gris">{nombreCompleto(cuenta)}</span>
												<span class="gris correo">{cuenta.correo_electronico}</span>
											</li>
										{/each}
									</ul>
								</div>

								<div>
									<h4>Productos involucrados ({anillo.productos.length})</h4>
									<ul class="simple">
										{#each anillo.productos as producto (producto.id_producto)}
											<li>
												<a href="/producto/{producto.id_producto}">{producto.nombre}</a>
											</li>
										{/each}
									</ul>
								</div>
							</div>

							{#if anillo.senales.length > 0}
								<h4>Por que se senalo</h4>
								<ul class="senales">
									{#each anillo.senales as senal}
										<li>{senal}</li>
									{/each}
								</ul>
							{/if}

							<h4>Las resenas del patron ({anillo.resenas.length})</h4>
							<div class="tabla">
								<table>
									<thead>
										<tr>
											<th>Quien califica</th>
											<th>A quien</th>
											<th>Producto</th>
											<th>Nota</th>
											<th>Cuando</th>
										</tr>
									</thead>
									<tbody>
										{#each anillo.resenas as resena (resena.id_resena)}
											<tr>
												<td class="fuerte">{resena.autor}</td>
												<td>{resena.vendedor}</td>
												<td>{resena.producto}</td>
												<td class="nota">{resena.calificacion}</td>
												<td class="gris">{fecha(resena.fecha)}</td>
											</tr>
										{/each}
									</tbody>
								</table>
							</div>
						</div>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
</section>

<style>
	.fraude {
		padding: 26px 28px;
		margin-bottom: 28px;
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
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: 999px;
	}

	/* Cero grupos no es una alarma: se pinta neutro, no rojo. */
	.etiqueta.limpio {
		color: var(--gris);
		background: var(--panel);
		border-color: var(--linea);
	}

	.acciones {
		margin-left: auto;
		display: flex;
		gap: 10px;
	}

	.acciones button,
	.pendiente button,
	.fallo button,
	.ejemplo-aviso button {
		padding: 8px 16px;
		font-family: inherit;
		font-size: 0.92rem;
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
	.pendiente button:hover,
	.ejemplo-aviso button:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.intro {
		max-width: 620px;
		margin-bottom: 20px;
		color: var(--gris);
		font-size: 0.94rem;
	}

	.gris {
		color: var(--gris);
	}

	.fuerte {
		font-weight: 500;
		color: var(--tinta);
	}

	code {
		padding: 1px 6px;
		font-size: 0.88em;
		background: var(--panel);
		border-radius: 4px;
	}

	/* -- estados que no son la lista -- */

	.ejemplo-aviso {
		display: flex;
		align-items: center;
		gap: 12px;
		flex-wrap: wrap;
		margin-bottom: 18px;
		padding: 10px 14px;
		font-size: 0.92rem;
		color: var(--tinta);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
	}

	.ejemplo-aviso button {
		margin-left: auto;
	}

	.pendiente,
	.limpio-caja {
		padding: 22px 24px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.pendiente h3,
	.limpio-caja h3 {
		font-size: 1.05rem;
		margin-bottom: 8px;
	}

	.pendiente p,
	.limpio-caja p {
		max-width: 620px;
		margin-bottom: 10px;
		font-size: 0.94rem;
	}

	.pendiente button {
		margin-top: 6px;
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

	/* -- la lista de anillos -- */

	.lista {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.anillo {
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		overflow: hidden;
	}

	.anillo.desplegada {
		border-color: var(--indigo);
	}

	/* La cabecera entera es el boton: el area pulsable es la fila completa y
	   no solo el signo de la derecha. Un objetivo de 12 pixeles al borde de la
	   tarjeta se falla mas de lo que se acierta en un telefono. */
	.cabeza {
		display: flex;
		align-items: center;
		gap: 12px;
		flex-wrap: wrap;
		width: 100%;
		padding: 14px 18px;
		font-family: inherit;
		font-size: 0.95rem;
		text-align: left;
		color: var(--tinta);
		background: none;
		border: 0;
		cursor: pointer;
	}

	.cabeza:hover {
		background: var(--panel);
	}

	.tipo {
		padding: 3px 10px;
		font-size: 0.8rem;
		border-radius: 999px;
		white-space: nowrap;
	}

	.tipo-ciclo,
	.tipo-reiterado {
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
	}

	.tipo-mutuo,
	.tipo-direccion {
		color: var(--indigo);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
	}

	.cuentas-resumen {
		display: flex;
		align-items: center;
		gap: 6px;
		flex-wrap: wrap;
	}

	.cuenta {
		font-weight: 500;
	}

	/* La cuenta repetida que cierra el ciclo. Se pinta distinta para que se
	   lea como "vuelve a la primera" y no como una cuarta cuenta. */
	.cuenta.cierra {
		color: var(--gris);
	}

	.flecha {
		color: var(--gris-2);
	}

	.saltos {
		margin-left: auto;
		font-size: 0.85rem;
		color: var(--gris);
		white-space: nowrap;
	}

	.chevron {
		width: 18px;
		text-align: center;
		color: var(--gris);
	}

	/* -- el detalle desplegado -- */

	.detalle {
		padding: 4px 18px 20px;
		border-top: 1px solid var(--linea);
	}

	.porque {
		max-width: 680px;
		margin: 16px 0 20px;
		font-size: 0.93rem;
		color: var(--gris);
	}

	.detalle h4 {
		font-size: 0.9rem;
		margin: 18px 0 8px;
		color: var(--tinta);
	}

	.columnas {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
		gap: 20px 28px;
	}

	.columnas h4 {
		margin-top: 0;
	}

	ul.simple {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 8px;
		font-size: 0.92rem;
	}

	ul.simple li {
		display: flex;
		flex-direction: column;
		gap: 1px;
	}

	.correo {
		font-size: 0.85rem;
		overflow-wrap: anywhere;
	}

	ul.simple a {
		color: var(--indigo);
	}

	ul.senales {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 6px;
		font-size: 0.92rem;
	}

	ul.senales li {
		padding-left: 16px;
		position: relative;
		color: var(--texto);
	}

	ul.senales li::before {
		content: '-';
		position: absolute;
		left: 0;
		color: var(--gris-2);
	}

	/* La tabla se desborda en horizontal DENTRO de su caja, y nunca empuja el
	   ancho de la pagina. */
	.tabla {
		overflow-x: auto;
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.9rem;
	}

	th {
		padding: 9px 12px;
		text-align: left;
		font-weight: 500;
		font-size: 0.85rem;
		color: var(--gris);
		background: var(--panel);
		white-space: nowrap;
	}

	td {
		padding: 9px 12px;
		border-top: 1px solid var(--linea);
		white-space: nowrap;
	}

	.nota {
		font-weight: 500;
	}

	@media (max-width: 620px) {
		.fraude {
			padding: 22px 20px;
		}
		.acciones {
			margin-left: 0;
			width: 100%;
		}
		.saltos {
			margin-left: 0;
		}
	}
</style>
