import { Producto } from '../models/producto';

/**
 * Una caracteristica del catalogo que manda el vendedor: solo nombre y
 * valor. La unidad no la manda el vendedor, la rellena el backend a partir
 * de la definicion de la categoria.
 */
export interface CaracteristicaCatalogoPeticion {
  nombre: string;
  valor: unknown;
}

/**
 * Una caracteristica personalizada: no sale de ningun catalogo, solo
 * nombre y valor, nada mas (nunca una unidad).
 */
export interface CaracteristicaPersonalizadaPeticion {
  nombre: string;
  valor: unknown;
}

/** Una variante dentro de POST /vendedor/productos. */
export interface VarianteCreacionPeticion {
  nombre_variante: string;
  precio: string;
  descripcion: string;
  imagenes?: string[];
  caracteristicas_adicionales?: CaracteristicaCatalogoPeticion[];
  caracteristicas_personalizadas?: CaracteristicaPersonalizadaPeticion[];
}

/** Cuerpo esperado en POST /vendedor/productos. */
export interface CrearProductoPeticion {
  id_categoria: number;
  nombre: string;
  descripcion?: string | null;
  caracteristicas_adicionales?: CaracteristicaCatalogoPeticion[];
  caracteristicas_personalizadas?: CaracteristicaPersonalizadaPeticion[];
  variantes: VarianteCreacionPeticion[];
}

/** Respuesta de POST /vendedor/productos: el producto tal como quedo creado. */
export type ProductoCreado = Producto;
