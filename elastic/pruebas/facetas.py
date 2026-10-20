"""facetas.py -- la consulta de los filtros facetados del buscador, y su prueba.

Uso:  python elastic/pruebas/facetas.py            corre las comprobaciones
      python elastic/pruebas/facetas.py --ejemplo  escribe elastic/consultas/facetas_ejemplo.json

Necesita solo Elasticsearch arriba (localhost:9200, o la variable ES_URL).
Solo usa la biblioteca estandar.

`consulta()` es la referencia para el backend. Arma el cuerpo que va a
POST /mesh_productos/_search y es lo que la ruta tiene que mandar, tal cual.

Como funciona, en corto
- El texto va en el `must` de la consulta, difuso, como en BuscadorService.
- Los filtros elegidos van en el `filter` de la misma consulta, junto con el de
  activo. Asi se filtra ANTES de agregar: las agregaciones cuentan solo lo que
  paso todos los filtros, y cada numero del panel es cuantos resultados hay de
  verdad con esa opcion sumada a lo ya elegido. Dentro de una faceta las
  opciones se suman con OR, entre facetas con AND.
- Hasta el 2026-10-20 los filtros iban en `post_filter` (despues de agregar) y
  cada faceta se contaba con los filtros de las otras. El profesor lo observo:
  si el filtro ya se sabe, se filtra antes y no despues en los agregados. La
  contra, aceptada: con una categoria elegida las demas salen del panel.

Cada comprobacion tiene su control. Sale con 1 si algo falla.
"""
import json
import os
import sys
import urllib.request

ES = os.environ.get('ES_URL', 'http://localhost:9200')
INDICE = 'mesh_productos'
FALLAS = 0
OKS = 0

# Los cortes salen de los percentiles medidos el 2026-09-25 sobre 3105
# productos activos. La mediana de precio_desde es 496 y el percentil 90 es 3500.
RANGOS_PRECIO = [
    {'key': 'hasta-250', 'to': 250},
    {'key': '250-500', 'from': 250, 'to': 500},
    {'key': '500-1000', 'from': 500, 'to': 1000},
    {'key': '1000-3000', 'from': 1000, 'to': 3000},
    {'key': 'desde-3000', 'from': 3000},
]
RANGOS_NOTA = [
    {'key': '4-o-mas', 'from': 4},
    {'key': '3-o-mas', 'from': 3},
]


def filtro_de(faceta, valores):
    """El filtro de UNA faceta, con sus valores sumados con OR. None si no hay nada elegido."""
    if not valores:
        return None
    if faceta == 'categoria':
        return {'terms': {'id_categoria': [int(v) for v in valores]}}
    if faceta == 'precio':
        rangos = {r['key']: r for r in RANGOS_PRECIO}
        return {'bool': {'should': [
            {'range': {'precio_desde': {k2: rangos[v][k] for k, k2 in (('from', 'gte'), ('to', 'lt')) if k in rangos[v]}}}
            for v in valores], 'minimum_should_match': 1}}
    if faceta == 'calificacion':
        # Las dos opciones se contienen, 4 o mas esta dentro de 3 o mas, asi que vale la mas baja.
        minimo = min(float(v.split('-')[0]) for v in valores)
        return {'range': {'resenas_promedio': {'gte': minimo}}}
    if faceta == 'disponible':
        return {'range': {'stock_total': {'gt': 0}}}
    raise ValueError(faceta)


FACETAS = ('categoria', 'precio', 'calificacion', 'disponible')


