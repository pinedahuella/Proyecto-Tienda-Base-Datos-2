/**
 * Cuerpo esperado en PATCH /admin/fraude/anillos-persistidos/:id -- marcar
 * un anillo (`mutuo`/`ciclo`/`reiterado`) como revisado o descartado.
 *
 * Solo se admite viniendo de `pendiente` -- mismo criterio que
 * `MarcarAlertaFraudeBody` (`dto/marcar-alerta-fraude.ts`): un anillo ya
 * revisado o descartado no se puede volver a mover desde esta ruta (409 si
 * se intenta).
 */
export interface MarcarAnilloFraudeBody {
  estado?: string;
}
