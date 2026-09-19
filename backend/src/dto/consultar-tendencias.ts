/**
 * Query params comunes a las seis rutas `GET /admin/eventos/*`: una ventana
 * de dias hacia atras, cuantos resultados del ranking traer, y la
 * direccion (positivo = los primeros M, mas alto; negativo = los ultimos
 * M, mas bajo).
 */
export interface ConsultarTendenciasQuery {
  dias?: string;
  limite?: string;
  direccion?: string;
}
