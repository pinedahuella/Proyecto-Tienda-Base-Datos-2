/**
 * Constantes de negocio compartidas entre varios servicios. Solo van aqui
 * las que de verdad se repiten en mas de un archivo; si algo se usa en un
 * solo lugar, se queda ahi.
 */

/**
 * El correo de la cuenta de la tienda (ver migrations/datos/generador.js y
 * backend/elementos Generales/cambios-multivendedor.md, seccion 9): en el
 * modelo multi-vendedor es la unica cuenta que oferta TODAS las variantes,
 * su precio es el que se ensena en el catalogo, y (decision del equipo) es
 * la unica que puede crear o editar entradas del catalogo compartido.
 */
export const CORREO_TIENDA = 'tienda@mesh.com';
