# -*- coding: utf-8 -*-
"""Dibuja el diagrama entidad relacion de Mesh a partir del esquema VIVO.

    python generar-er.py                  el diagrama completo, las 76 tablas
    python generar-er.py --modulo fraude  solo un modulo, para el informe

Escribe docs/diagrama-general.drawio (editable en diagrams.net) y, si encuentra
draw.io instalado, tambien el .png.

EL ESQUEMA NO SE COPIA A MANO. Se lee de information_schema y pg_constraint en el
contenedor mesh-postgres. Un diagrama con las columnas escritas a mano caduca en
cuanto alguien agrega una migracion, y es exactamente lo que le paso al anterior,
que se quedo en 42 cajas cuando la base ya tenia 50.

Al final se comprueba, y si algo no cuadra el script sale con 1 y lo dice:
  - que cada tabla de la base tiene UNA caja, ni mas ni menos
  - que cada llave foranea tiene su linea, y que no hay lineas de mas
  - que ninguna caja pisa a otra
"""
import io
import json
import os
import subprocess
import sys
from xml.sax.saxutils import escape

BASE = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.environ.get("MESH_RAIZ") or (
    os.path.dirname(BASE) if os.path.basename(BASE) == "docs" else BASE)

# ---------------------------------------------------------------- el esquema


def leer_env():
    env = {}
    ruta = os.path.join(RAIZ, ".env")
    with io.open(ruta, encoding="utf-8") as f:
        for linea in f:
            linea = linea.strip()
            if linea and not linea.startswith("#") and "=" in linea:
                k, v = linea.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def psql(env, sql):
    cmd = ["docker", "exec", "mesh-postgres", "psql", "-U", env["DB_USER"],
           "-d", env["DB_NAME"], "-At", "-F", "|", "-c", sql]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        raise SystemExit("psql fallo: " + r.stderr.strip())
    return [l.split("|") for l in r.stdout.splitlines() if l.strip()]


def leer_esquema():
    env = leer_env()
    cols = psql(env, """
        select c.table_name, c.column_name
        from information_schema.columns c
        join information_schema.tables t on t.table_name = c.table_name
         and t.table_schema = c.table_schema and t.table_type = 'BASE TABLE'
        where c.table_schema = 'public'
        order by c.table_name, c.ordinal_position""")
    claves = psql(env, """
        select tc.table_name, kcu.column_name, tc.constraint_type
        from information_schema.table_constraints tc
        join information_schema.key_column_usage kcu
          on kcu.constraint_name = tc.constraint_name and kcu.table_schema = tc.table_schema
        where tc.table_schema = 'public' and tc.constraint_type in ('PRIMARY KEY', 'UNIQUE')""")
    fks = psql(env, """
        select conrelid::regclass::text, a.attname, confrelid::regclass::text, af.attname,
               (not a.attnotnull)::text
        from pg_constraint c
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
        join pg_attribute af on af.attrelid = c.confrelid and af.attnum = any(c.confkey)
        where c.contype = 'f' and c.connamespace = 'public'::regnamespace
        order by 1, 2""")
    tablas = {}
    for t, c in cols:
        tablas.setdefault(t, {"cols": [], "pk": set(), "uq": set(), "fk": {}})["cols"].append(c)
    for t, c, tipo in claves:
        tablas[t]["pk" if tipo == "PRIMARY KEY" else "uq"].add(c)
    relaciones = []
    for hijo, col, padre, colp, nulo in fks:
        tablas[hijo]["fk"][col] = padre
        relaciones.append((hijo, col, padre, colp, nulo == "true"))
    return tablas, relaciones


# ------------------------------------------------------------ la composicion
# Cada columna es una lista de tablas, de arriba abajo. Un "|" separa grupos
# dentro de la columna. Los modulos son por dominio y llevan su color.

