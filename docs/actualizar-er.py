# Pone al dia el diagrama entidad relacion de la Entrega 1 (el de Google Drive)
# con el esquema vivo de PostgreSQL SIN TOCAR LO QUE YA TENIA. Cada caja, fila,
# flecha y nota del original se queda igual y en su lugar. Solo se agrega:
#   - las tablas nuevas, a la derecha y por modulo, con el mismo estilo
#   - las columnas que le faltan a una caja vieja, al final de la caja, si caben
#     sin pisar nada; las que no caben van en una nota naranja como las del original
#   - una flecha por cada llave foranea que todavia no tenga la suya
#
#   python docs/actualizar-er.py        (con las bases en la PC de David, MESH_REMOTO=1 antes)
#
# Lee docs/diagrama-er-entrega1.drawio, el original bajado de Google Drive, y
# escribe docs/diagrama-er.drawio. El esquema lo lee leer_esquema() de
# generar-er.py. Al final comprueba que lo del original no cambio, que cada
# tabla tiene su caja y que lo agregado no pisa nada.
import xml.etree.ElementTree as ET, sys, html, re, json, copy, itertools, os
sys.stdout.reconfigure(encoding='utf-8')
AQUI = os.path.dirname(os.path.abspath(__file__))
ENTRA = os.path.join(AQUI, 'diagrama-er-entrega1.drawio')
SALE = os.path.join(AQUI, 'diagrama-er.drawio')
import importlib.util
_s = importlib.util.spec_from_file_location('er', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'generar-er.py'))
_er = importlib.util.module_from_spec(_s); _s.loader.exec_module(_er)
NOMBRES = {'cuentas': 'Cuentas, seguridad y permisos por rol', 'catalogo': 'Catalogo', 'ofertas': 'Ofertas, descuentos, vectores y permisos por oferta',
           'pedidos': 'Pedidos y pagos', 'resenas': 'Resenas', 'fraude': 'Fraude, senales y grafo'}
MODULOS_ORDEN = [(NOMBRES[k], v[3]) for k, v in _er.MODULOS.items()]
MAPA = {'Usuarios': 'usuarios', 'Productos': 'productos', 'Reseña': 'resena', 'Direcciones': 'direcciones', 'Comentario': 'comentario',
 'Estado Producto': 'estado_producto', 'Estado Usuario': 'estado_usuario', 'Likes': 'likes', 'Pedido': 'pedido', 'Estado Pedido': 'estado_pedido',
 'Pedido / producto': 'pedido_producto', 'Productos Variantes': 'productos_variantes', 'Estado Variantes': 'estado_variantes', 'Pago': 'pago',
 'metodo pago': 'metodo_pago', 'Estado pago': 'estado_pago', 'Estado Direccion': 'estado_direccion', 'Direccion Historial': 'direccion_historial',
 'Productos Variantes Historial': 'productos_variantes_historial', 'log login': 'log_login', 'Rol Usuario': 'rol_usuario',
 'Stock Movimiento': 'stock_movimiento', 'Motivo_Movimiento': 'motivo_movimiento', 'tipo login': 'tipo_login', 'log registro': 'log_registro',
 'Oferta': 'oferta', 'oferta': 'oferta', 'Imagen Producto': 'imagen_producto', 'Imagen Producto / Producto Variante': 'imagen_producto_producto',
 'Categorias': 'categorias', 'Productos Historial': 'productos_historial', 'Caracteristica': 'caracteristica',
 'Producto / Caracteristica': 'producto_caracteristica', 'Caracteristica Variante': 'caracteristica_variante',
 'Producto Variante / Característica Variante': 'producto_variante_caracteristica_variante', 'tipo_dato': 'tipo_dato',
 'Categoria / Caracteristica': 'categoria_caracteristica', 'Categoria / Caracteristica Variante': 'categoria_caracteristica_variante',
 'Precio Historial': 'precio_historial', 'Estado Oferta': 'estado_oferta', 'propuesta_producto': 'propuesta_producto',
 'rechazo_producto': 'rechazo_producto', 'rechazo_oferta': 'rechazo_oferta'}

_t, REL = _er.leer_esquema()
T = {k: {'cols': v['cols']} for k, v in _t.items()}

