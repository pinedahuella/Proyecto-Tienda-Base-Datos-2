/**
 * Cuerpo esperado en PATCH /vendedor/reglas-descuento/:id. Todos los campos
 * son opcionales, pero hay que mandar al menos uno -- incluye `activa`, asi
 * que pausar/reactivar la regla es la misma ruta que editarle los numeros.
 */
export interface EditarReglaDescuentoPeticion {
  umbral_unidades?: number;
  ventana_minutos?: number;
  es_venta_relampago?: boolean;
  duracion_segundos?: number;
  porcentaje_descuento?: number;
  activa?: boolean;
}
