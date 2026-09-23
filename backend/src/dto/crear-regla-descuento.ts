/** Cuerpo esperado en POST /vendedor/reglas-descuento. */
export interface CrearReglaDescuentoPeticion {
  id_oferta: number;
  umbral_unidades: number;
  ventana_minutos: number;
  es_venta_relampago: boolean;
  duracion_segundos: number;
  porcentaje_descuento: number;
}
