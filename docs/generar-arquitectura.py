# -*- coding: utf-8 -*-
"""Dibuja el diagrama de arquitectura de Mesh (no es el entidad relacion).

    python docs/generar-arquitectura.py

Escribe docs/diagrama-arquitectura.drawio y, si encuentra draw.io, el .png.

Es un dibujo hecho a mano en coordenadas, no sale de la base. Lo que cambia con
el tiempo son las cifras de cada caja, y estan en la tabla CAJAS de abajo, en un
solo sitio. Se midieron el 2026-09-19 contra los contenedores vivos.

Las flechas punteadas llevan un numero y el mecanismo de cada una esta en la
leyenda de abajo. Un rotulo largo sobre una flecha de 80 puntos no se lee, y la
leyenda si.

Al final se comprueba que cada flecha nombra cajas que existen, porque un
.drawio roto no da error al abrirlo, sale en blanco.
"""
import io
import os
import subprocess
import sys
from xml.sax.saxutils import escape

BASE = os.path.dirname(os.path.abspath(__file__))
SALIDA = os.path.join(BASE, "diagrama-arquitectura.drawio")

# ---------------------------------------------------------------- las cajas

ANCHO_DB = 250
HUECO_DB = 78
Y_DB = 390
ALTO_DB = 210

# orden de izquierda a derecha pensado para que casi todos los flujos sean
# entre vecinos. clave, titulo, rol, lineas, relleno, borde
CAJAS = [
    ("neo4j", "Neo4j 5", "RELACIONES ENTRE CUENTAS", [
        "13 usuarios, 51 productos,",
        "90 reseñas y 9 domicilios",
        "3 aristas por reseña",
        "5 consultas de varios saltos",
    ], "#E1D5E7", "#9673A6"),
    ("pg", "PostgreSQL 18", "FUENTE DE VERDAD", [
        "50 tablas y 66 llaves foráneas",
        "pedidos, pagos, ofertas, stock",
        "reseñas, alertas y anillos de fraude",
        "cola evento_grafo",
    ], "#DAE8FC", "#6C8EBF"),
    ("mongo", "MongoDB", "CATÁLOGO Y LOG DE LOGIN", [
        "productos 1105, productos_eventos",
        "categorias, eventos_autenticacion",
        "atributos que varían por categoría",
        "historial por eventos",
    ], "#D5E8D4", "#82B366"),
    ("es", "Elasticsearch 8", "BÚSQUEDA DE TEXTO", [
        "mesh_productos, 1105 documentos",
        "mesh_eventos_autenticacion",
        "búsqueda difusa que ignora tildes",
    ], "#FFF2CC", "#D6B656"),
    ("ch", "ClickHouse", "EVENTOS EN EL TIEMPO", [
        "base columnar, mesh_eventos",
        "vista, carrito, compra, devolución,",
        "búsqueda y clic, más el resumen diario",
        "los rankings de tendencias salen de aquí",
    ], "#FFE6CC", "#D79B00"),
    ("redis", "Redis 8", "TRANSITORIO Y ATÓMICO", [
        "carrito con expiración por inactividad",
        "inventario limitado con script Lua",
        "candado de checkout",
        "contadores de fraude del login",
        "ranking de más vendidos",
    ], "#F8CECC", "#B85450"),
]

# flechas de coordinacion entre motores, la leyenda las explica
FLUJOS = [
    (1, "pg", "mongo", "PostgreSQL a MongoDB, etl/cargar.js por lotes, conserva lo que el vendedor edita desde la aplicación"),
    (2, "pg", "neo4j", "PostgreSQL a Neo4j, cada reseña tocada entra en la cola evento_grafo y un worker la vacía cada 10 segundos"),
    (3, "neo4j", "pg", "Neo4j a PostgreSQL, el detector de anillos corre cada 15 minutos y guarda lo que encuentra en anillo_fraude"),
    (4, "mongo", "es", "MongoDB a Elasticsearch, la marca pendiente_busqueda cada 10 segundos y los intentos de login cada 5"),
    (5, "es", "pg", "Elasticsearch a PostgreSQL, el análisis retrospectivo cada 15 minutos deja alertas en alerta_fraude"),
    (6, "redis", "pg", "Redis a PostgreSQL, un contador de fallos de login que cruza su umbral deja una fila en alerta_fraude"),
    (7, "pg", "ch", "PostgreSQL a ClickHouse, etl/cargar_compras.sh copia compras y devoluciones en cada arranque"),
    (8, "ch", "redis", "ClickHouse a Redis, un worker cada 10 minutos recalcula el ranking de más vendidos"),
]

