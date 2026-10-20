<script lang="ts">
	import { onMount } from 'svelte';
	import { mensajeUtil, pedir } from './api';
	import Cifra from './graficas/Cifra.svelte';
	import Dona from './graficas/Dona.svelte';
	import Barras from './graficas/Barras.svelte';

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
	 * float de JavaScript les mete el redondeo binario. Lo que se ESCRIBE en
	 * pantalla sale del texto (ver `quetzales`). El numero solo se usa para el
	 * TAMANO de cada parte de una grafica, donde un centavo de redondeo no se ve.
	 *
	 *
	 * POR QUE PEDIDOS Y PAGOS NO CUADRAN, Y ESTA BIEN
	 * ---------------------------------------------------------------
	 * `pedidos_por_estado[].monto` se suma de las LINEAS del pedido y
	 * `pagos_por_estado[].monto` de `pago.monto`: al cancelar un pedido ya
	 * comprado sus lineas quedan intactas y el pago pasa a `reembolsado`. Por
	 * eso la grafica de pedidos cuenta PEDIDOS y la de pagos cuenta DINERO, y
	 * no se ponen una al lado de la otra como si fueran la misma cifra.
	 *
	 *
	 * LOS ESTADOS DEL PEDIDO
	 * ---------------------------------------------------------------
	 * El catalogo tiene cinco (pendiente, comprado, enviado, entregado,
	 * cancelado), pero hoy el backend solo sabe comprar y cancelar: no hay ruta
	 * para marcar un pedido como enviado o entregado (docs/BACKEND-PENDIENTE.md).
	 * El camino del pedido se dibuja entero igual, con esos dos en cero.
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
	 * Le pone separadores de miles a un monto SIN convertirlo a numero: se
	 * parte el texto por el punto y se agrupan los enteros de tres en tres.
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

	/** Solo para el tamano de una grafica. Ver la nota de arriba. */
	function tamano(monto: string): number {
		const n = Number.parseFloat(monto);
		return Number.isFinite(n) ? n : 0;
	}

	function fecha(valor: string): string {
		if (!valor) return '--';
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '--';
		return d.toLocaleString('es-GT', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
	}

	function hora(valor: string): string {
		if (!valor) return '';
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '';
		return d.toLocaleTimeString('es-GT', { hour: '2-digit', minute: '2-digit' });
	}

	/** Los nombres que lee una persona, y el color de cada estado. */
	const PEDIDO: Record<string, { nombre: string; color: string }> = {
		pendiente: { nombre: 'Sin pagar', color: 'var(--g2)' },
		comprado: { nombre: 'Pagados', color: 'var(--g1)' },
		enviado: { nombre: 'Enviados', color: 'var(--g5)' },
		entregado: { nombre: 'Entregados', color: 'var(--g3)' },
		cancelado: { nombre: 'Cancelados', color: 'var(--g4)' }
	};

	const PAGO: Record<string, { nombre: string; color: string }> = {
		pagado: { nombre: 'Cobrados', color: 'var(--g3)' },
		reembolsado: { nombre: 'Devueltos', color: 'var(--g4)' },
		pendiente: { nombre: 'Por cobrar', color: 'var(--g2)' },
		fallido: { nombre: 'Rechazados', color: 'var(--g6)' }
	};

	function capital(t: string): string {
		return t ? t.charAt(0).toUpperCase() + t.slice(1) : t;
	}

	let cantidadDe = $derived((estado: string) => ventas?.pedidos_por_estado.find((f) => f.estado === estado)?.cantidad ?? 0);

	let partesPedidos = $derived(
		(ventas?.pedidos_por_estado ?? []).map((f) => ({
			nombre: PEDIDO[f.estado ?? '']?.nombre ?? capital(f.estado ?? ''),
			valor: f.cantidad,
			texto: String(f.cantidad),
			color: PEDIDO[f.estado ?? '']?.color
		}))
	);

	let partesPagos = $derived(
		(ventas?.pagos_por_estado ?? [])
			.map((f) => ({
				nombre: PAGO[f.estado ?? '']?.nombre ?? capital(f.estado ?? ''),
				valor: tamano(f.monto),
				texto: quetzales(f.monto),
				color: PAGO[f.estado ?? '']?.color
			}))
			.sort((a, b) => b.valor - a.valor)
	);

	let filasMetodo = $derived(
		[...(ventas?.pagos_por_metodo ?? [])]
			.sort((a, b) => tamano(b.monto) - tamano(a.monto))
			.map((f) => ({
				id: f.metodo ?? '',
				nombre: capital(f.metodo ?? ''),
				valor: tamano(f.monto),
				texto: quetzales(f.monto),
				detalle: `${f.cantidad} ${f.cantidad === 1 ? 'pago' : 'pagos'}`
			}))
	);

	let totalPedidos = $derived((ventas?.pedidos_por_estado ?? []).reduce((s, f) => s + f.cantidad, 0));

	/** Que parte del dinero que entro se devolvio, de 0 a 1. */
	let parteDevuelta = $derived.by(() => {
		if (!ventas) return 0;
		const c = tamano(ventas.totales.ingresos);
		const d = tamano(ventas.totales.reembolsado);
		return c + d > 0 ? d / (c + d) : 0;
	});

	/** El camino de un pedido, en orden. Cancelado va aparte. */
	const CAMINO = ['pendiente', 'comprado', 'enviado', 'entregado'];
</script>

<section class="reportes">
	<div class="titulo">
		<div>
			<h2>Reportes</h2>
			<p class="intro">Como va la tienda: lo que entro, lo que se devolvio y en que van los pedidos.</p>
		</div>
		{#if !cargando}
			<div class="acciones">
				{#if !error && ventas}<span class="sello">Al dia a las {hora(ventas.generado)}</span>{/if}
				<button type="button" onclick={cargar}>Actualizar</button>
			</div>
		{/if}
	</div>

	{#if cargando}
		<p class="gris">Preparando los reportes...</p>
	{:else if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={cargar}>Reintentar</button>
		</div>
	{:else if ventas && reservaciones}
		<div class="cifras">
			<Cifra rotulo="Cobrado" valor={quetzales(ventas.totales.ingresos)} nota="Pagos que entraron" tono="bien" />
			<Cifra rotulo="Compra promedio" valor={quetzales(ventas.totales.ticket_promedio)} nota="Lo que deja cada compra" />
			<Cifra rotulo="Unidades vendidas" valor={ventas.totales.unidades_vendidas.toLocaleString('es-GT')} nota="Sin contar lo cancelado" />
			<Cifra
				rotulo="Devuelto"
				valor={quetzales(ventas.totales.reembolsado)}
				nota="{Math.round(parteDevuelta * 100)} % de lo que se vendio"
				tono="ojo"
				parte={parteDevuelta}
			/>
		</div>

		<div class="rejilla">
			<article class="tarjeta">
				<h3>Pedidos</h3>
				<p class="sub">En que estado esta cada uno</p>
				<Dona partes={partesPedidos} centro={{ cifra: totalPedidos.toLocaleString('es-GT'), rotulo: 'pedidos' }} />

				<ol class="camino" aria-label="El camino de un pedido">
					{#each CAMINO as estado, i (estado)}
						<li class:vacio={cantidadDe(estado) === 0} style="--color: {PEDIDO[estado].color}">
							<span class="paso-cifra">{cantidadDe(estado)}</span>
							<span class="paso-nombre">{PEDIDO[estado].nombre}</span>
						</li>
						{#if i < CAMINO.length - 1}<li class="flecha" aria-hidden="true"></li>{/if}
					{/each}
				</ol>
				<p class="nota">Por ahora un pedido pagado no se marca como enviado ni entregado.</p>
			</article>

			<article class="tarjeta">
				<h3>Pagos</h3>
				<p class="sub">Cuanto dinero hay en cada estado</p>
				<Dona partes={partesPagos} centro={{ cifra: quetzales(ventas.totales.ingresos), rotulo: 'cobrado' }} />
				<div class="mini">
					{#each ventas.pagos_por_estado.filter((f) => f.cantidad > 0) as f (f.estado)}
						<div style="--color: {PAGO[f.estado ?? '']?.color ?? 'var(--g1)'}">
							<span class="mini-cifra">{f.cantidad.toLocaleString('es-GT')}</span>
							<span class="mini-nombre">pagos {(PAGO[f.estado ?? '']?.nombre ?? capital(f.estado ?? '')).toLowerCase()}</span>
						</div>
					{/each}
				</div>
			</article>

			<article class="tarjeta ancha">
				<h3>Como pagan</h3>
				<p class="sub">Lo cobrado por cada forma de pago</p>
				<Barras filas={filasMetodo} color="var(--g5)" />
			</article>
		</div>

		<h3 class="seccion">
			Pedidos sin pagar
			<span class="etiqueta" class:limpio={reservaciones.resumen.cantidad === 0}>
				{reservaciones.resumen.cantidad}
			</span>
		</h3>

		{#if reservaciones.reservaciones.length === 0}
			<p class="limpio-caja">Ningun pedido esta esperando pago.</p>
		{:else}
			<p class="intro chica">
				Suman {quetzales(reservaciones.resumen.total)} en {reservaciones.resumen.unidades}
				{reservaciones.resumen.unidades === 1 ? 'producto' : 'productos'}. No apartan nada: el producto
				se descuenta hasta que pagan.
			</p>

			<div class="tabla">
				<table>
					<thead>
						<tr>
							<th>Pedido</th>
							<th>Cliente</th>
							<th>Desde</th>
							<th>Envio a</th>
							<th class="num">Productos</th>
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
								<td class="gris">{[r.ciudad, r.departamento].filter((x) => x && x.trim()).join(', ') || 'Sin direccion'}</td>
								<td class="num">{r.unidades}</td>
								<td class="num dinero">{quetzales(r.total)}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
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
		align-items: flex-start;
		gap: var(--e3);
		flex-wrap: wrap;
		margin-bottom: var(--e5);
	}

	.titulo h2 {
		font-size: var(--f-xl);
		margin-bottom: 4px;
	}

	.sello {
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.acciones {
		margin-left: auto;
		display: flex;
		align-items: center;
		gap: var(--e3);
	}

	.acciones button,
	.fallo button {
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

	.acciones button:hover {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.intro {
		max-width: 640px;
		color: var(--gris);
		font-size: var(--f-base);
	}

	.intro.chica {
		margin-bottom: 14px;
		font-size: var(--f-ms);
	}

	.gris {
		color: var(--gris);
	}

	.chico {
		font-size: var(--f-sm);
	}

	.fuerte {
		font-weight: 500;
		color: var(--tinta);
	}

	.fallo {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		flex-wrap: wrap;
		padding: 14px 18px;
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	/* -- las cifras de arriba -- */

	.cifras {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
		gap: var(--e3);
		margin-bottom: var(--e5);
	}

	/* -- las tres graficas -- */

	.rejilla {
		display: grid;
		grid-template-columns: repeat(2, minmax(0, 1fr));
		gap: var(--e4);
	}

	.tarjeta.ancha {
		grid-column: 1 / -1;
	}

	.tarjeta {
		display: flex;
		flex-direction: column;
		gap: var(--e3);
		padding: 20px 22px;
		background: var(--off);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.tarjeta h3 {
		font-size: var(--f-md);
		color: var(--tinta);
	}

	.sub {
		margin-top: -8px;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.nota {
		font-size: var(--f-xs);
		color: var(--gris-2);
	}

	/* -- cuantos pagos hay en cada estado -- */

	.mini {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
		gap: var(--e2);
		margin-top: auto;
	}

	.mini div {
		display: flex;
		flex-direction: column;
		gap: 2px;
		padding: 10px 14px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.mini-cifra {
		font-size: var(--f-lg);
		font-weight: 600;
		color: var(--tinta);
		font-variant-numeric: tabular-nums;
	}

	.mini-nombre {
		font-size: var(--f-xs);
		color: var(--gris);
	}

	/* -- el camino del pedido -- */

	.camino {
		list-style: none;
		display: flex;
		align-items: center;
		gap: 4px;
		padding: 12px;
		background: var(--panel);
		border-radius: var(--r);
	}

	.camino li:not(.flecha) {
		flex: 1;
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 2px;
		min-width: 0;
	}

	.paso-cifra {
		min-width: 34px;
		padding: 2px 8px;
		font-weight: 600;
		text-align: center;
		color: var(--blanco);
		background: var(--color);
		border-radius: 999px;
		font-variant-numeric: tabular-nums;
	}

	.vacio .paso-cifra {
		color: var(--gris);
		background: none;
		border: 1px dashed var(--linea);
	}

	.paso-nombre {
		font-size: var(--f-xs);
		color: var(--gris);
		white-space: nowrap;
	}

	.flecha {
		flex: 0 0 14px;
		height: 2px;
		margin-bottom: 16px;
		background: var(--linea);
	}

	/* -- los pedidos sin pagar -- */

	.seccion {
		display: flex;
		align-items: center;
		gap: var(--e2);
		margin: 32px 0 8px;
		font-size: var(--f-md);
	}

	.etiqueta {
		padding: 2px 10px;
		font-size: var(--f-sm);
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

	.limpio-caja {
		padding: 14px 18px;
		color: var(--gris);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
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
		font-size: var(--f-ms);
	}

	th {
		padding: 9px 12px;
		text-align: left;
		font-weight: 500;
		font-size: var(--f-sm);
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

	@media (max-width: 620px) {
		.reportes {
			padding: 22px 16px;
		}
		.acciones {
			margin-left: 0;
			width: 100%;
		}
		.rejilla {
			grid-template-columns: 1fr;
		}
	}
</style>