MODULOS = {
    "cuentas": ("Cuentas y seguridad", "#DAE8FC", "#6C8EBF",
                ["usuarios", "rol_usuario", "estado_usuario", "direcciones", "estado_direccion",
                 "direccion_historial", "log_login", "tipo_login", "log_registro"]),
    "catalogo": ("Catalogo", "#D5E8D4", "#82B366",
                 ["categorias", "productos", "estado_producto", "productos_historial",
                  "productos_variantes", "estado_variantes", "productos_variantes_historial",
                  "imagen_producto", "imagen_producto_producto", "caracteristica",
                  "caracteristica_variante", "tipo_dato", "categoria_caracteristica",
                  "categoria_caracteristica_variante", "producto_caracteristica",
                  "producto_variante_caracteristica_variante", "producto_vector"]),
    "ofertas": ("Ofertas e inventario", "#FFE6CC", "#D79B00",
                ["oferta", "estado_oferta", "precio_historial", "stock_movimiento",
                 "motivo_movimiento", "propuesta_producto", "rechazo_producto", "rechazo_oferta",
                 "regla_descuento_automatico", "regla_descuento_periodo", "evento_producto",
                 # la copia del catalogo para comprar sin MongoDB (029)
                 "producto_catalogo", "variante_catalogo"]),
    "pedidos": ("Pedidos y pagos", "#FFF2CC", "#D6B656",
                ["pedido", "estado_pedido", "pedido_producto", "pago", "estado_pago", "metodo_pago"]),
    "resenas": ("Resenas", "#E1D5E7", "#9673A6",
                ["resena", "comentario", "likes"]),
    "fraude": ("Fraude y grafo", "#F8CECC", "#B85450",
               ["alerta_fraude", "tipo_alerta_fraude", "estado_alerta_fraude", "notificacion_fraude",
                "anillo_fraude", "tipo_anillo_fraude", "anillo_fraude_resena", "evento_grafo",
                "hallazgo_evento_fraude", "hallazgo_evento_fraude_cuenta", "tipo_hallazgo_evento",
                "caso_fraude", "nivel_caso_fraude", "caso_fraude_regla", "regla_casi_confirmado",
                "evidencia_caso_fraude", "evidencia_caso_fraude_cuenta",
                # el modelo unico de senales (031 a 033)
                "senal_fraude", "familia_senal_fraude", "fuente_senal_fraude", "tipo_senal_fraude",
                "rol_cuenta_senal", "senal_fraude_cuenta", "senal_fraude_resena",
                "senal_fraude_producto", "senal_fraude_pedido", "direccion_ip", "senal_fraude_ip"]),
}

# columnas del diagrama completo, de izquierda a derecha
DISPOSICION = [
    ["tipo_login", "estado_direccion"],
    ["log_login", "log_registro", "direcciones", "direccion_historial"],
    ["rol_usuario", "usuarios", "estado_usuario"],
    ["propuesta_producto", "|", "precio_historial", "oferta", "stock_movimiento", "pedido", "|",
     "resena", "comentario", "likes", "|", "alerta_fraude", "notificacion_fraude", "|",
     "hallazgo_evento_fraude_cuenta"],
    ["rechazo_producto", "|", "estado_oferta", "rechazo_oferta", "motivo_movimiento",
     "regla_descuento_automatico", "regla_descuento_periodo", "evento_producto", "|",
     "producto_catalogo", "variante_catalogo", "|",
     "estado_pedido", "pedido_producto", "pago", "|", "anillo_fraude_resena", "anillo_fraude",
     "|", "tipo_alerta_fraude", "estado_alerta_fraude", "tipo_anillo_fraude", "evento_grafo",
     "|", "hallazgo_evento_fraude", "tipo_hallazgo_evento"],
    ["metodo_pago", "estado_pago", "|", "evidencia_caso_fraude", "evidencia_caso_fraude_cuenta"],
    # los casos de fraude (026): juntan anillos, hallazgos de eventos y alertas
    ["caso_fraude", "nivel_caso_fraude", "|", "caso_fraude_regla", "regla_casi_confirmado"],
    # las senales (031 a 033): desde la 033 la evidencia y los avisos cuelgan de
    # senal_fraude, y las tablas viejas de alertas, anillos y hallazgos quedan
    # sin escrituras
    ["senal_fraude_cuenta", "senal_fraude_resena", "senal_fraude_pedido", "|", "senal_fraude",
     "rol_cuenta_senal"],
    ["tipo_senal_fraude", "familia_senal_fraude", "fuente_senal_fraude", "|",
     "senal_fraude_producto", "senal_fraude_ip", "direccion_ip"],
]