arbol = ET.parse(ENTRA); raiz = arbol.getroot()
root = raiz.find('diagram/mxGraphModel/root')
cells = list(root)
por_id = {c.get('id'): c for c in cells}
L = lambda v: html.unescape(re.sub('<[^>]+>', '', v or '')).replace('\xa0', ' ').strip()
geo = lambda c: c.find('mxGeometry')
def caja(c):
    g = geo(c); return [float(g.get('x', 0)), float(g.get('y', 0)), float(g.get('width', 0)), float(g.get('height', 0))]
ESTILO_TABLA = 'swimlane;fontStyle=0;childLayout=stackLayout;horizontal=1;startSize=26;horizontalStack=0;resizeParent=1;resizeParentMax=0;resizeLast=0;collapsible=1;marginBottom=0;align=center;fontSize=14;'
ESTILO_FILA = 'text;strokeColor=none;fillColor=none;spacingLeft=4;spacingRight=4;overflow=hidden;rotatable=0;points=[[0,0.5],[1,0.5]];portConstraint=eastwest;fontSize=12;whiteSpace=wrap;html=1;'
ALTO_FILA, CAB = 30, 26
nuevo_id = (f'mesh-{i}' for i in itertools.count(1))
NOTA = 'whiteSpace=wrap;html=1;align=left;verticalAlign=top;spacingLeft=8;spacingTop=6;fillColor=light-dark(#FFCC99,#A20505);strokeColor=#36393d;fontSize=12;'
TITULO = 'text;html=1;align=left;verticalAlign=middle;fontSize=16;fontStyle=1;strokeColor=none;fillColor=none;whiteSpace=wrap;'
norm = lambda v: re.sub(r'\s*\(.*\)$', '', L(v)).replace('ó', 'o').replace(' ', '_')
# la misma columna con su nombre de la Entrega 1: no se duplica, la flecha usa esa fila
ALIAS = {('caracteristica_variante', 'id_caracteristica'): 'id_caracteristica_variante'}
original_ids = {c.get('id') for c in cells}

naranjas = [c for c in cells if 'FFCC99' in (c.get('style') or '') and c.get('vertex') == '1']
def dentro(a, b):
    return a[0] >= b[0] - 1 and a[1] >= b[1] - 1 and a[0] + a[2] <= b[0] + b[2] + 1 and a[1] + a[3] <= b[1] + b[3] + 1
def se_pisan(A, B, m=10):
    return A[0] < B[0] + B[2] + m and B[0] < A[0] + A[2] + m and A[1] < B[1] + B[3] + m and B[1] < A[1] + A[3] + m

# las cajas del original: la blanca es la principal, la naranja es la version MongoDB
principal, todas_cajas = {}, {}
for c in [c for c in cells if 'swimlane' in (c.get('style') or '')]:
    t = MAPA[L(c.get('value'))]
    todas_cajas.setdefault(t, []).append(c)
    es_naranja = any(dentro(caja(c), caja(n)) for n in naranjas)
    if not es_naranja:
        principal[t] = c
    else:
        principal.setdefault(t, c)
fila_de = {}
for t, lista in todas_cajas.items():
    for c in sorted(lista, key=lambda c: c is not principal[t]):     # primero la principal
        for h in [h for h in cells if h.get('parent') == c.get('id') and h.get('vertex') == '1']:
            fila_de.setdefault((t, norm(h.get('value'))), h.get('id'))
for (t, col), vieja in ALIAS.items():
    if (t, vieja) in fila_de: fila_de.setdefault((t, col), fila_de[(t, vieja)])
cambiadas = set()

