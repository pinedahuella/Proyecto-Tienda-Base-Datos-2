import {
  MotivoFalloAutenticacion,
  ResultadoAutenticacion,
  TipoEventoAutenticacion,
} from '../models/evento-autenticacion';

/**
 * Query params esperados en GET /admin/fraude/eventos-login -- el explorador
 * de logs crudos, contra Elasticsearch (`mesh_eventos_autenticacion`), no
 * contra Mongo. Mismo criterio que `PaginarAlertasFraudeQuery`: cada filtro
 * es opcional e independiente, y todos son exactos (`term`), nunca
 * aproximados -- ip/identificador/huella_cliente son identificadores, no
 * texto para buscar de forma difusa.
 *
 * `incluir_usuario=true` agrega un lookup a Postgres para traer el `usuario`
 * de cada `id_usuario` (ver `FraudeLoginExploracionService`); por defecto
 * viene sin ese lookup.
 */
export interface PaginarEventosAutenticacionQuery {
  pagina?: string;
  limite?: string;
  tipo?: string;
  resultado?: string;
  motivo?: string;
  id_usuario?: string;
  identificador?: string;
  ip?: string;
  huella_cliente?: string;
  geo_pais?: string;
  fecha_desde?: string;
  fecha_hasta?: string;
  incluir_usuario?: string;
}

/** Un evento de autenticacion, forma de API -- ver `EventoAutenticacion` (el modelo de Mongo/Elastic). */
export interface EventoAutenticacionAdmin {
  id: string;
  tipo: TipoEventoAutenticacion;
  resultado: ResultadoAutenticacion;
  motivo: MotivoFalloAutenticacion | null;
  id_usuario: string | null;
  /**
   * Solo viene poblado (incluso en `null`) cuando la peticion pidio
   * `incluir_usuario=true`; sin la bandera, el campo no se manda.
   */
  cuenta_involucrada?: { id_usuario: string; usuario: string } | null;
  identificador_intentado: string | null;
  ip: string | null;
  user_agent: string | null;
  huella_cliente: string | null;
  geo: {
    lat: number;
    lon: number;
    pais: string | null;
    ciudad: string | null;
  } | null;
  fecha: string;
}

/** Respuesta de GET /admin/fraude/eventos-login. */
export interface EventosAutenticacionPaginados {
  eventos: EventoAutenticacionAdmin[];
  pagina: number;
  limite: number;
  total_eventos: number;
  total_paginas: number;
  incluyo_usuario: boolean;
}

export const TIPOS_EVENTO_AUTENTICACION_VALIDOS: TipoEventoAutenticacion[] = [
  'login',
  'logout',
  'registro',
];

export const RESULTADOS_AUTENTICACION_VALIDOS: ResultadoAutenticacion[] = [
  'exito',
  'fallo',
];

export const MOTIVOS_FALLO_AUTENTICACION_VALIDOS: MotivoFalloAutenticacion[] = [
  'credenciales_invalidas',
  'usuario_inexistente',
  'cuenta_inactiva',
  'datos_invalidos',
];
