/**
 * Cuerpo esperado en PATCH /admin/fraude/alertas-login/:id -- marcar una
 * alerta (de cualquiera de las 9 senales de `alerta_fraude`, Redis o
 * Elasticsearch, no hay distincion) como revisada o descartada.
 *
 * Solo se admite viniendo de `pendiente`: una alerta ya revisada o
 * descartada no se puede volver a mover desde esta ruta (409 si se
 * intenta) -- ver `validarNuevoEstadoAlerta` en `helpers/validaciones-fraude.ts`.
 */
export interface MarcarAlertaFraudeBody {
  estado?: string;
}
