/** Dos elementos (por su posicion en la lista) que se parecen, y cuanto. */
export interface ParParecido {
  a: number;
  b: number;
  valor: number;
}

export function media(valores: number[]): number {
  return valores.reduce((s, v) => s + v, 0) / valores.length;
}

/** A 3 decimales, para guardarlo en el `detalle` de una senal. */
export function redondear(valor: number): number {
  return Math.round(valor * 1000) / 1000;
}

/**
 * Marca cada elemento que tiene al menos una "gemela": otro elemento con el que
 * forma uno de los `pares`. A diferencia de `agruparPorParecido` no encadena: A
 * y C no quedan juntos porque ambos se parezcan a B, cada uno solo cuenta si
 * tiene su propia gemela. Sirve para medir "que porcentaje de estas resenas
 * tiene una copia" sin que un grupo grande infle el numero. Devuelve tambien el
 * `valor` de cada par.
 */
export function marcarConGemela(
  cantidad: number,
  pares: ParParecido[],
): { conGemela: boolean[]; similitudes: number[] } {
  const conGemela = new Array<boolean>(cantidad).fill(false);
  for (const par of pares) {
    conGemela[par.a] = true;
    conGemela[par.b] = true;
  }
  return { conGemela, similitudes: pares.map((par) => par.valor) };
}

/**
 * Une en grupos los elementos que los `pares` relacionan, directa o
 * encadenadamente (union-busqueda). Devuelve, de cada grupo, los indices de
 * sus elementos y los `valor` de los pares dentro de el. Los elementos que no
 * forman ningun par quedan en un grupo de uno.
 */
export function agruparPorParecido(
  cantidad: number,
  pares: ParParecido[],
): { indices: number[]; valores: number[] }[] {
  const padre = Array.from({ length: cantidad }, (_, i) => i);
  const raiz = (i: number): number => {
    while (padre[i] !== i) {
      padre[i] = padre[padre[i]];
      i = padre[i];
    }
    return i;
  };

  for (const par of pares) {
    padre[raiz(par.a)] = raiz(par.b);
  }

  const porRaiz = new Map<number, { indices: number[]; valores: number[] }>();
  for (let i = 0; i < cantidad; i++) {
    const r = raiz(i);
    const grupo = porRaiz.get(r) ?? { indices: [], valores: [] };
    grupo.indices.push(i);
    porRaiz.set(r, grupo);
  }
  for (const par of pares) {
    porRaiz.get(raiz(par.a))?.valores.push(par.valor);
  }
  return [...porRaiz.values()];
}
