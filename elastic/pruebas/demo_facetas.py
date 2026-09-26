"""demo_facetas.py -- los filtros facetados y la tolerancia del buscador, para ensenar en clase.

Uso:  python elastic/pruebas/demo_facetas.py [texto]      (por defecto laptop)
      .\\demo-entrega-final.ps1 -Parte facetas -Texto laptop

Usa la misma consulta que facetas.py, que es la que tiene que mandar la ruta del
backend, contra el indice real. Solo lee. Necesita Elasticsearch arriba.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from facetas import autocompletar, buscar, consulta, facetas, total  # noqa: E402

NOMBRES_PRECIO = {
    'hasta-250': 'hasta Q250', '250-500': 'Q250 a Q500', '500-1000': 'Q500 a Q1000',
    '1000-3000': 'Q1000 a Q3000', 'desde-3000': 'desde Q3000',
}


def pintar(f, t):
    print('   %d resultados' % t)
    print('   Categoria')
    for cid, c in sorted(f['categoria'].items(), key=lambda kv: -kv[1]['cantidad'])[:8]:
        print('      %-30s %5d' % (c['nombre'][:30], c['cantidad']))
    print('   Precio')
    for k, n in f['precio'].items():
        print('      %-30s %5d' % (NOMBRES_PRECIO.get(k, k), n))
    print('   Calificacion')
    for k, n in f['calificacion'].items():
        print('      %-30s %5d' % (k.replace('-o-mas', ' estrellas o mas'), n))
    print('   Con existencias                %5d' % f['disponible'])


def nombres(resp, n=5):
    return [h['_source'].get('nombre', '?') for h in resp['hits']['hits'][:n]]


def main():
    texto = sys.argv[1] if len(sys.argv) > 1 else 'laptop'
    try:
        r0 = buscar(consulta(texto))
    except Exception as e:  # noqa: BLE001
        print('   Elasticsearch no contesto. Corre .\\arrancar.ps1  (%s)' % e)
        return 1

    print('\n>> 1. Buscando "%s", sin filtros' % texto)
    f0, t0 = facetas(r0), total(r0)
    if t0 == 0:
        print('   No hay resultados para "%s". Prueba con otra palabra' % texto)
        return 1
    pintar(f0, t0)
    print('   Cada numero sale de una agregacion del indice en la misma consulta')

    cid, cat = max(f0['categoria'].items(), key=lambda kv: kv[1]['cantidad'])
    print('\n>> 2. Eligiendo la categoria %s' % cat['nombre'])
    r1 = buscar(consulta(texto, {'categoria': [cid]}))
    f1 = facetas(r1)
    pintar(f1, total(r1))
    print('   La categoria sigue mostrando las otras opciones, para poder sumar una segunda.')
    print('   El precio y la calificacion ya se recortaron a esa categoria')

    rango = max(f1['precio'].items(), key=lambda kv: kv[1])[0]
    print('\n>> 3. Sumando el precio %s' % NOMBRES_PRECIO.get(rango, rango))
    r2 = buscar(consulta(texto, {'categoria': [cid], 'precio': [rango]}))
    print('   %d resultados, los mismos que prometia la faceta (%d)' % (total(r2), f1['precio'][rango]))
    for n in nombres(r2):
        print('      ' + n)

    mal = texto[:-2] + texto[-1] + texto[-2] if len(texto) > 3 else texto + 'x'
    print('\n>> 4. Escrito mal, "%s"' % mal)
    r3 = buscar(consulta(mal))
    print('   %d resultados. Los primeros' % total(r3))
    for n in nombres(r3):
        print('      ' + n)

    prefijo = texto[:3]
    print('\n>> 5. Autocompletar mientras se escribe "%s"' % prefijo)
    r4 = buscar(autocompletar(prefijo))
    for n in nombres(r4, 8):
        print('      ' + n)
    print()
    return 0


if __name__ == '__main__':
    sys.exit(main())
