/**
 * Un rechazo de una propuesta de producto por parte de la tienda o un
 * admin, tal como vive en PostgreSQL (tabla `rechazo_producto`, ver
 * `elementos Generales/plan pendiente/propuesta-de-productos.md`).
 *
 * Espejo de `RechazoOferta`. Es una tabla de solo inserción: si una
 * propuesta se rechaza, el vendedor la re-envía y se rechaza de nuevo,
 * quedan varias filas -- una por cada rechazo, cada una con su
 * `fecha_rechazo`.
 *
 * `id_rechazo_producto` va como string: es `bigserial` y el driver `pg`
 * entrega los `bigint` como texto para no perder precisión.
 */
export interface RechazoProducto {
  id_rechazo_producto: string;
  razon_rechazo: string;
  fecha_rechazo: Date;
}
