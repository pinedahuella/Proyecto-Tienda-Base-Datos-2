import {
  AlertaFraude,
  EstadoAlertaFraude,
  TipoAlertaFraude,
} from '../models/alerta-fraude';

/**
 * Query params esperados en GET /admin/fraude/alertas-login.
 *
 * Mismo criterio que `PaginarOfertasQuery` (`dto/paginar-ofertas.ts`): cada
 * filtro es opcional e independiente.
 *
 *   - `estado=pendiente|revisada|descartada` -> solo esas.
 *   - `tipo=fuerza_bruta_ip|fuerza_bruta_cuenta|multi_cuenta_ip|ip_rotacion_cuenta|
 *     toma_cuenta|viaje_imposible|fuerza_bruta_cuenta_lenta|multi_cuenta_ip_lenta|
 *     ip_rotacion_cuenta_lenta` -> solo esa senal. Con nueve tipos mezclados
 *     en un solo listado hace falta poder acotar.
 *   - sin alguno de los dos -> no se filtra por ese campo.
 */
export interface PaginarAlertasFraudeQuery {
  pagina?: string;
  limite?: string;
  estado?: string;
  tipo?: string;
}

/** Respuesta de GET /admin/fraude/alertas-login. */
export interface AlertasFraudePaginadas {
  alertas: AlertaFraude[];
  pagina: number;
  limite: number;
  total_alertas: number;
  total_paginas: number;
}

export const ESTADOS_ALERTA_FRAUDE_VALIDOS: EstadoAlertaFraude[] = [
  'pendiente',
  'revisada',
  'descartada',
];

export const TIPOS_ALERTA_FRAUDE_VALIDOS: TipoAlertaFraude[] = [
  'fuerza_bruta_ip',
  'fuerza_bruta_cuenta',
  'multi_cuenta_ip',
  'ip_rotacion_cuenta',
  'toma_cuenta',
  'viaje_imposible',
  'fuerza_bruta_cuenta_lenta',
  'multi_cuenta_ip_lenta',
  'ip_rotacion_cuenta_lenta',
];
