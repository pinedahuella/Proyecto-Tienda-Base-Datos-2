import { Direccion } from '../models/direccion';
import { DireccionHistorial } from '../models/direccion-historial';

/**
 * Respuesta de GET /direccion-usuario/:id: la version vigente de la
 * direccion, mas todo su historial de cambios (mas reciente primero).
 */
export interface DireccionConHistorial {
  direccion: Direccion;
  historial: DireccionHistorial[];
}
