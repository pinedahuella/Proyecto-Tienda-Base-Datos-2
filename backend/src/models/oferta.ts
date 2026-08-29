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

/**
 * Una oferta propia, tal como la ve el vendedor logueado en su panel (
 * GET /vendedor/ofertas y GET /vendedor/ofertas/producto/:id). A diferencia
 * de OfertaVendedor (la ficha publica, con el vendedor embebido porque
 * quien la lee no lo conoce), aqui no hace falta el vendedor -- es uno
 * mismo -- pero si el estado completo (activa/pausada/retirada: en su
 * propio panel el vendedor tiene que ver TODAS sus ofertas, no solo las
 * activas) y las dos fechas.
 */
export interface OfertaPropiaResumen {
  id_oferta: string;
  /** numeric(12,2) de Postgres: string. */
  precio: string;
  stock: number;
  estado: string;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}

/**
 * Una oferta propia con el nombre del producto/variante y su portada ya
 * resueltos desde Mongo -- lo que necesita GET /vendedor/ofertas para no
 * obligar a pedir cada producto aparte. Ver OfertasVendedorService.
 */
export interface OfertaPropia extends OfertaPropiaResumen {
  id_producto: number;
  id_producto_variante: number;
  nombre_producto: string;
  nombre_variante: string;
  /** La primera imagen de la variante, o null si no tiene ninguna. */
  imagen: string | null;
}

/**
 * Una oferta en estado `pendiente`, tal como la ve la tienda (o un admin)
 * en su cola de revisión -- `GET /vendedor/ofertas/pendientes`. Como quien
 * la lee NO es el dueño, lleva el vendedor embebido (igual que
 * `OfertaVendedor` de la ficha pública), más el nombre del producto y de
 * la variante ya resueltos desde Mongo. No lleva `estado` (todas son
 * `pendiente`) ni `fecha_actualizacion` (lo que importa es desde cuándo
 * espera, `fecha_creacion`).
 */
export interface OfertaPendiente {
  id_oferta: string;
  id_producto: number;
  id_producto_variante: number;
  nombre_producto: string;
  nombre_variante: string;
  /** La primera imagen de la variante, o null si no tiene ninguna. */
  imagen: string | null;
  /** numeric(12,2) de Postgres: string. */
  precio: string;
  stock: number;
  /** Desde cuándo espera revisión. La cola se ordena por esto, ascendente. */
  fecha_creacion: Date;
  vendedor: {
    id_usuario: string;
    usuario: string;
    nombre: string;
    apellido: string | null;
  };
}

/**
 * Precio y stock de una oferta reconstruidos **como estaban en una fecha
 * especifica** -- ver ProductosService.reconstruirOfertaEnFecha(). Mismo
 * espiritu que reconstruir un producto a una fecha, pero del lado
 * economico (precio_historial + stock_movimiento), que vive en PostgreSQL,
 * no en Mongo.
 */
export interface OfertaHistorial {
  id_oferta: string;
  /** numeric(12,2) de Postgres: string. */
  precio: string;
  stock: number;
}
