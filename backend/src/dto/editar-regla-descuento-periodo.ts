/**
 * Cuerpo esperado en PATCH /vendedor/reglas-descuento-periodos/:id. Todos
 * los campos son opcionales, pero hay que mandar al menos uno -- incluye
 * `activa`, asi que pausar/reactivar la regla es la misma ruta que editarle
 * las fechas o el descuento.
 */
export interface EditarReglaDescuentoPeriodoPeticion {
  dia_inicio?: number;
  dia_fin?: number;
  mes_inicio?: number;
  mes_fin?: number;
  anio?: number;
  es_venta_relampago?: boolean;
  porcentaje_descuento?: number;
  activa?: boolean;
}
