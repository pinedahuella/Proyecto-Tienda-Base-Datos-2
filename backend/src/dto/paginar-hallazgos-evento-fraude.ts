import {
  HallazgoEventoFraude,
  TipoHallazgoEvento,
} from '../models/hallazgo-evento-fraude';

/**
 * Query params esperados en GET /admin/fraude/alertas-eventos.
 *
 * Mismo criterio que `PaginarAnillosFraudeQuery`
 * (`dto/paginar-anillos-fraude.ts`): cada filtro es opcional e
 * independiente. `estado` reusa `ESTADOS_ALERTA_FRAUDE_VALIDOS`
 * (`dto/paginar-alertas-fraude.ts`) via `validarFiltroEstadoAlerta` --
 * mismo catalogo, sin redefinirlo aqui.
 */
export interface PaginarHallazgosEventoFraudeQuery {
  pagina?: string;
  limite?: string;
  estado?: string;
  tipo?: string;
}

/** Respuesta de GET /admin/fraude/alertas-eventos. */
export interface HallazgosEventoFraudePaginados {
  hallazgos: HallazgoEventoFraude[];
  pagina: number;
  limite: number;
  total_hallazgos: number;
  total_paginas: number;
}

export const TIPOS_HALLAZGO_EVENTO_VALIDOS: TipoHallazgoEvento[] = [
  'vistas_infladas',
  'compras_en_rafaga',
  'ip_multicuenta_compras',
  'devoluciones_seriales',
  'granja_de_registros',
];
