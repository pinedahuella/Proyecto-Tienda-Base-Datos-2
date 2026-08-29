/**
 * El unico estado que hace visible un producto fuera del panel de la
 * tienda -- lista blanca, no lista negra: cualquier estado que no sea
 * exactamente este (incluido uno nuevo que se agregue despues y nadie
 * recuerde excluir) queda oculto por defecto, en vez de visible por
 * defecto. Se usa igual en la busqueda publica (GET /productos), la
 * ficha publica (GET /productos/:id) y crear una oferta nueva
 * (POST /vendedor/ofertas): un producto en cualquier otro estado no es
 * un resultado valido, sin importar que filtro se pida.
 */
export const ESTADO_PRODUCTO_VISIBLE = 'activo';

/**
 * Los cinco estados de `estado_producto` (ver migrations/003_productos.sql y
 * migrations/009_propuesta_productos.sql). `en_revision` y `rechazado` son
 * del flujo de propuesta de productos y NO los pone nunca el cliente por
 * `PATCH /vendedor/productos/:id`: los mueve solo el flujo de revision
 * (`.../:id/revision` aprobar/rechazar, y `.../:id/reenviar`).
 *
 * Antes esta lista tenia solo tres estados y el backend no conocia los dos
 * del flujo de propuesta, aunque la base ya los tuviera.
 */
export const ESTADOS_PRODUCTO = [
  'borrador',
  'activo',
  'inactivo',
  'en_revision',
  'rechazado',
];

/**
 * Los estados que el cliente puede enviar en el cuerpo de
 * `PATCH /vendedor/productos/:id` (lo valida `validarEstadoProducto`).
 * `en_revision` y `rechazado` quedan fuera a proposito -- esos dos solo los
 * mueve el flujo de revision.
 */
export const ESTADOS_PRODUCTO_VALIDOS = ['borrador', 'activo', 'inactivo'];

/**
 * Los estados del flujo de propuesta de productos
 * (migrations/009_propuesta_productos.sql). Un producto en uno de estos NO
 * se puede editar por `PATCH /vendedor/productos/:id`: la unica forma de
 * sacarlo de ahi es `PATCH /vendedor/productos/:id/revision`
 * (aprobar/rechazar) o `PATCH /vendedor/productos/:id/reenviar`, que son las
 * rutas que dejan constancia en `propuesta_producto` de quien y cuando. Sin
 * este candado, un `PATCH .../:id {estado:'activo'}` publicaria el producto
 * dejando la propuesta con `fecha_aprobacion = NULL` para siempre (y por
 * tanto atascada en la cola de `/propuestas/sin-aprobar`, sin poder
 * reenviarse).
 */
export const ESTADOS_PRODUCTO_SOLO_REVISION = ['en_revision', 'rechazado'];
