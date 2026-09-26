/**
 * Cuerpo esperado en PATCH /admin/fraude/alertas-eventos/:id -- marcar un
 * hallazgo de F1-F6 como revisado o descartado.
 *
 * Solo se admite viniendo de `pendiente` -- mismo criterio que
 * `MarcarAnilloFraudeBody`/`MarcarAlertaFraudeBody`: un hallazgo ya
 * revisado o descartado no se puede volver a mover desde esta ruta (409 si
 * se intenta).
 */
export interface MarcarHallazgoEventoFraudeBody {
  estado?: string;
}
