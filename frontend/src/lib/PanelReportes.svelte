<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';

	/**
	 * Los dos reportes del panel de administracion.
	 *
	 *   GET /admin/reportes/ventas          lo vendido, cobrado y devuelto
	 *   GET /admin/reportes/reservaciones   los pedidos abiertos sin pagar
	 *
	 * Las dos son de SOLO LECTURA y de SOLO ADMIN. La tienda no entra: es un
	 * vendedor mas, y el backend le contesta 403. Por eso este componente se
	 * monta bajo `esAdmin` y no bajo `administraLaTienda`, que es el
	 * interruptor que usan las pantallas del catalogo.
	 *
	 *
	 * EL DINERO ES TEXTO, Y NO SE TOCA
	 * ---------------------------------------------------------------
	 * Todos los montos llegan como string con dos decimales ("13346.00"),
	 * nunca como numero. Son `numeric(12,2)` de PostgreSQL y pasarlos por el
	 * float de JavaScript les mete el redondeo binario -- el clasico
	 * 0.1 + 0.2 = 0.30000000000000004, que en una columna de dinero de un
	 * reporte de ventas es un numero mal.
	 *
	 * Asi que aqui NO se suma, NO se promedia y NO se convierte a Number para
	 * mostrar. Lo unico que se hace es ponerle los separadores de miles
	 * partiendo el TEXTO (ver `quetzales`). Todo lo que hay que sumar ya viene
	 * sumado por PostgreSQL, que es quien sabe hacerlo.
	 *
	 *
	 * POR QUE LAS DOS COLUMNAS DE MONTO NO CUADRAN, Y ESTA BIEN
	 * ---------------------------------------------------------------
	 * `pedidos_por_estado[].monto` se suma de las LINEAS del pedido (el precio
	 * congelado por cantidad). `pagos_por_estado[].monto` se suma de
	 * `pago.monto`. No son la misma cifra y no tienen por que serlo: al
	 * cancelar un pedido ya comprado, sus lineas quedan intactas -- la suma no
	 * cambia -- pero el pago pasa a `reembolsado` conservando su monto.
	 *
	 * Se dice en pantalla. Dos tablas de dinero que no cuadran y nadie explica
	 * por que se leen como un error de cuentas.
	 */

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	/** Una fila de un desglose. Las tres tablas tienen la misma forma. */
	interface FilaDesglose {
		estado?: string;
		metodo?: string;
		cantidad: number;
		/** Texto con dos decimales. Ver la nota de arriba. */
		monto: string;
	}

	interface ReporteVentas {
		generado: string;
		/** Siempre las 5 filas del catalogo, aunque valgan 0. */
		pedidos_por_estado: FilaDesglose[];
		/** Siempre las 4. */
		pagos_por_estado: FilaDesglose[];
		/** Siempre las 3. */
		pagos_por_metodo: FilaDesglose[];
		totales: {
			pedidos: number;
			unidades_vendidas: number;
			ingresos: string;
			reembolsado: string;
			ticket_promedio: string;
		};
	}

	interface Reservacion {
		id_pedido: number;
		/** ISO 8601. El modelo del backend lo declara Date, pero por el cable llega string. */
		fecha_creacion: string;
		cliente: {
			id_usuario: number;
			usuario: string;
			correo_electronico: string;
			nombre: string;
		};
		cantidad_lineas: number;
		unidades: number;
		total: string;
		ciudad: string;
		departamento: string;
	}

	interface ReporteReservaciones {
		generado: string;
		resumen: { cantidad: number; unidades: number; total: string };
		reservaciones: Reservacion[];
	}

	let ventas = $state<ReporteVentas | null>(null);
	let reservaciones = $state<ReporteReservaciones | null>(null);

	let cargando = $state(true);
	let error = $state('');

	// onMount y no $effect. Con $effect esto se repetiria solo -- en este mismo
	// proyecto se midieron seis llamadas en el mismo instante con un
	// console.trace -- y aqui serian doce peticiones, que son dos reportes.
	onMount(cargar);

	async function cargar() {
		cargando = true;
		error = '';

		// Las dos en paralelo: no dependen una de otra.
		const [v, r] = await Promise.all([
			pedir<ReporteVentas>('/admin/reportes/ventas'),
			pedir<ReporteReservaciones>('/admin/reportes/reservaciones')
		]);

		cargando = false;

		if (v.estado === 401 || r.estado === 401) {
			alExpirarSesion();
			return;
		}

		const fallo = [v, r].find((x) => !x.ok || !x.payload);
		if (fallo) {
			// mensajeUtil y no el mensaje crudo: si el cuerpo no trae `mensaje`
			// -- un 500 de fuera del controlador, un proxy en el medio -- quedaba
			// undefined y la caja de error salia vacia.
			error = mensajeUtil(fallo);
			ventas = null;
			reservaciones = null;
			return;
		}

		ventas = v.payload;
		reservaciones = r.payload;
	}

	/**
	 * Le pone separadores de miles a un monto SIN convertirlo a numero.
	 *
	 * Se parte el texto por el punto y se agrupan los enteros de tres en tres.
	 * Un `Number(x).toLocaleString()` seria una linea mas corto y es justo lo
	 * que no se puede hacer: reintroduce el float que el backend evito
	 * mandando el dinero como texto.
	 */
	function quetzales(monto: string): string {
		const texto = String(monto ?? '').trim();
		if (texto === '') return 'Q0.00';

		const negativo = texto.startsWith('-');
		const limpio = negativo ? texto.slice(1) : texto;
		const [enteros, decimales = '00'] = limpio.split('.');

		const conMiles = enteros.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
		return `${negativo ? '-' : ''}Q${conMiles}.${decimales}`;
	}

	/** Cero se pinta gris: en una tabla de catalogo completo la mayoria son ceros. */
	function esCero(monto: string): boolean {
		return Number.parseFloat(monto) === 0;
	}

	function fecha(valor: string): string {
		if (!valor) return '--';
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '--';
		return d.toLocaleString('es-GT', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}

	function hora(valor: string): string {
		if (!valor) return '';
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '';
		return d.toLocaleTimeString('es-GT', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
	}
</script>

<section class="reportes">
	<div class="titulo">
		<h2>Reportes</h2>
		{#if !cargando && !error && ventas}
			<span class="sello">generado a las {hora(ventas.generado)}</span>
		{/if}
		{#if !cargando}
			<div class="acciones">
				<button type="button" onclick={cargar}>Actualizar</button>
			</div>
		{/if}
	</div>

	<p class="intro">
		El estado del dinero en toda la tienda, ahora mismo. Los dos reportes se leen de
		PostgreSQL y no escriben nada.
	</p>

	{#if cargando}
		<p class="gris">Generando los reportes...</p>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if ventas && reservaciones}
		<!-- ===================== VENTAS ===================== -->

		<h3 class="seccion">Ventas</h3>

		<div class="tarjetas">
			<div class="tarjeta">
				<span class="cifra">{quetzales(ventas.totales.ingresos)}</span>
				<span class="rotulo">Cobrado</span>
				<span class="pie">suma de los pagos en estado pagado</span>
			</div>
			<div class="tarjeta">
				<span class="cifra">{quetzales(ventas.totales.ticket_promedio)}</span>
				<span class="rotulo">Compra promedio</span>
				<span class="pie">cobrado entre el numero de pagos</span>
			</div>
			<div class="tarjeta">
				<span class="cifra">{ventas.totales.unidades_vendidas}</span>
				<span class="rotulo">Unidades vendidas</span>
				<!-- Se dice que la cancelada no cuenta porque si no, este numero
				     parece que no cuadra con el total de pedidos de la tabla. -->
				<span class="pie">sin contar las de pedidos cancelados</span>
			</div>
			<div class="tarjeta" class:alerta={!esCero(ventas.totales.reembolsado)}>
				<span class="cifra">{quetzales(ventas.totales.reembolsado)}</span>
				<span class="rotulo">Devuelto</span>
				<span class="pie">no se resta de lo cobrado; va aparte</span>
			</div>
		</div>

		<div class="rejilla">
			<div class="bloque">
				<h4>Pedidos por estado</h4>
				<div class="tabla">
					<table>
						<thead>
							<tr>
								<th>Estado</th>
								<th class="num">Pedidos</th>
								<th class="num">Monto</th>
							</tr>
						</thead>
						<tbody>
							{#each ventas.pedidos_por_estado as fila (fila.estado)}
								<tr class:vacia={fila.cantidad === 0}>
									<td>{fila.estado}</td>
									<td class="num">{fila.cantidad}</td>
									<td class="num dinero">{quetzales(fila.monto)}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
				<p class="nota">Monto sumado de las lineas de cada pedido, al precio congelado.</p>
			</div>

			<div class="bloque">
				<h4>Pagos por estado</h4>
				<div class="tabla">
					<table>
						<thead>
							<tr>
								<th>Estado</th>
								<th class="num">Pagos</th>
								<th class="num">Monto</th>
							</tr>
						</thead>
						<tbody>
							{#each ventas.pagos_por_estado as fila (fila.estado)}
								<tr class:vacia={fila.cantidad === 0}>
									<td>{fila.estado}</td>
									<td class="num">{fila.cantidad}</td>
									<td class="num dinero">{quetzales(fila.monto)}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
				<!-- La explicacion va aqui, pegada a las dos tablas que no cuadran
				     entre si. Puesta en otro sitio no la lee quien las compara. -->
				<p class="nota">
					Sumado de <code>pago.monto</code>, no de las lineas, asi que no tiene por que
					coincidir con la tabla de al lado: cancelar un pedido ya comprado deja sus lineas
					intactas y mueve el pago a devuelto.
				</p>
			</div>

			<div class="bloque">
				<h4>Pagos por metodo</h4>
				<div class="tabla">
					<table>
						<thead>
							<tr>
								<th>Metodo</th>
								<th class="num">Pagos</th>
								<th class="num">Monto</th>
							</tr>
						</thead>
						<tbody>
							{#each ventas.pagos_por_metodo as fila (fila.metodo)}
								<tr class:vacia={fila.cantidad === 0}>
									<td>{fila.metodo}</td>
									<td class="num">{fila.cantidad}</td>
									<td class="num dinero">{quetzales(fila.monto)}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
				<p class="nota">
					Hoy todos los pagos nacen ya pagados: comprar no distingue el metodo, es una
					simplificacion de la Entrega 1.
				</p>
			</div>
		</div>

		<!-- ===================== RESERVACIONES ===================== -->

		<h3 class="seccion">
			Reservaciones
			<span class="etiqueta" class:limpio={reservaciones.resumen.cantidad === 0}>
				{reservaciones.resumen.cantidad}
			</span>
		</h3>

		<p class="intro chica">
			Pedidos que se abrieron y todavia no se pagaron. En Mesh una reservacion <strong
				>es</strong
			> un pedido pendiente: no hay un concepto aparte.
		</p>

		{#if reservaciones.reservaciones.length === 0}
			<!-- El vacio con su motivo. Un "no hay nada" a secas en una pantalla
			     recien conectada se lee como que la ruta no funciona, y aqui el
			     cero es lo ESPERADO: desde que el carrito vive en Redis, agregar
			     y pagar ocurren en el mismo instante y ya casi no nacen pedidos
			     pendientes. -->
			<div class="limpio-caja">
				<h4>No hay ningun pedido esperando pago</h4>
				<p class="gris">
					Es lo normal: desde que el carrito vive en Redis, agregar y pagar pasan en el mismo
					instante, asi que un pedido solo se queda en pendiente si viene del flujo viejo
					(crear el pedido sin llegar a comprarlo).
				</p>
			</div>
		{:else}
			<div class="tarjetas chicas">
				<div class="tarjeta">
					<span class="cifra">{reservaciones.resumen.cantidad}</span>
					<span class="rotulo">Pedidos</span>
				</div>
				<div class="tarjeta">
					<span class="cifra">{reservaciones.resumen.unidades}</span>
					<span class="rotulo">Unidades</span>
				</div>
				<div class="tarjeta">
					<span class="cifra">{quetzales(reservaciones.resumen.total)}</span>
					<span class="rotulo">Valor retenido</span>
				</div>
			</div>

			<div class="tabla">
				<table>
					<thead>
						<tr>
							<th>Pedido</th>
							<th>Cliente</th>
							<th>Abierto</th>
							<th>Destino</th>
							<th class="num">Lineas</th>
							<th class="num">Unidades</th>
							<th class="num">Total</th>
						</tr>
					</thead>
					<tbody>
						{#each reservaciones.reservaciones as r (r.id_pedido)}
							<tr>
								<td class="fuerte">#{r.id_pedido}</td>
								<td>
									<span class="fuerte">{r.cliente.nombre}</span>
									<span class="gris chico">{r.cliente.correo_electronico}</span>
								</td>
								<td class="gris">{fecha(r.fecha_creacion)}</td>
								<td class="gris">{r.ciudad}, {r.departamento}</td>
								<td class="num">{r.cantidad_lineas}</td>
								<td class="num">{r.unidades}</td>
								<td class="num dinero">{quetzales(r.total)}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>

			<!-- Esto es lo que hay que decir de una lista de "reservaciones", y
			     no es un detalle: quien lee la palabra da por hecho que hay
			     unidades apartadas. No las hay. -->
			<p class="nota aviso">
				Un pedido pendiente <strong>no aparta existencias</strong>. Nunca descuenta ni
				reserva unidades; lo unico que quedo fijo es el precio de cada linea, congelado al
				agregarla, asi que el total de arriba es firme aunque el stock no este garantizado.
			</p>
		{/if}
	{/if}
</section>

<style>
	.reportes {
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

	.sello {
		font-size: 0.82rem;
		color: var(--gris);
	}

	.acciones {
		margin-left: auto;
		display: flex;
		gap: 10px;
	}

	.acciones button,
	.fallo button {
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

	.acciones button:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.intro {
		max-width: 640px;
		margin-bottom: 20px;
		color: var(--gris);
		font-size: 0.94rem;
	}

	.intro.chica {
		margin-bottom: 14px;
		font-size: 0.9rem;
	}

	.gris {
		color: var(--gris);
	}

	.chico {
		font-size: 0.84rem;
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

	.seccion {
		display: flex;
		align-items: center;
		gap: 10px;
		margin: 28px 0 6px;
		font-size: 1.05rem;
	}

	.seccion:first-of-type {
		margin-top: 8px;
	}

	.etiqueta {
		padding: 2px 10px;
		font-size: 0.8rem;
		font-weight: 400;
		color: var(--indigo);
		background: var(--indigo-cl);
		border: 1px solid var(--indigo);
		border-radius: 999px;
	}

	.etiqueta.limpio {
		color: var(--gris);
		background: var(--panel);
		border-color: var(--linea);
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

	/* -- las tarjetas de cifra -- */

	.tarjetas {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
		gap: 12px;
		margin: 14px 0 22px;
	}

	.tarjetas.chicas {
		grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
		margin-bottom: 16px;
	}

	.tarjeta {
		display: flex;
		flex-direction: column;
		gap: 3px;
		padding: 16px 18px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.tarjeta.alerta {
		border-color: var(--rojo);
	}

	.cifra {
		font-size: 1.45rem;
		font-weight: 500;
		color: var(--tinta);
		/* Las cifras se leen en columna: con ancho fijo por digito no bailan. */
		font-variant-numeric: tabular-nums;
	}

	.rotulo {
		font-size: 0.9rem;
		color: var(--tinta);
	}

	.pie {
		font-size: 0.78rem;
		color: var(--gris);
	}

	/* -- las tres tablas del desglose -- */

	.rejilla {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
		gap: 22px 24px;
	}

	.bloque h4 {
		margin-bottom: 8px;
		font-size: 0.92rem;
	}

	.nota {
		margin-top: 8px;
		font-size: 0.8rem;
		color: var(--gris);
	}

	.nota.aviso {
		margin-top: 12px;
		padding: 10px 14px;
		font-size: 0.86rem;
		color: var(--tinta);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	/* La tabla se desborda en horizontal DENTRO de su caja y nunca empuja el
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

	td .gris.chico {
		display: block;
	}

	th.num,
	td.num {
		text-align: right;
		font-variant-numeric: tabular-nums;
	}

	.dinero {
		font-weight: 500;
	}

	/* Una fila en cero sigue estando -- las tablas traen el catalogo completo a
	   proposito, para que se vea que el estado existe y vale cero -- pero se
	   apaga para que las que tienen datos salten a la vista. */
	tr.vacia td {
		color: var(--gris-2);
	}

	.limpio-caja {
		padding: 18px 22px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.limpio-caja h4 {
		margin-bottom: 6px;
		font-size: 1rem;
	}

	.limpio-caja p {
		max-width: 640px;
		font-size: 0.92rem;
	}

	@media (max-width: 620px) {
		.reportes {
			padding: 22px 20px;
		}
		.acciones {
			margin-left: 0;
			width: 100%;
		}
	}
</style>
