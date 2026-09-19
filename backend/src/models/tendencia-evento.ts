import { Producto } from './producto';

/**
 * Una fila del ranking de `GET /admin/eventos/vista|carrito|compra|devolucion`
 * -- las cuatro tablas que se agrupan por `id_producto`. `total` es la
 * metrica de esa tabla (ver `AdminTendenciasService`): sesiones distintas
 * para vista, usuarios distintos para carrito, unidades para compra y
 * devolucion.
 *
 * `producto` es el detalle real, pedido a MongoDB con el id que devolvio
 * ClickHouse -- `null` si ese producto ya no tiene documento (se borro).
 * A diferencia de `GET /productos/mas-vendidos` (publica), aqui NO se
 * filtra por estado ni se descarta el id: un admin explorando tendencias
 * necesita ver TODO, incluido un producto inactivo o ya borrado.
 */
export interface TendenciaProducto {
  total: number;
  producto: Producto | null;
}

/**
 * Una fila del ranking de `GET /admin/eventos/busqueda|busqueda-clic` --
 * las dos tablas que se agrupan por `termino`. No hay ninguna segunda
 * consulta: el termino ya es toda la informacion, no hay un "producto"
 * al que pedirle nombre o precio para un texto de busqueda.
 */
export interface TendenciaTermino {
  termino: string;
  total: number;
}