# lo que el backend hace con cada motor, escrito sobre su flecha
USO = {
    "neo4j": "lee el panel de fraude",
    "pg": "pedidos, pagos, ofertas, reseñas",
    "mongo": "catálogo, historial, intentos de login",
    "es": "busca productos y eventos",
    "ch": "escribe eventos, lee rankings",
    "redis": "carrito, reservas, candado",
}


class Lienzo:
    def __init__(self):
        self.celdas = []
        self.n = 0

    def nid(self, p):
        self.n += 1
        return "%s-%d" % (p, self.n)

    def rect(self, id_, x, y, w, h, html, relleno, borde, redondo=True, sizes=12, dash=False, alinea="center"):
        est = ("%swhiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;fontSize=%d;align=%s;verticalAlign=top;"
               "spacing=6;%s" % ("rounded=1;arcSize=6;" if redondo else "", relleno, borde, sizes, alinea,
                                 "dashed=1;" if dash else ""))
        self.celdas.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
                           '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
                           % (id_, escape(html, {'"': "&quot;"}), est, x, y, w, h))

    def texto(self, x, y, w, h, html, tam=12, gris=False, negrita=False):
        est = ("text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=top;whiteSpace=wrap;"
               "fontSize=%d;%s%s" % (tam, "fontColor=#666666;" if gris else "", "fontStyle=1;" if negrita else ""))
        self.celdas.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
                           '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
                           % (self.nid("txt"), escape(html, {'"': "&quot;"}), est, x, y, w, h))

    def flecha(self, origen, destino, exit_xy, entry_xy, etiqueta="", puntos=None, punteada=False,
               color="#444444", grosor=1.5):
        est = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeColor=%s;"
               "strokeWidth=%s;fontSize=11;fontColor=%s;%sexitX=%.3f;exitY=%.3f;exitDx=0;exitDy=0;"
               "entryX=%.3f;entryY=%.3f;entryDx=0;entryDy=0;labelBackgroundColor=#FFFFFF;"
               % (color, grosor, color, "dashed=1;" if punteada else "", exit_xy[0], exit_xy[1],
                  entry_xy[0], entry_xy[1]))
        pts = ""
        if puntos:
            pts = "<Array as=\"points\">%s</Array>" % "".join('<mxPoint x="%d" y="%d"/>' % p for p in puntos)
        self.celdas.append('<mxCell id="%s" value="%s" style="%s" edge="1" parent="1" source="%s" target="%s">'
                           '<mxGeometry relative="1" as="geometry">%s</mxGeometry></mxCell>'
                           % (self.nid("fl"), escape(etiqueta), est, origen, destino, pts))

    def xml(self):
        return ('<mxfile host="Mesh"><diagram name="Arquitectura" id="arq-mesh">'
                '<mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" '
                'arrows="1" fold="1" page="1" pageScale="1" pageWidth="827" pageHeight="1169" math="0" '
                'shadow="0"><root><mxCell id="0"/><mxCell id="1" parent="0"/>' + "".join(self.celdas) +
                '</root></mxGraphModel></diagram></mxfile>')


