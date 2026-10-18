import type { estypes } from '@elastic/elasticsearch';

/**
 * El "tal vez quisiste decir" del buscador. Lo comparten
 * `BuscadorProductosService` y `BuscadorFacetadoService`: viaja DENTRO de la
 * misma consulta a Elasticsearch (bloque `suggest`), no es una segunda vuelta.
 *
 * Usa el `term` suggester sobre `nombre`, que compara cada palabra escrita
 * con las que ya existen en el indice. No hace falta tocar el mapeo:
 * `espanol_llano` solo pasa a minusculas y quita tildes (sin raices), asi que
 * lo que sugiere son palabras reales del catalogo, sin tildes.
 *
 * `suggest_mode: missing` sugiere solo para las palabras que NO existen en
 * `nombre`. Una palabra bien escrita que solo aparece en una descripcion
 * podria recibir una sugerencia si se parece a un nombre; es un "tal vez",
 * no cambia la busqueda.
 *
 * Una palabra bien escrita que NO esta en el catalogo tambien parece un
 * error. Dos reglas lo acotan (medidas el 2026-10-17):
 *   - `max_edits: 1`: solo se corrige a una letra de distancia (una de mas,
 *     una de menos, una cambiada o dos cambiadas de lugar). Con 2, "comodos"
 *     salia "comedor"; los errores de tipeo reales (labtop, camiza,
 *     audifnos, impermiable, laptpo) son de una.
 *   - El plural no es un error: "zapatos" no se corrige a "zapato".
 *
 * Solo corrige hacia palabras que ya estan en el indice. Una palabra que no
 * se parece a nada del catalogo se queda como esta y no hay sugerencia. El
 * indice guarda todos los estados, asi que la palabra sugerida puede venir
 * de un producto que no esta activo.
 */

/** Lo que devuelve Elasticsearch por cada palabra del texto. */
interface EntradaSugerencia {
  offset: number;
  length: number;
  options: { text: string; score: number; freq: number }[];
}

/** El bloque `suggest` de la consulta. `texto` es lo que la persona escribio. */
export function pedirCorreccion(texto: string): estypes.SearchSuggester {
  return {
    text: texto,
    nombre: {
      term: {
        field: 'nombre',
        suggest_mode: 'missing',
        min_word_length: 3,
        max_edits: 1,
      },
    },
  };
}

/**
 * El texto con las palabras mal escritas cambiadas por la mejor sugerencia,
 * o `null` si no hay nada que corregir. Las palabras bien escritas quedan
 * como las escribio la persona.
 */
export function textoCorregido(
  texto: string,
  suggest: Record<string, EntradaSugerencia[]> | undefined,
): string | null {
  const palabras = (suggest?.nombre ?? []).filter(
    (entrada) =>
      entrada.options.length > 0 &&
      !esPlural(
        texto.slice(entrada.offset, entrada.offset + entrada.length),
        entrada.options[0].text,
      ),
  );
  if (palabras.length === 0) {
    return null;
  }

  // De derecha a izquierda para que un cambio no mueva el offset de los demas.
  let corregido = texto;
  for (const entrada of palabras.sort((a, b) => b.offset - a.offset)) {
    // `options` ya viene ordenado por parecido (score) y luego por frecuencia.
    corregido =
      corregido.slice(0, entrada.offset) +
      entrada.options[0].text +
      corregido.slice(entrada.offset + entrada.length);
  }
  return corregido;
}

/** `a` y `b` son la misma palabra en singular y en plural (+s o +es). */
function esPlural(a: string, b: string): boolean {
  const llana = (p: string) =>
    p.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
  const [x, y] = [llana(a), llana(b)];
  return [x + 's', x + 'es'].includes(y) || [y + 's', y + 'es'].includes(x);
}