# 1. columnas que faltan en las cajas viejas, al final de la caja si caben
solidos = [c for c in cells if c.get('vertex') == '1' and c.get('parent') == '1']
no_caben, agregadas = {}, {}
for t, c in principal.items():
    faltan = [col for col in T[t]['cols'] if (t, col) not in fila_de]
    if not faltan: continue
    filas = [h for h in cells if h.get('parent') == c.get('id') and h.get('vertex') == '1']
    x, y, w, h0 = caja(c)
    extra = [x, y + h0, w, ALTO_FILA * len(faltan)]
    choca = any(se_pisan(extra, caja(o)) for o in solidos if o is not c and not dentro(caja(o), [x, y, w, h0]))
    choca = choca or len(todas_cajas[t]) > 1     # con caja blanca y naranja, las dos quedan como estaban
    if choca:
        no_caben[t] = faltan; continue
    pos = list(root).index(filas[-1]) if filas else list(root).index(c)
    for i, col in enumerate(faltan):
        f = ET.Element('mxCell', {'id': next(nuevo_id), 'value': col, 'style': ESTILO_FILA, 'vertex': '1', 'parent': c.get('id')})
        ET.SubElement(f, 'mxGeometry', {'y': str(int(h0 + ALTO_FILA * i)), 'width': str(int(w)), 'height': str(ALTO_FILA), 'as': 'geometry'})
        root.insert(pos + 1 + i, f); fila_de[(t, col)] = f.get('id')
    geo(c).set('height', str(int(h0 + ALTO_FILA * len(faltan))))
    agregadas[t] = faltan; cambiadas.add(c.get('id'))
cells = list(root)

# 2. las tablas nuevas, a la derecha y por modulo
solidos = [c for c in cells if c.get('vertex') == '1' and c.get('parent') == '1']
x_max = max(caja(c)[0] + caja(c)[2] for c in solidos)
y_min = min(caja(c)[1] for c in solidos)
y_max = max(caja(c)[1] + caja(c)[3] for c in solidos)
nuevas = [t for t in T if t not in principal]
x, y = x_max + 320, y_min
ley = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': 'Cada color de flecha sigue a una sola tabla de destino. Las que llegan a la misma columna se juntan antes de entrar.', 'style': 'text;html=1;align=left;verticalAlign=middle;fontSize=13;strokeColor=none;fillColor=none;whiteSpace=wrap;', 'vertex': '1', 'parent': '1'})
ET.SubElement(ley, 'mxGeometry', {'x': str(int(x)), 'y': str(int(y - 50)), 'width': '1000', 'height': '34', 'as': 'geometry'})
ancho_col = 0
for titulo, lista in MODULOS_ORDEN:
    grupo = [t for t in lista if t in nuevas]
    if not grupo: continue
    if y > y_min and y + 60 + CAB + ALTO_FILA * len(T[grupo[0]]['cols']) > y_max:
        x += max(ancho_col, 230) + 220; y = y_min; ancho_col = 0
    et = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': titulo, 'style': TITULO, 'vertex': '1', 'parent': '1'})
    ET.SubElement(et, 'mxGeometry', {'x': str(int(x)), 'y': str(int(y)), 'width': '230', 'height': '50', 'as': 'geometry'})
    y += 60
    for t in grupo:
        cols = T[t]['cols']
        ancho = max(160, int(max(len(t) * 8.5, max(len(c) for c in cols) * 7.4) + 24))
        alto = CAB + ALTO_FILA * len(cols)
        if y + alto > y_max and y > y_min + 60:
            x += max(ancho_col, 230) + 220; y = y_min; ancho_col = 0
        c = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': t, 'style': ESTILO_TABLA, 'vertex': '1', 'parent': '1'})
        ET.SubElement(c, 'mxGeometry', {'x': str(int(x)), 'y': str(int(y)), 'width': str(ancho), 'height': str(alto), 'as': 'geometry'})
        principal[t] = c
        for i, col in enumerate(cols):
            h = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': col, 'style': ESTILO_FILA, 'vertex': '1', 'parent': c.get('id')})
            ET.SubElement(h, 'mxGeometry', {'y': str(CAB + ALTO_FILA * i), 'width': str(ancho), 'height': str(ALTO_FILA), 'as': 'geometry'})
            fila_de[(t, col)] = h.get('id')
        ancho_col = max(ancho_col, ancho); y += alto + 60
    y += 30

