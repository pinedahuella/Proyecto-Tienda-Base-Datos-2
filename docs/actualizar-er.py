# Pone al dia el diagrama entidad relacion de la Entrega 1 (el de Google Drive)
# con el esquema vivo de PostgreSQL, sin cambiarle el estilo: las cajas que ya
# estaban se quedan donde estaban y con su titulo, sus filas pasan a ser las
# columnas reales, las cajas naranjas de la migracion a MongoDB se quitan porque
# esa migracion ya se hizo, y las tablas nuevas entran a la derecha por modulo.
#
#   python docs/actualizar-er.py        (con las bases en la PC de David, MESH_REMOTO=1 antes)
#
# Lee docs/diagrama-er-entrega1.drawio, el original bajado de Google Drive, y
# escribe docs/diagrama-er.drawio. El esquema lo lee leer_esquema() de
# generar-er.py. Al final comprueba que cada tabla tenga su caja con sus
# columnas, cada llave foranea su flecha, y que nada se pise.
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

# 1. fuera lo naranja: los rectangulos, las cajas que contienen y las flechas que salen de ellos
naranjas = [c for c in cells if 'FFCC99' in (c.get('style') or '') and c.get('vertex') == '1']
def dentro(a, b):
    return a[0] >= b[0] - 1 and a[1] >= b[1] - 1 and a[0] + a[2] <= b[0] + b[2] + 1 and a[1] + a[3] <= b[1] + b[3] + 1
quitar = set(c.get('id') for c in naranjas)
for c in cells:
    if 'swimlane' in (c.get('style') or '') and c.get('parent') == '1':
        if any(dentro(caja(c), caja(n)) for n in naranjas):
            quitar.add(c.get('id'))
quitar |= {c.get('id') for c in cells if c.get('parent') in quitar}
quitar |= {c.get('id') for c in cells if c.get('edge') == '1' and (c.get('source') in quitar or c.get('target') in quitar)}
for c in cells:
    if c.get('id') in quitar: root.remove(c)
cells = list(root); por_id = {c.get('id'): c for c in cells}

# 2. cada caja blanca con su tabla, y sus filas iguales a las columnas reales
RENOMBRE = {('resena', 'id_producto'): 'id_producto_mongo', ('pedido_producto', 'id_producto_historial'): 'id_producto_mongo',
            ('pedido_producto', 'id_producto_variante_historial'): 'id_producto_variante_mongo',
            ('oferta', 'id_producto_variante'): 'id_producto_variante_mongo',
            ('caracteristica_variante', 'id_caracteristica_variante'): 'id_caracteristica'}
NOTA_COL = {'calificacion': 'calificacion (1-5)'}
fila_de = {}           # (tabla, columna) -> id de la celda
caja_de = {}           # tabla -> celda de la caja
crecio = set()
for c in [c for c in cells if 'swimlane' in (c.get('style') or '') and c.get('parent') == '1']:
    t = MAPA[L(c.get('value'))]
    if t in caja_de: raise SystemExit('dos cajas para ' + t)
    caja_de[t] = c
    filas = [h for h in cells if h.get('parent') == c.get('id') and h.get('vertex') == '1']
    viejas = {}
    for h in filas:
        nombre = re.sub(r'\s*\(.*\)$', '', L(h.get('value'))).replace('ó', 'o')
        nombre = RENOMBRE.get((t, nombre), nombre)
        viejas.setdefault(nombre, h)
    for h in filas: root.remove(h)
    pos_caja = list(root).index(c)
    ancho = float(geo(c).get('width'))
    antes = len(filas)
    for i, col in enumerate(T[t]['cols']):
        h = viejas.get(col)
        if h is None:
            h = ET.Element('mxCell', {'id': next(nuevo_id), 'value': col, 'style': ESTILO_FILA, 'vertex': '1', 'parent': c.get('id')})
            ET.SubElement(h, 'mxGeometry', {'y': str(CAB + ALTO_FILA * i), 'width': str(int(ancho)), 'height': str(ALTO_FILA), 'as': 'geometry'})
        else:
            v = L(h.get('value'))
            if '(' not in v or col == 'calificacion': h.set('value', NOTA_COL.get(col, col if '(' not in v else v))
            g = geo(h); g.set('y', str(CAB + ALTO_FILA * i))
        root.insert(pos_caja + 1 + i, h)
        fila_de[(t, col)] = h.get('id')
    necesita = int(max(len(x) for x in T[t]['cols']) * 7.4 + 24)
    if necesita > ancho:
        geo(c).set('width', str(necesita))
        for h in [h for h in root if h.get('parent') == c.get('id') and h.get('vertex') == '1']: geo(h).set('width', str(necesita))
    alto = CAB + ALTO_FILA * len(T[t]['cols'])
    if alto > float(geo(c).get('height')) + 1: crecio.add(c.get('id'))
    geo(c).set('height', str(alto))
cells = list(root); por_id = {c.get('id'): c for c in cells}

# 3. que nada se pise: lo que quedo debajo de una caja que crecio baja lo necesario
solidos = [c for c in cells if c.get('vertex') == '1' and c.get('parent') == '1']
movidos = set()
for _ in range(60):
    hubo = False
    for a in solidos:
        A = caja(a)
        for b in solidos:
            if a is b: continue
            B = caja(b)
            cruza_x = A[0] < B[0] + B[2] and B[0] < A[0] + A[2]
            if cruza_x and A[1] <= B[1] and B[1] < A[1] + A[3] + 20 and (a.get('id') in crecio or a.get('id') in movidos):
                dy = A[1] + A[3] + 30 - B[1]
                geo(b).set('y', str(B[1] + dy)); movidos.add(b.get('id')); hubo = True
    if not hubo: break
tocadas = crecio | movidos

