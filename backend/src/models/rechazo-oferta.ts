/**
 * Un rechazo de una oferta por parte de la tienda, tal como vive en
 * PostgreSQL (tabla `rechazo_oferta`, ver
 * `elementos Generales/plan pendiente/aceptacion-de-ofertas.md`).
 *
 * Es una tabla de solo inserción: si una oferta se rechaza, el vendedor la
 * corrige (vuelve a `pendiente`) y se rechaza de nuevo, quedan varias
 * filas -- una por cada rechazo, cada una con su `fecha_rechazo`.
 *
 * `id_rechazo_oferta` va como string: es `bigserial` y el driver `pg`
 * entrega los `bigint` como texto para no perder precisión.
 */
export interface RechazoOferta {
  id_rechazo_oferta: string;
  razon_rechazo: string;
  fecha_rechazo: Date;
}
