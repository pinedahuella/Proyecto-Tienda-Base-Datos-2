/**
 * Cuerpo esperado en POST /vendedor/ofertas.
 *
 * Cualquier vendedor (o admin) puede publicar una oferta sobre una variante
 * que ya existe en el catalogo compartido (Mongo) -- crear la variante
 * misma sigue siendo solo de tienda@mesh.com o admin (ver
 * ProductosVendedorService.exigirTiendaOAdmin).
 * id_producto e id_producto_variante son los mismos ids de MongoDB, no un
 * id de PostgreSQL.
 */
export interface CrearOfertaPeticion {
  id_producto: number;
  id_producto_variante: number;
  /** Mismo formato que valida validarPrecioObligatorio: numero > 0, hasta 2 decimales. */
  precio: string;
  /** Opcional, por defecto 0. Si es mayor a 0, se repone con reponer_stock justo despues de nacer la oferta -- nunca directo en el INSERT, para que el kardex explique tambien esas unidades. */
  stock_inicial?: number;
}
