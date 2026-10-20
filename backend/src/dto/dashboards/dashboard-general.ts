/**
 * Las respuestas del dashboard general del admin (`GET /admin/dashboard/...`,
 * `DashboardGeneralController`). Cada seccion es una ruta aparte y todas
 * reciben el mismo periodo (`?desde=AAAA-MM-DD&hasta=AAAA-MM-DD`), asi la
 * pagina las pide a la vez y una base caida solo apaga su tarjeta.
 *
 * Los montos van como texto con dos decimales (numeric de PostgreSQL), igual
 * que en los reportes (`dto/reporte` y `models/reporte`): un number de JS
 * pierde centavos con sumas grandes.
 */

/** El periodo que se uso, ya validado, y el de antes del mismo largo. */
export interface PeriodoDashboard {
  desde: string;
  hasta: string;
  dias: number;
  /** El periodo anterior del mismo largo, contra el que se comparan las cifras. */
  anterior_desde: string;
  anterior_hasta: string;
  /** Como se agrupan las series: por dia hasta 62 dias, por semana hasta 400, si no por mes. */
  agrupado: 'dia' | 'semana' | 'mes';
}

/** Las cifras de arriba, del periodo y del anterior. */
export interface CifrasDashboard {
  ingresos: string;
  pedidos: number;
  ticket_promedio: string;
  unidades: number;
  compradores: number;
  clientes_nuevos: number;
  cancelados: number;
  /** De 0 a 1: cancelados sobre todos los pedidos que llegaron a pagarse. */
  tasa_cancelacion: number;
  reembolsado: string;
  vendedores_con_ventas: number;
}

export interface ResumenDashboard {
  periodo: PeriodoDashboard;
  actual: CifrasDashboard;
  anterior: CifrasDashboard;
  /** Lo que no depende del periodo: lo que hay hoy. */
  hoy: {
    productos_activos: number;
    vendedores_activos: number;
    cuentas: number;
    carritos_abiertos: number;
  };
}

export interface PuntoVentas {
  /** El primer dia del dia, semana o mes, AAAA-MM-DD. */
  periodo: string;
  ingresos: string;
  pedidos: number;
  unidades: number;
}

export interface VentasDashboard {
  periodo: PeriodoDashboard;
  serie: PuntoVentas[];
}

/** De mirar a comprar. Las dos primeras salen de ClickHouse y pueden faltar. */
export interface EmbudoDashboard {
  periodo: PeriodoDashboard;
  vieron: number | null;
  agregaron: number | null;
  compraron: number;
  cancelaron: number;
  /** Si ClickHouse no respondio y las dos primeras etapas no estan. */
  sin_eventos: boolean;
  /**
   * El primer dia con vistas registradas (AAAA-MM-DD), o null si no hay. Antes
   * de ese dia hay compras sin vistas, y el embudo se lee raro: la pagina lo
   * dice.
   */
  eventos_desde: string | null;
}

export interface FilaCategoria {
  id_categoria: number | null;
  categoria: string;
  ingresos: string;
  unidades: number;
  pedidos: number;
}

export interface FilaPagoMensual {
  mes: string;
  metodo: string;
  ingresos: string;
  pedidos: number;
}

export interface CeldaMapaCalor {
  /** 1 lunes ... 7 domingo. */
  dia_semana: number;
  hora: number;
  pedidos: number;
  ingresos: string;
}

export interface FilaVendedor {
  id_usuario: number;
  vendedor: string;
  ingresos: string;
  unidades: number;
  pedidos: number;
  nota_promedio: number | null;
}

export interface FilaProducto {
  id_producto: number;
  nombre: string;
  ingresos: string;
  unidades: number;
  pedidos: number;
}

export interface FilaDepartamento {
  departamento: string;
  pedidos: number;
  ingresos: string;
}

export interface BusquedasDashboard {
  periodo: PeriodoDashboard;
  por_dia: { periodo: string; busquedas: number; sin_resultados: number }[];
  mas_buscadas: { termino: string; personas: number }[];
  sin_resultado: { termino: string; personas: number }[];
}

export interface CancelacionesDashboard {
  periodo: PeriodoDashboard;
  /** Cuanto paso entre comprar y cancelar. */
  por_tiempo: { tramo: string; pedidos: number }[];
  por_categoria: { categoria: string; pedidos: number; unidades: number }[];
  por_metodo: { metodo: string; pedidos: number; monto: string }[];
}

export interface FilaPedidoDashboard {
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
}

export interface PedidosDashboard {
  pedidos: FilaPedidoDashboard[];
  total: number;
  pagina: number;
  total_paginas: number;
}

/** Las secciones que se pueden exportar, en el orden del dashboard. */
export const SECCIONES_DASHBOARD = [
  'resumen',
  'ventas',
  'embudo',
  'categorias',
  'pagos',
  'mapa',
  'vendedores',
  'productos',
  'departamentos',
  'busquedas',
  'cancelaciones',
  'pedidos',
] as const;

export type SeccionDashboard = (typeof SECCIONES_DASHBOARD)[number];

/** Todo el dashboard junto, para exportarlo. Una seccion que fallo queda en null. */
export interface DashboardCompleto {
  periodo: PeriodoDashboard;
  resumen: ResumenDashboard | null;
  ventas: VentasDashboard | null;
  embudo: EmbudoDashboard | null;
  categorias: FilaCategoria[] | null;
  pagos: FilaPagoMensual[] | null;
  mapa: CeldaMapaCalor[] | null;
  vendedores: FilaVendedor[] | null;
  productos: FilaProducto[] | null;
  departamentos: FilaDepartamento[] | null;
  busquedas: BusquedasDashboard | null;
  cancelaciones: CancelacionesDashboard | null;
  pedidos: FilaPedidoDashboard[] | null;
}

/** POST /admin/dashboard/exportar/correo */
export interface PeticionCorreoDashboard {
  correos: string[];
  formato: 'pdf' | 'excel';
  desde?: string;
  hasta?: string;
  secciones?: string[];
}
