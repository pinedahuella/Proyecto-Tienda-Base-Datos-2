/**
 * Tabla motivo_movimiento. Catalogo de por que se movio el stock: venta,
 * devolucion, reposicion, ajuste positivo, ajuste negativo, merma.
 *
 * valor es el signo (1 o -1, ver 005_pedidos_stock.sql): decide si la
 * cantidad del movimiento suma o resta al stock. No se expone por ninguna
 * ruta publica todavia, solo lo usa InventarioVendedorService para
 * calcular el nuevo stock de un ajuste manual.
 */
export interface MotivoMovimiento {
  id_motivo_movimiento: number;
  motivo_nombre: string;
  valor: number;
}