# el catalogo es una isla: ninguna de sus tablas tiene llave foranea hacia el
# resto, porque oferta y pedido_producto apuntan a Mongo por id y no por FK.
DISPOSICION_CATALOGO = [
    ["tipo_dato", "|", "categorias", "|", "estado_producto"],
    ["caracteristica", "caracteristica_variante", "productos", "estado_variantes"],
    ["categoria_caracteristica", "categoria_caracteristica_variante", "producto_caracteristica",
     "productos_historial", "productos_variantes"],
    ["producto_variante_caracteristica_variante", "productos_variantes_historial", "imagen_producto",
     "imagen_producto_producto", "|", "producto_vector"],
]

# vistas recortadas para el informe. Solo se dibujan las lineas entre las tablas presentes.
VISTAS = {
    "fraude": ("Alertas de fraude, anillos y cola del grafo", [
        ["usuarios", "|", "resena"],
        ["alerta_fraude", "notificacion_fraude"],
        ["tipo_alerta_fraude", "estado_alerta_fraude", "anillo_fraude", "tipo_anillo_fraude",
         "anillo_fraude_resena", "evento_grafo"],
    ]),
    "senales": ("Senales de fraude, casos y avisos (031 a 033)", [
        ["usuarios", "|", "resena", "pedido"],
        ["senal_fraude_cuenta", "senal_fraude_resena", "senal_fraude_pedido", "|",
         "notificacion_fraude"],
        ["senal_fraude", "estado_alerta_fraude", "|", "evidencia_caso_fraude",
         "evidencia_caso_fraude_cuenta", "caso_fraude"],
        ["tipo_senal_fraude", "familia_senal_fraude", "fuente_senal_fraude", "rol_cuenta_senal",
         "|", "senal_fraude_producto", "senal_fraude_ip", "direccion_ip"],
    ]),
}

FUENTE = "Consolas"
TAM = 11
ANCHO_CAR = 6.9
ALTO_CAB = 26
ALTO_FILA = 20
HUECO_X = 110
HUECO_Y = 26
HUECO_GRUPO = 46


def modulo_de(tabla):
    for clave, (_, _, _, lista) in MODULOS.items():
        if tabla in lista:
            return clave
    raise KeyError(tabla)


def texto_fila(tabla, col, t):
    marcas = []
    if col in t["pk"]:
        marcas.append("PK")
    if col in t["fk"]:
        marcas.append("FK")
    if col in t["uq"] and col not in t["pk"]:
        marcas.append("UQ")
    return ("%-6s%s" % (" ".join(marcas), col))


def medir(tablas):
    """Ancho y alto de cada caja."""
    caja = {}
    for nombre, t in tablas.items():
        filas = [texto_fila(nombre, c, t) for c in t["cols"]]
        largo = max(len(nombre) + 2, max(len(f) for f in filas))
        ancho = max(150, int(largo * ANCHO_CAR + 22))
        alto = ALTO_CAB + ALTO_FILA * len(filas)
        caja[nombre] = {"w": ancho, "h": alto, "filas": filas}
    return caja


def colocar(disposicion, caja, x0, y0):
    """Devuelve {tabla: (x, y, col, fila)} apilando cada columna de arriba abajo."""
    pos = {}
    x = x0
    for ci, columna in enumerate(disposicion):
        y = y0
        ancho_col = max(caja[t]["w"] for t in columna if t != "|")
        fila = 0
        for t in columna:
            if t == "|":
                y += HUECO_GRUPO - HUECO_Y
                continue
            pos[t] = {"x": x, "y": y, "col": ci, "fila": fila, "w": caja[t]["w"], "h": caja[t]["h"]}
            y += caja[t]["h"] + HUECO_Y
            fila += 1
        x += ancho_col + HUECO_X
    return pos


# ---------------------------------------------------------------- el dibujo


