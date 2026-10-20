/**
 * Las marcas que ponen los dos generadores de lotes al final del nombre: " L1-0880"
 * (migrations/lote, nace en PostgreSQL) y " M7-0002" (mongo/lote, solo en Mongo).
 * Un clon de un clon lleva las dos: "... L1-0493 M77-0002".
 */
export const MARCA_DE_LOTE = /(\s+[LM]\d+-\d{4})+$/;

/**
 * Un resultado por producto: de las copias de lote de un mismo original queda
 * el lugar de la primera que aparece, con el original si tambien esta, hasta
 * `tope`. Con 1000 productos de 102 originales, la lista del buscador de la
 * cabecera era ocho veces el mismo libro (visto por Meme el 2026-10-20).
 */
export function unoPorProducto<T extends { nombre: string }>(
  resultados: T[],
  tope: number,
): T[] {
  const porNombre = new Map<string, T>();
  for (const r of resultados) {
    const base = r.nombre.replace(MARCA_DE_LOTE, '');
    const previa = porNombre.get(base);
    if (previa != null && !(previa.nombre !== base && r.nombre === base)) {
      continue;
    }
    if (previa == null && porNombre.size === tope) {
      continue;
    }
    porNombre.set(base, r);
  }
  return [...porNombre.values()];
}
