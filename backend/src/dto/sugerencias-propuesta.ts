/** Cuerpo esperado en POST /vendedor/productos/sugerencias. */
export interface SugerenciasPropuestaPeticion {
  /** El nombre del producto que se va a proponer. Obligatorio, mismas reglas que al crearlo. */
  nombre: string;
  /** La descripcion, si ya la tiene. Ayuda a acertar la categoria. */
  descripcion?: string | null;
}

/** Una categoria que se sugiere para el producto. */
export interface CategoriaSugerida {
  id_categoria: number;
  nombre: string;
  /**
   * Que tanto pesa esta categoria entre los productos parecidos, de 0 a 1: la
   * suma del parecido de los productos de esta categoria sobre la suma de todos.
   * Las categorias sugeridas se ordenan por aqui.
   */
  puntaje: number;
  /** Cuantos productos parecidos del catalogo tiene esta categoria. */
  productos_parecidos: number;
  /** El parecido (coseno, de 0 a 1) del producto mas cercano de esta categoria. */
  mejor_similitud: number;
}

/** Un producto del catalogo que se parece al que se va a proponer. */
export interface ProductoParecido {
  id_producto: number;
  nombre: string;
  id_categoria: number | null;
  categoria: string | null;
  precio_tienda: number | null;
  /** El parecido con lo escrito, de 0 a 1 (coseno). */
  similitud: number;
  /** `true` si el parecido es tan alto que probablemente es el mismo producto. */
  posible_duplicado: boolean;
}

/** La respuesta de POST /vendedor/productos/sugerencias. */
export interface SugerenciasPropuesta {
  /** Hasta 3 categorias, de la mas a la menos probable. Vacio si nada del catalogo se parece. */
  categorias: CategoriaSugerida[];
  /** Hasta 5 productos activos del catalogo, del mas parecido al menos. Vacio si nada se parece. */
  productos_similares: ProductoParecido[];
}