def consulta(texto, elegidos=None, tamano=20):
    """El cuerpo de la busqueda. `elegidos` es {'categoria': ['7'], 'precio': ['250-500'], ...}."""
    elegidos = elegidos or {}
    filtros = [q for q in (filtro_de(f, elegidos.get(f)) for f in FACETAS) if q is not None]
    texto_q = {'multi_match': {'query': texto, 'fields': ['nombre^3', 'descripcion', 'variantes'], 'fuzziness': 'AUTO'}}
    return {
        'size': tamano,
        'query': {'bool': {'must': [texto_q], 'filter': [{'term': {'estado': 'activo'}}] + filtros}},
        'aggs': {
            'categoria': {
                'terms': {'field': 'id_categoria', 'size': 50},
                'aggs': {'nombre': {'terms': {'field': 'categoria_nombre.exacto', 'size': 1}}},
            },
            'precio': {'range': {'field': 'precio_desde', 'keyed': True, 'ranges': RANGOS_PRECIO}},
            'calificacion': {'range': {'field': 'resenas_promedio', 'keyed': True, 'ranges': RANGOS_NOTA}},
            'disponible': {'filter': {'range': {'stock_total': {'gt': 0}}}},
        },
    }


def autocompletar(prefijo, tamano=8):
    """Sugerencias mientras se escribe, sobre el campo search_as_you_type que el mapeo ya trae."""
    return {
        'size': tamano,
        '_source': ['nombre'],
        'query': {'bool': {
            'must': [{'multi_match': {'query': prefijo, 'type': 'bool_prefix',
                                      'fields': ['nombre.escribiendo', 'nombre.escribiendo._2gram', 'nombre.escribiendo._3gram']}}],
            'filter': [{'term': {'estado': 'activo'}}],
        }},
    }


