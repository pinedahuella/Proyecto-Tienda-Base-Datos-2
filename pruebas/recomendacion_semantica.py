"""recomendacion_semantica.py -- la evidencia de la recomendacion por contenido (Entrega final).

Uso:  python pruebas/recomendacion_semantica.py

Necesita PostgreSQL, MongoDB y el backend arriba, y los vectores ya
cargados por etl/cargar_vectores.ps1 (o por .\\arrancar.ps1, que lo corre). No
necesita Ollama, porque prueba lo que ya quedo guardado.

Donde vivio el vector de cada producto: producto_vector de PostgreSQL hasta el
2026-10-02, su documento de mesh_productos (Elasticsearch, kNN) hasta el
2026-10-16, y desde entonces la tabla vector_producto (migracion 040,
pgvector, a pedido del profesor). La consulta esta en el backend, asi que los
parecidos se piden a la ruta que usa la ficha, GET /productos/:id/similares, y
PostgreSQL solo se mira.

Que se comprueba
  1. Cada producto de producto_catalogo tiene su vector, de 768 y del mismo
     modelo, y cada producto de MongoDB esta en producto_catalogo.
  2. Solo por el vector, sin mirar la categoria, los vecinos de un producto
     son de su misma categoria mucho mas seguido de lo que daria el azar. El
     control es ese azar, medido con los mismos productos, no un numero
     supuesto. Se calcula en PostgreSQL contra todos (exacto), porque desde el
     2026-11-05 la ruta ya pone primero su categoria y su cifra no diria nada
     del modelo.
  2b. Van por bloques, como tambien-compraron (desde el 2026-11-05): primero
     todos los de su categoria y despues el resto, cada bloque del mas
     parecido al menos, y misma_categoria dice la verdad.
  3. La ruta no devuelve el propio producto ni productos inactivos.
  4. Un producto sin vector no rompe nada, devuelve vacio.

Solo usa la biblioteca estandar. Sale con 1 si algo falla.
"""
import json
import os
import random
import subprocess
import sys
import urllib.error
import urllib.request

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
BACKEND = os.environ.get('BACKEND', 'http://localhost:3000')


def comando_docker():
    """En el modo remoto (remoto/README.md) docker es un script de Git Bash, que
    Python no puede correr directo en Windows: se le pasa al bash de Git, con la
    ruta entera, porque un bash suelto puede ser el de WSL (System32)."""
    if not os.environ.get('MESH_REMOTO'):
        return ['docker']
    for base in (os.environ.get('ProgramFiles', ''), os.environ.get('ProgramFiles(x86)', '')):
        bash = os.path.join(base, 'Git', 'bin', 'bash.exe')
        if os.path.isfile(bash):
            return [bash, os.path.join(RAIZ, 'remoto', 'bin', 'docker')]
    raise RuntimeError('el modo remoto necesita Git Bash (C:/Program Files/Git)')


DOCKER = comando_docker()


def pedir(url, cuerpo=None):
    datos = json.dumps(cuerpo).encode('utf-8') if cuerpo is not None else None
    req = urllib.request.Request(url, data=datos, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode('utf-8'))


def documentos():
    """id -> {grupo, modelo, dims, tiene} de cada producto de producto_catalogo.

    Se mira PostgreSQL, sin traer los vectores: vector_dims() dice el largo de
    cada uno, y un producto sin fila en vector_producto sale con tiene=False."""
    sql = ("SELECT pc.id_producto_mongo || '|' || coalesce(v.grupo, '') || '|' || coalesce(v.modelo, '') || '|' || "
           "coalesce(vector_dims(v.vector)::text, '0') FROM producto_catalogo pc "
           "LEFT JOIN vector_producto v USING (id_producto_mongo);")
    r = subprocess.run(DOCKER + ['exec', 'mesh-postgres', 'psql', '-U', ENV['DB_USER'], '-d', ENV['DB_NAME'],
                        '-qtAX', '-c', sql], capture_output=True, text=True, encoding='utf-8')
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    out = {}
    for linea in r.stdout.splitlines():
        c = linea.strip().split('|')
        if len(c) == 4:
            out[int(c[0])] = {'grupo': c[1] or None, 'modelo': c[2] or None, 'dims': int(c[3]), 'tiene': c[3] != '0'}
    return out


