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

/** Catalogo completo de estado_producto (ver 003_productos.sql). */
export const ESTADOS_PRODUCTO_VALIDOS = ['borrador', 'activo', 'inactivo'];
