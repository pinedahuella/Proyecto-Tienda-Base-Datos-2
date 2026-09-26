"""recomendacion_semantica.py -- la evidencia de la recomendacion por contenido (Entrega final).

Uso:  python pruebas/recomendacion_semantica.py

Necesita PostgreSQL y MongoDB arriba y los vectores ya cargados por
etl/cargar_vectores.ps1 (o por .\\arrancar.ps1, que lo corre). No necesita el
backend ni Ollama, porque prueba lo que ya quedo guardado y la funcion
productos_similares() de la migracion 024, que es lo unico que la ruta del
backend tiene que llamar.

Que se comprueba
  1. Cada producto de MongoDB tiene su vector, y ninguno sobra.
  2. Los parecidos de un producto son de su misma categoria mucho mas seguido
     de lo que daria el azar. El control es ese azar, medido con los mismos
     productos, no un numero supuesto.
  3. La funcion no devuelve el propio producto ni productos inactivos.
  4. Un producto sin vector no rompe nada, devuelve vacio.

Solo usa la biblioteca estandar. Sale con 1 si algo falla.
"""
import json
import os
import random
import subprocess
import sys

RAIZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
OKS = 0
FALLAS = 0


def leer_env():
    env = {}
    with open(os.path.join(RAIZ, '.env'), encoding='utf-8') as f:
        for linea in f:
            linea = linea.strip()
            if linea and not linea.startswith('#') and '=' in linea:
                k, v = linea.split('=', 1)
                env[k.strip()] = v.strip()
    return env


ENV = leer_env()


def sql(consulta):
    r = subprocess.run(['docker', 'exec', '-i', 'mesh-postgres', 'psql', '-U', ENV['DB_USER'], '-d', ENV['DB_NAME'],
                        '-qtAX', '-v', 'ON_ERROR_STOP=1', '-c', consulta],
                       capture_output=True, text=True, encoding='utf-8')
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return [l for l in r.stdout.splitlines() if l.strip()]


def mongo_categorias():
    js = ("db.productos.find({}, {'categoria.nombre': 1, estado: 1}).forEach(function (d) {"
          " print(JSON.stringify({ id: d._id, cat: (d.categoria && d.categoria.nombre) || '', activo: d.estado === 'activo' })); });")
    cmd = ('mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" '
           '--authenticationDatabase admin "$MONGO_INITDB_DATABASE" --eval ' + json.dumps(js))
    r = subprocess.run(['docker', 'exec', 'mesh-mongo', 'sh', '-c', cmd], capture_output=True, text=True, encoding='utf-8')
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    out = {}
    for linea in r.stdout.splitlines():
        if linea.startswith('{'):
            d = json.loads(linea)
            out[int(d['id'])] = d
    return out


def revisar(cond, que):
    global OKS, FALLAS
    if cond:
        OKS += 1
        print('  OK     ' + que)
    else:
        FALLAS += 1
        print('  FALLA  ' + que)


def similares(pid, limite=6):
    return [int(l.split('|')[0]) for l in sql('SELECT id_producto || \'|\' || similitud FROM productos_similares(%d, %d);' % (pid, limite))]


def main():
    print('1. Cada producto tiene su vector')
    cat = mongo_categorias()
    con_vector = set(int(x) for x in sql('SELECT id_producto FROM producto_vector;'))
    revisar(len(cat) > 0, '%d productos en MongoDB' % len(cat))
    revisar(con_vector == set(cat), '%d vectores, uno por producto, ninguno de mas' % len(con_vector))
    dims = sql('SELECT DISTINCT vector_dims(vector) FROM producto_vector;')
    revisar(dims == ['768'], 'todos con 768 dimensiones')
    modelos = sql('SELECT DISTINCT modelo FROM producto_vector;')
    revisar(len(modelos) == 1, 'todos del mismo modelo, %s' % (modelos[0] if modelos else '?'))

    print('2. Los parecidos son de la misma categoria mucho mas que al azar')
    activos = [p for p, d in cat.items() if d['activo'] and p in con_vector]
    random.seed(25)
    muestra = random.sample(activos, min(60, len(activos)))
    misma = total = 0
    for p in muestra:
        for s in similares(p):
            total += 1
            misma += cat.get(s, {}).get('cat') == cat[p]['cat']
    tasa = misma / total if total else 0
    # El azar, con los mismos productos: la chance de que un activo cualquiera caiga en la categoria del de la muestra.
    por_cat = {}
    for p in activos:
        por_cat[cat[p]['cat']] = por_cat.get(cat[p]['cat'], 0) + 1
    azar = sum(por_cat[cat[p]['cat']] / len(activos) for p in muestra) / len(muestra)
    # Sin las copias del generador quedan unos 106 productos distintos, unos 6 por
    # categoria, asi que de 6 parecidos a lo sumo 5 pueden ser de la misma. Por
    # eso el piso es la mitad y lo que de verdad dice algo es el control de abajo.
    revisar(tasa >= 0.5, 'en %d productos, el %d %% de sus parecidos es de su categoria' % (len(muestra), round(tasa * 100)))
    revisar(tasa > 5 * azar, 'control, al azar seria el %d %%' % round(azar * 100))

    print('3. Lo que la funcion no devuelve')
    revisar(all(p not in similares(p) for p in muestra[:20]), 'nunca el propio producto')
    inactivos = set(int(x) for x in sql('SELECT id_producto FROM producto_vector WHERE NOT activo;'))
    vistos = set()
    for p in muestra[:20]:
        vistos.update(similares(p, 24))
    revisar(not (vistos & inactivos), 'ningun inactivo entre %d parecidos (hay %d inactivos con vector)' % (len(vistos), len(inactivos)))
    revisar(all(len(similares(p)) == 6 for p in muestra[:10]), 'devuelve los 6 que se piden')
    revisar(len(similares(muestra[0], 999)) <= 24, 'pedir 999 no trae mas de 24')

    print('3b. Las copias del mismo producto no cuentan como parecidos')
    grupos = dict((int(l.split('|')[0]), l.split('|')[1]) for l in sql("SELECT id_producto || '|' || COALESCE(grupo, '') FROM producto_vector;"))
    revisar(all(grupos.get(i) for i in con_vector), 'cada vector tiene su grupo')
    copias = distintos = True
    for p in muestra[:20]:
        s = similares(p)
        copias &= all(grupos[x] != grupos[p] for x in s)
        distintos &= len(set(grupos[x] for x in s)) == len(s)
    revisar(copias, 'ningun parecido es una copia del producto')
    revisar(distintos, 'y ninguno se repite, uno por grupo')
    con_copias = [g for g in set(grupos.values()) if list(grupos.values()).count(g) > 1]
    revisar(len(con_copias) > 0, 'control, el catalogo si tiene copias, %d grupos con mas de un producto' % len(con_copias))

    print('4. Un producto sin vector')
    revisar(similares(99999999) == [], 'devuelve vacio y no falla')

    ejemplo = muestra[0]
    print()
    print('Ejemplo, producto %d (%s)' % (ejemplo, cat[ejemplo]['cat']))
    for l in sql('SELECT id_producto || \'  \' || round(similitud::numeric, 3) FROM productos_similares(%d, 6);' % ejemplo):
        pid = int(l.split()[0])
        print('   ', l, cat.get(pid, {}).get('cat'))

    print()
    print('%d OK, %d FALLA' % (OKS, FALLAS))
    sys.exit(1 if FALLAS else 0)


if __name__ == '__main__':
    main()
