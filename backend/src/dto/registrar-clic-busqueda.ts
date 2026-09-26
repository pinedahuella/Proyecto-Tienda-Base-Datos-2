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
  /**
   * Las cuatro facetas que estaban activas en la pantalla de resultados al
   * hacer clic (Entrega final,
   * `elementos Generales/plan pendiente/buscador-facetado-clickhouse.md`).
   * Opcionales -- si la busqueda no era facetada, se omiten y quedan en
   * su default (vacio/false).
   */
  facetada?: unknown;
  categorias?: unknown;
  precios?: unknown;
  calificaciones?: unknown;
  disponible?: unknown;
}
