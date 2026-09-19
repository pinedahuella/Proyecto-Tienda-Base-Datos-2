/**
 * Cuerpo esperado en `POST /eventos/busqueda-clic`. `id_usuario` no viene
 * aqui -- mismo criterio que `RegistrarVistaPeticion`: opcional, sale de
 * la cookie de sesion si hay una valida, nunca del cuerpo.
 */
export interface RegistrarClicBusquedaPeticion {
  termino?: unknown;
  id_producto?: unknown;
  posicion?: unknown;
  sesion?: unknown;
}
