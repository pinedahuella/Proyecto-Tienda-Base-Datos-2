/**
 * Cuerpo esperado en PATCH /vendedor/productos/:id/inventario.
 *
 * id_producto sale de la URL (:id, el mismo producto que las demas rutas
 * de /vendedor/productos/:id/...); esto es solo lo que falta para ajustar
 * una de sus variantes. id_motivo_movimiento tiene que ser el de
 * "ajuste positivo" o "ajuste negativo" (ver
 * GET /vendedor/productos/inventario/motivos-ajuste) -- esta ruta es solo
 * para correcciones manuales, no para ventas, devoluciones, reposiciones
 * ni merma, que tienen (o van a tener) su propio flujo.
 */
export interface AjustarInventarioPeticion {
  id_producto_variante: number;
  id_motivo_movimiento: number;
  cantidad: number;
}
