/**
 * Estados de producto que nunca deben aparecer en el catalogo publico
 * (GET /productos): un producto inactivo o en borrador no es un resultado
 * de busqueda valido, sin importar que filtro de estado se pida.
 */
export const ESTADOS_PRODUCTO_OCULTOS = ['inactivo', 'borrador'];

/** Catalogo completo de estado_producto (ver 003_productos.sql). */
export const ESTADOS_PRODUCTO_VALIDOS = ['borrador', 'activo', 'inactivo'];
