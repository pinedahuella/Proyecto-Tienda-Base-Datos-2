/**
 * Catalogos y forma de `alerta_fraude` (ver
 * `elementos Generales/plan pendiente/fraude-login-eventos.sql`).
 *
 * Los pares sin sufijo / `_lenta` son la MISMA pregunta, calculada por dos
 * mecanismos: sin sufijo = `FraudeLoginService`, contadores de Redis en el
 * propio camino del login (sincrono, ventana de minutos); `_lenta` =
 * `FraudeLoginRetrospectivoService`, agregaciones de Elasticsearch
 * (`mesh_eventos_autenticacion`) cada 15 min sobre una ventana de 24h.
 * `toma_cuenta` y `viaje_imposible` son la excepcion: no son ventanas de
 * tiempo, comparan el login actual contra el anterior de la misma cuenta
 * (`TomaCuentaService` / `ViajeImposibleService`, ambos en cada login
 * exitoso).
 */

export const ID_ESTADO_ALERTA_FRAUDE_PENDIENTE = 1;
export const ID_ESTADO_ALERTA_FRAUDE_REVISADA = 2;
export const ID_ESTADO_ALERTA_FRAUDE_DESCARTADA = 3;

export type TipoAlertaFraude =
  | 'fuerza_bruta_ip'
  | 'fuerza_bruta_cuenta'
  | 'multi_cuenta_ip'
  | 'toma_cuenta'
  | 'fuerza_bruta_cuenta_lenta'
  | 'multi_cuenta_ip_lenta'
  | 'ip_rotacion_cuenta_lenta'
  | 'ip_rotacion_cuenta'
  | 'viaje_imposible';

export type EstadoAlertaFraude = 'pendiente' | 'revisada' | 'descartada';

/**
 * Una cuenta notificada de una alerta -- una fila de `notificacion_fraude`
 * (ver `helpers/registrar-alerta-fraude.ts` para cómo se decide quién
 * termina aquí), con su propio estado de lectura. Una alerta puede tener
 * varias: `multi_cuenta_ip`/`multi_cuenta_ip_lenta` le llegan a cada cuenta
 * que esa IP probó, no solo a una.
 */
export interface CuentaAfectada {
  id_usuario: string;
  usuario: string;
  fecha_lectura: Date | null;
}

/** Una fila de `alerta_fraude` + sus afectados, tal como la trae `pool.query`. */
export interface FilaAlertaFraude {
  id_alerta_fraude: string;
  tipo_alerta: TipoAlertaFraude;
  clave: string;
  cuentas_afectadas: CuentaAfectada[];
  detalle: Record<string, unknown>;
  contador: number;
  ventana_inicio: Date;
  estado: EstadoAlertaFraude;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}

/** `GET /admin/fraude/alertas-login`: una alerta, forma de API. */
export interface AlertaFraude {
  id_alerta_fraude: string;
  tipo_alerta: TipoAlertaFraude;
  clave: string;
  cuentas_afectadas: CuentaAfectada[];
  detalle: Record<string, unknown>;
  contador: number;
  ventana_inicio: Date;
  estado: EstadoAlertaFraude;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}