def construir_grafo():
    """El modelo del grafo de Neo4j y un anillo de tres cuentas, para el informe."""
    L = Lienzo()

    def nodo(id_, x, y, w, h, texto, relleno, borde):
        est = ("ellipse;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;fontSize=16;strokeWidth=2;"
               % (relleno, borde))
        L.celdas.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
                        '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
                        % (id_, escape(texto, {'"': "&quot;"}), est, x, y, w, h))

    def rel(a, b, texto, color="#444444"):
        est = ("endArrow=block;endFill=1;html=1;strokeColor=%s;strokeWidth=2;fontSize=15;fontColor=%s;"
               "labelBackgroundColor=#FFFFFF;" % (color, color))
        L.celdas.append('<mxCell id="%s" value="%s" style="%s" edge="1" parent="1" source="%s" target="%s">'
                        '<mxGeometry relative="1" as="geometry"/></mxCell>'
                        % (L.nid("r"), escape(texto), est, a, b))

    L.texto(30, 6, 900, 34, "El grafo de Neo4j", 24, negrita=True)
    L.texto(30, 42, 900, 24, "Arriba el modelo, abajo un anillo de tres cuentas, que la consulta A.1 encuentra como un camino cerrado de seis saltos.", 14, gris=True)
    nodo("m-u1", 30, 100, 150, 74, "<b>Usuario</b><br>quien escribe", "#DAE8FC", "#6C8EBF")
    nodo("m-r", 330, 100, 150, 74, "<b>Reseña</b><br>es un nodo", "#E1D5E7", "#9673A6")
    nodo("m-u2", 630, 100, 150, 74, "<b>Usuario</b><br>quien es calificado", "#DAE8FC", "#6C8EBF")
    nodo("m-p", 330, 250, 150, 74, "<b>Producto</b><br>sobre qué", "#D5E8D4", "#82B366")
    nodo("m-d", 30, 250, 150, 74, "<b>Dirección</b><br>texto normalizado", "#FFE6CC", "#D79B00")
    rel("m-u1", "m-r", "ESCRIBIO")
    rel("m-r", "m-u2", "CALIFICA_A")
    rel("m-r", "m-p", "SOBRE")
    rel("m-u1", "m-d", "VIVE_EN")

    L.texto(30, 360, 900, 30, "Un anillo de tres cuentas", 18, negrita=True)
    pos = {"a": (30, 470), "r1": (270, 400), "b": (510, 470), "r2": (510, 620), "c": (270, 690), "r3": (30, 620)}
    for k, (x, y) in pos.items():
        if k.startswith("r"):
            nodo("a-" + k, x, y, 130, 64, "<b>Reseña</b>", "#E1D5E7", "#9673A6")
        else:
            nodo("a-" + k, x, y, 130, 64, "<b>Cuenta %s</b>" % k.upper(), "#DAE8FC", "#6C8EBF")
    rel("a-a", "a-r1", "ESCRIBIO")
    rel("a-r1", "a-b", "CALIFICA_A")
    rel("a-b", "a-r2", "ESCRIBIO")
    rel("a-r2", "a-c", "CALIFICA_A")
    rel("a-c", "a-r3", "ESCRIBIO")
    rel("a-r3", "a-a", "CALIFICA_A", "#B85450")
    L.texto(680, 520, 300, 120, "Seis saltos entre la cuenta A y ella misma. Cada reseña que se suma al anillo agrega dos saltos, por eso la consulta busca de cuatro a ocho.", 15, gris=True)
    return L


