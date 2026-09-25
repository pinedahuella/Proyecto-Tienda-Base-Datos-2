/**
 * Query params compartidos por `GET /admin/eventos/embudo` y
 * `GET /admin/eventos/busquedas-sin-respuesta`: una sola ventana de dias
 * hacia atras y cuantos resultados traer. El resto de los umbrales de cada
 * consulta (sesiones minimas, conversion maxima, etc.) quedan fijos en el
 * servicio, mismos valores ya probados en
 * `clickhouse/consultas/parametros.txt`.
 */
export interface ConsultarTendenciaVentanaQuery {
  dias_ventana?: string;
  limite?: string;
}
