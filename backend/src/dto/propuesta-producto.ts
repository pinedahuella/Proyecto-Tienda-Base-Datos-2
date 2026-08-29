import { Producto } from '../models/producto';
import { RechazoProducto } from '../models/rechazo-producto';

/**
 * Una propuesta de producto: la fila de `propuesta_producto` (PostgreSQL)
 * ya cruzada con el documento del producto (MongoDB) y su historial de
 * rechazos.
 *
 * La usan las tres rutas GET de propuestas:
 *   - `GET /vendedor/productos/propuestas`            (las mías, sin `vendedor`)
 *   - `GET /vendedor/productos/propuestas/sin-aprobar` (tienda/admin, con `vendedor`)
 *   - `GET /vendedor/productos/propuestas/todas`       (tienda/admin, con `vendedor`)
 *
 * `id_propuesta_producto` va como string (bigserial). El estado actual de
 * la propuesta se lee de `producto.estado` (`en_revision` / `rechazado` /
 * `activo` / ...); `fecha_aprobacion` no NULL indica que ya se aprobó.
 */
export interface PropuestaProducto {
  id_propuesta_producto: string;
  /** El `_id` del documento del producto en Mongo (= `id_producto_mongo`). */
  id_producto: number;
  fecha_propuesta: Date;
  /** NULL mientras la propuesta no haya sido aprobada. */
  fecha_aprobacion: Date | null;
  /** La nota opcional de quien aprobó. NULL si todavía no se aprobó. */
  comentario_aprobacion: string | null;
  /** El producto tal como está en Mongo. `null` si no se encontró (no debería pasar). */
  producto: Producto | null;
  /** Rechazos, del más reciente al más viejo. `[]` si nunca se rechazó. */
  rechazos: RechazoProducto[];
  /**
   * El vendedor que propuso. Solo en las vistas de tienda/admin
   * (`/sin-aprobar` y `/todas`); en "las mías" se omite (ya sé que soy yo).
   */
  vendedor?: {
    id_usuario: string;
    usuario: string;
    nombre: string;
    apellido: string | null;
  };
}