def vecinos_solo_vector(ids):
    """id -> los 6 vecinos mas cercanos por coseno, uno por grupo, sin mirar la
    categoria: lo que devolvia la ruta antes del orden por bloques. Contra todos
    (DISTINCT ON por grupo y despues los 6 de menor distancia), sin indice."""
    sql = ("SELECT b.id_producto_mongo || '|' || string_agg(x.id::text, ',' ORDER BY x.d) "
           "FROM vector_producto b CROSS JOIN LATERAL ("
           " SELECT id, d FROM ("
           "  SELECT DISTINCT ON (v.grupo) v.id_producto_mongo AS id, v.vector <=> b.vector AS d"
           "    FROM vector_producto v"
           "   WHERE v.activo AND v.id_producto_mongo <> b.id_producto_mongo AND v.grupo <> b.grupo"
           "   ORDER BY v.grupo, v.vector <=> b.vector) u"
           " ORDER BY d LIMIT 6) x "
           "WHERE b.id_producto_mongo IN (%s) GROUP BY b.id_producto_mongo;" % ','.join(str(i) for i in ids))
    r = subprocess.run(DOCKER + ['exec', 'mesh-postgres', 'psql', '-U', ENV['DB_USER'], '-d', ENV['DB_NAME'],
                        '-qtAX', '-c', sql], capture_output=True, text=True, encoding='utf-8')
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    out = {}
    for linea in r.stdout.splitlines():
        c = linea.strip().split('|')
        if len(c) == 2 and c[1]:
            out[int(c[0])] = [int(x) for x in c[1].split(',')]
    return out


def mongo_categorias():
    js = ("db.productos.find({}, {'categoria.nombre': 1, estado: 1}).forEach(function (d) {"
          " print(JSON.stringify({ id: d._id, cat: (d.categoria && d.categoria.nombre) || '', activo: d.estado === 'activo' })); });")
    cmd = ('mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" '
           '--authenticationDatabase admin "$MONGO_INITDB_DATABASE" --eval ' + json.dumps(js))
    r = subprocess.run(DOCKER + ['exec', 'mesh-mongo', 'sh', '-c', cmd], capture_output=True, text=True, encoding='utf-8')
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


def similares_con_nota(pid):
    try:
        r = pedir('%s/productos/%d/similares' % (BACKEND, pid))
    except urllib.error.HTTPError as e:
        raise RuntimeError('la ruta contesto %d para el producto %d' % (e.code, pid))
    return [(int(f['id_producto']), f['similitud']) for f in r['payload']]


def similares(pid):
    return [i for i, _ in similares_con_nota(pid)]


def similares_con_bloque(pid):
    try:
        r = pedir('%s/productos/%d/similares' % (BACKEND, pid))
    except urllib.error.HTTPError as e:
        raise RuntimeError('la ruta contesto %d para el producto %d' % (e.code, pid))
    return [(int(f['id_producto']), f['similitud'], f.get('misma_categoria')) for f in r['payload']]


