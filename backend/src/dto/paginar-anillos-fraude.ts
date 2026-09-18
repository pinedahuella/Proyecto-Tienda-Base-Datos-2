import { EstadoAlertaFraude } from '../models/alerta-fraude';
import { AnilloFraude, TipoAnilloFraude } from '../models/anillo-fraude';

/**
 * Query params esperados en GET /admin/fraude/anillos-persistidos.
 *
 * Mismo criterio que `PaginarAlertasFraudeQuery` (`dto/paginar-alertas-fraude.ts`):
 * cada filtro es opcional e independiente.
 *
 *   - `estado=pendiente|revisada|descartada` -> solo esos.
 *   - `tipo=mutuo|ciclo|reiterado` -> solo ese tipo de anillo.
 *   - sin alguno de los dos -> no se filtra por ese campo.
 */
export interface PaginarAnillosFraudeQuery {
  pagina?: string;
  limite?: string;
  estado?: string;
  tipo?: string;
}

/** Respuesta de GET /admin/fraude/anillos-persistidos. */
export interface AnillosFraudePaginados {
  anillos: AnilloFraude[];
  pagina: number;
  limite: number;
  total_anillos: number;
  total_paginas: number;
}

export const ESTADOS_ANILLO_FRAUDE_VALIDOS: EstadoAlertaFraude[] = [
  'pendiente',
  'revisada',
  'descartada',
];

export const TIPOS_ANILLO_FRAUDE_VALIDOS: TipoAnilloFraude[] = [
  'mutuo',
  'ciclo',
  'reiterado',
];
