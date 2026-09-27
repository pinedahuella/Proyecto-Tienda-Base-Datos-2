/**
 * Union-Find (union y busqueda) generico, sobre numeros. Usado por
 * `AgrupadorFraudeService` para juntar cuentas conectadas transitivamente
 * -- si A comparte un hallazgo con B, y B con C, A y C terminan en el
 * mismo grupo aunque nunca hayan compartido un hallazgo directo entre
 * ellas.
 *
 * Con compresion de camino: cada `encontrar()` deja los nodos que
 * recorrio apuntando directo a la raiz, para que la siguiente busqueda
 * sobre esos mismos nodos sea O(1).
 */
export class UnionFind {
  private readonly padre = new Map<number, number>();

  /** La raiz del grupo de `x`. Si `x` no se habia visto, nace como su
   * propio grupo de un solo elemento. */
  encontrar(x: number): number {
    if (!this.padre.has(x)) {
      this.padre.set(x, x);
      return x;
    }

    let raiz = x;
    while (this.padre.get(raiz) !== raiz) {
      raiz = this.padre.get(raiz)!;
    }

    let actual = x;
    while (this.padre.get(actual) !== raiz) {
      const siguiente = this.padre.get(actual)!;
      this.padre.set(actual, raiz);
      actual = siguiente;
    }

    return raiz;
  }

  /** Junta los grupos de `a` y `b` en uno solo. */
  unir(a: number, b: number): void {
    const raizA = this.encontrar(a);
    const raizB = this.encontrar(b);
    if (raizA !== raizB) {
      this.padre.set(raizA, raizB);
    }
  }
}
