/**
 * Cuerpo esperado en POST /vendedor/reglas-descuento-periodos. `mes_inicio`/
 * `mes_fin`/`anio` son opcionales -- su ausencia es lo que amplia la
 * repeticion en cascada, ver el modelo `ReglaDescuentoPeriodo`.
 */
export interface CrearReglaDescuentoPeriodoPeticion {
  id_oferta: number;
  dia_inicio: number;
  dia_fin: number;
  mes_inicio?: number;
  mes_fin?: number;
  anio?: number;
  es_venta_relampago: boolean;
  porcentaje_descuento: number;
}