class Lienzo:
    def __init__(self):
        self.celdas = []
        self.n = 1

    def nuevo_id(self, pref="er"):
        self.n += 1
        return "%s-%d" % (pref, self.n)

    def texto_suelto(self, x, y, w, h, valor, tam=12, negrita=False, gris=False):
        i = self.nuevo_id("txt")
        est = ("text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=top;"
               "whiteSpace=wrap;fontSize=%d;%s%s" % (tam, "fontStyle=1;" if negrita else "",
                                                       "fontColor=#666666;" if gris else ""))
        self.celdas.append(
            '<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
            % (i, escape(valor), est, x, y, w, h))

    def tabla(self, nombre, p, caja, t, relleno, borde):
        i = "t-" + nombre
        est = ("swimlane;fontStyle=1;childLayout=stackLayout;horizontal=1;startSize=%d;"
               "horizontalStack=0;resizeParent=1;resizeParentMax=0;resizeLast=0;collapsible=0;"
               "marginBottom=0;align=center;fontSize=12;fontFamily=%s;fillColor=%s;strokeColor=%s;"
               "swimlaneFillColor=#FFFFFF;" % (ALTO_CAB, FUENTE, relleno, borde))
        self.celdas.append(
            '<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
            '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
            % (i, escape(nombre), est, p["x"], p["y"], p["w"], p["h"]))
        for k, col in enumerate(t["cols"]):
            es_pk = col in t["pk"]
            est_f = ("text;strokeColor=none;fillColor=none;spacingLeft=6;spacingRight=4;overflow=hidden;"
                     "rotatable=0;points=[[0,0.5],[1,0.5]];portConstraint=eastwest;fontSize=%d;"
                     "fontFamily=%s;whiteSpace=pre;html=0;align=left;%s"
                     % (TAM, FUENTE, "fontStyle=1;" if es_pk else ""))
            self.celdas.append(
                '<mxCell id="%s-f%d" value="%s" style="%s" vertex="1" parent="%s">'
                '<mxGeometry y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
                % (i, k, escape(caja["filas"][k]), est_f, i, ALTO_CAB + ALTO_FILA * k,
                   p["w"], ALTO_FILA))

    def arista(self, hijo, padre, nulo, sx, sy, ex, ey, puntos, etiqueta=""):
        i = self.nuevo_id("fk")
        fin = "ERzeroToOne" if nulo else "ERmandOne"
        est = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;jettySize=auto;orthogonalLoop=1;"
               "startArrow=ERmany;startFill=0;endArrow=%s;endFill=0;strokeColor=#555555;fontSize=9;"
               "exitX=%.3f;exitY=%.3f;exitDx=0;exitDy=0;entryX=%.3f;entryY=%.3f;entryDx=0;entryDy=0;"
               % (fin, sx, sy, ex, ey))
        pts = ""
        if puntos:
            pts = "<Array as=\"points\">%s</Array>" % "".join(
                '<mxPoint x="%d" y="%d"/>' % (px, py) for px, py in puntos)
        self.celdas.append(
            '<mxCell id="%s" value="%s" style="%s" edge="1" parent="1" source="t-%s" target="t-%s">'
            '<mxGeometry relative="1" as="geometry">%s</mxGeometry></mxCell>'
            % (i, escape(etiqueta), est, hijo, padre, pts))

    def xml(self):
        return ('<mxfile host="Mesh"><diagram name="Modelo relacional" id="er-mesh">'
                '<mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" '
                'connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="827" '
                'pageHeight="1169" math="0" shadow="0"><root><mxCell id="0"/>'
                '<mxCell id="1" parent="0"/>' + "".join(self.celdas) + '</root></mxGraphModel>'
                '</diagram></mxfile>')


def lados(pos, relaciones, tablas_dibujadas):
    """Decide de que lado sale y entra cada linea y reparte los puntos de amarre."""
    trabajo = []
    for hijo, col, padre, colp, nulo in relaciones:
        if hijo not in tablas_dibujadas or padre not in tablas_dibujadas:
            continue
        trabajo.append({"hijo": hijo, "col": col, "padre": padre, "nulo": nulo})
    # lado por caja: cuantas lineas se amarran a cada lado
    amarres = {}
    for e in trabajo:
        a, b = pos[e["hijo"]], pos[e["padre"]]
        if e["hijo"] == e["padre"]:
            e["ls"], e["le"] = "R", "R"
        elif a["col"] == b["col"] and abs(a["fila"] - b["fila"]) == 1 and abs(a["y"] - b["y"]) < 900:
            e["ls"], e["le"] = ("B", "T") if a["y"] < b["y"] else ("T", "B")
        elif a["col"] < b["col"]:
            e["ls"], e["le"] = "R", "L"
        elif a["col"] > b["col"]:
            e["ls"], e["le"] = "L", "R"
        else:
            e["ls"], e["le"] = "R", "R"
        amarres.setdefault((e["hijo"], e["ls"]), []).append((e, "s"))
        amarres.setdefault((e["padre"], e["le"]), []).append((e, "e"))
    for (caja, lado), lista in amarres.items():
        def clave(item):
            e, rol = item
            otro = e["padre"] if rol == "s" else e["hijo"]
            return pos[otro]["y"] + pos[otro]["h"] / 2.0
        lista.sort(key=clave)
        n = len(lista)
        for k, (e, rol) in enumerate(lista):
            f = 0.5 if n == 1 else 0.12 + 0.76 * k / (n - 1)
            e["f_" + rol] = f
    return trabajo


