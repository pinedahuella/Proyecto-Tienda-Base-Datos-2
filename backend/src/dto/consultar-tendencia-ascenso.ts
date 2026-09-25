/**
 * Query params de `GET /admin/eventos/tendencias`: dos ventanas de dias
 * (la reciente contra la base con la que se compara) y cuantos resultados
 * traer. Los umbrales de minimo de vistas y de crecimiento NO son
 * configurables por query param -- quedan fijos en el servicio, mismos
 * valores ya probados en `clickhouse/consultas/parametros.txt`.
 */
export interface ConsultarTendenciaAscensoQuery {
  dias_recientes?: string;
  dias_base?: string;
  limite?: string;
}
