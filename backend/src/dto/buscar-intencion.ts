import { ResultadoBusquedaProducto } from './buscar-productos';

/** Query params esperados en GET /buscador/productos/intencion. */
export interface BuscarIntencionQuery {
  /** Lo que la persona quiere lograr, con sus palabras: "mi ventana esta muy solitaria". */
  q?: string;
  limite?: string;
  /**
   * Opcional: calificacion minima (1 a 5) de las resenas que cuentan. Por
   * defecto 4: se busca lo que a otros les funciono.
   */
  calificacion_minima?: string;
}

/** Una resena que explica POR QUE un producto salio en la busqueda. */
export interface MotivoIntencion {
  id_resena: number;
  calificacion: number;
  comentario: string;
  /** Que tan cerca esta de lo que se pidio, de 0 a 1 (coseno). */
  similitud: number;
}

/**
 * Un resultado de la busqueda por intencion: el mismo resumen que
 * `GET /buscador/productos`, mas lo que explica por que salio.
 */
export interface ResultadoIntencion extends ResultadoBusquedaProducto {
  /** El mayor entre `similitud_resenas` y `similitud_producto`, de 0 a 1. Por aqui se ordena. */
  puntaje: number;
  /** De donde viene la coincidencia: las resenas, la descripcion del producto, o las dos. */
  origen: ('resenas' | 'producto')[];
  /** La resena mas cercana a lo pedido, o `null` si el producto salio solo por su descripcion. */
  motivo: MotivoIntencion | null;
  /** Cuantas resenas del producto pasan del umbral de parecido. */
  resenas_coincidentes: number;
  /** El parecido de la mejor resena, o `null` si ninguna paso del umbral. */
  similitud_resenas: number | null;
  /** El parecido entre lo pedido y el nombre, categoria y descripcion del producto, o `null`. */
  similitud_producto: number | null;
}
