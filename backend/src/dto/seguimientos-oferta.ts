/**
 * Cuerpo de POST /comprador/seguimientos. Dos formas, segun `tipo`:
 *
 *   { "tipo": "busqueda", "texto": "laptop 16 gb", "precio_maximo": "5000.00" }
 *   { "tipo": "baja_precio", "id_producto": 7, "id_producto_variante": 1,
 *     "solo_tienda": true, "precio_referencia": "6000.00" }
 *
 * `precio_maximo`, `solo_tienda` y `precio_referencia` son opcionales. Sin
 * `precio_referencia`, el backend toma el precio final mas bajo de ese
 * momento (de la tienda si `solo_tienda`). Las reglas estan en
 * helpers/validaciones-seguimiento.ts.
 */
export interface CrearSeguimientoPeticion {
  tipo?: unknown;
  texto?: unknown;
  precio_maximo?: unknown;
  id_producto?: unknown;
  id_producto_variante?: unknown;
  solo_tienda?: unknown;
  precio_referencia?: unknown;
}

/** Query de GET /comprador/seguimientos: `estado` = `activos` o `cumplidos` (sin el, todos). */
export interface ListarSeguimientosQuery {
  estado?: string;
}

/** Query de GET /comprador/seguimientos/avisos: `no_leidos=true` para ver solo esos. */
export interface ListarAvisosQuery {
  no_leidos?: string;
}

/** Cuerpo de PATCH /comprador/seguimientos/avisos/:id. */
export interface MarcarAvisoPeticion {
  leido?: unknown;
}

/** Un seguimiento, tal como lo ve su dueno. Ids y montos como texto (bigint, numeric). */
export interface SeguimientoOferta {
  id_seguimiento: string;
  tipo: string;
  texto: string | null;
  precio_maximo: string | null;
  id_producto: string | null;
  id_producto_variante: string | null;
  nombre_producto: string | null;
  nombre_variante: string | null;
  precio_referencia: string | null;
  solo_tienda: boolean;
  fecha_creacion: Date;
  /** `null` = sigue esperando. */
  fecha_cumplido: Date | null;
  /** El aviso que genero al cumplirse, o `null`. */
  id_aviso: string | null;
}

/** Un aviso: que seguimiento se cumplio, con que oferta, y como esta esa oferta ahora. */
export interface AvisoSeguimientoOferta {
  id_aviso: string;
  leido: boolean;
  fecha_aviso: Date;
  fecha_leida: Date | null;
  /** El precio final cuando aviso. */
  precio_final_aviso: string;
  seguimiento: {
    id_seguimiento: string;
    tipo: string;
    texto: string | null;
    precio_maximo: string | null;
    precio_referencia: string | null;
    solo_tienda: boolean;
  };
  oferta: {
    id_oferta: string;
    id_producto: string;
    id_producto_variante: string;
    nombre_producto: string | null;
    nombre_variante: string | null;
    vendedor_usuario: string;
    /** Como esta AHORA (puede haber cambiado desde el aviso). */
    precio_final: string;
    stock: number;
    estado: string;
  };
}

/** Respuesta de GET /comprador/seguimientos/avisos. */
export interface AvisosSeguimiento {
  avisos: AvisoSeguimientoOferta[];
  total_no_leidos: number;
}
