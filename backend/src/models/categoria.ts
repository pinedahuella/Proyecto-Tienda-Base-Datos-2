import { Decimal128 } from 'mongodb';

/**
 * Documentos de la coleccion `categorias` en MongoDB: el menu de que
 * caracteristicas ofrece cada categoria (sin valores, esos van en
 * `productos`). Ver
 * backend/elementos Generales/Elementos Documentales/ejemplos_bson_productos.md
 */

export type TipoDato = 'texto' | 'entero' | 'decimal' | 'booleano' | 'lista';

/** Una entrada de `caracteristicas` o `caracteristicas_variante`: que se ofrece, no que valor tiene. */
export interface CaracteristicaDefinicion {
  nombre: string;
  unidad: string | null;
  tipo_dato: TipoDato;
}

/**
 * Documento crudo tal como esta en Mongo (con _id). Solo lo usa
 * CategoriasService para leer; hacia afuera de la API se expone `Categoria`,
 * con `id_categoria` en vez de `_id`.
 */
export interface CategoriaDocumento {
  _id: number;
  nombre: string;
  /** null solo en las categorias raiz. */
  categoria_padre: string | null;
  porcentaje_comision: Decimal128;
  fecha_creacion: Date;
  caracteristicas: CaracteristicaDefinicion[];
  caracteristicas_variante: CaracteristicaDefinicion[];
}

/**
 * Forma publica de una categoria completa: `id_categoria` en vez de `_id`,
 * para ser consistente con como ya se expone en el resto de la API (por
 * ejemplo, el objeto `categoria` embebido en un producto).
 */
export interface Categoria {
  id_categoria: number;
  nombre: string;
  categoria_padre: string | null;
  porcentaje_comision: Decimal128;
  fecha_creacion: Date;
  caracteristicas: CaracteristicaDefinicion[];
  caracteristicas_variante: CaracteristicaDefinicion[];
}

/** Respuesta de GET /vendedor/categorias: solo lo minimo para armar un selector. */
export interface CategoriaValida {
  id_categoria: number;
  nombre: string;
  /** Nunca null aqui: una categoria valida es, por definicion, la que no es raiz. */
  categoria_padre: string;
}
