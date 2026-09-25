/**
 * Query params de `GET /productos/vistos-recientemente`. `sesion` es
 * opcional -- mismo criterio que `GET /buscador/productos`: sin ella, solo
 * cuenta lo visto con la cuenta (si hay sesion iniciada). `dias_historial`
 * y `limite` son opcionales, con los mismos valores por defecto que el
 * resto de rutas de eventos.
 */
export interface ConsultarVistosRecientementeQuery {
  sesion?: string;
  dias_historial?: string;
  limite?: string;
}
