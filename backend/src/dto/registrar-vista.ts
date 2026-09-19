/**
 * Cuerpo esperado en `POST /eventos/vista`. Ver
 * `elementos Generales/plan pendiente/eventos-clickhouse.md` para el porque
 * de cada campo.
 *
 * `id_usuario` NO viene aqui: si la peticion trae una cookie de sesion
 * valida, el controlador saca el id de ahi (nunca del cuerpo -- confiar en
 * un id que manda el cliente dejaria que cualquiera reporte vistas a nombre
 * de otra cuenta).
 */
export interface RegistrarVistaPeticion {
  id_producto?: unknown;
  sesion?: unknown;
  origen?: unknown;
}

/** Por donde puede haber llegado el clic a la ficha del producto. */
export const ORIGENES_VISTA_VALIDOS = [
  'catalogo',
  'buscador',
  'enlace_directo',
] as const;

export type OrigenVista = (typeof ORIGENES_VISTA_VALIDOS)[number];
