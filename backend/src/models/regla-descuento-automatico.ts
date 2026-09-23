/**
 * Una regla de descuento automatico de una oferta, tal como vive en
 * PostgreSQL (tabla `regla_descuento_automatico`): si ClickHouse detecta
 * `umbral_unidades` vendidas en `ventana_minutos`, se activa un descuento
 * (`es_venta_relampago: false`) o una venta relampago completa
 * (`es_venta_relampago: true`), por `duracion_segundos`, con
 * `porcentaje_descuento`.
 *
 * Esto es solo la configuracion (el CRUD) -- el disparo real (leer
 * ClickHouse y decidir si activar) todavia no existe.
 *
 * id_regla_descuento_automatico e id_oferta van como string: son bigint, y
 * el driver pg los devuelve como texto para no perder precision (igual que
 * en Oferta).
 */
export interface ReglaDescuentoAutomatico {
  id_regla_descuento_automatico: string;
  id_oferta: string;
  umbral_unidades: number;
  ventana_minutos: number;
  es_venta_relampago: boolean;
  duracion_segundos: number;
  /** numeric(5,2) de Postgres: string, para no perder precision por el redondeo binario. */
  porcentaje_descuento: string;
  activa: boolean;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}
