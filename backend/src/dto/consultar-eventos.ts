/**
 * Query params comunes a las seis rutas `GET /admin/eventos/*`: una ventana
 * de dias hacia atras, un limite de filas, y el orden. Nunca agrupan ni
 * calculan tendencias -- son las filas CRUDAS tal como quedaron en
 * ClickHouse, para explorar, no para un panel de "mas vendidos".
 */
export interface ConsultarEventosQuery {
  dias?: string;
  limite?: string;
  orden?: string;
}
