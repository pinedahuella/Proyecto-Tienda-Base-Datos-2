import { AlertaFraude, EstadoAlertaFraude } from '../models/alerta-fraude';

/**
 * Query params esperados en GET /admin/fraude/alertas-login.
 *
 * Mismo criterio que `PaginarOfertasQuery` (`dto/paginar-ofertas.ts`): un
 * unico filtro opcional.
 *
 *   - `estado=pendiente|revisada|descartada` -> solo esas.
 *   - sin el parametro -> todas, sin filtrar por estado.
 */
export interface PaginarAlertasFraudeQuery {
  pagina?: string;
  limite?: string;
  estado?: string;
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
