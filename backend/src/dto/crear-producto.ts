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

/**
 * Una variante dentro de POST /vendedor/productos o PATCH /vendedor/productos/:id.
 *
 * Sin precio ni stock: eso es de la oferta (ver POST /vendedor/ofertas),
 * no del catalogo. Publicar un producto (o agregarle una variante) no crea
 * ninguna oferta -- nace sin nadie que lo venda todavia.
 */
export interface VarianteCreacionPeticion {
  /**
   * Solo tiene efecto en PATCH (POST la ignora: ahi nunca hay una variante
   * previa que emparejar). Si viene y coincide con una variante que el
   * producto ya tenia, esa variante CONSERVA su mismo id_producto_variante
   * (no se le asigna uno nuevo) -- ver ProductosVendedorService. Si viene y
   * no coincide con ninguna, se rechaza la edicion completa. Si no viene,
   * es una variante nueva: id nuevo.
   */
  id_producto_variante?: number;
  nombre_variante: string;
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
