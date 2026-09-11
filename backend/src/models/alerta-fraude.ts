/**
 * Catalogos y forma de `alerta_fraude` (ver
 * `elementos Generales/plan pendiente/fraude-login-eventos.sql`).
 *
 * Los tres tipos son las senales que `DeteccionFraudeLoginService` puede
 * calcular con contadores de Redis en el propio camino del login: no
 * necesitan geolocalizacion ni una consulta retrospectiva a Elasticsearch.
 */

// La migracion de referencia inserta estos tres en este orden -- un
// catalogo tan chico no cambia sin una migracion nueva, asi que es seguro
// fijar los ids aqui en vez de consultarlos cada vez (mismo criterio que
// ID_ROL_COMPRADOR/ID_ROL_VENDEDOR/ID_ROL_ADMIN en models/rol-usuario.ts).
export const ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_IP = 1;
export const ID_TIPO_ALERTA_FRAUDE_FUERZA_BRUTA_CUENTA = 2;
export const ID_TIPO_ALERTA_FRAUDE_MULTI_CUENTA_IP = 3;

export const ID_ESTADO_ALERTA_FRAUDE_PENDIENTE = 1;
export const ID_ESTADO_ALERTA_FRAUDE_REVISADA = 2;
export const ID_ESTADO_ALERTA_FRAUDE_DESCARTADA = 3;

export type TipoAlertaFraude =
  'fuerza_bruta_ip' | 'fuerza_bruta_cuenta' | 'multi_cuenta_ip';

export type EstadoAlertaFraude = 'pendiente' | 'revisada' | 'descartada';

/** Una fila de `alerta_fraude`, tal como la trae `pool.query`. */
export interface FilaAlertaFraude {
  id_alerta_fraude: string;
  tipo_alerta: TipoAlertaFraude;
  clave: string;
  id_usuario: string | null;
  usuario: string | null;
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
  cuenta_involucrada: { id_usuario: string; usuario: string } | null;
  detalle: Record<string, unknown>;
  contador: number;
  ventana_inicio: Date;
  estado: EstadoAlertaFraude;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}
