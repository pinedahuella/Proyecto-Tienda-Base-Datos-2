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
x, y = x_max + 260, y_min
enc = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': 'Lo que se agrego despues de la Entrega 1, leido de la base el 6 de noviembre de 2026', 'style': TITULO, 'vertex': '1', 'parent': '1'})
ET.SubElement(enc, 'mxGeometry', {'x': str(int(x)), 'y': str(int(y - 90)), 'width': '900', 'height': '40', 'as': 'geometry'})
ancho_col = 0
for titulo, lista in MODULOS_ORDEN:
    grupo = [t for t in lista if t in nuevas]
    if not grupo: continue
    if y > y_min and y + 60 + CAB + ALTO_FILA * len(T[grupo[0]]['cols']) > y_max:
        x += max(ancho_col, 230) + 140; y = y_min; ancho_col = 0
    et = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': titulo, 'style': TITULO, 'vertex': '1', 'parent': '1'})
    ET.SubElement(et, 'mxGeometry', {'x': str(int(x)), 'y': str(int(y)), 'width': '230', 'height': '50', 'as': 'geometry'})
    y += 60
    for t in grupo:
        cols = T[t]['cols']
        ancho = max(160, int(max(len(t) * 8.5, max(len(c) for c in cols) * 7.4) + 24))
        alto = CAB + ALTO_FILA * len(cols)
        if y + alto > y_max and y > y_min + 60:
            x += max(ancho_col, 230) + 140; y = y_min; ancho_col = 0
        c = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': t, 'style': ESTILO_TABLA, 'vertex': '1', 'parent': '1'})
        ET.SubElement(c, 'mxGeometry', {'x': str(int(x)), 'y': str(int(y)), 'width': str(ancho), 'height': str(alto), 'as': 'geometry'})
        principal[t] = c
        for i, col in enumerate(cols):
            h = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': col, 'style': ESTILO_FILA, 'vertex': '1', 'parent': c.get('id')})
            ET.SubElement(h, 'mxGeometry', {'y': str(CAB + ALTO_FILA * i), 'width': str(ancho), 'height': str(ALTO_FILA), 'as': 'geometry'})
            fila_de[(t, col)] = h.get('id')
        ancho_col = max(ancho_col, ancho); y += alto + 40
    y += 30

# 3. la nota naranja con lo que no cupo
if no_caben:
    texto = ('<b>Columnas que se agregaron despues de la Entrega 1</b><br>No caben en su caja sin mover el diagrama, o la tabla tiene dos cajas, la de la Entrega 1 y la naranja de MongoDB, asi que van aqui.<br><br>'
             + '<br>'.join(f'<b>{t}</b>: ' + ', '.join(cols) for t, cols in no_caben.items()))
    alto = 90 + 20 * sum(1 + len(', '.join(c)) // 55 for c in no_caben.values())
    n = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': texto, 'style': NOTA, 'vertex': '1', 'parent': '1'})
    ET.SubElement(n, 'mxGeometry', {'x': str(int(x_max + 260)), 'y': str(int(y_max + 80)), 'width': '520', 'height': str(alto), 'as': 'geometry'})
cells = list(root)

# 4. una flecha por cada llave foranea que no la tenga
pares = {(e.get('source'), e.get('target')) for e in cells if e.get('edge') == '1'}
pares |= {(b, a) for a, b in pares}
caja_de_fila = {c.get('id'): c.get('parent') for c in cells}
por_id = {c.get('id'): c for c in cells}
sin_fila, nuevas_flechas = [], 0
for hijo, col, padre, colp, _ in REL:
    a, b = fila_de.get((hijo, col)), fila_de.get((padre, colp))
    if not a or not b:
        sin_fila.append(f'{hijo}.{col} -> {padre}.{colp}'); continue
    if (a, b) in pares: continue
    A, B = caja(por_id[caja_de_fila[a]]), caja(por_id[caja_de_fila[b]])
    ca, cb = A[0] + A[2] / 2, B[0] + B[2] / 2
    if caja_de_fila[a] == caja_de_fila[b] or abs(ca - cb) < (A[2] + B[2]) / 2: sx, ex = 1, 1
    elif ca < cb: sx, ex = 1, 0
    else: sx, ex = 0, 1
    st = f'edgeStyle=orthogonalEdgeStyle;fontSize=12;html=1;endArrow=ERoneToMany;rounded=0;exitX={sx};exitY=0.5;exitDx=0;exitDy=0;entryX={ex};entryY=0.5;entryDx=0;entryDy=0;'
    e = ET.SubElement(root, 'mxCell', {'id': next(nuevo_id), 'value': '', 'style': st, 'edge': '1', 'parent': '1', 'source': a, 'target': b})
    ET.SubElement(e, 'mxGeometry', {'relative': '1', 'as': 'geometry'})
    pares |= {(a, b), (b, a)}; nuevas_flechas += 1

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
