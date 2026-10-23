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
  /**
   * `1` para la lista del buscador de la cabecera, que busca con cada letra:
   * la ultima palabra vale tambien a medias y queda un resultado por producto
   * (ver `BuscadorProductosService.ejecutar`). Sin esto, la busqueda de
   * siempre.
   */
  escribiendo?: string;
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
  /** De donde salieron los `sugeridos`, o `null` si no hay. */
  sugeridos_desde: FuenteSugeridos | null;
}

/**
 * De donde salen los sugeridos (`SugeridosBusquedaService`): de Elasticsearch
 * mientras responda, y sin el, de las otras tres fuentes en ese orden.
 */
export type FuenteSugeridos =
  'elasticsearch' | 'significado' | 'mas vendido' | 'mas resenados';

/**
 * Un resultado de busqueda: el RESUMEN que guarda el indice de Elasticsearch
 * para encontrar, ordenar y pintar la tarjeta, no el producto completo (sin
 * caracteristicas ni el detalle de cada variante). Desde el 2026-10-23 trae
 * tambien la foto, a pedido del profesor: la tarjeta sale entera de
 * Elasticsearch, de una sola consulta. Para el detalle esta
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
  /**
   * La foto de la tarjeta: la primera imagen de la primera variante, la misma
   * que eligen las demas tarjetas de la tienda (tarjetas-producto.ts). `null`
   * si el producto no tiene ninguna.
   */
  imagen: string | null;
}
