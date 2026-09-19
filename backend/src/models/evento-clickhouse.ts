/**
 * Una fila cruda de cada tabla de eventos en ClickHouse, tal como las
 * devuelve `GET /admin/eventos/*`. Mismas columnas que
 * `elementos Generales/plan pendiente/eventos-clickhouse.sql` -- si esa
 * referencia cambia, estos tipos tienen que seguirla.
 *
 * Las columnas `UInt64` (`id_producto`, `id_oferta`, `id_usuario`,
 * `id_pedido`) llegan como STRING, no `number`: ClickHouse serializa los
 * enteros de 64 bits entre comillas en JSON (para no perder precision en
 * clientes como JS, que no representan un `UInt64` exacto como `number`) --
 * confirmado contra el servidor real, ver el ejemplo de
 * `endpoints-eventos.md`. Solo `cantidad` (`UInt32`), `resultados`
 * (`UInt32`) y `posicion` (`UInt16`) quedan como `number`.
 */

export interface FilaVistaProducto {
  fecha: string;
  id_producto: string;
  id_usuario: string | null;
  sesion: string;
  ip: string;
  origen: string;
  lote: string;
}

export interface FilaCarritoProducto {
  fecha: string;
  id_producto: string;
  id_oferta: string;
  id_usuario: string;
  cantidad: number;
  ip: string;
  lote: string;
}

/** Misma forma para `compra_producto` y `devolucion_producto`. */
export interface FilaCompraODevolucionProducto {
  fecha: string;
  id_producto: string;
  id_oferta: string;
  id_usuario: string;
  cantidad: number;
  id_pedido: string;
  ip: string;
  lote: string;
}

export interface FilaBusquedaRealizada {
  fecha: string;
  termino: string;
  resultados: number;
  id_usuario: string | null;
  sesion: string;
  lote: string;
}

export interface FilaBusquedaClic {
  fecha: string;
  termino: string;
  id_producto: string;
  posicion: number;
  id_usuario: string | null;
  sesion: string;
  lote: string;
}
