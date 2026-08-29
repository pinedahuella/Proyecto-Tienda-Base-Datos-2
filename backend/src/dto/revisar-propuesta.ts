/**
 * Cuerpo esperado en PATCH /vendedor/productos/:id/revision.
 *
 * Solo la cuenta de la tienda o un admin. La propuesta tiene que estar en
 * estado `en_revision`. Aprobar la pasa a `activo` (y le pone
 * `fecha_aprobacion` + `id_usuario_aprobo` + el `comentario` opcional);
 * rechazar la pasa a `rechazado` y guarda una fila en `rechazo_producto`
 * con el motivo -- ver
 * `elementos Generales/plan pendiente/propuesta-de-productos.md`.
 */
export interface RevisarPropuestaPeticion {
  /** `"aprobar"` o `"rechazar"`. */
  decision: string;
  /** Obligatorio y no vacio solo cuando `decision` es `"rechazar"`. */
  razon?: string;
  /** Opcional, solo se guarda cuando `decision` es `"aprobar"`. */
  comentario?: string;
}