def buscar(cuerpo):
    req = urllib.request.Request(ES + '/' + INDICE + '/_search', data=json.dumps(cuerpo).encode('utf-8'),
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def facetas(resp):
    """La respuesta de ES en la forma que tendria que devolver la ruta."""
    a = resp['aggregations']
    return {
        'categoria': {str(b['key']): {'nombre': (b['nombre']['buckets'] or [{'key': '?'}])[0]['key'], 'cantidad': b['doc_count']}
                      for b in a['categoria']['buckets']},
        'precio': {k: v['doc_count'] for k, v in a['precio']['buckets'].items()},
        'calificacion': {k: v['doc_count'] for k, v in a['calificacion']['buckets'].items()},
        'disponible': a['disponible']['doc_count'],
    }


def total(resp):
    return resp['hits']['total']['value']


def revisar(cond, que):
    global FALLAS, OKS
    if cond:
        OKS += 1
        print('  OK     ' + que)
    else:
        FALLAS += 1
        print('  FALLA  ' + que)


def main():
    if '--ejemplo' in sys.argv:
        destino = os.path.join(os.path.dirname(__file__), '..', 'consultas', 'facetas_ejemplo.json')
        os.makedirs(os.path.dirname(destino), exist_ok=True)
        with open(destino, 'w', encoding='utf-8') as f:
            json.dump(consulta('laptop', {'categoria': ['7'], 'precio': ['1000-3000', 'desde-3000']}), f, ensure_ascii=False, indent=2)
            f.write('\n')
        print('escrito ' + os.path.normpath(destino))
        return

    texto = 'laptop'
    print('1. Sin nada elegido, buscando "%s"' % texto)
    r0 = buscar(consulta(texto))
    f0 = facetas(r0)
    t0 = total(r0)
    revisar(t0 > 0, '%d resultados' % t0)
    revisar(sum(v['cantidad'] for v in f0['categoria'].values()) == t0,
            'las categorias suman el total, cada producto esta en una sola')
    revisar(sum(f0['precio'].values()) == t0, 'los rangos de precio suman el total, no se pisan ni dejan huecos')
    revisar(f0['calificacion']['4-o-mas'] <= f0['calificacion']['3-o-mas'], '4 o mas cabe dentro de 3 o mas')
    revisar(f0['disponible'] <= t0, 'con existencias no pasa del total')

    cat_id, cat = max(f0['categoria'].items(), key=lambda kv: kv[1]['cantidad'])
    print('2. Eligiendo la categoria %s (%s)' % (cat['nombre'], cat_id))
    c1 = consulta(texto, {'categoria': [cat_id]})
    revisar('post_filter' not in c1 and {'terms': {'id_categoria': [int(cat_id)]}} in c1['query']['bool']['filter'],
            'el filtro va en la consulta, no en un post_filter')
    r1 = buscar(c1)
    f1 = facetas(r1)
    revisar(total(r1) == cat['cantidad'], 'los resultados son los que prometia la faceta, %d' % cat['cantidad'])
    revisar(list(f1['categoria']) == [cat_id] and f1['categoria'][cat_id]['cantidad'] == total(r1),
            'la faceta de categoria ya se cuenta con el filtro: solo queda la elegida, con %d' % total(r1))
    revisar(sum(f1['precio'].values()) == total(r1), 'la de precio tambien, suma %d' % total(r1))
    revisar(f1['disponible'] <= total(r1), 'con existencias no pasa de lo filtrado')
    revisar(all(h['_source']['id_categoria'] == int(cat_id) for h in r1['hits']['hits']), 'cada resultado es de esa categoria')

    otras = [k for k in f0['categoria'] if k != cat_id]
    if otras:
        dos = [cat_id, otras[0]]
        r2 = buscar(consulta(texto, {'categoria': dos}))
        f2 = facetas(r2)
        revisar(total(r2) == cat['cantidad'] + f0['categoria'][otras[0]]['cantidad'],
                'dos categorias se suman con OR, %d' % total(r2))
        revisar(sorted(f2['categoria']) == sorted(dos), 'y la faceta muestra justo esas dos')

    rango = max(f1['precio'].items(), key=lambda kv: kv[1])[0]
    print('3. Sumando el precio %s' % rango)
    r3 = buscar(consulta(texto, {'categoria': [cat_id], 'precio': [rango]}))
    f3 = facetas(r3)
    revisar(total(r3) == f1['precio'][rango], 'categoria Y precio da lo que prometia la faceta de precio, %d' % total(r3))
    revisar(f3['categoria'][cat_id]['cantidad'] == total(r3), 'la faceta de categoria ya mira el precio elegido')
    revisar(all(v == 0 for k, v in f3['precio'].items() if k != rango), 'los otros rangos de precio quedan en 0')
    revisar(all(h['_source']['id_categoria'] == int(cat_id) for h in r3['hits']['hits']), 'control, siguen siendo de la categoria')

    print('4. Solo con existencias')
    r4 = buscar(consulta(texto, {'disponible': ['si']}))
    revisar(total(r4) == f0['disponible'], 'da lo que prometia la faceta, %d' % total(r4))
    revisar(facetas(r4)['disponible'] == total(r4), 'y ya todos los que quedan tienen existencias')
    revisar(all(h['_source']['stock_total'] > 0 for h in r4['hits']['hits']), 'ninguno sin existencias')

    print('5. La tolerancia sigue funcionando con facetas')
    r5 = buscar(consulta('labtop'))
    f5 = facetas(r5)
    top = max(f5['categoria'].values(), key=lambda v: v['cantidad'])['nombre'] if f5['categoria'] else None
    revisar(top == 'Laptops', '"labtop" encuentra sobre todo Laptops')
    r6 = buscar(consulta('zzqxw'))
    revisar(total(r6) == 0 and not facetas(r6)['categoria'], 'control, un texto sin sentido no trae ni resultados ni facetas')

    print('6. Autocompletado sobre nombre.escribiendo')
    sugeridos = [h['_source']['nombre'] for h in buscar(autocompletar('lap'))['hits']['hits']]
    revisar(sugeridos and all(s.lower().startswith('lap') for s in sugeridos), '"lap" sugiere %s' % (sugeridos[:3],))
    hoy = buscar({'size': 5, 'query': {'multi_match': {'query': 'lap', 'fields': ['nombre^3', 'descripcion', 'variantes'], 'fuzziness': 'AUTO'}}})
    revisar(total(hoy) == 0 or not all(h['_source']['nombre'].lower().startswith('lap') for h in hoy['hits']['hits']),
            'control, la busqueda de hoy con "lap" no sabe completar, trae %d' % total(hoy))

    print()
    print('%d OK, %d FALLA' % (OKS, FALLAS))
    sys.exit(1 if FALLAS else 0)


if __name__ == '__main__':
    main()
