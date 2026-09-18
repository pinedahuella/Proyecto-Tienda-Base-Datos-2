import { TipoAlertaFraude } from '../models/alerta-fraude';

/** Query params esperados en GET /perfil/alertas-fraude: solo paginación, siempre "las mías". */
export interface PaginarAlertasFraudeUsuarioQuery {
  pagina?: string;
  limite?: string;
}

/**
 * Una alerta tal como la ve UNA cuenta afectada -- distinta de `AlertaFraude`
 * (la del admin): sin `cuentas_afectadas` (el resto de afectados no es
 * asunto de esta cuenta) ni nada del lado de la investigación del admin
 * (`estado`, `fecha_actualizacion`). `fecha_lectura` es la de SU propia
 * notificación (`notificacion_fraude`), no de la alerta -- cada afectado
 * tiene la suya. `detalle` viene redactado en `multi_cuenta_ip`/
 * `multi_cuenta_ip_lenta` (sin `identificadores`, las demás cuentas
 * afectadas) -- ver `detalleParaUsuario` en `fraude-login.service.ts`.
 */
export interface AlertaFraudeUsuario {
  id_alerta_fraude: string;
  tipo_alerta: TipoAlertaFraude;
  clave: string;
  detalle: Record<string, unknown>;
  contador: number;
  ventana_inicio: Date;
  fecha_creacion: Date;
  fecha_lectura: Date | null;
}

/** Respuesta de GET /perfil/alertas-fraude. */
export interface AlertasFraudeUsuarioPaginadas {
  alertas: AlertaFraudeUsuario[];
  pagina: number;
  limite: number;
  total_alertas: number;
  total_paginas: number;
}
