"""
Paso 1. Convierte cada resena de datos/ en su vector con Ollama.

    python 1_vectorizar.py

Escribe vectores/vectores.json. Si se corre otra vez solo pide a Ollama las
resenas nuevas o editadas (se comparan por id, md5 del texto y modelo), asi que
agregar diez resenas al set no obliga a recalcular las 520.

Al final avisa de los pares de resenas casi iguales. Dos textos que significan
lo mismo, uno en entrenamiento y otro en prueba, inflan la nota del modelo.
"""

import json
import time
from datetime import datetime

import numpy as np

from comun import OLLAMA_MODELO, OLLAMA_URL, VECTORES, cargar_resenas, md5, pedir_vectores

TANDA = 32
CASI_IGUALES = 0.95


def main():
    resenas = cargar_resenas()
    print(f'{len(resenas)} resenas validas '
          f'({sum(r["conjunto"] == "entrenamiento" for r in resenas)} para entrenar, '
          f'{sum(r["conjunto"] == "casos_unicos" for r in resenas)} casos unicos)')

    guardados = {}
    if VECTORES.exists():
        anterior = json.loads(VECTORES.read_text(encoding='utf-8'))
        if anterior.get('modelo_vectores') == OLLAMA_MODELO:
            guardados = {(i['id'], i['md5']): i['vector'] for i in anterior['items']}

    faltan = [r for r in resenas if (r['id'], md5(r['texto'])) not in guardados]
    print(f'Ollama {OLLAMA_URL}, modelo {OLLAMA_MODELO}. Ya calculados {len(resenas) - len(faltan)}, '
          f'por calcular {len(faltan)}')

    inicio = time.time()
    for desde in range(0, len(faltan), TANDA):
        tanda = faltan[desde:desde + TANDA]
        for r, v in zip(tanda, pedir_vectores([r['texto'] for r in tanda])):
            guardados[(r['id'], md5(r['texto']))] = v
        print(f'   {min(desde + TANDA, len(faltan))} de {len(faltan)}')
    if faltan:
        print(f'   {time.time() - inicio:.1f} s')

    items = []
    for r in resenas:
        items.append({
            'id': r['id'], 'conjunto': r['conjunto'], 'etiqueta': r['etiqueta'],
            'estrellas': r['estrellas'], 'categoria': r['categoria'], 'caso': r.get('caso'),
            'md5': md5(r['texto']),
            'vector': [round(x, 7) for x in guardados[(r['id'], md5(r['texto']))]],
        })
    dimensiones = len(items[0]['vector'])
    VECTORES.parent.mkdir(exist_ok=True)
    VECTORES.write_text(json.dumps({
        'modelo_vectores': OLLAMA_MODELO, 'dimensiones': dimensiones, 'normalizado_l2': True,
        'generado': datetime.now().isoformat(timespec='seconds'), 'items': items,
    }, ensure_ascii=False), encoding='utf-8')
    print(f'Escrito {VECTORES.name}: {len(items)} vectores de {dimensiones} numeros')

    # Vectores de largo 1: el producto punto es directamente el parecido (coseno).
    matriz = np.array([i['vector'] for i in items])
    parecido = matriz @ matriz.T
    np.fill_diagonal(parecido, 0)
    pares = [(items[a]['id'], items[b]['id'], parecido[a, b])
             for a, b in zip(*np.where(np.triu(parecido) > CASI_IGUALES))]
    if pares:
        print(f'Ojo, {len(pares)} pares casi iguales (parecido mayor a {CASI_IGUALES}):')
        for a, b, p in sorted(pares, key=lambda x: -x[2])[:15]:
            print(f'   {a} y {b}  {p:.3f}')
    else:
        print(f'Ningun par casi igual (todos los parecidos bajo {CASI_IGUALES})')


if __name__ == '__main__':
    main()