def punto_de(lado, f):
    if lado == "R":
        return (1.0, f)
    if lado == "L":
        return (0.0, f)
    if lado == "T":
        return (f, 0.0)
    return (f, 1.0)


def pasillo(pos, e, a, b, sy, ey, usados):
    """Ruta de una linea que salta columnas: canal junto a cada extremo y un
    pasillo horizontal libre entre las cajas de las columnas del medio."""
    ys = a["y"] + a["h"] * sy
    yt = b["y"] + b["h"] * ey
    xs = a["x"] + a["w"] + 28 if e["ls"] == "R" else a["x"] - 28
    xt = b["x"] + b["w"] + 28 if e["le"] == "R" else b["x"] - 28
    lo, hi = sorted((a["col"], b["col"]))
    medio = [p for p in pos.values() if lo < p["col"] < hi]
    def libre(y):
        return all(not (p["y"] - 8 < y < p["y"] + p["h"] + 8) for p in medio)
    cand = {ys, yt}
    for c in range(lo + 1, hi):
        col = sorted((p for p in medio if p["col"] == c), key=lambda p: p["y"])
        cand.add(col[0]["y"] - 18)
        for p, q in zip(col, col[1:]):
            cand.add((p["y"] + p["h"] + q["y"]) / 2.0)
        cand.add(col[-1]["y"] + col[-1]["h"] + 18)
    ok = [y for y in cand if libre(y)]
    yc = min(ok, key=lambda y: abs(y - ys) + abs(y - yt)) if ok else ys
    k = usados.get(round(yc), 0)
    usados[round(yc)] = k + 1
    yc += 6 * k
    return [(xs, ys), (xs, yc), (xt, yc), (xt, yt)]


def pintar(lienzo, tablas, caja, pos, relaciones, titulo_modulo=None):
    usados = {}
    for nombre, p in pos.items():
        _, relleno, borde, _ = MODULOS[modulo_de(nombre)]
        lienzo.tabla(nombre, p, caja[nombre], tablas[nombre], relleno, borde)
    for e in lados(pos, relaciones, set(pos)):
        sx, sy = punto_de(e["ls"], e["f_s"])
        ex, ey = punto_de(e["le"], e["f_e"])
        puntos = []
        a, b = pos[e["hijo"]], pos[e["padre"]]
        if e["hijo"] != e["padre"] and abs(a["col"] - b["col"]) > 1 and e["ls"] in "LR" and e["le"] in "LR":
            puntos = pasillo(pos, e, a, b, sy, ey, usados)
        if e["hijo"] == e["padre"]:
            p = pos[e["hijo"]]
            xr = p["x"] + p["w"] + 34
            y1 = p["y"] + p["h"] * sy
            y2 = p["y"] + p["h"] * ey
            puntos = [(xr, y1), (xr, y2)]
        lienzo.arista(e["hijo"], e["padre"], e["nulo"], sx, sy, ex, ey, puntos)


