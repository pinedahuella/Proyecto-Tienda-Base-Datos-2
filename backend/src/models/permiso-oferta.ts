/**
 * El ACL de la aplicacion, por oferta (migracion 049). El dueno de una oferta
 * le da a otra cuenta uno o mas de estos permisos; lo que no esta en la lista
 * se niega. Ver `docs/SEGURIDAD.md`, El ACL de la aplicacion.
 *
 * - `ver`: mirar la oferta. Cualquier entrada vigente lo da: no se puede
 *   editar lo que no se ve.
 * - `editar`: cambiar el precio y ajustar la existencia. NO el estado: retirar
 *   o reactivar la oferta sigue siendo solo del dueno.
 * - `descuento`: poner y quitar el descuento.
 */
export const PERMISOS_OFERTA = ['ver', 'editar', 'descuento'] as const;

export type PermisoOfertaNombre = (typeof PERMISOS_OFERTA)[number];

/** Lo que deja `PermisoOfertaGuard` en `request.permisoOferta` si deja pasar. */
export interface PermisoOfertaResuelto {
  id_oferta: number;
  /** El dueno de la oferta: las rutas compartidas actuan a su nombre. */
  id_dueno: string;
  permiso: PermisoOfertaNombre;
}

/** Una cuenta, como sale en las respuestas del ACL. */
export interface CuentaPermiso {
  id_usuario: string;
  usuario: string;
  nombre: string;
  apellido: string | null;
  correo: string;
}

/** Una entrada del ACL de una oferta, vista por su dueno. */
export interface EntradaPermisoOferta {
  id_permiso_oferta: string;
  permiso: PermisoOfertaNombre;
  receptor: CuentaPermiso;
  otorgado_por: string;
  fecha_otorgado: Date;
  /** null = no vence. */
  fecha_vencimiento: Date | null;
  vigente: boolean;
}

/** Una fila del registro del ACL, vista por el dueno. */
export interface RegistroPermisoOferta {
  fecha: Date;
  accion: string;
  permiso: string | null;
  actor: string | null;
  receptor: string | null;
  detalle: Record<string, unknown>;
}

/** Una oferta compartida conmigo. */
export interface OfertaCompartida {
  id_oferta: string;
  id_producto: string;
  id_variante: string;
  producto: string | null;
  variante: string | null;
  imagen: string | null;
  precio: string;
  porcentaje_descuento: number | null;
  precio_final: string;
  stock: number;
  estado: string;
  es_inventario_limitado: boolean;
  fecha_vencimiento_descuento: Date | null;
  dueno: CuentaPermiso;
  /** Mis permisos vigentes sobre esta oferta, con su vencimiento. */
  permisos: {
    permiso: PermisoOfertaNombre;
    fecha_vencimiento: string | null;
  }[];
}
