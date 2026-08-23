import {
  CaracteristicaCatalogoPeticion,
  CaracteristicaPersonalizadaPeticion,
  VarianteCreacionPeticion,
} from './crear-producto';

/**
 * Cuerpo esperado en PATCH /vendedor/productos/:id.
 *
 * Cada campo es independiente: el que venga en null (o no venga) no se
 * toca. Debe venir al menos uno. Para las dos listas de caracteristicas,
 * null es "no tocar" y un array (aunque sea vacio, []) es "reemplazar por
 * esto" — asi se puede vaciar una lista a proposito sin confundirlo con no
 * tocarla.
 *
 * `variantes` funciona distinto de las dos listas de caracteristicas: null
 * es igual "no tocar", pero un array se reemplaza completo y tiene que
 * traer al menos una variante — un producto nunca se queda sin ninguna, ni
 * siquiera al editar.
 */
export interface EditarProductoPeticion {
  nombre?: string | null;
  descripcion?: string | null;
  estado?: string | null;
  id_categoria?: number | null;
  caracteristicas_adicionales?: CaracteristicaCatalogoPeticion[] | null;
  caracteristicas_personalizadas?: CaracteristicaPersonalizadaPeticion[] | null;
  variantes?: VarianteCreacionPeticion[] | null;
}
