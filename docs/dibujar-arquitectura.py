# -*- coding: utf-8 -*-
"""Dibuja el diagrama de arquitectura de Mesh en SVG y lo pasa a PNG.

    python docs/dibujar-arquitectura.py

Escribe docs/diagrama-arquitectura.svg y docs/diagrama-arquitectura.png, y
copia el PNG a presentacion-final/img/arquitectura.png, que es la lamina 6.
El Word final usa docs/diagrama-arquitectura.png.

Sigue la notacion del modelo C4, nivel de contenedores, junto con el despliegue:
un titulo que dice que se ve, una leyenda que explica cada forma y cada linea,
flechas de una sola direccion con su rotulo, el cilindro para cada base y un
recuadro punteado para cada maquina. Va en blanco y negro a proposito: lo que
distingue una cosa de otra es la forma, el grosor y el tipo de linea, no el
color, asi que se lee igual impreso.

La idea que tiene que verse de un vistazo: PostgreSQL es la fuente de verdad y
va abajo, ancha, como el cimiento. Las otras cinco bases estan encima y cada una
se conecta con ella por dos flechas cortas y numeradas, ida y vuelta. El numero
lleva a la tabla de abajo, que dice que viaja y como.

El PNG sale de Edge sin ventana, a doble resolucion. Edge sin ventana deja
procesos vivos al terminar, asi que se cierran por su carpeta de perfil.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
from xml.sax.saxutils import escape

BASE = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(BASE)
SVG = os.path.join(BASE, "diagrama-arquitectura.svg")
PNG = os.path.join(BASE, "diagrama-arquitectura.png")
LAMINA = os.path.join(RAIZ, "presentacion-final", "img", "arquitectura.png")

ANCHO, ALTO = 1600, 1240
FUENTE = "Segoe UI, Helvetica Neue, Arial, sans-serif"
NEGRO, GRIS, GRIS_CLARO = "#111111", "#4a4a4a", "#777777"
FONDO_PIEZA, FONDO_TAPA, FONDO_VERDAD = "#f4f4f4", "#e8e8e8", "#e2e2e2"

partes = []


def add(s):
    partes.append(s)


def texto(x, y, s, tam=13, peso="normal", ancla="start", color=NEGRO, estilo="normal", espacio=0):
    extra = ' letter-spacing="%s"' % espacio if espacio else ""
    add('<text x="%s" y="%s" font-size="%s" font-weight="%s" text-anchor="%s" fill="%s" font-style="%s"%s>%s</text>'
        % (x, y, tam, peso, ancla, color, estilo, extra, escape(s)))


def caja(x, y, w, h, relleno="#ffffff", grosor=1.4, radio=8, trazo=NEGRO, guiones=None):
    g = ' stroke-dasharray="%s"' % guiones if guiones else ""
    add('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s" stroke="%s" stroke-width="%s"%s/>'
        % (x, y, w, h, radio, relleno, trazo, grosor, g))


def linea(x1, y1, x2, y2, punteada=False, flecha=True, grosor=1.4, color=NEGRO):
    g = ' stroke-dasharray="6 4"' if punteada else ""
    m = ' marker-end="url(#%s)"' % ("punta-p" if punteada else "punta") if flecha else ""
    add('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="%s"%s%s/>'
        % (x1, y1, x2, y2, color, grosor, g, m))


def numero(cx, cy, n):
    add('<circle cx="%s" cy="%s" r="10" fill="#ffffff" stroke="%s" stroke-width="1.3"/>' % (cx, cy, NEGRO))
    texto(cx, cy + 4, str(n), 11, "bold", "middle")


def cilindro(x, y, w, h, ry=14, relleno="#ffffff", tapa=FONDO_TAPA, grosor=1.4):
    add('<path d="M%s,%s L%s,%s A%s,%s 0 0 0 %s,%s L%s,%s" fill="%s" stroke="%s" stroke-width="%s"/>'
        % (x, y + ry, x, y + h, w / 2, ry, x + w, y + h, x + w, y + ry, relleno, NEGRO, grosor))
    add('<ellipse cx="%s" cy="%s" rx="%s" ry="%s" fill="%s" stroke="%s" stroke-width="%s"/>'
        % (x + w / 2, y + ry, w / 2, ry, tapa, NEGRO, grosor))


# ---------------------------------------------------------------- iconos
# Dibujos de linea, de unos 26 puntos, todos con el mismo trazo.
TRAZO = 'fill="none" stroke="%s" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"' % NEGRO


def icono_persona(cx, y):
    add('<circle cx="%s" cy="%s" r="9" fill="#ffffff" stroke="%s" stroke-width="1.6"/>' % (cx, y + 10, NEGRO))
    add('<path d="M%s,%s q0,-21 18,-21 q18,0 18,21 z" fill="#ffffff" stroke="%s" stroke-width="1.6" stroke-linejoin="round"/>'
        % (cx - 18, y + 46, NEGRO))


def icono_navegador(x, y):
    add('<rect x="%s" y="%s" width="30" height="24" rx="3" %s/>' % (x, y, TRAZO))
    add('<line x1="%s" y1="%s" x2="%s" y2="%s" %s/>' % (x, y + 7, x + 30, y + 7, TRAZO))
    for i in range(3):
        add('<circle cx="%s" cy="%s" r="1.3" fill="%s"/>' % (x + 4 + i * 4, y + 3.6, NEGRO))
    add('<path d="M%s,%s l-4,4 l4,4 M%s,%s l4,4 l-4,4" %s/>' % (x + 11, y + 12, x + 19, y + 12, TRAZO))


def icono_servidor(x, y):
    for i in range(3):
        add('<rect x="%s" y="%s" width="28" height="8" rx="2" %s/>' % (x, y + i * 10, TRAZO))
        add('<circle cx="%s" cy="%s" r="1.4" fill="%s"/>' % (x + 23, y + 4 + i * 10, NEGRO))
        add('<line x1="%s" y1="%s" x2="%s" y2="%s" %s/>' % (x + 4, y + 4 + i * 10, x + 12, y + 4 + i * 10, TRAZO))


def icono_chip(x, y):
    add('<rect x="%s" y="%s" width="20" height="20" rx="3" %s/>' % (x + 5, y + 5, TRAZO))
    add('<rect x="%s" y="%s" width="8" height="8" rx="1" %s/>' % (x + 11, y + 11, TRAZO))
    for i in range(3):
        p = 10 + i * 5
        add('<path d="M%s,%s v-4 M%s,%s v4 M%s,%s h-4 M%s,%s h4" %s/>'
            % (x + p, y + 5, x + p, y + 25, x + 5, y + p, x + 25, y + p, TRAZO))


def icono_escudo(x, y):
    add('<path d="M%s,%s l9,-3 l9,3 v7 c0,6 -4,10 -9,12 c-5,-2 -9,-6 -9,-12 z" %s/>' % (x, y + 4, TRAZO))
    add('<path d="M%s,%s l3,3 l5,-6" %s/>' % (x + 5, y + 11, TRAZO))


def icono_codigo(x, y):
    add('<path d="M%s,%s l-6,6 l6,6 M%s,%s l6,6 l-6,6 M%s,%s l-4,14" %s/>'
        % (x + 6, y + 3, x + 14, y + 3, x + 12, y + 2, TRAZO))


def icono_engrane(x, y):
    cx, cy = x + 10, y + 10
    add('<circle cx="%s" cy="%s" r="6" %s/>' % (cx, cy, TRAZO))
    add('<circle cx="%s" cy="%s" r="2" %s/>' % (cx, cy, TRAZO))
    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7), (-0.7, -0.7)):
        add('<line x1="%s" y1="%s" x2="%s" y2="%s" %s/>' % (cx + dx * 7, cy + dy * 7, cx + dx * 10, cy + dy * 10, TRAZO))


def icono_rayo(x, y):
    add('<path d="M%s,%s l-7,10 h6 l-3,10 l9,-12 h-6 l3,-8 z" %s/>' % (x + 12, y + 0, TRAZO))


def icono_candado(x, y):
    add('<rect x="%s" y="%s" width="16" height="12" rx="2" %s/>' % (x, y + 8, TRAZO))
    add('<path d="M%s,%s v-3 a5,5 0 0 1 10,0 v3" %s/>' % (x + 3, y + 8, TRAZO))


def glifo_tabla(cx, y):
    x = cx - 13
    add('<rect x="%s" y="%s" width="26" height="20" rx="2" %s/>' % (x, y, TRAZO))
    add('<path d="M%s,%s h26 M%s,%s h26 M%s,%s v14" %s/>' % (x, y + 6, x, y + 13, x + 10, y + 6, TRAZO))


def glifo_documento(cx, y):
    x = cx - 9
    add('<path d="M%s,%s h12 l6,6 v16 h-18 z M%s,%s v6 h6" %s/>' % (x, y, x + 12, y, TRAZO))
    add('<path d="M%s,%s h10 M%s,%s h10 M%s,%s h7" %s/>' % (x + 4, y + 10, x + 4, y + 14, x + 4, y + 18, TRAZO))


def glifo_lupa(cx, y):
    add('<circle cx="%s" cy="%s" r="7" %s/>' % (cx - 2, y + 8, TRAZO))
    add('<line x1="%s" y1="%s" x2="%s" y2="%s" %s/>' % (cx + 3, y + 13, cx + 9, y + 19, TRAZO))


def glifo_grafo(cx, y):
    pts = ((cx - 10, y + 16), (cx, y + 3), (cx + 10, y + 16), (cx + 1, y + 19))
    add('<path d="M%s,%s L%s,%s L%s,%s L%s,%s Z" %s/>'
        % (pts[0][0], pts[0][1], pts[1][0], pts[1][1], pts[2][0], pts[2][1], pts[3][0], pts[3][1], TRAZO))
    for px, py in pts:
        add('<circle cx="%s" cy="%s" r="3" fill="#ffffff" stroke="%s" stroke-width="1.6"/>' % (px, py, NEGRO))


def glifo_llave(cx, y):
    add('<circle cx="%s" cy="%s" r="5" %s/>' % (cx - 7, y + 10, TRAZO))
    add('<path d="M%s,%s h15 M%s,%s v4 M%s,%s v3" %s/>' % (cx - 2, y + 10, cx + 9, y + 10, cx + 5, y + 10, TRAZO))


def glifo_columnas(cx, y):
    for i, h in enumerate((10, 16, 8, 20)):
        add('<rect x="%s" y="%s" width="4" height="%s" %s/>' % (cx - 11 + i * 6, y + 20 - h, h, TRAZO))


# ---------------------------------------------------------------- el dibujo
PG_X, PG_ANCHO, PG_RY = 120, 1380, 14


def borde_pg(x, pg_top):
    """La altura de la curva de arriba de PostgreSQL en esa x, para que cada
    flecha toque la elipse justo, cerca del centro y cerca de las puntas."""
    rx = PG_ANCHO / 2.0
    dx = (x - (PG_X + rx)) / rx
    return round(pg_top + PG_RY - PG_RY * max(0.0, 1 - dx * dx) ** 0.5, 1)


def dibujar():
    add('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="%s">'
        % (ANCHO, ALTO, ANCHO, ALTO, FUENTE))
    add('<defs>'
        '<marker id="punta" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="9" markerHeight="9" markerUnits="userSpaceOnUse" orient="auto">'
        '<path d="M0,0 L10,5 L0,10 z" fill="%s"/></marker>'
        '<marker id="punta-p" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="9" markerHeight="9" markerUnits="userSpaceOnUse" orient="auto">'
        '<path d="M0,0 L10,5 L0,10 z" fill="%s"/></marker>'
        '</defs>' % (NEGRO, NEGRO))
    add('<rect width="100%" height="100%" fill="#ffffff"/>')

    # titulo
    texto(40, 54, "Mesh, diagrama de arquitectura", 28, "bold")
    texto(40, 82, "Contenedores y despliegue, al 8 de noviembre de 2026. Entrega final de Bases de Datos 2.", 15, "normal", color=GRIS)
    add('<line x1="40" y1="100" x2="1040" y2="100" stroke="%s" stroke-width="1"/>' % GRIS_CLARO)

    # leyenda, arriba a la derecha
    lx, ly = 1090, 22
    caja(lx, ly, 470, 176, "#ffffff", 1, 6, GRIS_CLARO)
    texto(lx + 16, ly + 24, "Cómo leerlo", 13, "bold")
    linea(lx + 16, ly + 46, lx + 70, ly + 46)
    texto(lx + 82, ly + 50, "Petición en línea del backend, con su protocolo", 12)
    linea(lx + 16, ly + 74, lx + 70, ly + 74, punteada=True)
    numero(lx + 43, ly + 74, 1)
    texto(lx + 82, ly + 78, "Copia de fondo entre bases, la tabla dice qué viaja", 12)
    caja(lx + 16, ly + 92, 54, 24, "#ffffff", 1.4, 5)
    texto(lx + 82, ly + 109, "Aplicación o servicio", 12)
    cilindro(lx + 262, ly + 90, 34, 30, 6)
    texto(lx + 306, ly + 109, "Base de datos", 12)
    caja(lx + 16, ly + 130, 54, 24, "#ffffff", 1.2, 6, GRIS_CLARO, "6 4")
    texto(lx + 82, ly + 147, "Máquina donde corre", 12)
    cilindro(lx + 262, ly + 128, 34, 30, 6, FONDO_VERDAD, "#d2d2d2", 2.4)
    texto(lx + 306, ly + 147, "Fuente de verdad", 12)

    # personas
    for cx, nombre in ((565, "Compradora"), (675, "Vendedor"), (785, "Administrador")):
        icono_persona(cx, 108)
        texto(cx, 172, nombre, 13, "normal", "middle")
    linea(675, 182, 675, 262)
    texto(683, 210, "Usan la tienda en el navegador, HTTPS", 12, color=GRIS)

    # PC de la aplicacion
    caja(40, 222, 1520, 320, "#ffffff", 1.2, 10, GRIS_CLARO, "6 4")
    texto(56, 246, "PC DE LA APLICACIÓN, NODE.JS", 11, "bold", color=GRIS, espacio=1)

    # tienda web
    caja(505, 262, 340, 104)
    icono_navegador(521, 276)
    texto(563, 294, "Tienda web", 18, "bold")
    texto(521, 322, "SvelteKit 2, Svelte 5, Vite 8, puerto 5173", 12, color=GRIS)
    texto(521, 344, "Páginas de compradora, vendedor y admin.", 13)
    texto(521, 360, "Pasa cada /api al backend.", 13)

    # Ollama
    caja(1150, 262, 330, 104)
    icono_chip(1164, 272)
    texto(1206, 294, "Ollama", 18, "bold")
    texto(1166, 322, "paraphrase-multilingual, puerto 11434", 12, color=GRIS)
    texto(1166, 344, "Convierte texto en un vector de 768", 13)
    texto(1166, 360, "números, en la misma PC y sin costo.", 13)

    # backend
    caja(120, 404, 1380, 124)
    icono_servidor(138, 424)
    texto(178, 444, "Backend", 18, "bold")
    texto(138, 472, "NestJS 11 sobre Fastify, puerto 3000", 12, color=GRIS)
    texto(138, 494, "Lo único que habla con las bases.", 13)
    texto(138, 510, "Toda respuesta trae ok, mensaje y payload.", 13)
    piezas = (
        (icono_escudo, "Guards", "Sesión, 401 sin cookie.", "Permiso por rol, 403."),
        (icono_codigo, "API REST", "179 rutas, cada una con", "su controller y su service."),
        (icono_engrane, "Workers", "31 tareas de fondo que", "mueven las copias numeradas."),
        (icono_rayo, "Cortacircuitos", "Si una base no contesta,", "usa su respaldo 15 s."),
    )
    for i, (ico, t, l1, l2) in enumerate(piezas):
        x = 440 + i * 266
        caja(x, 418, 246, 96, FONDO_PIEZA, 1.2, 6)
        ico(x + 14, 430)
        texto(x + 46, 448, t, 14, "bold")
        texto(x + 14, 478, l1, 12)
        texto(x + 14, 495, l2, 12)

    # flechas de la PC de la aplicacion
    linea(675, 366, 675, 404)
    texto(683, 390, "JSON por HTTP, con la cookie de sesión", 12, color=GRIS)
    linea(1315, 404, 1315, 366)
    texto(1323, 390, "Pide vectores, HTTP", 12, color=GRIS)

    # entre las dos PC
    icono_candado(963, 562)
    texto(985, 576, "Tailscale", 13, "bold")
    texto(985, 592, "red privada y cifrada", 12, color=GRIS)

    # PC de las bases
    caja(40, 608, 1520, 424, "#ffffff", 1.2, 10, GRIS_CLARO, "6 4")
    texto(56, 1020, "PC DE LAS BASES, DOCKER, 100.64.42.11", 11, "bold", color=GRIS, espacio=1)

    bases = (
        (220, glifo_documento, "MongoDB 8", "puerto 27018", "CATÁLOGO E HISTORIAL", "productos y sus eventos,", "registro de entradas", "entra como mesh_backend", "driver MongoDB"),
        (490, glifo_lupa, "Elasticsearch 8.15", "puerto 9200", "BÚSQUEDA DE TEXTO", "productos, ofertas, avísame,", "registro de entradas", "entra como mesh_backend", "HTTP REST"),
        (860, glifo_grafo, "Neo4j 5", "puerto 7687", "RELACIONES", "reseñas y compras en grafo,", "anillos y para ti", "entra como neo4j, sin roles", "Bolt, Cypher"),
        (1130, glifo_llave, "Redis 8", "puerto 6379", "RÁPIDO Y ATÓMICO", "copia del carrito, script Lua,", "contadores y rankings", "entra como backend", "RESP"),
        (1400, glifo_columnas, "ClickHouse 25.3", "puerto 8123", "EVENTOS EN EL TIEMPO", "vistas, compras, búsquedas,", "tendencias", "entra como mesh_backend", "HTTP, SQL"),
    )
    top, alto = 650, 182
    for cx, glifo, nombre, puerto, rol, d1, d2, usuario, protocolo in bases:
        # peticion en linea del backend a esta base
        linea(cx, 528, cx, top)
        texto(cx + 7, 638, protocolo, 12, color=GRIS)
        cilindro(cx - 100, top, 200, alto)
        glifo(cx, top + 32)
        texto(cx, top + 78, nombre, 15, "bold", "middle")
        texto(cx, top + 95, puerto, 11, color=GRIS, ancla="middle")
        texto(cx, top + 116, rol, 11, "bold", "middle", espacio=0.6)
        texto(cx, top + 134, d1, 12, ancla="middle")
        texto(cx, top + 150, d2, 12, ancla="middle")
        texto(cx, top + 172, usuario, 11, color=GRIS, ancla="middle", estilo="italic")

    # PostgreSQL, el cimiento
    pg_top = 898
    linea(675, 528, 675, borde_pg(675, pg_top))
    texto(682, 638, "SQL", 12, color=GRIS)
    cilindro(PG_X, pg_top, PG_ANCHO, 84, PG_RY, FONDO_VERDAD, "#d2d2d2", 2.4)
    glifo_tabla(150, pg_top + 36)
    texto(180, pg_top + 50, "PostgreSQL 18 con pgvector", 17, "bold")
    texto(420, pg_top + 50, "puerto 5432", 11, color=GRIS)
    texto(510, pg_top + 50, "FUENTE DE VERDAD", 11, "bold", espacio=0.6)
    texto(180, pg_top + 70, "Pedidos, pagos, stock y ofertas, el carrito de verdad, reseñas, señales de fraude, vectores con índice HNSW y permisos.", 13)
    texto(180, pg_top + 88, "96 tablas y 126 llaves foráneas. Lo que guardan las otras bases se puede rehacer desde aquí.", 13)
    texto(1480, pg_top + 50, "entra como mesh_backend", 11, color=GRIS, ancla="end", estilo="italic")

    # copias de fondo, ida y vuelta entre cada base y PostgreSQL
    numeros = {220: (1, 2), 490: (4, 5), 860: (6, 7), 1130: (8, 9), 1400: (11, 12)}
    y_abajo = top + alto + 15
    for cx, (ida, vuelta) in numeros.items():
        for dx, n, sube in ((-28, ida, True), (28, vuelta, False)):
            x = cx + dx
            y_pg = borde_pg(x, pg_top)
            if sube:
                linea(x, y_pg, x, y_abajo, punteada=True)
            else:
                linea(x, y_abajo, x, y_pg, punteada=True)
            numero(x, (y_abajo + y_pg) / 2, n)
    # entre vecinas
    linea(320, top + 92, 390, top + 92, punteada=True)
    numero(355, top + 92, 3)
    linea(1300, top + 92, 1230, top + 92, punteada=True)
    numero(1265, top + 92, 10)

    # la tabla de las copias
    texto(40, 1062, "Las copias de fondo, qué viaja y cómo. Las mueven los workers del backend o un ETL del arranque.", 14, "bold")
    filas = (
        (1, "PostgreSQL a MongoDB. Precio, stock y nota del producto, cola evento_producto, cada 5 s."),
        (2, "MongoDB a PostgreSQL. Copia del catálogo y los dos textos que Ollama pasa a vector_producto, cada 10 s."),
        (3, "MongoDB a Elasticsearch. Productos con la bandera pendiente_busqueda, cada 10 s."),
        (4, "PostgreSQL a Elasticsearch. Ofertas por la cola evento_oferta y el percolator del avísame, 5 s."),
        (5, "Elasticsearch a PostgreSQL. Señales del login lento y de la granja de registros, cada 15 min."),
        (6, "PostgreSQL a Neo4j. Reseñas y compras por las colas evento_grafo, cada 10 s."),
        (7, "Neo4j a PostgreSQL. Señales de anillos de reseñas, cada 15 min y al llegar una reseña."),
        (8, "PostgreSQL a Redis. Las reservas rehacen el contador de la venta relámpago, cada 10 s."),
        (9, "Redis a PostgreSQL. La copia del carrito al pedido pendiente y las señales del login."),
        (10, "ClickHouse a Redis. Más vendidos y más vistos cada 10 min, y los combos cada 30 min."),
        (11, "PostgreSQL a ClickHouse. Compras y devoluciones con etl/cargar_compras.sh, en cada arranque."),
        (12, "ClickHouse a PostgreSQL. Ventas para las reglas automáticas cada minuto, y señales de compras cada día."),
    )
    for i, (n, s) in enumerate(filas):
        col, fila = divmod(i, 6)
        x, y = 40 + col * 770, 1090 + fila * 22
        numero(x + 10, y - 4, n)
        texto(x + 28, y, s, 12.5)
    texto(40, 1228, "Fuera del sistema, solo en 127.0.0.1, quedan las ventanas de inspección, pgAdmin, DbGate, RedisInsight, Kibana, Neo4j Browser y ClickHouse play.",
          12, color=GRIS)
    add("</svg>")
    return "\n".join(partes)


# ---------------------------------------------------------------- a PNG
def edge():
    for c in (r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
              r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"):
        if os.path.exists(c):
            return c
    return None


def a_png(svg, png, escala=2):
    exe = edge()
    if not exe:
        print("  No encontre Edge, el PNG no se genero. El SVG si esta.")
        return False
    perfil = tempfile.mkdtemp(prefix="mesh-arq-edge-")
    if os.path.exists(png):
        os.remove(png)
    url = "file:///" + svg.replace("\\", "/")
    cmd = [exe, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
           "--user-data-dir=" + perfil, "--force-device-scale-factor=%d" % escala,
           "--default-background-color=FFFFFFFF", "--window-size=%d,%d" % (ANCHO, ALTO),
           "--screenshot=" + png, url]
    try:
        subprocess.run(cmd, capture_output=True, timeout=90,
                       creationflags=0x08000000 if os.name == "nt" else 0)
        # Edge devuelve el control ANTES de escribir la captura: la escribe un
        # proceso hijo un momento despues. Cerrarlo ya la corta (paso el 8 de
        # noviembre, la primera corrida salio y la segunda no). Se espera a que
        # el archivo exista y deje de crecer.
        antes, quieto = -1, 0
        for _ in range(120):
            tam = os.path.getsize(png) if os.path.exists(png) else -1
            quieto = quieto + 1 if tam > 0 and tam == antes else 0
            if quieto >= 3:
                break
            antes = tam
            time.sleep(0.5)
    except subprocess.TimeoutExpired:
        print("  Edge no termino en 90 s")
    finally:
        # Edge sin ventana deja hijos vivos: se cierran por la carpeta de perfil
        if os.name == "nt":
            subprocess.run(["powershell", "-NoProfile", "-Command",
                            "Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | "
                            "Where-Object { $_.CommandLine -like '*%s*' } | "
                            "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
                            % os.path.basename(perfil)], capture_output=True)
        time.sleep(1)
        shutil.rmtree(perfil, ignore_errors=True)
    ok = os.path.exists(png) and os.path.getsize(png) > 10000
    print("  %s %s" % ("PNG" if ok else "NO SE GENERO el PNG", png))
    return ok


def main():
    svg = dibujar()
    with open(SVG, "w", encoding="utf-8") as f:
        f.write(svg)
    print("  SVG " + SVG)
    if "--sin-png" in sys.argv:
        return 0
    if not a_png(SVG, PNG):
        return 1
    if os.path.isdir(os.path.dirname(LAMINA)):
        shutil.copyfile(PNG, LAMINA)
        print("  lamina 6 " + LAMINA)
    return 0


if __name__ == "__main__":
    sys.exit(main())
