/**
 * La formula del precio final de una oferta con descuento: el de lista si
 * no hay descuento, o redondeado con el % aplicado si lo hay. Nunca se
 * guarda -- se calcula en cada consulta que lo necesita (decision del
 * equipo, ver `elementos Generales/plan pendiente/descuentos-oferta.md`).
 *
 * Esta funcion NO calcula nada en JavaScript: arma el FRAGMENTO DE SQL que
 * cada consulta interpola, para que la formula viva en un solo lugar del
 * codigo TypeScript en vez de repetirse a mano (con riesgo de que una
 * copia se escriba distinta) en cada uno de los sitios que la necesitan --
 * `carrito.service.ts`, `productos.service.ts`, `admin-reportes.service.ts`,
 * `pedidos.service.ts` y `ofertas.service.ts`.
 *
 * `alias` es el prefijo de la tabla en esa consulta (`"o"` para
 * `o.precio`/`o.porcentaje_descuento` de `oferta`, `"ph"` para
 * `ph.precio`/`ph.porcentaje_descuento` de `precio_historial`) -- las dos
 * columnas tienen que existir con esos nombres exactos en la tabla que ese
 * alias identifica.
 */
export function expresionPrecioFinal(alias: string): string {
  return `ROUND(${alias}.precio * (1 - COALESCE(${alias}.porcentaje_descuento, 0) / 100), 2)`;
}