def construir_informe():
    """Variante para el informe de Word. Sin el contenido de cada caja y con la
    letra grande, porque un dibujo de 1900 de ancho metido en una hoja queda a
    4 puntos. El detalle de cada motor va en la tabla del texto."""
    L = Lienzo()
    ancho, hueco, y_db, alto = 196, 44, 235, 92
    total = len(CAJAS) * ancho + (len(CAJAS) - 1) * hueco
    x0 = 30
    L.texto(x0, 4, total, 36, "Mesh, seis motores de persistencia", 26, negrita=True)
    L.rect("cliente", x0, 52, 250, 52, "<b>Frontend</b><br>SvelteKit", "#E6E6F5", "#3D3D99", sizes=17)
    L.rect("backend", x0, 140, total, 46, "<b>Backend</b>, NestJS con Fastify", "#E6E6F5", "#3D3D99", sizes=18)
    L.flecha("cliente", "backend", (0.5, 1.0), (125.0 / total, 0.0), "")
    xs = {}
    for i, (k, titulo, rol, lineas, relleno, borde) in enumerate(CAJAS):
        x = x0 + i * (ancho + hueco)
        xs[k] = x
        corto = {"neo4j": "RELACIONES", "pg": "FUENTE DE VERDAD", "mongo": "CATÁLOGO", "es": "BÚSQUEDA",
                 "ch": "EVENTOS", "redis": "TRANSITORIO"}[k]
        L.rect(k, x, y_db, ancho, alto, "<b>%s</b><br>%s" % (titulo, corto), relleno, borde, sizes=17)
        fx = (x + ancho / 2.0 - x0) / float(total)
        L.flecha("backend", k, (fx, 1.0), (0.5, 0.0), "", color="#222222", grosor=2)
    orden = [k for k, *_ in CAJAS]
    y_bajo = {5: y_db + alto + 30, 6: y_db + alto + 60, 7: y_db + alto + 90}
    for n, a, b, _ in FLUJOS:
        ia, ib = orden.index(a), orden.index(b)
        col = "#8A5A00"
        if abs(ia - ib) == 1:
            la, lb = ((1.0, 0.0), (0.0, 0.0)) if ib > ia else ((0.0, 0.0), (1.0, 0.0))
            base = 0.28 if (a, b) in (("pg", "neo4j"), ("mongo", "es"), ("pg", "mongo"), ("ch", "redis")) else 0.72
            L.flecha(a, b, (la[0], base), (lb[0], base), str(n), punteada=True, color=col)
        else:
            y = y_bajo[n]
            xa = xs[a] + int(ancho * (0.32 + 0.12 * (n % 3)))
            xb = xs[b] + int(ancho * (0.32 + 0.12 * (n % 3)))
            L.flecha(a, b, ((xa - xs[a]) / float(ancho), 1.0), ((xb - xs[b]) / float(ancho), 1.0), str(n),
                     puntos=[(xa, y), (xb, y)], punteada=True, color=col)
    L.texto(x0, y_db + alto + 118, total, 24,
            "Flechas continuas, lo que hace el backend. Flechas punteadas, datos que viajan entre motores.", 15,
            gris=True)
    return L