# 4. las tablas nuevas, a la derecha y por modulo, con el mismo estilo
x_max = max(caja(c)[0] + caja(c)[2] for c in solidos)
y_min = min(caja(c)[1] for c in solidos)
y_max = max(caja(c)[1] + caja(c)[3] for c in solidos)
nuevas = [t for t in T if t not in caja_de]
x, y = x_max + 260, y_min
ancho_col = 0
TITULO = 'text;html=1;align=left;verticalAlign=middle;fontSize=16;fontStyle=1;strokeColor=none;fillColor=none;'
for titulo, lista in MODULOS_ORDEN:
    grupo = [t for t in lista if t in nuevas]
    if not grupo: continue
    if y > y_min and y + 40 + CAB + ALTO_FILA * len(T[grupo[0]]['cols']) > y_max:
        x += max(ancho_col, 230) + 140; y = y_min; ancho_col = 0
    et = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': titulo, 'style': TITULO + 'whiteSpace=wrap;', 'vertex': '1', 'parent': '1'})
    ET.SubElement(et, 'mxGeometry', {'x': str(int(x)), 'y': str(int(y)), 'width': '230', 'height': '50', 'as': 'geometry'})
    y += 60
    for t in grupo:
        cols = T[t]['cols']
        ancho = max(160, int(max(len(t) * 8.5, max(len(c) for c in cols) * 7.4) + 24))
        alto = CAB + ALTO_FILA * len(cols)
        if y + alto > y_max and y > y_min + 40:
            x += max(ancho_col, 230) + 140; y = y_min; ancho_col = 0
        c = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': t, 'style': ESTILO_TABLA, 'vertex': '1', 'parent': '1'})
        ET.SubElement(c, 'mxGeometry', {'x': str(int(x)), 'y': str(int(y)), 'width': str(ancho), 'height': str(alto), 'as': 'geometry'})
        caja_de[t] = c
        for i, col in enumerate(cols):
            h = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': col, 'style': ESTILO_FILA, 'vertex': '1', 'parent': c.get('id')})
            ET.SubElement(h, 'mxGeometry', {'y': str(CAB + ALTO_FILA * i), 'width': str(ancho), 'height': str(ALTO_FILA), 'as': 'geometry'})
            fila_de[(t, col)] = h.get('id')
        ancho_col = max(ancho_col, ancho); y += alto + 40
    y += 30
cells = list(root); por_id = {c.get('id'): c for c in cells}

# 5. una flecha por llave foranea, ni una mas
padre_caja = {c.get('id'): c.get('parent') for c in cells}
quiero = {}
for hijo, col, padre, colp, _ in REL:
    quiero[(fila_de[(hijo, col)], fila_de[(padre, colp)])] = (hijo, col, padre, colp)
tengo = set()
for e in [c for c in cells if c.get('edge') == '1']:
    par = (e.get('source'), e.get('target'))
    if par in quiero and par not in tengo:
        tengo.add(par)
        if padre_caja.get(par[0]) in tocadas or padre_caja.get(par[1]) in tocadas:
            g = geo(e); arr = g.find('Array')
            if arr is not None: g.remove(arr)
    else:
        root.remove(e)
def centro(t):
    b = caja(caja_de[t]); return b[0] + b[2] / 2, b
for par, (hijo, col, padre, colp) in quiero.items():
    if par in tengo: continue
    (cx1, b1), (cx2, b2) = centro(hijo), centro(padre)
    if hijo == padre or abs(cx1 - cx2) < (b1[2] + b2[2]) / 2:
        sx, ex = 1, 1
    elif cx1 < cx2: sx, ex = 1, 0
    else: sx, ex = 0, 1
    st = f'edgeStyle=orthogonalEdgeStyle;fontSize=12;html=1;endArrow=ERoneToMany;rounded=0;exitX={sx};exitY=0.5;exitDx=0;exitDy=0;entryX={ex};entryY=0.5;entryDx=0;entryDy=0;'
    e = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': '', 'style': st, 'edge': '1', 'parent': '1', 'source': par[0], 'target': par[1]})
    ET.SubElement(e, 'mxGeometry', {'relative': '1', 'as': 'geometry'})

# 6. comprobar
cells = list(root)
cajas = [c for c in cells if 'swimlane' in (c.get('style') or '')]
fallos = []
if len(cajas) != len(T): fallos.append(f'{len(cajas)} cajas y {len(T)} tablas')
aristas = [c for c in cells if c.get('edge') == '1']
pares = {(e.get('source'), e.get('target')) for e in aristas}
if pares != set(quiero): fallos.append(f'flechas {len(pares)} y llaves {len(quiero)}')
sol = [c for c in cells if c.get('vertex') == '1' and c.get('parent') == '1']
for a, b in itertools.combinations(sol, 2):
    A, B = caja(a), caja(b)
    if A[0] < B[0] + B[2] and B[0] < A[0] + A[2] and A[1] < B[1] + B[3] and B[1] < A[1] + A[3]:
        fallos.append('se pisan ' + L(a.get('value'))[:20] + ' y ' + L(b.get('value'))[:20])
for t in T:
    filas = [L(h.get('value')) for h in cells if h.get('parent') == caja_de[t].get('id') and h.get('vertex') == '1']
    if [re.sub(r'\s*\(.*\)$', '', f) for f in filas] != T[t]['cols']: fallos.append('filas de ' + t)
arbol.write(SALE, encoding='utf-8', xml_declaration=False)
print(f'{len(cajas)} cajas, {len(aristas)} flechas, {len(nuevas)} tablas nuevas, {len(crecio)} cajas crecieron, {len(movidos)} bajaron')
print('\n'.join(fallos) if fallos else 'OK: cada tabla una caja con sus columnas reales, cada llave foranea una flecha, nada se pisa')
