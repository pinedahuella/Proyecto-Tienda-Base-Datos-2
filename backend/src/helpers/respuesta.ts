/**
 * La forma unica de respuesta de toda la API.
 *
 * Todos los endpoints devuelven estos tres campos, salga bien o salga mal:
 *
 *   ok       si la operacion salio bien
 *   mensaje  explicacion corta, se le puede ensenar al usuario
 *   payload  los datos utiles para el frontend
 *
 * Esta explicado en docs/api.md
 */
export interface RespuestaApi<T> {
  ok: boolean;
  mensaje: string;
  payload: T;
}

/** Arma una respuesta correcta: ok en true y los datos en payload. */
export function exito<T>(payload: T, mensaje: string): RespuestaApi<T> {
  return { ok: true, mensaje, payload };
}

/**
 * Arma una respuesta fallida: ok en false y payload en null.
 *
 * El payload viaja en null y nunca se omite, para que el frontend siempre lea
 * la misma estructura y no tenga que preguntar si el campo existe.
 */
export function fallo(mensaje: string): RespuestaApi<null> {
  return { ok: false, mensaje, payload: null };
}
