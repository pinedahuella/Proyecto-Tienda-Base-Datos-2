/**
 * Cuerpo esperado en PATCH /vendedor/ofertas/:id/revision.
 *
 * Solo la cuenta de la tienda o un admin. La oferta tiene que estar en
 * estado `pendiente`. Aprobar la pasa a `activa` (y le pone
 * `fecha_aprobacion`); rechazar la pasa a `rechazada` y guarda una fila en
 * `rechazo_oferta` con el motivo -- ver
 * `elementos Generales/plan pendiente/aceptacion-de-ofertas.md`.
 */
export interface RevisarOfertaPeticion {
  /** `"aprobar"` o `"rechazar"`. */
  decision: string;
  /** Obligatorio y no vacio solo cuando `decision` es `"rechazar"`. */
  razon?: string;
}
