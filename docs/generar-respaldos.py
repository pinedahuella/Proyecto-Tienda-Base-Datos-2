# -*- coding: utf-8 -*-
"""Dibuja que base cubre a cual cuando una se cae, para el informe de la Entrega 3.

    python docs/generar-respaldos.py

Escribe docs/diagrama-respaldos.drawio y, si encuentra draw.io, el .png.

Cada flecha va de la base que cubre a la base caida, y su numero se explica en
la leyenda de abajo. Lo que sale de aqui tiene que decir lo mismo que
docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md y que los respaldos del backend
(helpers/catalogo-respaldo.ts, buscador-respaldo.ts, recomendaciones-respaldo.ts,
mas-vendidos.service.ts y el SesionGuard).

Reusa el lienzo y la exportacion de generar-arquitectura.py, con los mismos
colores por base.
"""
import importlib.util
import io
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
SALIDA = os.path.join(BASE, "diagrama-respaldos.drawio")

_spec = importlib.util.spec_from_file_location("arquitectura", os.path.join(BASE, "generar-arquitectura.py"))
arq = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(arq)

ANCHO, ALTO = 300, 130

# clave, x, y, titulo, lo que guarda, relleno, borde
CAJAS = [
    ("mongo", 60, 90, "MongoDB", "ficha completa del producto", "#D5E8D4", "#82B366"),
    ("es", 1060, 90, "Elasticsearch", "buscador y sus filtros", "#FFF2CC", "#D6B656"),
    ("neo4j", 60, 370, "Neo4j", "para ti y también compraron", "#E1D5E7", "#9673A6"),
    ("pg", 560, 370, "PostgreSQL", "la verdad, pedidos, pagos, stock y carrito", "#DAE8FC", "#6C8EBF"),
    ("redis", 1060, 370, "Redis", "rankings, ofertas destacadas y copia del carrito", "#F8CECC", "#B85450"),
    ("ch", 1060, 650, "ClickHouse", "vistas, búsquedas y tendencias", "#FFE6CC", "#D79B00"),
]

# numero, cubre, caida, salida, entrada, lo que pasa
FLECHAS = [
    (1, "pg", "mongo", (0.2, 0.0), (0.5, 1.0),
     "Sin MongoDB el catálogo y la ficha salen de la copia en PostgreSQL, sin las características"),
    (2, "pg", "es", (0.8, 0.0), (0.5, 1.0),
     "Sin Elasticsearch el buscador y sus filtros salen de la misma copia, con la misma regla de texto"),
    (3, "pg", "neo4j", (0.0, 0.5), (1.0, 0.5),
     "Sin Neo4j para ti y también compraron salen de los pedidos en PostgreSQL"),
    (4, "pg", "redis", (1.0, 0.3), (0.0, 0.3),
     "Sin Redis las ofertas destacadas y el carrito salen de PostgreSQL"),
    (5, "redis", "pg", (0.0, 0.75), (1.0, 0.75),
     "Sin PostgreSQL la sesión abierta sigue por su token y el perfil y el carrito salen de la copia en Redis"),
    (6, "ch", "redis", (0.3, 0.0), (0.3, 1.0),
     "Sin Redis los cuatro rankings se calculan en el momento en ClickHouse"),
    (7, "redis", "ch", (0.7, 1.0), (0.7, 0.0),
     "Sin ClickHouse lo más vendido, lo más visto y se compran juntos siguen en Redis"),
]

SIN_RESPALDO = [
    "Pagar e iniciar sesión sin PostgreSQL",
    "Crear o cambiar productos sin MongoDB",
    "Crear un avísame sin Elasticsearch",
    "Viste hace poco y las tendencias sin ClickHouse",
]


def construir():
    L = arq.Lienzo()
    L.texto(60, 6, 1300, 40, "Qué base cubre a cuál cuando una se cae", 28, negrita=True)
    L.texto(60, 48, 1300, 30,
            "Cada flecha va de la base que cubre a la base caída. Su número está explicado abajo.", 17,
            gris=True)
    for k, x, y, titulo, guarda, relleno, borde in CAJAS:
        L.rect(k, x, y, ANCHO, ALTO, "<b>%s</b><br><br>%s" % (titulo, guarda), relleno, borde, sizes=19)
    for n, a, b, sale, entra, _ in FLECHAS:
        L.flecha(a, b, sale, entra, str(n), color="#1F5F1F", grosor=3)
        # el numero con la letra de 11 del lienzo no se lee metido en una hoja
        L.celdas[-1] = L.celdas[-1].replace("fontSize=11;", "fontSize=22;fontStyle=1;")
    L.rect("sin", 60, 650, 820, 125,
           "<b>Sin respaldo, a propósito</b><br>" + "<br>".join(SIN_RESPALDO),
           "#FFFFFF", "#B85450", sizes=17, dash=True, alinea="left")
    leyenda = "<br>".join("<b>%d</b> %s" % (n, t) for n, _, _, _, _, t in FLECHAS)
    L.texto(60, 810, 1300, 170, leyenda, 17)
    return L


def comprobar(L):
    ids = set()
    fallos = []
    n = 0
    for c in L.celdas:
        ids.add(c.split('id="')[1].split('"')[0])
    for c in L.celdas:
        if ' edge="1"' in c:
            n += 1
            for lado in ("source", "target"):
                v = c.split(lado + '="')[1].split('"')[0]
                if v not in ids:
                    fallos.append("una flecha nombra la caja %s, que no existe" % v)
    if n != len(FLECHAS):
        fallos.append("hay %d flechas y se esperaban %d" % (n, len(FLECHAS)))
    return fallos


def main():
    L = construir()
    fallos = comprobar(L)
    with io.open(SALIDA, "w", encoding="utf-8") as f:
        f.write(L.xml())
    print("  %d elementos -> %s" % (len(L.celdas), SALIDA))
    if fallos:
        for x in fallos:
            print("  FALLA " + x)
        return 1
    print("  OK: todas las flechas nombran cajas que existen")
    arq.exportar_png(SALIDA)
    return 0


if __name__ == "__main__":
    sys.exit(main())
