# -*- coding: utf-8 -*-
"""Dibuja el diagrama de arquitectura de Mesh (no es el entidad relacion).

    python docs/generar-arquitectura.py

Escribe docs/diagrama-arquitectura.drawio y, si encuentra draw.io, el .png.

Es un dibujo hecho a mano en coordenadas, no sale de la base. Lo que cambia con
el tiempo son las cifras de cada caja, y estan en la tabla CAJAS de abajo, en un
solo sitio. Se midieron el 2026-09-19 contra los contenedores vivos, y el
2026-09-25 se sumaron las reglas de descuento, la familia B de fraude y las
recomendaciones, leidas del codigo del backend.

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
ALTO_DB = 290

# orden de izquierda a derecha pensado para que casi todos los flujos sean
# entre vecinos. clave, titulo, rol, lineas, relleno, borde
CAJAS = [
    ("neo4j", "Neo4j 5", "RELACIONES ENTRE CUENTAS", [
        "cuentas, reseñas, productos,",
        "domicilios y compras como nodo",
        "anillos cerrados de varios saltos",
        "familia B, satélites, persistentes,",
        "coordinados y reputación exprés",
        "para ti y también compraron,",
        "recorridos de dos saltos en vivo",
    ], "#E1D5E7", "#9673A6"),
    ("pg", "PostgreSQL 18", "FUENTE DE VERDAD", [
        "86 tablas y 107 llaves foráneas",
        "pedidos, pagos, ofertas, stock",
        "la verdad del carrito y las reservas",
        "de venta relámpago",
        "vectores con pgvector e índice HNSW",
        "respaldo del catálogo y del buscador",
        "reseñas, señales y casos de fraude",
        "colas hacia los otros motores",
    ], "#DAE8FC", "#6C8EBF"),
    ("mongo", "MongoDB", "CATÁLOGO Y LOG DE LOGIN", [
        "productos 1003, productos_eventos",
        "categorias, eventos_autenticacion",
        "atributos que varían por categoría",
        "historial por eventos",
        "el texto de donde sale el vector",
    ], "#D5E8D4", "#82B366"),
    ("es", "Elasticsearch 8", "BÚSQUEDA DE TEXTO", [
        "mesh_productos, 1003 productos",
        "mesh_ofertas, buscador del vendedor",
        "mesh_seguimientos, avísame",
        "con percolator",
        "mesh_eventos_autenticacion",
        "búsqueda difusa que ignora tildes",
        "quisiste decir y facetas",
        "granja de registros por IP",
    ], "#FFF2CC", "#D6B656"),
    ("ch", "ClickHouse", "EVENTOS EN EL TIEMPO", [
        "base columnar, mesh_eventos",
        "vista, carrito, compra, devolución,",
        "búsqueda y clic, más el resumen diario",
        "tendencias, embudo y búsquedas",
        "sin resultados",
        "más vistos, también vieron",
        "y combos de 2 y 3 productos",
        "hallazgos de compras y navegación",
    ], "#FFE6CC", "#D79B00"),
    ("redis", "Redis 8", "TRANSITORIO Y ATÓMICO", [
        "copia rápida del carrito",
        "venta relámpago con script Lua",
        "candado de checkout",
        "contadores de fraude del login",
        "cuatro usuarios de ACL por servicio",
        "más vendidos, más vistos, combos",
        "y también vieron, ya calculados",
    ], "#F8CECC", "#B85450"),
]

# flechas de coordinacion entre motores, la leyenda las explica
FLUJOS = [
    (1, "pg", "mongo", "PostgreSQL a MongoDB, etl/cargar.js por lotes, conserva lo que el vendedor edita desde la aplicación, y la cola evento_producto, que un worker vacía cada 5 segundos recalculando precio, stock y nota del producto que cambió"),
    (2, "pg", "neo4j", "PostgreSQL a Neo4j, cada reseña tocada entra en la cola evento_grafo y cada compra en evento_grafo_compra, y un worker vacía cada una cada 10 segundos"),
    (3, "neo4j", "pg", "Neo4j a PostgreSQL, los detectores de anillos y de la familia B corren cada 15 minutos, B también al llegar una reseña, y guardan lo que encuentran en senal_fraude"),
    (4, "mongo", "es", "MongoDB a Elasticsearch, la marca pendiente_busqueda cada 10 segundos y los intentos de login cada 5"),
    (5, "es", "pg", "Elasticsearch a PostgreSQL, el análisis retrospectivo del login y la granja de registros por IP corren cada 15 minutos y dejan señales en senal_fraude"),
    (6, "redis", "pg", "Redis a PostgreSQL, un contador de fallos de login que cruza su umbral deja o suma una señal en senal_fraude"),
    (7, "pg", "ch", "PostgreSQL a ClickHouse, etl/cargar_compras.sh copia compras y devoluciones en cada arranque y borra las de los pedidos anotados en pedido_quitado"),
    (8, "ch", "redis", "ClickHouse a Redis, cada 10 minutos se recalculan más vendidos y más vistos, cada 15 también vieron y cada 30 los combos"),
    (9, "ch", "pg", "ClickHouse a PostgreSQL, cada 60 segundos el disparador cuenta las ventas recientes y aplica la regla automática, y una vez al día los hallazgos de compras y navegación van a senal_fraude"),
    (10, "pg", "redis", "PostgreSQL a Redis, cada 10 segundos las reservas de venta relámpago guardadas en PostgreSQL rehacen el contador de Redis si se perdió, y cada 10 minutos se borran en las dos los carritos vencidos"),
    (11, "mongo", "pg", "MongoDB a PostgreSQL, el nombre, estado y portada de cada producto y variante se copian a producto_catalogo y variante_catalogo para comprar y ver la tienda sin MongoDB, y cada 10 segundos el texto de cada producto que cambió pasa por Ollama y su vector queda en vector_producto"),
    (12, "pg", "es", "PostgreSQL a Elasticsearch, cada oferta tocada entra en la cola evento_oferta, un worker la indexa en mesh_ofertas cada 5 segundos y la percola contra mesh_seguimientos, y el aviso queda en PostgreSQL"),
]

# con que usuario entra el backend a cada motor (control de acceso, ADR-14)
USUARIO = {
    "neo4j": "el backend entra como neo4j,<br>community no trae roles",
    "pg": "el backend entra como mesh_backend,<br>filas sí, tablas no",
    "mongo": "el backend entra como mesh_backend,<br>documentos sí, colecciones no",
    "es": "con seguridad, el backend entra como<br>mesh_backend, solo índices mesh_*",
    "ch": "el backend entra como mesh_backend,<br>leer y agregar eventos",
    "redis": "el backend entra como backend,<br>solo las claves mesh:*",
}

# Las flechas que saltan cajas van por debajo, todas desde o hacia PostgreSQL.
# Van anidadas para que ninguna cruce a otra. La que va mas lejos sale mas a la
# izquierda de PostgreSQL, baja mas y llega mas a la derecha del destino.
# numero de flujo, fraccion en PostgreSQL, fraccion en el otro motor, nivel
DEBAJO = {
    5: (0.92, 0.10, 0), 12: (0.82, 0.22, 1),
    9: (0.70, 0.10, 2), 7: (0.58, 0.22, 3),
    6: (0.46, 0.10, 4), 10: (0.34, 0.22, 5),
}

# lo que el backend hace con cada motor, escrito sobre su flecha
USO = {
    "neo4j": "para ti, también compraron y fraude",
    "pg": "pedidos, pagos, carrito, reseñas, vectores",
    "mongo": "catálogo, historial, intentos de login",
    "es": "busca productos y ofertas, avísame",
    "ch": "escribe eventos, lee tendencias y rankings",
    "redis": "carrito, venta relámpago, candado",
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
    L.texto(x0, 48, 1700, 24, "Estado al 23 de octubre de 2026. Las flechas continuas son lo que hace el backend, "
            "las punteadas y numeradas son datos que viajan de un motor a otro, y su mecanismo está en la leyenda.",
            11, gris=True)

    # cliente, workers y backend. El backend ocupa todo el ancho para que la
    # flecha a cada motor baje derecha, sin cruzar otras cajas.
    ancho_be = ancho_total
    L.rect("cliente", x0, 90, 300, 62, "<b>Frontend</b><br>SvelteKit, puerto 5173", "#E6E6F5", "#3D3D99")
    x_ollama = x0 + (len(CAJAS) - 1) * (ANCHO_DB + HUECO_DB)
    L.rect("workers", x0 + 400, 80, x_ollama - x0 - 430, 104,
           "<b>Workers del backend</b><br>grafo de reseñas y de compras 10 s, buscador 10 s, catálogo a MongoDB 5 s, "
           "ofertas a Elasticsearch 5 s, login a Elasticsearch 5 s, vectores de productos y de reseñas 10 s, clasificador de reseñas 30 s, "
           "reservas de venta relámpago 10 s, ventas relámpago y descuentos vencidos 1 min, reglas automáticas 60 s, reglas por fecha 15 min, "
           "carritos vencidos 10 min, más vendidos y más vistos 10 min, también vieron 15 min, combos 30 min, registro de ofertas en Redis 10 min, "
           "anillos, familia B, señales de texto y de compras canceladas 15 min y al momento, fraude retrospectivo del login 15 min, "
           "casos de fraude 15 min, hallazgos de compras y navegación cada día",
           "#FFFFFF", "#888888", sizes=11, dash=True, alinea="left")
    L.rect("backend", x0, 216, ancho_be, 56,
           "<b>Backend</b>, NestJS con Fastify, puerto 3000. Lee y escribe en los seis motores",
           "#E6E6F5", "#3D3D99")
    L.flecha("cliente", "backend", (0.08, 1.0), (0.08 * 300.0 / ancho_be, 0.0), "HTTP con cookie de sesión")

    # Ollama, en la misma PC que el backend. Convierte el texto en vectores
    # para pgvector (flujo 11) y la frase de quien busca en la híbrida.
    L.rect("ollama", x_ollama, 80, ANCHO_DB, 104,
           "<b>Ollama</b><br>paraphrase-multilingual<br>texto a 768 números, en la<br>misma PC, sin servicio externo",
           "#F5F5F5", "#666666", sizes=11)
    fo = (x_ollama + ANCHO_DB / 2.0 - x0) / float(ancho_be)
    L.flecha("backend", "ollama", (fo, 0.0), (0.5, 1.0), "", color="#222222", grosor=1.8)

    # Las seis bases pueden correr en otra PC (modo remoto, remoto/README.md).
    # El rotulo va abajo, bajo MongoDB, donde no pasa ninguna flecha.
    L.rect("remoto", x0 - 14, Y_DB - 30, ancho_total + 28, ALTO_DB + 58, "", "#FFFFFF", "#999999",
           redondo=False, dash=True)
    x_mongo = x0 + 2 * (ANCHO_DB + HUECO_DB)
    L.texto(x_mongo - 20, Y_DB + ALTO_DB + 4, ANCHO_DB + 60, 20,
            "Las seis bases, en esta PC o en otra por Tailscale", 11, gris=True)

    # motores
    xs = {}
    for i, (k, titulo, rol, lineas, relleno, borde) in enumerate(CAJAS):
        x = x0 + i * (ANCHO_DB + HUECO_DB)
        xs[k] = x
        html = "<b>%s</b><br><b>%s</b><br><br>%s<br><br><i>%s</i>" % (titulo, rol, "<br>".join(lineas), USUARIO[k])
        L.rect(k, x, Y_DB, ANCHO_DB, ALTO_DB, html, relleno, borde, sizes=12)
        fx = (x + ANCHO_DB / 2.0 - x0) / float(ancho_be)
        L.flecha("backend", k, (fx, 1.0), (0.5, 0.0), USO[k], color="#222222", grosor=1.8)

    # flujos numerados. Adyacentes van por el hueco, los saltados por debajo.
    orden = [k for k, *_ in CAJAS]
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
            en_pg, en_otro, nivel = DEBAJO[n]
            fa, fb = (en_pg, en_otro) if a == "pg" else (en_otro, en_pg)
            y = Y_DB + ALTO_DB + 48 + nivel * 28
            xa = xs[a] + int(ANCHO_DB * fa)
            xb = xs[b] + int(ANCHO_DB * fb)
            L.flecha(a, b, (fa, 1.0), (fb, 1.0), etiqueta, puntos=[(xa, y), (xb, y)], punteada=True, color=col)

    # leyenda
    y_ley = Y_DB + ALTO_DB + 236
    L.texto(x0, y_ley, 800, 24, "Leyenda de las flechas punteadas", 13, negrita=True)
    y = y_ley + 30
    for n, a, b, texto in FLUJOS:
        L.texto(x0, y, 1800, 22, "<b>%d</b>&nbsp;&nbsp;%s" % (n, texto), 11)
        y += 22
    y += 14
    L.texto(x0, y, 1800, 22,
            "Herramientas de inspección que no son parte del sistema, solo en 127.0.0.1, pgAdmin 5050, DbGate 3001 como "
            "mesh_lectura, RedisInsight 5540 como inspeccion, Kibana 5601, Neo4j Browser 7474 y ClickHouse play 8123. "
            "Las seis bases piden usuario y contraseña.", 11, gris=True)
    y += 24
    L.texto(x0, y, 1800, 22,
            "Todo corre en diez contenedores de un mismo Docker, más dos de un solo uso que preparan las vistas de Kibana y los usuarios "
            "de Elasticsearch, y el de Ollama, que solo se levanta si la PC no lo tiene. Cada motor guarda lo que le corresponde por la forma de la pregunta que va a recibir.", 11, gris=True)
    return L


def comprobar(L, extra=0):
    ids = set()
    aristas = []
    for c in L.celdas:
        ids.add(c.split('id="')[1].split('"')[0])
        if ' edge="1"' in c:
            aristas.append((c.split('source="')[1].split('"')[0], c.split('target="')[1].split('"')[0]))
    fallos = ["la flecha %s a %s nombra una caja que no existe" % (s, t)
              for s, t in aristas if s not in ids or t not in ids]
    n_flujos = sum(1 for s, t in aristas)
    esperadas = 1 + len(CAJAS) + len(FLUJOS) + extra
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
    # la version completa lleva ademas la flecha del backend a Ollama
    fallos = comprobar(L, 0 if informe else 1)
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
