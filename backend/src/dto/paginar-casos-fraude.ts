import { CasoFraudeResumen } from '../models/fraude/caso-fraude';

/** Query params de GET /admin/fraude/casos. */
export interface PaginarCasosFraudeQuery {
  pagina?: string;
  limite?: string;
  nivel?: string;
  estado?: string;
}

/** `PATCH /admin/fraude/casos/:id`. */
export interface ActualizarCasoFraudePeticion {
  estado?: unknown;
  motivo?: unknown;
}

export interface CasosFraudePaginados {
  casos: CasoFraudeResumen[];
  pagina: number;
  limite: number;
  total_casos: number;
  total_paginas: number;
}
