export type NivelCasoFraude =
  'informativo' | 'revisar' | 'prioritario' | 'casi_confirmado';

export const NIVELES_CASO_FRAUDE_VALIDOS: NivelCasoFraude[] = [
  'informativo',
  'revisar',
  'prioritario',
  'casi_confirmado',
];

/** Los mismos tres de `alerta_fraude`/`hallazgo_evento_fraude`, mas
 * `confirmada` -- el unico que habilita sanciones (seccion 5 del
 * documento original). */
export type EstadoCasoFraude =
  'pendiente' | 'revisada' | 'descartada' | 'confirmada';

export const ESTADOS_CASO_FRAUDE_VALIDOS: EstadoCasoFraude[] = [
  'pendiente',
  'revisada',
  'descartada',
  'confirmada',
];

/** Solo estos tres se piden por `PATCH` -- `pendiente` es de donde se
 * sale, nunca a donde se llega desde esta ruta. */
export const ESTADOS_CASO_FRAUDE_DESTINO: EstadoCasoFraude[] = [
  'revisada',
  'descartada',
  'confirmada',
];

/** Fila resumida de `GET /admin/fraude/casos` (la lista). */
export interface CasoFraudeResumen {
  id_caso_fraude: number;
  nivel: NivelCasoFraude;
  puntaje: number;
  estado: EstadoCasoFraude;
  reglas_cumplidas: string[];
  cantidad_evidencias: number;
  cantidad_cuentas: number;
  ultima_evidencia: Date;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}

/** Una cuenta del caso, ya resuelta contra `usuarios`. */
export interface CuentaCasoFraude {
  id_usuario: number;
  usuario: string;
  es_nucleo: boolean;
}

/** Un hallazgo de evidencia, ya resuelto contra su senal (`senal_fraude`);
 * `fuente` sale de la fuente del tipo de la senal. */
export interface EvidenciaCasoFraude {
  id_evidencia_caso_fraude: number;
  fuente: 'grafo' | 'eventos' | 'login' | 'elastic' | 'postgres';
  tipo: string;
  clave: string;
  puntos: number;
  metricas: Record<string, unknown>;
  ultima_evidencia: Date;
}

/** `GET /admin/fraude/casos/:id` -- el resumen mas las cuentas y la
 * evidencia completa. */
export interface CasoFraudeDetalle extends CasoFraudeResumen {
  motivo: string | null;
  cuentas: CuentaCasoFraude[];
  evidencia: EvidenciaCasoFraude[];
}
