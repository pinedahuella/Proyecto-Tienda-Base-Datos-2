import { EstadoAlertaFraude } from '../models/alerta-fraude';
import { AnilloFraude, TipoAnilloFraude } from '../models/anillo-fraude';

/**
 * Query params esperados en GET /admin/fraude/alertas-resenas.
 *
 * Mismo criterio que `PaginarAlertasFraudeQuery` (`dto/paginar-alertas-fraude.ts`):
 * cada filtro es opcional e independiente.
 *
 *   - `estado=pendiente|revisada|descartada` -> solo esos.
 *   - `tipo=` uno de `TIPOS_ANILLO_FRAUDE_VALIDOS` -> solo ese tipo de caso.
 *   - sin alguno de los dos -> no se filtra por ese campo.
 */
export interface PaginarAnillosFraudeQuery {
  pagina?: string;
  limite?: string;
  estado?: string;
  tipo?: string;
}

/** Respuesta de GET /admin/fraude/alertas-resenas. */
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

// `anillo_en_el_tiempo` (B.4) queda fuera: no se persiste como fila propia
// (ver models/anillo-fraude.ts), asi que nunca hay un caso real de ese tipo
// que filtrar.
export const TIPOS_ANILLO_FRAUDE_VALIDOS: TipoAnilloFraude[] = [
  'mutuo',
  'ciclo',
  'reiterado',
  'cadena_abierta',
  'satelites',
  'persistente',
  'favor_devuelto',
  'coordinados',
  'reputacion_expres',
  'resenas_repetidas',
  'anillo_de_texto',
  'notas_incoherentes_cuenta',
  'notas_incoherentes_producto',
  'notas_incoherentes_vendedor',
  'resenas_parecidas_producto',
  'resenas_parecidas_vendedor',
  'resena_positiva_cancelada',
  'resenas_negativas_canceladas_vendedor',
];
