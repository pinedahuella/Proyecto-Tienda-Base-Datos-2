/**
 * Una oferta de un vendedor sobre una variante, tal como vive en PostgreSQL
 * (tabla `oferta`, migrations/005_ofertas.sql) con el vendedor ya resuelto
 * via JOIN a usuarios.
 *
 * Las ofertas ya NO se copian a MongoDB (ver docs/base-de-datos.md, "El
 * catalogo se mudo a MongoDB"): precio, stock y estado cambian en cada
 * venta, y una copia en la base documental se desfasaria. La ficha de un
 * producto las pide aqui, con una consulta indexada por
 * (id_producto_mongo, id_producto_variante_mongo, precio).
 *
 * id_oferta y id_usuario van como string: son bigint, y el driver pg los
 * devuelve como texto para no perder precision (igual que en Usuario).
 */
export interface OfertaVendedor {
  id_oferta: string;
  id_producto_variante_mongo: string;
  vendedor: {
    id_usuario: string;
    usuario: string;
    nombre: string;
    apellido: string | null;
  };
  /** true solo en la oferta de la cuenta de la tienda (ver CORREO_TIENDA). */
  es_tienda: boolean;
  /** numeric(12,2) de Postgres: string, para no perder centavos por el redondeo binario. */
  precio: string;
  stock: number;
  fecha_actualizacion: Date;
}