def main():
    try:
        pedir(BACKEND + '/vectores')
    except Exception as e:
        print('El backend no contesta en %s (%s). Levantalo con panel-comandos\\servicios.ps1' % (BACKEND, e))
        sys.exit(2)

    print('1. Cada producto tiene su vector')
    cat = mongo_categorias()
    docs = documentos()
    con_vector = set(i for i, d in docs.items() if d['tiene'])
    revisar(len(cat) > 0, '%d productos en MongoDB' % len(cat))
    revisar(set(cat) <= set(docs), '%d productos en producto_catalogo, todos los de MongoDB' % len(docs))
    revisar(con_vector == set(docs), '%d con vector en vector_producto, todos los del catalogo' % len(con_vector))
    revisar(all(docs[i]['dims'] == 768 for i in con_vector), 'todos con 768 dimensiones (vector_dims)')
    modelos = set(d['modelo'] for d in docs.values() if d['tiene'])
    revisar(len(modelos) == 1, 'todos del mismo modelo, %s' % ', '.join(str(m) for m in modelos))

    print('2. Solo por el vector, los vecinos son de la misma categoria mucho mas que al azar')
    activos = [p for p, d in cat.items() if d['activo'] and p in con_vector]
    random.seed(25)
    muestra = random.sample(activos, min(60, len(activos)))
    vecinos = vecinos_solo_vector(muestra)
    revisar(set(vecinos) == set(muestra), 'PostgreSQL calculo los vecinos de los %d, contra todos' % len(muestra))
    misma = total = 0
    for p in muestra:
        for s_ in vecinos.get(p, []):
            total += 1
            misma += cat.get(s_, {}).get('cat') == cat[p]['cat']
    tasa = misma / total if total else 0
    # El azar, con los mismos productos: la chance de que un activo cualquiera caiga en la categoria del de la muestra.
    por_cat = {}
    for p in activos:
        por_cat[cat[p]['cat']] = por_cat.get(cat[p]['cat'], 0) + 1
    azar = sum(por_cat[cat[p]['cat']] / len(activos) for p in muestra) / len(muestra)
    # Sin las copias del generador quedan unos 106 productos distintos, unos 6 por
    # categoria, asi que de 6 parecidos a lo sumo 5 pueden ser de la misma. Por
    # eso el piso es la mitad y lo que de verdad dice algo es el control de abajo.
    revisar(tasa >= 0.5, 'en %d productos, el %d %% de sus 6 vecinos es de su categoria' % (len(muestra), round(tasa * 100)))
    revisar(tasa > 5 * azar, 'control, al azar seria el %d %%' % round(azar * 100))

    print('2b. Primero los de su categoria, despues el resto')
    grupo_de = dict((i, d['grupo']) for i, d in docs.items())
    en_orden = dice_verdad = completos = bajando = True
    con_resto = 0
    for p in muestra:
        lista = similares_con_bloque(p)
        banderas = [m for _, _, m in lista]
        # Ningun True despues de un False: el bloque de su categoria va entero delante.
        en_orden &= banderas == sorted(banderas, key=lambda m: not m)
        dice_verdad &= all(m == (cat.get(i, {}).get('cat') == cat[p]['cat']) for i, _, m in lista)
        # Cuantos grupos distintos de su categoria podian salir: activos, con vector y no de su grupo.
        posibles = set(grupo_de[i] for i in activos
                       if i != p and cat[i]['cat'] == cat[p]['cat'] and grupo_de[i] != grupo_de[p])
        completos &= sum(1 for m in banderas if m) == min(6, len(posibles))
        for bloque in (True, False):
            notas = [s for _, s, m in lista if m == bloque]
            bajando &= all(a >= b for a, b in zip(notas, notas[1:]))
        con_resto += any(not m for m in banderas)
    revisar(en_orden, 'en los %d, el bloque de su categoria va delante y despues el resto' % len(muestra))
    revisar(dice_verdad, 'misma_categoria coincide con la categoria de MongoDB en cada parecido')
    revisar(completos, 'el primer bloque trae todos los de su categoria que caben, hasta 6, uno por grupo')
    revisar(bajando, 'dentro de cada bloque, del mas parecido al menos')
    revisar(con_resto > 0, 'control, en %d de %d el segundo bloque si trae otras categorias' % (con_resto, len(muestra)))

    print('3. Lo que la ruta no devuelve')
    revisar(all(p not in similares(p) for p in muestra[:20]), 'nunca el propio producto')
    inactivos = set(i for i, d in cat.items() if not d['activo'] and i in con_vector)
    vistos = set()
    for p in muestra[:20]:
        vistos.update(similares(p))
    revisar(not (vistos & inactivos), 'ningun inactivo entre %d parecidos (hay %d inactivos con vector)' % (len(vistos), len(inactivos)))
    revisar(all(len(similares(p)) == 6 for p in muestra[:10]), 'devuelve los 6 de la ficha')

    print('3b. Las copias del mismo producto no cuentan como parecidos')
    grupos = dict((i, d['grupo']) for i, d in docs.items())
    revisar(all(grupos.get(i) for i in con_vector), 'cada vector tiene su grupo')
    copias = distintos = True
    for p in muestra[:20]:
        s_ = similares(p)
        copias &= all(grupos[x] != grupos[p] for x in s_)
        distintos &= len(set(grupos[x] for x in s_)) == len(s_)
    revisar(copias, 'ningun parecido es una copia del producto')
    revisar(distintos, 'y ninguno se repite, uno por grupo')
    cuenta = {}
    for g in grupos.values():
        cuenta[g] = cuenta.get(g, 0) + 1
    con_copias = [g for g, n in cuenta.items() if n > 1]
    revisar(len(con_copias) > 0, 'control, el catalogo si tiene copias, %d grupos con mas de un producto' % len(con_copias))

    print('4. Un producto sin vector')
    revisar(similares(99999999) == [], 'devuelve vacio y no falla')

    ejemplo = muestra[0]
    print()
    print('Ejemplo, producto %d (%s)' % (ejemplo, cat[ejemplo]['cat']))
    for pid, nota, misma_ in similares_con_bloque(ejemplo):
        print('    %d  %.3f %-18s %s' % (pid, nota, cat.get(pid, {}).get('cat'), 'bloque 1' if misma_ else 'bloque 2'))

    print()
    print('%d OK, %d FALLA' % (OKS, FALLAS))
    sys.exit(1 if FALLAS else 0)


if __name__ == '__main__':
    main()
