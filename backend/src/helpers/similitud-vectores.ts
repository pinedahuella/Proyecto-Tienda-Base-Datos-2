/** Un vector con su norma ya calculada, para comparar muchos pares sin
 * recalcularla. */
export interface VectorConNorma {
  vector: number[];
  norma: number;
}

/** La norma (longitud) de un vector. */
export function norma(vector: number[]): number {
  let suma = 0;
  for (const x of vector) suma += x * x;
  return Math.sqrt(suma);
}

/** El coseno entre dos vectores: 1 si apuntan igual, 0 si no se parecen. */
export function cosenoEntre(a: VectorConNorma, b: VectorConNorma): number {
  let producto = 0;
  for (let i = 0; i < a.vector.length; i++) {
    producto += a.vector[i] * b.vector[i];
  }
  return producto / (a.norma * b.norma);
}

export function media(valores: number[]): number {
  return valores.reduce((s, v) => s + v, 0) / valores.length;
}

/** Elasticsearch puntua una busqueda kNN con coseno como `(1 + coseno) / 2`:
 * esto lo devuelve al coseno, de -1 a 1. */
export function cosenoDePuntaje(puntaje: number | null | undefined): number {
  return 2 * (puntaje ?? 0) - 1;
}

/** A 3 decimales, para guardarlo en el `detalle` de una senal. */
export function redondear(valor: number): number {
  return Math.round(valor * 1000) / 1000;
}

/**
 * Marca cada elemento que tiene al menos una "gemela": otro elemento con el que
 * `sonGemelas` da un valor (no `null`). A diferencia de `agruparPorParecido` no
 * encadena: A y C no quedan juntos porque ambos se parezcan a B, cada uno solo
 * cuenta si tiene su propia gemela. Sirve para medir "que porcentaje de estas
 * resenas tiene una copia" sin que un grupo grande infle el numero. Devuelve
 * tambien el `valor` de cada par que paso la prueba.
 */
export function marcarConGemela(
  cantidad: number,
  sonGemelas: (a: number, b: number) => number | null,
): { conGemela: boolean[]; similitudes: number[] } {
  const conGemela = new Array<boolean>(cantidad).fill(false);
  const similitudes: number[] = [];
  for (let a = 0; a < cantidad; a++) {
    for (let b = a + 1; b < cantidad; b++) {
      const valor = sonGemelas(a, b);
      if (valor != null) {
        conGemela[a] = true;
        conGemela[b] = true;
        similitudes.push(valor);
      }
    }
  }
  return { conGemela, similitudes };
}

/**
 * Une en grupos los elementos que `sonParecidos` relaciona, directa o
 * encadenadamente (union-busqueda). Devuelve, de cada grupo, los indices de
 * sus elementos y los `valor` de los pares que pasaron la prueba dentro de el.
 * Los elementos que no se parecen a ninguno quedan en un grupo de uno.
 */
export function agruparPorParecido(
  cantidad: number,
  sonParecidos: (a: number, b: number) => number | null,
): { indices: number[]; valores: number[] }[] {
  const padre = Array.from({ length: cantidad }, (_, i) => i);
  const raiz = (i: number): number => {
    while (padre[i] !== i) {
      padre[i] = padre[padre[i]];
      i = padre[i];
    }
    return i;
  };

  const pares: { a: number; valor: number }[] = [];
  for (let a = 0; a < cantidad; a++) {
    for (let b = a + 1; b < cantidad; b++) {
      const valor = sonParecidos(a, b);
      if (valor != null) {
        pares.push({ a, valor });
        padre[raiz(a)] = raiz(b);
      }
    }
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
