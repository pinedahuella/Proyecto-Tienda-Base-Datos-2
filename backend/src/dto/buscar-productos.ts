/** Query params esperados en GET /buscador/productos. */
export interface BuscarProductosQuery {
  /** Lo que la persona escribio. Busca en nombre, descripcion y variantes. */
  nombre?: string;
  limite?: string;
  /**
   * Opcional, solo para el evento de analitica `busqueda_realizada` en
   * ClickHouse (ver `elementos Generales/plan pendiente/eventos-clickhouse.md`).
   * La genera el navegador, igual que en `POST /eventos/vista`. Si no
   * viene, la busqueda funciona igual -- simplemente no se registra el
   * evento (nunca bloquea ni rechaza la busqueda).
   */
  sesion?: string;
}

/** La respuesta de GET /buscador/productos (la ruta publica). */
export interface RespuestaBusquedaProductos {
  resultados: ResultadoBusquedaProducto[];
  /**
   * El texto escrito con las palabras mal escritas ya corregidas ("tal vez
   * quisiste decir ..."), o `null` si no hay nada que corregir. La busqueda
   * se hizo con lo que la persona escribio, no con esto.
   */
  quisiste_decir: string | null;
  /**
   * Sin resultados, productos para ensenar en vez de una lista vacia
   * (`SugeridosBusquedaService`). Van aparte: la busqueda se sigue contando
   * como sin resultados. Vacio si hubo resultados.
   */
  sugeridos: ResultadoBusquedaProducto[];
}

/**
 * Un resultado de busqueda: el RESUMEN que guarda el indice de Elasticsearch
 * para encontrar y ordenar, no el producto completo (sin imagenes, sin
 * caracteristicas, sin el detalle de cada variante). Para eso esta
 * GET /productos/:id_producto contra MongoDB, que sigue siendo la fuente de
 * verdad del catalogo.
 */
export interface ResultadoBusquedaProducto {
  id_producto: number;
  nombre: string;
  /**
   * En GET /buscador/productos SIEMPRE es "activo" (esa ruta filtra por
   * codigo, no por lo que pida la peticion). En GET /buscador/productos/admin
   * puede ser cualquiera -- es lo que le permite a un admin distinguir un
   * producto rechazado de uno activo en la misma lista.
   */
  estado: string;
  categoria: string | null;
  /** El precio mas barato entre todos los vendedores. */
  precio_desde: number | null;
  /** El precio de la tienda, el que se ensena primero. */
  precio_tienda: number | null;
  /** `true` si alguna variante tiene una oferta activa con descuento. */
  hay_descuento: boolean;
  /** Existencias activas entre todos los vendedores. */
  stock_total: number;
  resenas_promedio: number;
  resenas_total: number;
}
