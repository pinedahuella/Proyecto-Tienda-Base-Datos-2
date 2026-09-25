/**
 * Una regla de descuento por PERIODO (calendario) de una oferta, tal como
 * vive en PostgreSQL (tabla `regla_descuento_periodo`): a diferencia de
 * `regla_descuento_automatico` (dispara por umbral de ventas en una
 * ventana), esta dispara por fecha. El rango se arma con `dia_inicio`,
 * `dia_fin`, `mes_inicio`, `mes_fin` y `anio`; la ausencia de un campo
 * amplia la repeticion en cascada:
 *   - con `anio`       -> ocurre una sola vez, en ese anio exacto.
 *   - sin `anio`       -> se repite cada anio, mismo dia/mes de inicio y fin.
 *   - sin mes (y por lo tanto sin `anio`) -> se repite en todos los meses de
 *     todos los anios, usando solo el rango de dia.
 *
 * Esto es solo la configuracion (el CRUD) -- el disparador real (revisar la
 * fecha de hoy contra las reglas activas y decidir si activar) todavia no
 * existe.
 *
 * id_regla_descuento_periodo e id_oferta van como string: son bigint, y el
 * driver pg los devuelve como texto para no perder precision (igual que en
 * Oferta y en ReglaDescuentoAutomatico).
 */
export interface ReglaDescuentoPeriodo {
  id_regla_descuento_periodo: string;
  id_oferta: string;
  dia_inicio: number;
  dia_fin: number;
  mes_inicio: number | null;
  mes_fin: number | null;
  anio: number | null;
  es_venta_relampago: boolean;
  /** numeric(5,2) de Postgres: string, para no perder precision por el redondeo binario. */
  porcentaje_descuento: string;
  activa: boolean;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}