def comprobar(tablas, relaciones, pos, lienzo, todas):
    fallos = []
    if todas:
        faltan = sorted(set(tablas) - set(pos))
        sobran = sorted(set(pos) - set(tablas))
        if faltan:
            fallos.append("tablas de la base SIN caja: " + ", ".join(faltan))
        if sobran:
            fallos.append("cajas sin tabla en la base: " + ", ".join(sobran))
    dibujadas = set()
    for c in lienzo.celdas:
        if ' edge="1"' in c:
            s = c.split('source="t-')[1].split('"')[0]
            t = c.split('target="t-')[1].split('"')[0]
            dibujadas.add((s, t))
    esperadas = {(h, p) for h, _, p, _, _ in relaciones if h in pos and p in pos}
    # una relacion doble (dos columnas hacia la misma tabla) son dos lineas
    n_esp = sum(1 for h, _, p, _, _ in relaciones if h in pos and p in pos)
    n_dib = sum(1 for c in lienzo.celdas if ' edge="1"' in c)
    if esperadas - dibujadas:
        fallos.append("llaves foraneas SIN linea: %s" % sorted(esperadas - dibujadas))
    if dibujadas - esperadas:
        fallos.append("lineas sin llave foranea: %s" % sorted(dibujadas - esperadas))
    if n_esp != n_dib:
        fallos.append("hay %d llaves foraneas y %d lineas" % (n_esp, n_dib))
    nombres = list(pos)
    for i in range(len(nombres)):
        for j in range(i + 1, len(nombres)):
            a, b = pos[nombres[i]], pos[nombres[j]]
            if (a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"]
                    and a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"]):
                fallos.append("se pisan %s y %s" % (nombres[i], nombres[j]))
    return fallos, n_esp


def exportar_png(drawio):
    """Si draw.io esta instalado, saca el .png junto al .drawio. Sin ventana."""
    exe = None
    for c in (r"C:\Program Files\draw.io\draw.io.exe",
              os.path.expandvars(r"%LOCALAPPDATA%\Programs\draw.io\draw.io.exe")):
        if os.path.exists(c):
            exe = c
            break
    if not exe:
        print("  No encontre draw.io, el .png no se genero. El .drawio si esta.")
        return
    png = os.path.splitext(drawio)[0] + ".png"
    if os.path.exists(png):
        os.remove(png)
    flags = 0x08000000 if os.name == "nt" else 0
    subprocess.run([exe, "-x", "-f", "png", "-s", "1", "-b", "20", "--crop", "-o", png, drawio],
                   capture_output=True, creationflags=flags)
    print("  %s %s" % ("PNG" if os.path.exists(png) else "NO SE GENERO el PNG", png))


def main():
    args = sys.argv[1:]
    modulo = None
    if "--modulo" in args:
        modulo = args[args.index("--modulo") + 1]
    salida = os.path.join(BASE, "diagrama-general.drawio")
    if "--salida" in args:
        salida = args[args.index("--salida") + 1]

    tablas, relaciones = leer_esquema()
    caja = medir(tablas)

    lienzo = Lienzo()
    if modulo is None:
        pos = colocar(DISPOSICION, caja, 40, 110)
        ancho_core = max(p["x"] + p["w"] for p in pos.values())
        alto_core = max(p["y"] + p["h"] for p in pos.values())
        pos_cat = colocar(DISPOSICION_CATALOGO, caja, 40, alto_core + 150)
        pos.update(pos_cat)
        # La ultima migracion se lee de la carpeta: escrita a mano se quedo en la
        # 025 cuando ya iban por la 027.
        ultima = max(f[:3] for f in os.listdir(os.path.join(RAIZ, "migrations"))
                     if f[:3].isdigit() and f.endswith(".sql"))
        lienzo.texto_suelto(40, 20, 1400, 30,
                            "Modelo relacional de Mesh en PostgreSQL, %d tablas, migraciones 001 a %s"
                            % (len(tablas), ultima), 18, True)
        lienzo.texto_suelto(40, 54, 1400, 24,
                            "PK llave primaria, FK llave foránea, UQ valor único. La pata de gallo marca el lado "
                            "muchos. El catálogo de abajo es una isla a propósito, oferta y pedido_producto "
                            "apuntan a MongoDB por id y no por llave foránea.", 11, False, True)
        lienzo.texto_suelto(40, alto_core + 100, 900, 24, "Catálogo", 14, True)
        todas = True
    else:
        titulo, cols = VISTAS[modulo]
        global HUECO_X
        HUECO_X = 64       # en la vista recortada la letra tiene que caber en una hoja
        pos = colocar(cols, caja, 40, 80)
        lienzo.texto_suelto(40, 20, 1200, 30, titulo, 18, True)
        todas = False

    pintar(lienzo, tablas, caja, pos, relaciones)
    fallos, n_fk = comprobar(tablas, relaciones, pos, lienzo, todas)
    with io.open(salida, "w", encoding="utf-8") as f:
        f.write(lienzo.xml())
    print("  %d cajas, %d lineas -> %s" % (len(pos), n_fk, salida))
    if fallos:
        for x in fallos:
            print("  FALLA " + x)
        return 1
    print("  OK: cada tabla tiene su caja, cada llave foranea su linea, y no se pisa nada")
    exportar_png(salida)
    return 0


if __name__ == "__main__":
    sys.exit(main())
