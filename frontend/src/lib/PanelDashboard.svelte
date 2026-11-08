<script lang="ts">
	/**
	 * El dashboard general del admin (pestana Dashboard del panel): como va la
	 * tienda en un periodo, con las cifras contra el periodo anterior, las
	 * graficas y el registro de pedidos. Cada seccion es una ruta aparte de
	 * GET /admin/dashboard/* y se piden todas a la vez: si una base no
	 * responde, solo su tarjeta avisa.
	 *
	 * Se exporta igual que el panel de metricas de la aerolinea: PDF con las
	 * graficas, Excel con una hoja por seccion, o cualquiera de los dos por
	 * correo, eligiendo que secciones van.
	 */
	import { onMount } from 'svelte';
	import { API, conJson, mensajeUtil, pedir } from './api';
	import Apiladas from './graficas/Apiladas.svelte';
	import Barras from './graficas/Barras.svelte';
	import Dona from './graficas/Dona.svelte';
	import Embudo from './graficas/Embudo.svelte';
	import Linea from './graficas/Linea.svelte';
	import MapaCalor from './graficas/MapaCalor.svelte';

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	// ------------------------------------------------------------ los tipos

	interface Periodo {
		desde: string;
		hasta: string;
		dias: number;
		anterior_desde: string;
		anterior_hasta: string;
		agrupado: 'dia' | 'semana' | 'mes';
	}
	interface Cifras {
		ingresos: string;
		pedidos: number;
		ticket_promedio: string;
		unidades: number;
		compradores: number;
		clientes_nuevos: number;
		cancelados: number;
		tasa_cancelacion: number;
		reembolsado: string;
		vendedores_con_ventas: number;
	}
	interface Resumen {
		periodo: Periodo;
		actual: Cifras;
		anterior: Cifras;
		hoy: { productos_activos: number; vendedores_activos: number; cuentas: number; carritos_abiertos: number };
	}
	interface Ventas {
		serie: { periodo: string; ingresos: string; pedidos: number; unidades: number }[];
	}
	interface EmbudoApi {
		vieron: number | null;
		agregaron: number | null;
		compraron: number;
		cancelaron: number;
		sin_eventos: boolean;
		eventos_desde: string | null;
	}
	interface FilaCategoria {
		id_categoria: number | null;
		categoria: string;
		ingresos: string;
		unidades: number;
		pedidos: number;
	}
	interface FilaPago {
		mes: string;
		metodo: string;
		ingresos: string;
		pedidos: number;
	}
	interface CeldaApi {
		dia_semana: number;
		hora: number;
		pedidos: number;
		ingresos: string;
	}
	interface FilaVendedor {
		id_usuario: number;
		vendedor: string;
		ingresos: string;
		unidades: number;
		pedidos: number;
		nota_promedio: number | null;
	}
	interface FilaProducto {
		id_producto: number;
		nombre: string;
		ingresos: string;
		unidades: number;
		pedidos: number;
	}
	interface FilaDepartamento {
		departamento: string;
		pedidos: number;
		ingresos: string;
	}
	interface Busquedas {
		por_dia: { periodo: string; busquedas: number; sin_resultados: number }[];
		mas_buscadas: { termino: string; personas: number }[];
		sin_resultado: { termino: string; personas: number }[];
	}
	interface Cancelaciones {
		por_tiempo: { tramo: string; pedidos: number }[];
		por_categoria: { categoria: string; pedidos: number; unidades: number }[];
		por_metodo: { metodo: string; pedidos: number; monto: string }[];
	}
	interface FilaPedido {
		id_pedido: number;
		fecha: string;
		cliente: string;
		correo: string;
		estado: string;
		metodo: string | null;
		estado_pago: string | null;
		total: string;
		unidades: number;
		departamento: string | null;
		/** Del ultimo cambio de estado (migracion 051). true si lo hizo la tienda. */
		por_la_tienda: boolean | null;
		motivo: string | null;
	}
	interface Pedidos {
		pedidos: FilaPedido[];
		total: number;
		pagina: number;
		total_paginas: number;
	}

	/** Una seccion: lo que llego, si esta cargando y el aviso si fallo. */
	interface Seccion<T> {
		datos: T | null;
		cargando: boolean;
		error: string;
	}
	const nueva = <T,>(): Seccion<T> => ({ datos: null, cargando: true, error: '' });

	// ------------------------------------------------------------ el periodo

	const hoy = () => {
		const d = new Date();
		return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
	};
	const restarDias = (texto: string, dias: number) => {
		const d = new Date(`${texto}T12:00:00`);
		d.setDate(d.getDate() - dias);
		return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
	};
	type Rapido = '7' | '30' | 'mes' | 'anio' | 'todo' | 'otro';
	const RAPIDOS: { id: Rapido; nombre: string }[] = [
		{ id: '7', nombre: '7 dias' },
		{ id: '30', nombre: '30 dias' },
		{ id: 'mes', nombre: 'Este mes' },
		{ id: 'anio', nombre: 'Este anio' },
		{ id: 'todo', nombre: 'Tres anios' }
	];
	let rapido = $state<Rapido>('anio');
	let desde = $state(`${hoy().slice(0, 4)}-01-01`);
	let hasta = $state(hoy());

	function elegirRapido(r: Rapido) {
		rapido = r;
		periodoAbierto = false;
		hasta = hoy();
		if (r === '7') desde = restarDias(hasta, 6);
		else if (r === '30') desde = restarDias(hasta, 29);
		else if (r === 'mes') desde = `${hasta.slice(0, 7)}-01`;
		else if (r === 'anio') desde = `${hasta.slice(0, 4)}-01-01`;
		else if (r === 'todo') desde = restarDias(hasta, 3 * 365);
		void cargarTodo();
	}

	const consulta = () => `desde=${desde}&hasta=${hasta}`;

	const MESES_LARGOS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
	/** 2026-10-20 como 20 de octubre de 2026. */
	const fechaLarga = (texto: string) => {
		const [a, m, d] = texto.split('-').map(Number);
		return `${d} de ${MESES_LARGOS[m - 1]} de ${a}`;
	};
	/** Lo que dice el boton del periodo. */
	let nombrePeriodo = $derived.by(() => {
		const r = RAPIDOS.find((x) => x.id === rapido);
		if (r) return r.nombre;
		const [ad, md, dd] = desde.split('-').map(Number);
		const [ah, mh, dh] = hasta.split('-').map(Number);
		return ad === ah ? `${dd} ${MESES_CORTOS[md - 1]} al ${dh} ${MESES_CORTOS[mh - 1]} ${ah}` : `${dd} ${MESES_CORTOS[md - 1]} ${ad} al ${dh} ${MESES_CORTOS[mh - 1]} ${ah}`;
	});
	const MESES_CORTOS = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

	// ------------------------------------------------------------ los datos

	let resumen = $state(nueva<Resumen>());
	let ventas = $state(nueva<Ventas>());
	let embudo = $state(nueva<EmbudoApi>());
	let categorias = $state(nueva<FilaCategoria[]>());
	let pagos = $state(nueva<FilaPago[]>());
	let mapa = $state(nueva<CeldaApi[]>());
	let vendedores = $state(nueva<FilaVendedor[]>());
	let productos = $state(nueva<FilaProducto[]>());
	let departamentos = $state(nueva<FilaDepartamento[]>());
	let busquedas = $state(nueva<Busquedas>());
	let cancelaciones = $state(nueva<Cancelaciones>());
	let pedidos = $state(nueva<Pedidos>());

	let vuelta = 0;
	let errorPeriodo = $state('');

	async function traer<T>(ruta: string, poner: (s: Seccion<T>) => void, esta: number) {
		poner({ datos: null, cargando: true, error: '' });
		const r = await pedir<T>(`/admin/dashboard/${ruta}`);
		if (esta !== vuelta) return;
		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}
		poner(r.ok ? { datos: r.payload, cargando: false, error: '' } : { datos: null, cargando: false, error: mensajeUtil(r) });
	}

	async function cargarTodo() {
		errorPeriodo = '';
		if (desde > hasta) {
			errorPeriodo = 'Desde tiene que ir antes que hasta';
			return;
		}
		const esta = ++vuelta;
		const q = consulta();
		paginaPedidos = 1;
		await Promise.all([
			traer<Resumen>(`resumen?${q}`, (s) => (resumen = s), esta),
			traer<Ventas>(`ventas?${q}`, (s) => (ventas = s), esta),
			traer<EmbudoApi>(`embudo?${q}`, (s) => (embudo = s), esta),
			traer<FilaCategoria[]>(`categorias?${q}`, (s) => (categorias = s), esta),
			traer<FilaPago[]>(`pagos?${q}`, (s) => (pagos = s), esta),
			traer<CeldaApi[]>(`mapa?${q}`, (s) => (mapa = s), esta),
			traer<FilaVendedor[]>(`vendedores?${q}`, (s) => (vendedores = s), esta),
			traer<FilaProducto[]>(`productos?${q}`, (s) => (productos = s), esta),
			traer<FilaDepartamento[]>(`departamentos?${q}`, (s) => (departamentos = s), esta),
			traer<Busquedas>(`busquedas?${q}`, (s) => (busquedas = s), esta),
			traer<Cancelaciones>(`cancelaciones?${q}`, (s) => (cancelaciones = s), esta),
			cargarPedidos(esta)
		]);
	}

	// El registro de pedidos tiene sus propios filtros y paginas.
	let paginaPedidos = $state(1);
	let filtroEstado = $state('');
	let filtroMetodo = $state('');
	let filtroTexto = $state('');
	async function cargarPedidos(esta = vuelta) {
		const partes = [consulta(), `pagina=${paginaPedidos}`, 'limite=15'];
		if (filtroEstado) partes.push(`estado=${filtroEstado}`);
		if (filtroMetodo) partes.push(`metodo=${encodeURIComponent(filtroMetodo)}`);
		if (filtroTexto.trim()) partes.push(`texto=${encodeURIComponent(filtroTexto.trim())}`);
		await traer<Pedidos>(`pedidos?${partes.join('&')}`, (s) => (pedidos = s), esta);
	}
	// La tienda gestiona cada pedido desde el registro (migracion 051):
	// marcarlo enviado o entregado, o cancelarlo aunque ya se haya enviado.
	// Cancelar pide confirmar en la misma fila, sin ventanas del navegador.
	let pedidoEnCurso = $state<number | null>(null);
	let confirmandoCancelar = $state<number | null>(null);
	let motivoCancelar = $state('');
	let avisoPedido = $state('');
	let errorPedido = $state('');
	async function gestionarPedido(p: FilaPedido, que: 'enviado' | 'entregado' | 'cancelar') {
		pedidoEnCurso = p.id_pedido;
		avisoPedido = '';
		errorPedido = '';
		const motivo = que === 'cancelar' ? motivoCancelar.trim() || null : null;
		const r = await pedir<unknown>(
			`/admin/pedidos/${p.id_pedido}/${que}`,
			conJson('POST', que === 'cancelar' ? { motivo } : {})
		);
		pedidoEnCurso = null;
		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}
		if (!r.ok) {
			errorPedido = `Pedido ${p.id_pedido}. ${mensajeUtil(r)}`;
			return;
		}
		const estado = que === 'cancelar' ? 'cancelado' : que;
		// Se cambia la fila en su sitio en vez de volver a pedir la pagina, que
		// la vaciaria mientras carga y se perderia de vista el pedido tocado.
		if (pedidos.datos) {
			pedidos = {
				...pedidos,
				datos: {
					...pedidos.datos,
					pedidos: pedidos.datos.pedidos.map((x) =>
						x.id_pedido === p.id_pedido
							? {
									...x,
									estado,
									por_la_tienda: true,
									motivo,
									estado_pago: que === 'cancelar' && x.estado_pago ? 'reembolsado' : x.estado_pago
								}
							: x
					)
				}
			};
		}
		avisoPedido =
			que === 'cancelar'
				? `Pedido ${p.id_pedido} cancelado por la tienda. Se devolvieron las unidades y el pago quedo reembolsado.`
				: `Pedido ${p.id_pedido} marcado como ${estado}.`;
		confirmandoCancelar = null;
		motivoCancelar = '';
	}

	let esperaTexto: ReturnType<typeof setTimeout> | undefined;
	function alEscribirTexto() {
		clearTimeout(esperaTexto);
		esperaTexto = setTimeout(() => {
			paginaPedidos = 1;
			void cargarPedidos();
		}, 350);
	}

	// Un dashboard a la vez (Meme, 2026-10-20: todo junto no cabia). Las
	// subpestanas reparten lo mismo que antes iba en una sola pagina. La ultima
	// que se vio se recuerda en este navegador, es solo una comodidad.
	type Vista = 'ventas' | 'clientes' | 'vendedores' | 'busquedas' | 'cancelaciones' | 'pedidos';
	const VISTAS: { id: Vista; nombre: string }[] = [
		{ id: 'ventas', nombre: 'Ventas' },
		{ id: 'clientes', nombre: 'Clientes' },
		{ id: 'vendedores', nombre: 'Vendedores y productos' },
		{ id: 'busquedas', nombre: 'Busquedas' },
		{ id: 'cancelaciones', nombre: 'Cancelaciones' },
		{ id: 'pedidos', nombre: 'Pedidos' }
	];
	const GUARDADO = 'mesh.dashboard.vista';
	let vista = $state<Vista>('ventas');
	let barra = $state<HTMLDivElement | null>(null);
	function elegirVista(v: Vista) {
		vista = v;
		const arriba = barra?.parentElement?.getBoundingClientRect().top ?? 0;
		if (arriba < 0) window.scrollBy({ top: arriba - 130, behavior: 'smooth' });
		try {
			localStorage.setItem(GUARDADO, v);
		} catch {
			/* sin almacenamiento, se olvida al salir */
		}
	}

	// El periodo vive en un solo boton que abre las opciones.
	let periodoAbierto = $state(false);
	let cajaPeriodo = $state<HTMLDivElement | null>(null);
	function alTocarAfuera(e: MouseEvent) {
		if (periodoAbierto && cajaPeriodo && !cajaPeriodo.contains(e.target as Node)) periodoAbierto = false;
	}
	function alTeclaGlobal(e: KeyboardEvent) {
		if (e.key === 'Escape') periodoAbierto = false;
	}

	onMount(() => {
		try {
			const antes = localStorage.getItem(GUARDADO);
			if (VISTAS.some((v) => v.id === antes)) vista = antes as Vista;
		} catch {
			/* nada guardado */
		}
		document.addEventListener('click', alTocarAfuera);
		document.addEventListener('keydown', alTeclaGlobal);
		void cargarTodo();
		return () => {
			document.removeEventListener('click', alTocarAfuera);
			document.removeEventListener('keydown', alTeclaGlobal);
		};
	});

	// ------------------------------------------------------------ formatos

	const n = (v: string | number | null | undefined) => Number(v ?? 0);
	const quetzales = (v: string | number) =>
		`Q${n(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
	const quetzalesCortos = (v: number) =>
		v >= 1_000_000 ? `Q${(v / 1_000_000).toFixed(1)} M` : v >= 10_000 ? `Q${Math.round(v / 1000)} mil` : `Q${Math.round(v).toLocaleString('en-US')}`;
	const entero = (v: number) => v.toLocaleString('en-US');
	const mayuscula = (t: string) => t.charAt(0).toUpperCase() + t.slice(1);
	const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
	const fechaCorta = (texto: string, agrupado: Periodo['agrupado']) => {
		const [a, m, d] = texto.split('-').map(Number);
		return agrupado === 'mes' ? `${MESES[m - 1]} ${String(a).slice(2)}` : `${d} ${MESES[m - 1]}`;
	};
	const mesCorto = (texto: string) => {
		const [a, m] = texto.split('-').map(Number);
		return `${MESES[m - 1]} ${String(a).slice(2)}`;
	};

	/** La flecha contra el periodo anterior. `alReves` cuando subir es malo (cancelados). */
	function cambio(actual: number, anterior: number, alReves = false) {
		if (anterior === 0) return { texto: actual === 0 ? 'Igual que antes' : 'Sin datos del periodo anterior', clase: 'igual' };
		const d = (actual - anterior) / anterior;
		if (Math.abs(d) < 0.005) return { texto: 'Igual que antes', clase: 'igual' };
		const sube = d > 0;
		return {
			texto: `${sube ? '+' : ''}${(d * 100).toFixed(Math.abs(d) < 0.1 ? 1 : 0)} % contra el periodo anterior`,
			clase: sube !== alReves ? 'bien' : 'mal'
		};
	}

	interface Tarjeta {
		rotulo: string;
		valor: string;
		texto: string;
		clase: string;
		extra?: string;
		principal?: boolean;
	}
	let tarjetas = $derived.by((): Tarjeta[] => {
		const r = resumen.datos;
		if (!r) return [];
		const a = r.actual;
		const b = r.anterior;
		return [
			{ rotulo: 'Cobrado', valor: quetzales(a.ingresos), ...cambio(n(a.ingresos), n(b.ingresos)), principal: true },
			{ rotulo: 'Pedidos', valor: entero(a.pedidos), ...cambio(a.pedidos, b.pedidos) },
			{ rotulo: 'Compra promedio', valor: quetzales(a.ticket_promedio), ...cambio(n(a.ticket_promedio), n(b.ticket_promedio)) },
			{ rotulo: 'Unidades vendidas', valor: entero(a.unidades), ...cambio(a.unidades, b.unidades) },
			{ rotulo: 'Compradores', valor: entero(a.compradores), ...cambio(a.compradores, b.compradores) },
			{ rotulo: 'Cuentas nuevas', valor: entero(a.clientes_nuevos), ...cambio(a.clientes_nuevos, b.clientes_nuevos) },
			{
				rotulo: 'Cancelados',
				valor: `${entero(a.cancelados)}`,
				extra: `${(a.tasa_cancelacion * 100).toFixed(1)} % de los pedidos`,
				...cambio(a.cancelados, b.cancelados, true)
			},
			{ rotulo: 'Reembolsado', valor: quetzales(a.reembolsado), ...cambio(n(a.reembolsado), n(b.reembolsado), true) }
		];
	});

	let verVentas = $state<'ingresos' | 'pedidos' | 'unidades'>('ingresos');
	let puntosVentas = $derived(
		(ventas.datos?.serie ?? []).map((p) => ({
			rotulo: fechaCorta(p.periodo, resumen.datos?.periodo.agrupado ?? 'dia'),
			valor: verVentas === 'ingresos' ? n(p.ingresos) : verVentas === 'pedidos' ? p.pedidos : p.unidades,
			detalle:
				verVentas === 'ingresos'
					? `${entero(p.pedidos)} pedidos, ${entero(p.unidades)} unidades`
					: `${quetzales(p.ingresos)} cobrado`
		}))
	);
	let agrupadoTexto = $derived(
		{ dia: 'por dia', semana: 'por semana', mes: 'por mes' }[resumen.datos?.periodo.agrupado ?? 'dia']
	);

	let columnasPagos = $derived.by(() => {
		const filas = pagos.datos ?? [];
		const meses = [...new Set(filas.map((f) => f.mes))];
		return meses.map((m) => ({
			rotulo: mesCorto(m),
			partes: filas.filter((f) => f.mes === m).map((f) => ({ nombre: mayuscula(f.metodo), valor: n(f.ingresos) }))
		}));
	});
	let totalPorMetodo = $derived.by(() => {
		const total = new Map<string, number>();
		for (const f of pagos.datos ?? []) total.set(f.metodo, (total.get(f.metodo) ?? 0) + n(f.ingresos));
		return [...total.entries()].map(([nombre, valor]) => ({ nombre: mayuscula(nombre), valor, texto: quetzales(valor) }));
	});

	let totalBusquedas = $derived((busquedas.datos?.por_dia ?? []).reduce((s, p) => s + p.busquedas, 0));
	let totalSinResultado = $derived((busquedas.datos?.por_dia ?? []).reduce((s, p) => s + p.sin_resultados, 0));

	const NOMBRE_ESTADO: Record<string, string> = {
		comprado: 'Comprado',
		enviado: 'Enviado',
		entregado: 'Entregado',
		cancelado: 'Cancelado'
	};

	// ------------------------------------------------------------ exportar

	const SECCIONES: { id: string; nombre: string }[] = [
		{ id: 'resumen', nombre: 'Cifras del periodo' },
		{ id: 'ventas', nombre: 'Ventas en el tiempo' },
		{ id: 'embudo', nombre: 'De mirar a comprar' },
		{ id: 'categorias', nombre: 'Por categoria' },
		{ id: 'pagos', nombre: 'Cobrado por mes y metodo' },
		{ id: 'mapa', nombre: 'Cuando se compra' },
		{ id: 'vendedores', nombre: 'Vendedores' },
		{ id: 'productos', nombre: 'Productos' },
		{ id: 'departamentos', nombre: 'Departamentos' },
		{ id: 'busquedas', nombre: 'Busquedas' },
		{ id: 'cancelaciones', nombre: 'Cancelaciones' },
		{ id: 'pedidos', nombre: 'Registro de pedidos' }
	];
	let exportando = $state(false);
	let modal = $state(false);
	let formato = $state<'pdf' | 'excel' | 'correo'>('pdf');
	let formatoAdjunto = $state<'pdf' | 'excel'>('pdf');
	let elegidas = $state<string[]>(SECCIONES.map((s) => s.id));
	let correos = $state<string[]>([]);
	let correoNuevo = $state('');
	let avisoExportar = $state('');
	let exitoExportar = $state('');
	let dialogo = $state<HTMLDialogElement | null>(null);

	function abrirExportar() {
		avisoExportar = '';
		exitoExportar = '';
		modal = true;
		dialogo?.showModal();
	}
	function cerrarExportar() {
		modal = false;
		dialogo?.close();
	}
	function alternarSeccion(id: string) {
		elegidas = elegidas.includes(id) ? elegidas.filter((x) => x !== id) : [...elegidas, id];
	}
	function agregarCorreo() {
		const c = correoNuevo.trim().toLowerCase().replace(/[,;\s]+$/, '');
		if (!c) return;
		if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(c)) {
			avisoExportar = `${c} no parece un correo`;
			return;
		}
		if (!correos.includes(c)) correos = [...correos, c];
		correoNuevo = '';
		avisoExportar = '';
	}
	function alTeclearCorreo(e: KeyboardEvent) {
		if (e.key === 'Enter' || e.key === ',' || e.key === ';') {
			e.preventDefault();
			agregarCorreo();
		}
	}

	async function exportar() {
		avisoExportar = '';
		exitoExportar = '';
		if (elegidas.length === 0) {
			avisoExportar = 'Elige al menos una seccion';
			return;
		}
		exportando = true;
		try {
			if (formato === 'correo') {
				agregarCorreo();
				if (correos.length === 0) {
					avisoExportar = 'Pon al menos un correo';
					return;
				}
				const r = await pedir<{ correos: string[] }>(
					'/admin/dashboard/exportar/correo',
					conJson('POST', { correos, formato: formatoAdjunto, desde, hasta, secciones: elegidas })
				);
				if (r.estado === 401) return alExpirarSesion();
				if (!r.ok) {
					avisoExportar = mensajeUtil(r);
					return;
				}
				exitoExportar = `Enviado a ${correos.join(', ')}`;
				return;
			}
			const ruta = `${API}/admin/dashboard/exportar/${formato}?${consulta()}&secciones=${elegidas.join(',')}`;
			const r = await fetch(ruta, { credentials: 'include' });
			if (r.status === 401) return alExpirarSesion();
			if (!r.ok) {
				let mensaje = 'No se pudo armar el archivo';
				try {
					mensaje = mensajeUtil({ ...(await r.json()) });
				} catch {
					/* sin cuerpo */
				}
				avisoExportar = mensaje;
				return;
			}
			const archivo = await r.blob();
			const nombre =
				/filename="([^"]+)"/.exec(r.headers.get('content-disposition') ?? '')?.[1] ??
				`dashboard-mesh.${formato === 'pdf' ? 'pdf' : 'xlsx'}`;
			const enlace = document.createElement('a');
			enlace.href = URL.createObjectURL(archivo);
			enlace.download = nombre;
			enlace.click();
			setTimeout(() => URL.revokeObjectURL(enlace.href), 10_000);
			exitoExportar = `Listo, se descargo ${nombre}`;
		} catch {
			avisoExportar = 'No se pudo conectar. Intenta de nuevo.';
		} finally {
			exportando = false;
		}
	}
</script>

<section class="dashboard">
	<!-- Una barra: que dashboard ver, el periodo y exportar. El titulo y la
	     explicacion ya los pone la pestana del panel, no se repiten aqui. -->
	<div class="barra" bind:this={barra}>
		<div class="vistas" role="tablist" aria-label="Que dashboard ver">
			{#each VISTAS as v (v.id)}
				<button
					type="button"
					role="tab"
					aria-selected={vista === v.id}
					class:activa={vista === v.id}
					onclick={() => elegirVista(v.id)}
				>
					{v.nombre}
				</button>
			{/each}
		</div>
		<div class="herramientas">
			<div class="periodo" bind:this={cajaPeriodo}>
				<button
					type="button"
					class="elegir-periodo"
					aria-expanded={periodoAbierto}
					aria-controls="menu-periodo"
					onclick={() => (periodoAbierto = !periodoAbierto)}
				>
					<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
						<rect x="3" y="4.5" width="14" height="12" rx="2" />
						<path d="M3 8.5h14M7 3v3M13 3v3" stroke-linecap="round" />
					</svg>
					<span>{nombrePeriodo}</span>
					<svg class="flecha" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
						<path d="m6 8 4 4 4-4" stroke-linecap="round" stroke-linejoin="round" />
					</svg>
				</button>
				{#if periodoAbierto}
					<div id="menu-periodo" class="menu-periodo">
						<div class="rapidos">
							{#each RAPIDOS as r (r.id)}
								<button type="button" class:activo={rapido === r.id} onclick={() => elegirRapido(r.id)}>{r.nombre}</button>
							{/each}
						</div>
						<form
							class="fechas"
							onsubmit={(e) => {
								e.preventDefault();
								rapido = 'otro';
								periodoAbierto = false;
								void cargarTodo();
							}}
						>
							<label>Desde <input type="date" bind:value={desde} max={hasta} /></label>
							<label>Hasta <input type="date" bind:value={hasta} min={desde} max={hoy()} /></label>
							<button type="submit" class="aplicar">Ver estas fechas</button>
						</form>
						{#if resumen.datos}
							<p class="contra">
								Se compara con el {fechaLarga(resumen.datos.periodo.anterior_desde)} al
								{fechaLarga(resumen.datos.periodo.anterior_hasta)}
							</p>
						{/if}
					</div>
				{/if}
			</div>
			<button type="button" class="exportar" onclick={abrirExportar}>
				<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true">
					<path d="M10 3v10m0 0 4-4m-4 4-4-4M4 16h12" stroke-linecap="round" stroke-linejoin="round" />
				</svg>
				Exportar
			</button>
		</div>
	</div>
	{#if errorPeriodo}<p class="aviso" role="alert">{errorPeriodo}</p>{/if}

	{#if vista === 'ventas'}
		<!-- Las cifras -->
		{#if resumen.cargando}
			<div class="cifras">
				{#each Array(8) as _, i (i)}<div class="cifra esqueleto"></div>{/each}
			</div>
		{:else if resumen.error}
			<p class="aviso">{resumen.error}</p>
		{:else}
			<div class="cifras">
				{#each tarjetas as t (t.rotulo)}
					<div class="cifra" class:principal={t.principal}>
						<span class="rotulo">{t.rotulo}</span>
						<span class="valor">{t.valor}</span>
						<span class="delta {t.clase}">
							{#if t.clase === 'bien' || t.clase === 'mal'}
								<svg viewBox="0 0 12 12" aria-hidden="true">
									<path d={t.texto.startsWith('+') ? 'M6 2l4 5H2z' : 'M6 10 2 5h8z'} fill="currentColor" />
								</svg>
							{/if}
							{t.extra ?? t.texto}
						</span>
						{#if t.extra}<span class="delta-chica {t.clase}">{t.texto}</span>{/if}
					</div>
				{/each}
			</div>
		{/if}

		<div class="rejilla">
			<article class="tarjeta ancha">
				<header>
					<div>
						<h3>Ventas en el tiempo</h3>
						<p class="sub">{agrupadoTexto}, sin cancelados</p>
					</div>
					<div class="cambiar" role="group" aria-label="Que ver">
						<button type="button" class:activo={verVentas === 'ingresos'} onclick={() => (verVentas = 'ingresos')}>Cobrado</button>
						<button type="button" class:activo={verVentas === 'pedidos'} onclick={() => (verVentas = 'pedidos')}>Pedidos</button>
						<button type="button" class:activo={verVentas === 'unidades'} onclick={() => (verVentas = 'unidades')}>Unidades</button>
					</div>
				</header>
				{#if ventas.cargando}<div class="cargando"></div>
				{:else if ventas.error}<p class="aviso">{ventas.error}</p>
				{:else}
					<Linea puntos={puntosVentas} texto={verVentas === 'ingresos' ? quetzalesCortos : entero} />
				{/if}
			</article>

			<article class="tarjeta">
				<header>
					<div>
						<h3>Por categoria</h3>
						<p class="sub">Lo vendido en quetzales</p>
					</div>
				</header>
				{#if categorias.cargando}<div class="cargando"></div>
				{:else if categorias.error}<p class="aviso">{categorias.error}</p>
				{:else}
					<Dona
						partes={(categorias.datos ?? []).slice(0, 6).map((c) => ({ nombre: c.categoria, valor: n(c.ingresos), texto: quetzales(c.ingresos) }))}
						centro={{ cifra: String(categorias.datos?.length ?? 0), rotulo: 'categorias' }}
						vacio="Nada vendido en este periodo"
					/>
				{/if}
			</article>

			<article class="tarjeta">
				<header>
					<div>
						<h3>Por metodo de pago</h3>
						<p class="sub">Lo cobrado con cada uno</p>
					</div>
				</header>
				{#if pagos.cargando}<div class="cargando"></div>
				{:else if pagos.error}<p class="aviso">{pagos.error}</p>
				{:else}
					<Dona partes={totalPorMetodo} vacio="Sin pagos en este periodo" />
				{/if}
			</article>

			<article class="tarjeta ancha">
				<header>
					<div>
						<h3>Cobrado por mes</h3>
						<p class="sub">Cada mes partido por metodo de pago</p>
					</div>
				</header>
				{#if pagos.cargando}<div class="cargando"></div>
				{:else if pagos.error}<p class="aviso">{pagos.error}</p>
				{:else}
					<Apiladas columnas={columnasPagos} texto={quetzalesCortos} />
				{/if}
			</article>
		</div>
	{:else if vista === 'clientes'}
		<div class="rejilla">
			<article class="tarjeta">
				<header>
					<div>
						<h3>De mirar a comprar</h3>
						<p class="sub">Personas en cada paso</p>
					</div>
				</header>
				{#if embudo.cargando}<div class="cargando"></div>
				{:else if embudo.error}<p class="aviso">{embudo.error}</p>
				{:else if embudo.datos}
					<Embudo
						etapas={[
							{ nombre: 'vieron un producto', valor: embudo.datos.vieron },
							{ nombre: 'agregaron al carrito', valor: embudo.datos.agregaron },
							{ nombre: 'compraron', valor: embudo.datos.compraron },
							{ nombre: 'pedidos cancelados', valor: embudo.datos.cancelaron }
						]}
					/>
					{#if embudo.datos.sin_eventos}
						<p class="nota">Las vistas y los carritos no cargaron ahora. Lo de las compras si.</p>
					{:else if embudo.datos.eventos_desde && embudo.datos.eventos_desde > desde}
						<p class="nota">
							Las vistas y los carritos se cuentan desde el {fechaLarga(embudo.datos.eventos_desde)}. Antes hubo compras
							sin vistas registradas, por eso compraron puede ser mas que vieron.
						</p>
					{/if}
				{/if}
			</article>

			<article class="tarjeta">
				<header>
					<div>
						<h3>A donde se manda</h3>
						<p class="sub">Por departamento de entrega</p>
					</div>
				</header>
				{#if departamentos.cargando}<div class="cargando"></div>
				{:else if departamentos.error}<p class="aviso">{departamentos.error}</p>
				{:else}
					<Barras
						compacta
						color="var(--g6)"
						filas={(departamentos.datos ?? []).slice(0, 8).map((d) => ({
							id: d.departamento,
							nombre: d.departamento,
							valor: n(d.ingresos),
							texto: quetzales(d.ingresos),
							detalle: `${entero(d.pedidos)} pedidos`
						}))}
						vacio="Sin entregas en este periodo"
					/>
				{/if}
			</article>

			<article class="tarjeta ancha">
				<header>
					<div>
						<h3>Cuando compra la gente</h3>
						<p class="sub">Pedidos por dia y hora, en hora de Guatemala</p>
					</div>
				</header>
				{#if mapa.cargando}<div class="cargando"></div>
				{:else if mapa.error}<p class="aviso">{mapa.error}</p>
				{:else}
					<MapaCalor
						celdas={(mapa.datos ?? []).map((c) => ({ dia: c.dia_semana, hora: c.hora, valor: c.pedidos, detalle: quetzales(c.ingresos) }))}
					/>
				{/if}
			</article>
		</div>
	{:else if vista === 'vendedores'}
		<div class="rejilla">
			<article class="tarjeta">
				<header>
					<div>
						<h3>Vendedores que mas venden</h3>
						<p class="sub">Lo vendido y su nota de 1 a 5</p>
					</div>
				</header>
				{#if vendedores.cargando}<div class="cargando"></div>
				{:else if vendedores.error}<p class="aviso">{vendedores.error}</p>
				{:else}
					<Barras
						compacta
						color="var(--g3)"
						filas={(vendedores.datos ?? []).map((v) => ({
							id: String(v.id_usuario),
							nombre: v.vendedor,
							valor: n(v.ingresos),
							texto: quetzales(v.ingresos),
							detalle: `${entero(v.pedidos)} pedidos${v.nota_promedio != null ? `, nota ${v.nota_promedio.toFixed(1)}` : ''}`
						}))}
						vacio="Nadie vendio en este periodo"
					/>
				{/if}
			</article>

			<article class="tarjeta">
				<header>
					<div>
						<h3>Productos que mas dejan</h3>
						<p class="sub">Lo vendido de cada uno</p>
					</div>
				</header>
				{#if productos.cargando}<div class="cargando"></div>
				{:else if productos.error}<p class="aviso">{productos.error}</p>
				{:else}
					<Barras
						compacta
						color="var(--g1)"
						filas={(productos.datos ?? []).map((p) => ({
							id: String(p.id_producto),
							nombre: p.nombre,
							valor: n(p.ingresos),
							texto: quetzales(p.ingresos),
							detalle: `${entero(p.unidades)} unidades`,
							enlace: `/producto/${p.id_producto}`
						}))}
						vacio="Nada vendido en este periodo"
					/>
				{/if}
			</article>
		</div>
	{:else if vista === 'busquedas'}
		<div class="rejilla">
			<article class="tarjeta ancha">
				<header>
					<div>
						<h3>Personas que buscaron</h3>
						<p class="sub">
							{#if busquedas.datos}
								{entero(totalBusquedas)} en el periodo, {entero(totalSinResultado)} no encontraron nada
							{:else}
								Y cuantas no encontraron nada
							{/if}
						</p>
					</div>
				</header>
				{#if busquedas.cargando}<div class="cargando"></div>
				{:else if busquedas.error}<p class="aviso">{busquedas.error}</p>
				{:else if busquedas.datos}
					<Linea
						alto={190}
						color="var(--g5)"
						puntos={busquedas.datos.por_dia.map((p) => ({
							rotulo: fechaCorta(p.periodo, resumen.datos?.periodo.agrupado ?? 'dia'),
							valor: p.busquedas,
							detalle: `${p.sin_resultados} sin resultados`
						}))}
						vacio="Nadie busco en este periodo"
					/>
				{/if}
			</article>
			{#if busquedas.datos}
				<article class="tarjeta">
					<header>
						<div>
							<h3>Lo mas buscado</h3>
							<p class="sub">En personas distintas</p>
						</div>
					</header>
					<Barras
						compacta
						color="var(--g5)"
						filas={busquedas.datos.mas_buscadas.map((b) => ({ id: b.termino, nombre: b.termino, valor: b.personas, texto: `${b.personas}` }))}
						vacio="Nadie busco en este periodo"
					/>
				</article>
				<article class="tarjeta">
					<header>
						<div>
							<h3>Se busca y no se encuentra</h3>
							<p class="sub">Lo que la tienda podria sumar</p>
						</div>
					</header>
					<Barras
						compacta
						color="var(--g4)"
						filas={busquedas.datos.sin_resultado.map((b) => ({ id: b.termino, nombre: b.termino, valor: b.personas, texto: `${b.personas}` }))}
						vacio="Todo lo que se busco se encontro"
					/>
				</article>
			{/if}
		</div>
	{:else if vista === 'cancelaciones'}
		<div class="rejilla">
			{#if cancelaciones.cargando}
				<article class="tarjeta ancha"><div class="cargando"></div></article>
			{:else if cancelaciones.error}
				<article class="tarjeta ancha"><p class="aviso">{cancelaciones.error}</p></article>
			{:else if cancelaciones.datos}
				<article class="tarjeta">
					<header>
						<div>
							<h3>Cuanto tardan en cancelar</h3>
							<p class="sub">Desde que compraron</p>
						</div>
					</header>
					<Barras
						compacta
						color="var(--g4)"
						filas={cancelaciones.datos.por_tiempo.map((t) => ({ id: t.tramo, nombre: t.tramo, valor: t.pedidos, texto: `${t.pedidos}` }))}
						vacio="Nada cancelado en este periodo"
					/>
				</article>
				<article class="tarjeta">
					<header>
						<div>
							<h3>Con que habian pagado</h3>
							<p class="sub">Pedidos cancelados por metodo</p>
						</div>
					</header>
					<Dona
						partes={cancelaciones.datos.por_metodo.map((m) => ({ nombre: mayuscula(m.metodo), valor: m.pedidos, texto: `${m.pedidos}` }))}
						vacio="Nada cancelado en este periodo"
					/>
				</article>
				<article class="tarjeta ancha">
					<header>
						<div>
							<h3>De que categoria eran</h3>
							<p class="sub">Pedidos cancelados que llevaban algo de cada una</p>
						</div>
					</header>
					<Barras
						compacta
						color="var(--g2)"
						columnas={2}
						filas={cancelaciones.datos.por_categoria.map((c) => ({
							id: c.categoria,
							nombre: c.categoria,
							valor: c.pedidos,
							texto: `${c.pedidos}`,
							detalle: `${entero(c.unidades)} unidades`
						}))}
						vacio="Nada cancelado en este periodo"
					/>
				</article>
			{/if}
		</div>
	{:else if vista === 'pedidos'}
		<article class="tarjeta">
			<header>
				<div>
					<h3>Registro de pedidos</h3>
					<p class="sub">{pedidos.datos ? `${entero(pedidos.datos.total)} pedidos en el periodo` : 'Los pedidos del periodo'}</p>
				</div>
			</header>
			<div class="filtros">
				<select
					bind:value={filtroEstado}
					onchange={() => {
						paginaPedidos = 1;
						void cargarPedidos();
					}}
					aria-label="Estado"
				>
					<option value="">Todos los estados</option>
					<option value="comprado">Comprado</option>
					<option value="enviado">Enviado</option>
					<option value="entregado">Entregado</option>
					<option value="cancelado">Cancelado</option>
				</select>
				<select
					bind:value={filtroMetodo}
					onchange={() => {
						paginaPedidos = 1;
						void cargarPedidos();
					}}
					aria-label="Metodo de pago"
				>
					<option value="">Todos los metodos</option>
					<option value="tarjeta">Tarjeta</option>
					<option value="transferencia">Transferencia</option>
					<option value="efectivo contra entrega">Efectivo contra entrega</option>
				</select>
				<input
					type="search"
					placeholder="Cliente, correo o numero"
					bind:value={filtroTexto}
					oninput={alEscribirTexto}
					aria-label="Buscar pedido"
				/>
			</div>
			{#if avisoPedido}<p class="hecho" role="status">{avisoPedido}</p>{/if}
			{#if errorPedido}<p class="aviso" role="alert">{errorPedido}</p>{/if}
			{#if pedidos.error}<p class="aviso">{pedidos.error}</p>
			{:else if pedidos.datos && pedidos.datos.pedidos.length === 0}
				<p class="nota">Ningun pedido con esos filtros.</p>
			{:else if pedidos.datos}
				<div class="tabla" class:esperando={pedidos.cargando}>
					<table>
						<thead>
							<tr>
								<th>Pedido</th>
								<th>Fecha</th>
								<th>Cliente</th>
								<th>Estado</th>
								<th class="ocultable">Pago</th>
								<th class="ocultable">Departamento</th>
								<th class="num">Unidades</th>
								<th class="num">Total</th>
								<th>Gestion</th>
							</tr>
						</thead>
						<tbody>
							{#each pedidos.datos.pedidos as p (p.id_pedido)}
								<tr>
									<td>{p.id_pedido}</td>
									<td class="apagado">{p.fecha}</td>
									<td>
										<span class="cliente">{p.cliente}</span>
										<span class="apagado correo">{p.correo}</span>
									</td>
									<td>
										<span class="estado e-{p.estado}">{NOMBRE_ESTADO[p.estado] ?? p.estado}</span>
										{#if p.por_la_tienda && p.estado === 'cancelado'}
											<span class="apagado por-tienda" title={p.motivo ?? ''}>por la tienda</span>
										{/if}
									</td>
									<td class="apagado ocultable">{p.metodo ? mayuscula(p.metodo) : 'Sin pago'}{p.estado_pago && p.estado_pago !== 'pagado' ? `, ${p.estado_pago}` : ''}</td>
									<td class="apagado ocultable">{p.departamento ?? ''}</td>
									<td class="num">{p.unidades}</td>
									<td class="num">{quetzales(p.total)}</td>
									<td class="gestion">
										{#if confirmandoCancelar === p.id_pedido}
											<div class="confirmar">
												<input
													type="text"
													maxlength="300"
													placeholder="Motivo, si quieres"
													bind:value={motivoCancelar}
													aria-label="Motivo de la cancelacion"
												/>
												<button
													type="button"
													class="peligro"
													disabled={pedidoEnCurso === p.id_pedido}
													onclick={() => gestionarPedido(p, 'cancelar')}
												>
													{pedidoEnCurso === p.id_pedido ? 'Cancelando...' : 'Si, cancelar'}
												</button>
												<button type="button" onclick={() => (confirmandoCancelar = null)}>No</button>
											</div>
										{:else if p.estado !== 'cancelado'}
											{#if p.estado === 'comprado'}
												<button type="button" disabled={pedidoEnCurso === p.id_pedido} onclick={() => gestionarPedido(p, 'enviado')}>
													Enviado
												</button>
											{/if}
											{#if p.estado === 'comprado' || p.estado === 'enviado'}
												<button type="button" disabled={pedidoEnCurso === p.id_pedido} onclick={() => gestionarPedido(p, 'entregado')}>
													Entregado
												</button>
											{/if}
											<button
												type="button"
												class="suave-rojo"
												disabled={pedidoEnCurso === p.id_pedido}
												onclick={() => {
													confirmandoCancelar = p.id_pedido;
													motivoCancelar = '';
												}}
											>
												Cancelar
											</button>
										{/if}
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
				{#if pedidos.datos.total_paginas > 1}
					<nav class="paginas" aria-label="Paginas de pedidos">
						<button
							type="button"
							disabled={paginaPedidos <= 1}
							onclick={() => {
								paginaPedidos -= 1;
								void cargarPedidos();
							}}>Anterior</button
						>
						<span>Pagina {pedidos.datos.pagina} de {pedidos.datos.total_paginas}</span>
						<button
							type="button"
							disabled={paginaPedidos >= pedidos.datos.total_paginas}
							onclick={() => {
								paginaPedidos += 1;
								void cargarPedidos();
							}}>Siguiente</button
						>
					</nav>
				{/if}
			{:else}
				<div class="cargando"></div>
			{/if}
		</article>
	{/if}

	{#if resumen.datos && vista === 'ventas'}
		<p class="hoy">
			Hoy hay {entero(resumen.datos.hoy.productos_activos)} productos a la venta, {entero(resumen.datos.hoy.vendedores_activos)}
			vendedores con ofertas activas, {entero(resumen.datos.hoy.cuentas)} cuentas y {entero(resumen.datos.hoy.carritos_abiertos)}
			carritos abiertos.
		</p>
	{/if}
</section>

<dialog bind:this={dialogo} class="modal" onclose={() => (modal = false)} aria-labelledby="titulo-exportar">
	{#if modal}
		<form
			method="dialog"
			onsubmit={(e) => {
				e.preventDefault();
				void exportar();
			}}
		>
			<header>
				<h3 id="titulo-exportar">Exportar el dashboard</h3>
				<button type="button" class="cerrar" onclick={cerrarExportar} aria-label="Cerrar">
					<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M5 5l10 10M15 5 5 15" stroke-linecap="round" /></svg>
				</button>
			</header>
			<p class="gris">Del {fechaLarga(desde)} al {fechaLarga(hasta)}</p>

			<fieldset>
				<legend>Como</legend>
				<div class="formatos">
					<label class:activo={formato === 'pdf'}><input type="radio" bind:group={formato} value="pdf" /> PDF con graficas</label>
					<label class:activo={formato === 'excel'}><input type="radio" bind:group={formato} value="excel" /> Excel</label>
					<label class:activo={formato === 'correo'}><input type="radio" bind:group={formato} value="correo" /> Por correo</label>
				</div>
			</fieldset>

			{#if formato === 'correo'}
				<fieldset>
					<legend>A quien</legend>
					<div class="correos">
						{#each correos as c (c)}
							<span class="ficha">
								{c}
								<button type="button" aria-label="Quitar {c}" onclick={() => (correos = correos.filter((x) => x !== c))}>
									<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M6 6l8 8M14 6l-8 8" stroke-linecap="round" /></svg>
								</button>
							</span>
						{/each}
						<input
							type="email"
							placeholder={correos.length ? 'Otro correo' : 'correo@ejemplo.com'}
							bind:value={correoNuevo}
							onkeydown={alTeclearCorreo}
							onblur={agregarCorreo}
							aria-label="Correo"
						/>
					</div>
					<div class="formatos chicos">
						<label class:activo={formatoAdjunto === 'pdf'}><input type="radio" bind:group={formatoAdjunto} value="pdf" /> Adjuntar PDF</label>
						<label class:activo={formatoAdjunto === 'excel'}><input type="radio" bind:group={formatoAdjunto} value="excel" /> Adjuntar Excel</label>
					</div>
				</fieldset>
			{/if}

			<fieldset>
				<legend>
					Que secciones
					<button type="button" class="enlace" onclick={() => (elegidas = SECCIONES.map((s) => s.id))}>Todas</button>
					<button type="button" class="enlace" onclick={() => (elegidas = [])}>Ninguna</button>
				</legend>
				<div class="secciones">
					{#each SECCIONES as s (s.id)}
						<label>
							<input type="checkbox" checked={elegidas.includes(s.id)} onchange={() => alternarSeccion(s.id)} />
							{s.nombre}
						</label>
					{/each}
				</div>
			</fieldset>

			{#if avisoExportar}<p class="aviso" role="alert">{avisoExportar}</p>{/if}
			{#if exitoExportar}<p class="exito" role="status">{exitoExportar}</p>{/if}

			<footer>
				<button type="button" class="secundario" onclick={cerrarExportar}>Cerrar</button>
				<button type="submit" class="primario" disabled={exportando}>
					{exportando ? 'Preparando...' : formato === 'correo' ? 'Enviar' : 'Descargar'}
				</button>
			</footer>
		</form>
	{/if}
</dialog>

<style>
	.dashboard {
		display: flex;
		flex-direction: column;
		gap: var(--e4);
	}

	/* ---------- la barra de arriba ---------- */

	.barra {
		position: sticky;
		top: 116px;
		z-index: 5;
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		align-items: center;
		gap: 10px 16px;
		padding: 8px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.vistas {
		display: flex;
		flex-wrap: wrap;
		gap: 2px;
	}

	.vistas button {
		padding: 8px 14px;
		font: inherit;
		font-size: var(--f-sm);
		color: var(--texto);
		background: none;
		border: none;
		border-radius: var(--r);
		cursor: pointer;
		white-space: nowrap;
		transition:
			background var(--t),
			color var(--t);
	}

	.vistas button:hover {
		background: var(--panel);
		color: var(--tinta);
	}

	.vistas button.activa {
		font-weight: 600;
		color: var(--sobre-indigo);
		background: var(--indigo);
	}

	.herramientas {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.periodo {
		position: relative;
	}

	.elegir-periodo,
	.exportar {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		height: 38px;
		padding: 0 14px;
		font: inherit;
		font-size: var(--f-sm);
		border-radius: var(--r);
		cursor: pointer;
		white-space: nowrap;
	}

	.elegir-periodo {
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
	}

	.elegir-periodo:hover,
	.elegir-periodo[aria-expanded='true'] {
		border-color: var(--indigo);
	}

	.elegir-periodo svg {
		width: 17px;
		height: 17px;
		color: var(--gris);
	}

	.elegir-periodo .flecha {
		width: 15px;
		height: 15px;
		transition: transform var(--t);
	}

	.elegir-periodo[aria-expanded='true'] .flecha {
		transform: rotate(180deg);
	}

	.exportar {
		color: var(--sobre-indigo);
		background: var(--indigo);
		border: 1px solid var(--indigo);
	}

	.exportar svg {
		width: 17px;
		height: 17px;
	}

	.menu-periodo {
		position: absolute;
		top: calc(100% + 6px);
		right: 0;
		z-index: 10;
		display: flex;
		flex-direction: column;
		gap: 12px;
		width: min(340px, calc(100vw - 32px));
		padding: 14px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		box-shadow: var(--sombra);
	}

	.rapidos {
		display: grid;
		grid-template-columns: repeat(3, minmax(0, 1fr));
		gap: 6px;
	}

	.rapidos button,
	.cambiar button {
		padding: 7px 10px;
		font: inherit;
		font-size: var(--f-sm);
		color: var(--texto);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	.rapidos button.activo,
	.cambiar button.activo {
		color: var(--sobre-indigo);
		background: var(--indigo);
		border-color: var(--indigo);
	}

	.fechas {
		display: grid;
		grid-template-columns: repeat(2, minmax(0, 1fr));
		gap: 8px;
		padding-top: 12px;
		border-top: 1px solid var(--linea);
	}

	.fechas label {
		display: flex;
		flex-direction: column;
		gap: 4px;
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.fechas input,
	.filtros select,
	.filtros input {
		min-width: 0;
		height: 36px;
		padding: 0 9px;
		font: inherit;
		font-size: var(--f-sm);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.aplicar {
		grid-column: 1 / -1;
		height: 36px;
		font: inherit;
		font-size: var(--f-sm);
		color: var(--sobre-indigo);
		background: var(--indigo);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
		cursor: pointer;
	}

	.contra {
		margin: 0;
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.cambiar {
		display: inline-flex;
		flex-wrap: wrap;
		gap: 4px;
	}

	/* ---------- las cifras ---------- */

	.cifras {
		display: grid;
		grid-template-columns: repeat(4, minmax(0, 1fr));
		gap: var(--e3);
	}

	.cifra {
		display: grid;
		grid-template-rows: auto auto 1fr auto;
		gap: 4px;
		min-height: 108px;
		padding: 14px 16px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.cifra.principal {
		background: var(--indigo-cl);
		border-color: color-mix(in srgb, var(--indigo) 35%, var(--linea));
	}

	.cifra .rotulo {
		font-size: var(--f-xs);
		font-weight: 600;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		color: var(--gris);
	}

	.cifra .valor {
		font-size: 1.5rem;
		font-weight: 700;
		line-height: 1.2;
		color: var(--tinta);
		font-variant-numeric: tabular-nums;
		overflow-wrap: anywhere;
	}

	.delta {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		align-self: end;
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.delta-chica {
		font-size: var(--f-xs);
		color: var(--gris);
	}

	.delta svg {
		flex-shrink: 0;
		width: 10px;
		height: 10px;
	}

	.delta.bien {
		color: var(--g3);
	}

	.delta.mal {
		color: var(--g4);
	}

	.esqueleto {
		animation: latido 1.2s ease-in-out infinite;
	}

	@keyframes latido {
		50% {
			opacity: 0.5;
		}
	}

	.hoy {
		margin: 0;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	/* ---------- las tarjetas ---------- */

	.rejilla {
		display: grid;
		grid-template-columns: repeat(2, minmax(0, 1fr));
		gap: var(--e4);
	}

	.tarjeta {
		display: flex;
		flex-direction: column;
		gap: var(--e4);
		min-width: 0;
		padding: 18px 20px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.tarjeta.ancha {
		grid-column: 1 / -1;
	}

	.tarjeta > header {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		align-items: flex-start;
		gap: 10px;
		min-height: 44px;
	}

	h3 {
		margin: 0;
		font-size: var(--f-md);
		font-weight: 600;
		color: var(--tinta);
	}

	.sub {
		margin: 3px 0 0;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.cargando {
		height: 200px;
		background: var(--panel);
		border-radius: var(--r);
		animation: latido 1.2s ease-in-out infinite;
	}

	.aviso {
		margin: 0;
		padding: 10px 12px;
		font-size: var(--f-sm);
		color: var(--rojo);
		background: var(--rojo-cl);
		border-radius: var(--r);
	}

	.exito {
		margin: 0;
		padding: 10px 12px;
		font-size: var(--f-sm);
		color: var(--descuento-tinta);
		background: var(--descuento-fondo);
		border-radius: var(--r);
	}

	.nota {
		margin: 0;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	/* ---------- el registro ---------- */

	.filtros {
		display: grid;
		grid-template-columns: minmax(150px, 200px) minmax(170px, 230px) minmax(0, 1fr);
		gap: 8px;
	}

	.tabla {
		overflow-x: auto;
		transition: opacity var(--t);
	}

	.tabla.esperando {
		opacity: 0.55;
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: var(--f-sm);
	}

	th {
		padding: 8px 10px;
		text-align: left;
		font-size: var(--f-xs);
		font-weight: 600;
		color: var(--gris);
		border-bottom: 1px solid var(--linea);
		white-space: nowrap;
	}

	td {
		padding: 9px 10px;
		color: var(--tinta);
		border-bottom: 1px solid var(--linea);
		vertical-align: middle;
	}

	.apagado {
		color: var(--gris);
	}

	tbody tr:hover {
		background: var(--off);
	}

	.num {
		text-align: right;
		font-variant-numeric: tabular-nums;
		white-space: nowrap;
	}

	.cliente {
		display: block;
	}

	.correo {
		display: block;
		font-size: var(--f-xs);
	}

	.estado {
		display: inline-block;
		padding: 2px 9px;
		font-size: var(--f-xs);
		border: 1px solid var(--linea);
		border-radius: 999px;
		white-space: nowrap;
	}

	.por-tienda {
		display: block;
		margin-top: 2px;
		font-size: var(--f-xs);
	}

	/* ---------- gestion de cada pedido (migracion 051) ---------- */
	.hecho {
		margin: 0;
		padding: 10px 12px;
		font-size: var(--f-sm);
		color: var(--g3);
		background: color-mix(in srgb, var(--g3) 12%, transparent);
		border-radius: var(--r);
	}

	.gestion {
		white-space: nowrap;
	}

	.gestion button {
		padding: 4px 10px;
		margin-right: 4px;
		font: inherit;
		font-size: var(--f-xs);
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: 999px;
		cursor: pointer;
	}

	.gestion button:hover:not(:disabled) {
		border-color: var(--indigo);
		color: var(--indigo);
	}

	.gestion button:disabled {
		opacity: 0.5;
		cursor: default;
	}

	.gestion .suave-rojo {
		color: var(--rojo);
		border-color: color-mix(in srgb, var(--rojo) 45%, transparent);
	}

	.gestion .suave-rojo:hover:not(:disabled) {
		color: var(--rojo);
		border-color: var(--rojo);
	}

	.gestion .peligro {
		color: #fff;
		background: var(--rojo);
		border-color: var(--rojo);
	}

	.gestion .peligro:hover:not(:disabled) {
		color: #fff;
		border-color: var(--rojo);
	}

	.confirmar {
		display: flex;
		align-items: center;
		gap: 6px;
	}

	.confirmar input {
		width: 130px;
		padding: 4px 8px;
		font: inherit;
		font-size: var(--f-xs);
		color: var(--tinta);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.e-cancelado {
		color: var(--rojo);
		border-color: color-mix(in srgb, var(--rojo) 45%, transparent);
	}

	.e-entregado,
	.e-comprado {
		color: var(--g3);
		border-color: color-mix(in srgb, var(--g3) 45%, transparent);
	}

	.paginas {
		display: flex;
		justify-content: center;
		align-items: center;
		gap: 14px;
		font-size: var(--f-sm);
		color: var(--texto);
	}

	.paginas button {
		padding: 6px 12px;
		font: inherit;
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	.paginas button:disabled {
		opacity: 0.45;
		cursor: default;
	}

	/* ---------- exportar ---------- */

	/* margin auto: el reset de margenes de la pagina tambien le quitaba al
	   dialogo el centrado que trae el navegador. */
	.modal {
		margin: auto;
		width: min(560px, calc(100vw - 32px));
		max-height: calc(100vh - 48px);
		padding: 22px 24px;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
		box-shadow: var(--sombra);
	}

	.modal::backdrop {
		background: rgba(10, 12, 20, 0.45);
	}

	.modal form {
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	.modal header {
		display: flex;
		justify-content: space-between;
		align-items: center;
	}

	.modal .gris {
		margin: -6px 0 0;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.cerrar {
		width: 32px;
		height: 32px;
		padding: 6px;
		color: var(--gris);
		background: none;
		border: none;
		cursor: pointer;
	}

	fieldset {
		margin: 0;
		padding: 0;
		border: none;
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	legend {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 8px;
		font-size: var(--f-sm);
		font-weight: 600;
		color: var(--texto);
	}

	.enlace {
		padding: 0;
		font: inherit;
		font-weight: 400;
		color: var(--indigo);
		background: none;
		border: none;
		cursor: pointer;
	}

	.formatos {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
	}

	.formatos label {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 8px 12px;
		font-size: var(--f-sm);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	.formatos label.activo {
		border-color: var(--indigo);
		background: var(--indigo-cl);
	}

	.formatos.chicos label {
		padding: 6px 10px;
	}

	.correos {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		padding: 6px;
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.correos input {
		flex: 1;
		min-width: 180px;
		padding: 5px 6px;
		font: inherit;
		font-size: var(--f-sm);
		color: var(--tinta);
		background: none;
		border: none;
		outline: none;
	}

	.ficha {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		padding: 3px 4px 3px 10px;
		font-size: var(--f-sm);
		background: var(--indigo-cl);
		border-radius: 999px;
	}

	.ficha button {
		width: 20px;
		height: 20px;
		padding: 3px;
		color: var(--gris);
		background: none;
		border: none;
		cursor: pointer;
	}

	.secciones {
		display: grid;
		grid-template-columns: repeat(2, minmax(0, 1fr));
		gap: 6px 14px;
	}

	.secciones label {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		font-size: var(--f-sm);
		cursor: pointer;
	}

	.modal footer {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
	}

	.primario {
		padding: 9px 16px;
		font: inherit;
		color: var(--sobre-indigo);
		background: var(--indigo);
		border: 1px solid var(--indigo);
		border-radius: var(--r);
		cursor: pointer;
	}

	.primario:disabled {
		opacity: 0.6;
		cursor: wait;
	}

	.secundario {
		padding: 9px 16px;
		font: inherit;
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	/* ---------- pantallas chicas ---------- */

	@media (max-width: 1024px) {
		.barra {
			position: static;
		}
	}

	@media (max-width: 860px) {
		.rejilla {
			grid-template-columns: minmax(0, 1fr);
		}

		.cifras {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}

		.filtros {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}

		.filtros input {
			grid-column: 1 / -1;
		}

		.ocultable {
			display: none;
		}
	}

	@media (max-width: 620px) {
		/* Las pestanas del dashboard se deslizan de lado en vez de apilarse. */
		.vistas {
			flex-wrap: nowrap;
			width: 100%;
			overflow-x: auto;
			scrollbar-width: none;
		}

		.herramientas {
			width: 100%;
		}

		.periodo {
			flex: 1;
		}

		.elegir-periodo {
			width: 100%;
		}

		.menu-periodo {
			left: 0;
			right: auto;
		}

		.cifra {
			min-height: 96px;
			padding: 12px;
		}

		.cifra .valor {
			font-size: 1.2rem;
		}

		.tarjeta {
			padding: 14px;
		}

		.secciones {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