# 3. la nota naranja con lo que no cupo
if no_caben:
    texto = ('<b>Columnas que faltan en su caja</b><br>No caben sin mover el diagrama, o la tabla tiene dos cajas, la blanca y la naranja de MongoDB, asi que van aqui.<br><br>'
             + '<br>'.join(f'<b>{t}</b>: ' + ', '.join(cols) for t, cols in no_caben.items()))
    alto = 90 + 20 * sum(1 + len(', '.join(c)) // 55 for c in no_caben.values())
    n = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': texto, 'style': NOTA, 'vertex': '1', 'parent': '1'})
    ET.SubElement(n, 'mxGeometry', {'x': str(int(x_max + 260)), 'y': str(int(y_max + 80)), 'width': '520', 'height': str(alto), 'as': 'geometry'})
cells = list(root)

# 4. una flecha por cada llave foranea que no la tenga, trazada a mano por un
# enrutador propio: draw.io las tira rectas y atraviesan cajas y se enciman.
# Cuadricula de 10 px. Las cajas son paredes con un margen. Cada flecha sale de
# la fila de la llave foranea por un costado, sube o baja por los pasillos
# libres y entra por un costado de la fila de la llave primaria. Una curva
# cuesta, ir encima de otra flecha cuesta mucho, cruzarla de lado poco, y
# tocar la esquina de otra flecha tambien se evita. Las que llegan a la misma
# fila pueden compartir el ultimo tramo, como un tronco. Se trazan de la mas
# corta a la mas larga y cada una deja ocupado su carril para las siguientes.
import heapq, math
pares = {(e.get('source'), e.get('target')) for e in cells if e.get('edge') == '1'}
pares |= {(b, a) for a, b in pares}
padre_de = {c.get('id'): c.get('parent') for c in cells}
por_id = {c.get('id'): c for c in cells}
def rect_abs(cid):
    c = por_id[cid]; g = geo(c)
    x, y = float(g.get('x', 0)), float(g.get('y', 0))
    p = padre_de.get(cid)
    if p and p != '1' and p in por_id:
        px, py, _, _ = rect_abs(p); x += px; y += py
    return [x, y, float(g.get('width', 0)), float(g.get('height', 0))]

pendientes, sin_fila = [], []
for hijo, col, padre, colp, _ in REL:
    a, b = fila_de.get((hijo, col)), fila_de.get((padre, colp))
    if not a or not b:
        sin_fila.append(f'{hijo}.{col} -> {padre}.{colp}'); continue
    if (a, b) in pares: continue
    pares |= {(a, b), (b, a)}
    pendientes.append((a, b))

G, MARGEN = 10, 8
solidos = [c for c in cells if c.get('vertex') == '1' and c.get('parent') == '1']
obst = [caja(c) for c in solidos]
x0 = min(o[0] for o in obst) - 300; y0 = min(o[1] for o in obst) - 300
x1 = max(o[0] + o[2] for o in obst) + 300; y1 = max(o[1] + o[3] for o in obst) + 300
NX, NY = int((x1 - x0) / G) + 1, int((y1 - y0) / G) + 1
X = lambda i: x0 + i * G
Y = lambda j: y0 + j * G
gi = lambda x: int(round((x - x0) / G))
gj = lambda y: int(round((y - y0) / G))
pared = bytearray(NX * NY)
for (x, y, w, h) in obst:
    for j in range(max(0, math.ceil((y - MARGEN - y0) / G)), min(NY - 1, math.floor((y + h + MARGEN - y0) / G)) + 1):
        base = j * NX
        for i in range(max(0, math.ceil((x - MARGEN - x0) / G)), min(NX - 1, math.floor((x + w + MARGEN - x0) / G)) + 1):
            pared[base + i] = 1

# ocupacion: tramo horizontal (i,j)-(i+1,j) en H, vertical (i,j)-(i,j+1) en V,
# guardan el dueno (la fila de destino) o -1 si es de una flecha del original.
H = [0] * (NX * NY); V = [0] * (NX * NY); ESQ = [0] * (NX * NY)
duenos = {}
def dueno(t): return duenos.setdefault(t, len(duenos) + 1)
def marcar_tramo(i, j, i2, j2, d):
    if j == j2:
        for k in range(min(i, i2), max(i, i2)):
            n = j * NX + k
            H[n] = d if H[n] in (0, d) else -1
    else:
        for k in range(min(j, j2), max(j, j2)):
            n = k * NX + i
            V[n] = d if V[n] in (0, d) else -1
def marcar_linea(pts, d):
    for (xa, ya), (xb, yb) in zip(pts, pts[1:]):
        ia, ja, ib, jb = gi(xa), gj(ya), gi(xb), gj(yb)
        if ja == jb or ia == ib:
            marcar_tramo(ia, ja, ib, jb, d)
        else:       # una diagonal del original: se marcan sus puntos como esquinas
            pasos = max(abs(ib - ia), abs(jb - ja))
            for s in range(pasos + 1):
                ESQ[gj(ya + (yb - ya) * s / pasos) * NX + gi(xa + (xb - xa) * s / pasos)] = -1
    for (xa, ya) in pts[1:-1]:
        n = gj(ya) * NX + gi(xa)
        ESQ[n] = d if ESQ[n] in (0, d) else -1

# las flechas del original, como las dibuja draw.io: puerto, sus puntos, puerto
def puerto(cid, estilo, cual, otro):
    r = rect_abs(cid)
    m = dict(kv.split('=', 1) for kv in estilo.split(';') if '=' in kv)
    fx = m.get(cual + 'X'); fy = m.get(cual + 'Y')
    if fx is None:
        fx = 1 if otro[0] > r[0] + r[2] / 2 else 0
    return (r[0] + float(fx) * r[2], r[1] + float(fy if fy is not None else 0.5) * r[3])
for e in [c for c in cells if c.get('edge') == '1']:
    s, t = e.get('source'), e.get('target')
    if s not in por_id or t not in por_id: continue
    arr = geo(e).find('Array')
    pts = [(float(p.get('x')), float(p.get('y'))) for p in arr] if arr is not None else []
    if e.get('parent') not in (None, '1') and e.get('parent') in por_id:
        ox, oy, _, _ = rect_abs(e.get('parent')); pts = [(px + ox, py + oy) for px, py in pts]
    rs, rt = rect_abs(s), rect_abs(t)
    ps = puerto(s, e.get('style') or '', 'exit', pts[0] if pts else (rt[0], rt[1]))
    pt = puerto(t, e.get('style') or '', 'entry', pts[-1] if pts else ps)
    linea = [ps] + pts + [pt]
    orto = [linea[0]]
    for q in linea[1:]:
        p = orto[-1]
        if p[0] != q[0] and p[1] != q[1]: orto.append((q[0], p[1]))   # el codo que pone draw.io
        orto.append(q)
    marcar_linea(orto, -1)

PASO, CURVA, ENCIMA, VECINA, CRUCE, ESQUINA = 10, 80, 1500, 160, 30, 500
VECINA2 = 40
def costo_mover(n, m, horizontal, d):
    c = PASO
    occ = H if horizontal else V
    k = min(n, m)
    o = occ[k]
    if o and o != d: c += ENCIMA
    # carril pegado: la linea paralela de al lado
    lado = NX if horizontal else 1
    for kk in (k - lado, k + lado):
        if 0 <= kk < len(occ) and occ[kk] and occ[kk] != d: c += VECINA
    for kk in (k - 2 * lado, k + 2 * lado):
        if 0 <= kk < len(occ) and occ[kk] and occ[kk] != d: c += VECINA2
    # cruzar de lado o tocar una esquina en el nodo de llegada
    otra = V if horizontal else H
    if (otra[m] and otra[m] != d) or (otra[m - lado] if m - lado >= 0 else 0) not in (0, d):
        c += CRUCE
    if ESQ[m] and ESQ[m] != d: c += ESQUINA
    return c

def rutear(a, b):
    ra, rb = rect_abs(a), rect_abs(b)
    d = dueno(b)
    def salidas(r):
        y = Y(gj(r[1] + r[3] / 2))
        out = []
        for lado in (0, 1):
            if lado == 1: i = math.ceil((r[0] + r[2] + MARGEN + 1 - x0) / G)
            else: i = math.floor((r[0] - MARGEN - 1 - x0) / G)
            j = gj(y)
            paso = 1 if lado == 1 else -1
            for _ in range(40):          # una caja dentro de un recuadro naranja sale cruzandolo
                if not (0 <= i < NX) or not pared[j * NX + i]: break
                i += paso
            if 0 <= i < NX and not pared[j * NX + i]:
                out.append((lado, i, j, y))
        return out
    S, T = salidas(ra), salidas(rb)
    if not S or not T: return None
    metas = {(i, j): (lado, yy) for lado, i, j, yy in T}
    hj = lambda i, j: min(abs(i - ti) + abs(j - tj) for (ti, tj) in metas) * PASO
    abiertos, mejor, de = [], {}, {}
    for lado, i, j, yy in S:
        n = j * NX + i
        heapq.heappush(abiertos, (hj(i, j), 0, n, 0, lado)); mejor[(n, 0)] = 0; de[(n, 0)] = None
    fin = None
    while abiertos:
        f, g, n, dr, lado0 = heapq.heappop(abiertos)
        if g > mejor.get((n, dr), 1e18): continue
        i, j = n % NX, n // NX
        if (i, j) in metas:
            extra = CURVA if dr == 1 else 0
            fin = (n, dr); break
        for di, dj, ndr in ((1, 0, 0), (-1, 0, 0), (0, 1, 1), (0, -1, 1)):
            ii, jj = i + di, j + dj
            if not (0 <= ii < NX and 0 <= jj < NY): continue
            m = jj * NX + ii
            if pared[m] and (ii, jj) not in metas: continue
            c = g + costo_mover(n, m, ndr == 0, d) + (CURVA if ndr != dr else 0)
            if c < mejor.get((m, ndr), 1e18):
                mejor[(m, ndr)] = c; de[(m, ndr)] = (n, dr, lado0)
                heapq.heappush(abiertos, (c + hj(ii, jj), c, m, ndr, lado0))
    if fin is None: return None
    camino = []; k = fin
    while k is not None:
        camino.append(k[0]); prev = de[k]; k = (prev[0], prev[1]) if prev else None
    camino.reverse()
    nodos = [(n % NX, n // NX) for n in camino]
    lado_s = 1 if X(nodos[0][0]) > ra[0] + ra[2] / 2 else 0
    lado_t, ytg = metas[nodos[-1]]
    # marcar
    for (ia, ja), (ib, jb) in zip(nodos, nodos[1:]): marcar_tramo(ia, ja, ib, jb, d)
    esquinas = [nodos[0]] + [q for p, q, r in zip(nodos, nodos[1:], nodos[2:]) if (p[0] == q[0]) != (q[0] == r[0])] + [nodos[-1]]
    for (ii, jj) in esquinas: ESQ[jj * NX + ii] = d if ESQ[jj * NX + ii] in (0, d) else -1
    return [(X(ii), Y(jj)) for ii, jj in esquinas], lado_s, lado_t, nodos

def largo(p):
    ra, rb = rect_abs(p[0]), rect_abs(p[1])
    return abs(ra[0] - rb[0]) + abs(ra[1] - rb[1])
nuevas_flechas, a_mano = 0, []
trazos = []
for a, b in sorted(pendientes, key=largo):
    r = rutear(a, b)
    ra, rb = rect_abs(a), rect_abs(b)
    if r is None:
        puntos, sx, ex, nodos = [], 1, 0, []; a_mano.append(f'{a}->{b}')
    else:
        puntos, sx, ex, nodos = r
    # el puerto se corre lo justo para caer en la cuadricula, asi el primer y el
    # ultimo tramo son horizontales exactos
    ey_s = (Y(gj(ra[1] + ra[3] / 2)) - ra[1]) / ra[3]
    ey_t = (Y(gj(rb[1] + rb[3] / 2)) - rb[1]) / rb[3]
    st = (f'edgeStyle=orthogonalEdgeStyle;fontSize=12;html=1;endArrow=ERoneToMany;rounded=0;'
          f'exitX={sx};exitY={ey_s:.4f};exitDx=0;exitDy=0;entryX={ex};entryY={ey_t:.4f};entryDx=0;entryDy=0;')
    e = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': '', 'style': st, 'edge': '1', 'parent': '1', 'source': a, 'target': b})
    trazos.append((e, b, nodos))
    g = ET.SubElement(e, 'mxGeometry', {'relative': '1', 'as': 'geometry'})
    if puntos:
        arr = ET.SubElement(g, 'Array', {'as': 'points'})
        for (px, py) in puntos: ET.SubElement(arr, 'mxPoint', {'x': str(int(px)), 'y': str(int(py))})
    nuevas_flechas += 1

# colores: cada destino un color, y dos destinos cuyas flechas pasan a menos de
# 30 px nunca comparten color. Sin naranja, que es el color de las notas.
COLORES = ['#1F5FBF', '#2E8B2E', '#C62828', '#7B3FA0', '#00838F', '#AD1457', '#5D4037', '#558B2F', '#283593', '#00695C', '#6A1B9A', '#37474F']
cerca = {}
for e, d, nodos in trazos:
    for (i, j) in nodos:
        for di in range(-3, 4):
            for dj in range(-3, 4):
                cerca.setdefault((i + di, j + dj), set()).add(d)
vecinos = {}
for s in cerca.values():
    for d in s: vecinos.setdefault(d, set()).update(s - {d})
color_de = {}
for d in sorted(vecinos, key=lambda d: -len(vecinos[d])):
    usados = {color_de[v] for v in vecinos[d] if v in color_de}
    libres = [c for c in COLORES if c not in usados]
    color_de[d] = libres[0] if libres else COLORES[len(color_de) % len(COLORES)]
for e, d, nodos in trazos:
    e.set('style', e.get('style') + f'strokeColor={color_de.get(d, COLORES[0])};strokeWidth=2;')
choque_color = sum(1 for d in vecinos for v in vecinos[d] if color_de.get(d) == color_de.get(v)) // 2
print(f'{len(color_de)} destinos con color, pares cercanos con el mismo color {choque_color}')

# comprobar las rutas: ningun tramo nuevo pasa por una caja
def corta(p, q, r):
    x, y, w, h = r
    if p[1] == q[1]:
        return y < p[1] < y + h and min(p[0], q[0]) < x + w and max(p[0], q[0]) > x
    return x < p[0] < x + w and min(p[1], q[1]) < y + h and max(p[1], q[1]) > y
choques = 0
for e in list(root)[-nuevas_flechas:]:
    arr = geo(e).find('Array')
    if arr is None: continue
    ra, rb = rect_abs(e.get('source')), rect_abs(e.get('target'))
    pts = [(float(p.get('x')), float(p.get('y'))) for p in arr]
    for p, q in zip(pts, pts[1:]):
        for o in obst:
            if corta(p, q, o): choques += 1
print(f'enrutadas {nuevas_flechas - len(a_mano)} de {nuevas_flechas}, tramos que cortan una caja {choques}, sin ruta {a_mano}')

# 5. comprobar: lo original intacto, nada nuevo pisa a nada, cada tabla con su caja
cells = list(root)
fallos = []
ahora = {x.get('id'): x for x in cells}
for o in ET.parse(ENTRA).getroot().find('diagram/mxGraphModel/root'):
    c = ahora.get(o.get('id'))
    if c is None:
        fallos.append('se perdio ' + o.get('id')); continue
    if o.get('id') in cambiadas:      # solo crecio su alto
        g1, g2 = dict(o.find('mxGeometry').attrib), dict(c.find('mxGeometry').attrib)
        g1.pop('height'); g2.pop('height')
        if g1 != g2 or o.get('value') != c.get('value'): fallos.append('cambio de mas ' + L(o.get('value')))
        continue
    if ET.tostring(o) != ET.tostring(c): fallos.append('cambio ' + L(o.get('value'))[:30])
faltan_tablas = [t for t in T if t not in principal]
if faltan_tablas: fallos.append('sin caja ' + ', '.join(faltan_tablas))
sol = [c for c in cells if c.get('vertex') == '1' and c.get('parent') == '1']
for a, b in itertools.combinations(sol, 2):
    if a.get('id') in original_ids and b.get('id') in original_ids and not ({a.get('id'), b.get('id')} & cambiadas): continue
    A, B = caja(a), caja(b)
    if se_pisan(A, B, 0) and not (dentro(A, B) or dentro(B, A)):
        fallos.append('se pisan ' + L(a.get('value'))[:25] + ' y ' + L(b.get('value'))[:25])
arbol.write(SALE, encoding='utf-8', xml_declaration=False)
print(f'{len(nuevas)} tablas nuevas, {nuevas_flechas} flechas nuevas')
print('columnas agregadas en su caja:', agregadas)
print('no caben, van en la nota naranja:', no_caben)
print('llaves sin fila donde dibujarse:', sin_fila)
print('\n'.join(fallos) if fallos else 'OK: el original intacto, cada tabla con su caja y lo nuevo no pisa nada')