def construir():
    L = Lienzo()
    ancho_total = len(CAJAS) * ANCHO_DB + (len(CAJAS) - 1) * HUECO_DB
    x0 = 40

    L.texto(x0, 14, 1500, 30, "Mesh, arquitectura políglota con seis motores de persistencia", 20, negrita=True)
    L.texto(x0, 48, 1700, 24, "Estado al 19 de septiembre de 2026. Las flechas continuas son lo que hace el backend, "
            "las punteadas y numeradas son datos que viajan de un motor a otro, y su mecanismo está en la leyenda.",
            11, gris=True)

    # cliente, workers y backend. El backend ocupa todo el ancho para que la
    # flecha a cada motor baje derecha, sin cruzar otras cajas.
    ancho_be = ancho_total
    L.rect("cliente", x0, 90, 300, 62, "<b>Frontend</b><br>SvelteKit, puerto 5173", "#E6E6F5", "#3D3D99")
    L.rect("workers", x0 + 400, 86, 1380, 70,
           "<b>Workers del backend</b><br>grafo 10 s, buscador 10 s, login a Elasticsearch 5 s, anillos 15 min, "
           "fraude retrospectivo 15 min, más vendidos 10 min, venta relámpago 1 min",
           "#FFFFFF", "#888888", sizes=11, dash=True, alinea="left")
    L.rect("backend", x0, 216, ancho_be, 56,
           "<b>Backend</b>, NestJS con Fastify, puerto 3000. Escribe en cinco motores y lee de los seis",
           "#E6E6F5", "#3D3D99")
    L.flecha("cliente", "backend", (0.08, 1.0), (0.08 * 300.0 / ancho_be, 0.0), "HTTP con cookie de sesión")

    # motores
    xs = {}
    for i, (k, titulo, rol, lineas, relleno, borde) in enumerate(CAJAS):
        x = x0 + i * (ANCHO_DB + HUECO_DB)
        xs[k] = x
        html = "<b>%s</b><br><b>%s</b><br><br>%s" % (titulo, rol, "<br>".join(lineas))
        L.rect(k, x, Y_DB, ANCHO_DB, ALTO_DB, html, relleno, borde, sizes=12)
        fx = (x + ANCHO_DB / 2.0 - x0) / float(ancho_be)
        L.flecha("backend", k, (fx, 1.0), (0.5, 0.0), USO[k], color="#222222", grosor=1.8)

    # flujos numerados. Adyacentes van por el hueco, los saltados por debajo.
    orden = [k for k, *_ in CAJAS]
    y_bajo = {5: Y_DB + ALTO_DB + 34, 6: Y_DB + ALTO_DB + 62, 7: Y_DB + ALTO_DB + 90}
    for n, a, b, _ in FLUJOS:
        ia, ib = orden.index(a), orden.index(b)
        etiqueta = str(n)
        col = "#8A5A00"
        if abs(ia - ib) == 1:
            lado_a, lado_b = ((1.0, 0.0), (0.0, 0.0)) if ib > ia else ((0.0, 0.0), (1.0, 0.0))
            # dos flechas entre el mismo par van a alturas distintas
            base = 0.30 if (a, b) in ((("pg", "neo4j")), ("mongo", "es"), ("pg", "mongo"), ("ch", "redis")) else 0.72
            L.flecha(a, b, (lado_a[0], base), (lado_b[0], base), etiqueta, punteada=True, color=col)
        else:
            y = y_bajo[n]
            xa = xs[a] + ANCHO_DB * (0.30 if ib < ia else 0.70) if False else xs[a] + int(ANCHO_DB * (0.32 + 0.12 * (n % 3)))
            xb = xs[b] + int(ANCHO_DB * (0.32 + 0.12 * (n % 3)))
            L.flecha(a, b, ((xa - xs[a]) / float(ANCHO_DB), 1.0), ((xb - xs[b]) / float(ANCHO_DB), 1.0), etiqueta,
                     puntos=[(xa, y), (xb, y)], punteada=True, color=col)

    # leyenda
    y_ley = Y_DB + ALTO_DB + 140
    L.texto(x0, y_ley, 800, 24, "Leyenda de las flechas punteadas", 13, negrita=True)
    y = y_ley + 30
    for n, a, b, texto in FLUJOS:
        L.texto(x0, y, 1800, 22, "<b>%d</b>&nbsp;&nbsp;%s" % (n, texto), 11)
        y += 22
    y += 14
    L.texto(x0, y, 1800, 22,
            "Herramientas de inspección que no son parte del sistema, pgAdmin 5050, DbGate 3001, RedisInsight 5540, "
            "Kibana 5601, Neo4j Browser 7474 y ClickHouse play 8123.", 11, gris=True)
    y += 24
    L.texto(x0, y, 1800, 22,
            "Todo corre en una sola máquina, en diez contenedores de un mismo Docker, más uno de un solo uso que prepara las "
            "vistas de Kibana. Cada motor guarda lo que le corresponde por la forma de la pregunta que va a recibir.", 11, gris=True)
    return L


def comprobar(L):
    ids = set()
    aristas = []
    for c in L.celdas:
        ids.add(c.split('id="')[1].split('"')[0])
        if ' edge="1"' in c:
            aristas.append((c.split('source="')[1].split('"')[0], c.split('target="')[1].split('"')[0]))
    fallos = ["la flecha %s a %s nombra una caja que no existe" % (s, t)
              for s, t in aristas if s not in ids or t not in ids]
    n_flujos = sum(1 for s, t in aristas)
    esperadas = 1 + len(CAJAS) + len(FLUJOS)
    if n_flujos != esperadas:
        fallos.append("hay %d flechas y se esperaban %d" % (n_flujos, esperadas))
    return fallos


def exportar_png(drawio):
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
    salida = SALIDA
    if "--salida" in sys.argv:
        salida = sys.argv[sys.argv.index("--salida") + 1]
    informe = "--informe" in sys.argv
    if "--grafo" in sys.argv:
        L = construir_grafo()
        with io.open(salida, "w", encoding="utf-8") as f:
            f.write(L.xml())
        print("  modelo del grafo -> " + salida)
        exportar_png(salida)
        return 0
    L = construir_informe() if informe else construir()
    fallos = comprobar(L)
    with io.open(salida, "w", encoding="utf-8") as f:
        f.write(L.xml())
    print("  %d elementos -> %s" % (len(L.celdas), salida))
    if fallos:
        for x in fallos:
            print("  FALLA " + x)
        return 1
    print("  OK: todas las flechas nombran cajas que existen")
    exportar_png(salida)
    return 0


if __name__ == "__main__":
    sys.exit(main())
