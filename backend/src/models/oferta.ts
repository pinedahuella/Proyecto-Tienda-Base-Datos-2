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
  /**
   * true si esta oferta esta operando bajo el mecanismo de venta relampago
   * de Redis (`oferta.es_inventario_limitado`, migrations/014). Para quien
   * compra: el stock de esta oferta lo decide una reserva atomica en Redis
   * con un plazo, no el flujo normal de PostgreSQL. Lo enciende el vendedor
   * con `POST /vendedor/ofertas/:id/venta-limitada`.
   */
  es_inventario_limitado: boolean;
  /** numeric(12,2) de Postgres: string, para no perder centavos por el redondeo binario. */
  precio: string;
  stock: number;
  /**
   * Unidades que quedan AHORA, leidas del contador de Redis (operacion
   * `estado` de `redis/inventario_limitado.lua`). Solo se llena cuando
   * `es_inventario_limitado` es `true`; `null` en el resto. Tambien `null`
   * si la venta relampago ya cerro o si Redis no respondio -- ahi el unico
   * stock que hay es `stock`, el de PostgreSQL (que en una oferta en venta
   * relampago queda congelado desde que se abrio).
   */
  stock_disponible: number | null;
  fecha_actualizacion: Date;
}

/**
 * El vendedor/tienda que aprobo una oferta, resuelto via JOIN a `usuarios`
 * desde `oferta.id_usuario_aprobo` (migrations/010_aprobacion_ofertas.sql).
 * Es quien pulso "aprobar" en `PATCH /vendedor/ofertas/:id/revision`: la
 * cuenta de la tienda, o el admin real que la reviso -- nunca el dueno de
 * la oferta, que sale de `oferta.id_usuario`.
 */
export interface AprobadorOferta {
  id_usuario: string;
  usuario: string;
  nombre: string;
  apellido: string | null;
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
  /**
   * Unidades que quedan AHORA segun el contador de Redis (operacion
   * `estado` de `redis/inventario_limitado.lua`). Solo se llena cuando
   * `es_inventario_limitado` es `true`; `null` en el resto, si la venta
   * relampago ya cerro, o si Redis no respondio. Con `null`, el numero real
   * es `stock` (PostgreSQL).
   */
  stock_disponible: number | null;
  estado: string;
  /**
   * Cuando la tienda aprobo esta oferta. `null` = nunca aprobada: esta
   * `pendiente`, `rechazada`, o `retirada` sin haber pasado por revision.
   * Sobrevive a que despues la oferta se pause o se retire.
   */
  fecha_aprobacion: Date | null;
  /**
   * Quien la aprobo (`PATCH /vendedor/ofertas/:id/revision`). `null` cuando
   * `fecha_aprobacion` es `null`, y tambien en las ofertas de la propia
   * tienda o de un admin -- nacen aprobadas sin revisor -- y en las
   * anteriores al flujo de aprobacion.
   */
  aprobado_por: AprobadorOferta | null;
  /**
   * true si el vendedor abrio la venta relampago de esta oferta
   * (`oferta.es_inventario_limitado`, migrations/014). En el panel es lo
   * que decide si el boton dice "Abrir venta relampago" o "Cerrar la
   * venta". Ver `POST/DELETE /vendedor/ofertas/:id/venta-limitada`.
   */
  es_inventario_limitado: boolean;
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

/**
 * Fila cruda de `oferta` (mas el nombre de su estado y el aprobador
 * resuelto por LEFT JOIN a `usuarios`), tal como la lee
 * OfertasVendedorService antes de mezclarla con el nombre del producto que
 * vive en Mongo. Uso interno del servicio, no se expone en ninguna ruta --
 * hacia afuera se arma `OfertaPropia`.
 */
export interface FilaOfertaPropia {
  id_oferta: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  precio: string;
  stock: number;
  estado_oferta_nombre: string;
  /** NULL mientras la tienda no la haya aprobado (ver flujo de aprobacion de ofertas). */
  fecha_aprobacion: Date | null;
  /** NULL si no consta aprobador: oferta de la tienda/admin, o anterior al flujo. */
  id_usuario_aprobo: string | null;
  aprobo_usuario: string | null;
  aprobo_nombre: string | null;
  aprobo_apellido: string | null;
  es_inventario_limitado: boolean;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}

/**
 * Fila cruda de la cola de revision: una `oferta` pendiente mas su vendedor
 * (JOIN a `usuarios`), tal como la lee OfertasVendedorService.listarPendientes
 * antes de resolver el nombre del producto contra Mongo. Uso interno del
 * servicio -- hacia afuera se arma `OfertaPendiente`.
 */
export interface FilaOfertaPendiente {
  id_oferta: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  precio: string;
  stock: number;
  fecha_creacion: Date;
  id_usuario: string;
  usuario: string;
  nombre: string;
  apellido: string | null;
}

/**
 * Lo que devuelve `POST /vendedor/ofertas/:id/venta-limitada`: cuantas
 * unidades quedaron sembradas en el contador de Redis -- el `stock` que la
 * oferta tenia en PostgreSQL en el instante de abrir la venta. Ver
 * VentasLimitadasService.
 */
export interface VentaLimitadaAbierta {
  id_oferta: string;
  stock_sembrado: number;
}

/**
 * Lo que devuelve el INSERT de una oferta nueva en
 * OfertasVendedorService.crear (`RETURNING`). Uso interno del servicio.
 */
export interface FilaOfertaNueva {
  id_oferta: string;
  precio: string;
  stock: number;
  /** now() si nace `activa` (tienda/admin); NULL si nace `pendiente`. */
  fecha_aprobacion: Date | null;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}
