/**
 * Los tipos de los dos reportes del panel de admin (Entrega 2):
 *
 *   GET /admin/reportes/reservaciones   los pedidos abiertos y sin pagar
 *   GET /admin/reportes/ventas          el resumen de lo vendido, cobrado y devuelto
 *
 * Todo sale de PostgreSQL (`pedido`, `pedido_producto`, `pago` y sus
 * catalogos de estado). Es solo lectura: ningun reporte escribe nada.
 *
 * El dinero viaja como STRING con dos decimales (`"1850.00"`), no como
 * number: son `numeric(12,2)` de Postgres y compararlos/sumarlos como float
 * de JavaScript mete el redondeo binario. El frontend los muestra tal cual
 * o los pasa por `Number()` bajo su responsabilidad.
 */

// ---------------------------------------------------------------------
// GET /admin/reportes/reservaciones
// ---------------------------------------------------------------------

/** Quien abrio la reservacion. */
export interface ClienteReserva {
  id_usuario: number;
  usuario: string;
  correo_electronico: string;
  /** Nombre y apellido juntos; solo el nombre si no hay apellido. */
  nombre: string;
}

/**
 * Un pedido en estado `pendiente`: se abrio y todavia no se pago. NO aparta
 * stock (un pedido pendiente nunca descuenta ni reserva unidades -- ver
 * `migrations/007_flujo_pedido.sql`), pero el precio de cada linea ya quedo
 * congelado al agregarla, asi que `total` es firme.
 */
export interface Reservacion {
  id_pedido: number;
  fecha_creacion: Date;
  cliente: ClienteReserva;
  cantidad_lineas: number;
  unidades: number;
  /** Suma de `precio_congelado * cantidad` de sus lineas. */
  total: string;
  ciudad: string;
  departamento: string;
}

export interface ReporteReservaciones {
  /** Cuando se genero el reporte (ISO 8601). */
  generado: string;
  resumen: {
    cantidad: number;
    unidades: number;
    total: string;
  };
  reservaciones: Reservacion[];
}

// ---------------------------------------------------------------------
// GET /admin/reportes/ventas
// ---------------------------------------------------------------------

/** Cuantos pedidos hay en un estado y cuanto suman sus lineas. */
export interface LineaPorEstadoPedido {
  estado: string;
  cantidad: number;
  /** Suma de las lineas de los pedidos en este estado. */
  monto: string;
}

/** Cuantos pagos hay en un estado (o por un metodo) y cuanto suman. */
export interface LineaPorEstadoPago {
  estado: string;
  cantidad: number;
  monto: string;
}

export interface LineaPorMetodoPago {
  metodo: string;
  cantidad: number;
  monto: string;
}

export interface ReporteVentas {
  generado: string;
  /** Las 5 filas del catalogo `estado_pedido`, aunque alguna valga 0. */
  pedidos_por_estado: LineaPorEstadoPedido[];
  /** Las 4 filas del catalogo `estado_pago`. */
  pagos_por_estado: LineaPorEstadoPago[];
  /** Las 3 filas del catalogo `metodo_pago`. */
  pagos_por_metodo: LineaPorMetodoPago[];
  totales: {
    pedidos: number;
    /** Unidades de pedidos en `comprado` / `enviado` / `entregado`. */
    unidades_vendidas: number;
    /** Suma de `pago.monto` con el pago en estado `pagado`. */
    ingresos: string;
    /** Suma de `pago.monto` con el pago en estado `reembolsado`. */
    reembolsado: string;
    /** `ingresos` entre el numero de pagos `pagado`; `"0.00"` si no hay. */
    ticket_promedio: string;
  };
}
