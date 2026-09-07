# -*- coding: utf-8 -*-
"""Construye el Reporte de Entrega 2 de Mesh clonando la caratula del de Entrega 1.

    python generar-reporte-entrega2.py

El contenido vive en contenido-entrega2.json, que se genera aparte. Este archivo
solo lo maqueta, y esa separacion es a proposito: el texto se revisa leyendolo y
el formato se revisa abriendo el Word, y mezclarlos obliga a rehacer las dos
cosas cada vez que cambia una.

DOS PASADAS PARA EL INDICE. La primera deja el indice con numeros provisionales
porque python-docx no sabe cuantas paginas ocupa nada: eso solo lo sabe Word al
abrir el archivo. medir-paginas-entrega2.ps1 abre el documento con Word, apunta
en que pagina empieza cada seccion, y escribe paginas.json. La segunda pasada de
este script lee ese archivo y pone los numeros de verdad.

Si paginas.json no existe, se avisa por pantalla y se sigue. Un indice con
numeros inventados que nadie avisa es peor que uno vacio.
"""
import io
import json
import os
import shutil
import sys

import docx
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT, WD_TAB_LEADER
from docx.shared import Inches, Pt, RGBColor

BASE = os.path.dirname(os.path.abspath(__file__))
CARATULA = os.path.join(BASE, "Reporte Primera Entrega - DABD2 - Mesh.docx")
SALIDA = os.path.join(BASE, "Reporte Segunda Entrega - DABD2 - Mesh.docx")
CONTENIDO = os.path.join(BASE, "contenido-entrega2.json")
PAGINAS = os.path.join(BASE, "paginas-entrega2.json")

FUENTE = "Times New Roman"
FUENTE_FIJA = "Consolas"
T_TITULO = Pt(18)
T_CUERPO = Pt(12)
T_SUB = Pt(13)
T_FIJA = Pt(9)
GRIS = RGBColor(0x44, 0x44, 0x44)

d = None


def fmt(p, alineado=None, interlineado=1.5, antes=0, despues=0):
    pf = p.paragraph_format
    pf.space_before = Pt(antes)
    pf.space_after = Pt(despues)
    pf.line_spacing = interlineado
    if alineado is not None:
        p.alignment = alineado
    return p


def parrafo(texto="", tam=T_CUERPO, negrita=False, alineado=None,
            interlineado=1.5, fuente=FUENTE, color=None, antes=0, despues=0):
    p = d.add_paragraph()
    fmt(p, alineado, interlineado, antes, despues)
    if texto:
        r = p.add_run(texto)
        r.font.name = fuente
        r.font.size = tam
        r.bold = negrita
        if color is not None:
            r.font.color.rgb = color
    return p


def h1(texto, numero=None):
    """Titulo de seccion. Empieza en pagina nueva, como en el reporte anterior."""
    p = parrafo()
    p.paragraph_format.page_break_before = True
    etiqueta = ("%d. %s" % (numero, texto)) if numero else texto
    parrafo(etiqueta, tam=T_TITULO, negrita=True, despues=10)


def h2(texto):
    parrafo(texto, tam=T_SUB, negrita=True, antes=10, despues=4)


def bloque_fijo(texto, leyenda=""):
    """Codigo o salida medida. Va a ancho fijo y sin interlineado de 1.5.

    El interlineado se baja a 1 a proposito: una salida de consola con 1.5 se
    lee como si tuviera lineas en blanco entre medias y deja de parecer una
    salida de consola.
    """
    for linea in texto.rstrip("\n").split("\n"):
        p = d.add_paragraph()
        fmt(p, None, 1.0)
        p.paragraph_format.left_indent = Inches(0.3)
        r = p.add_run(linea if linea else " ")
        r.font.name = FUENTE_FIJA
        r.font.size = T_FIJA
    if leyenda:
        parrafo(leyenda, tam=Pt(10), color=GRIS, alineado=WD_ALIGN_PARAGRAPH.LEFT,
                interlineado=1.0, antes=3, despues=8)
    else:
        parrafo(despues=6)


def entrada_indice(texto, pagina, sangria=False):
    p = d.add_paragraph()
    fmt(p, None, 1.5)
    if sangria:
        p.paragraph_format.left_indent = Inches(0.35)
    p.paragraph_format.tab_stops.add_tab_stop(
        Inches(6.2), WD_TAB_ALIGNMENT.RIGHT, WD_TAB_LEADER.DOTS)
    r = p.add_run(texto + "\t" + str(pagina))
    r.font.name = FUENTE
    r.font.size = T_CUERPO


def limpiar_cuerpo(doc, dejar):
    """Se queda con los primeros `dejar` parrafos (la caratula) y borra el resto.

    Clonar el documento anterior en vez de crear uno vacio no es pereza: la
    caratula lleva el escudo, los margenes de A4 y los estilos ya puestos, y
    rehacer eso a mano es donde se cuelan las diferencias entre una entrega y la
    siguiente.
    """
    for p in list(doc.paragraphs[dejar:]):
        p._element.getparent().remove(p._element)
    for t in list(doc.tables):
        t._element.getparent().remove(t._element)


def main():
    global d

    if not os.path.exists(CONTENIDO):
        print("  FALTA " + CONTENIDO)
        print("  Ese archivo lo escribe el paso de redaccion. Sin el no hay nada que maquetar.")
        return 1

    with io.open(CONTENIDO, encoding="utf-8") as f:
        secciones = json.load(f)

    paginas = {}
    if os.path.exists(PAGINAS):
        with io.open(PAGINAS, encoding="utf-8-sig") as f:
            paginas = json.load(f)
    else:
        print("  AVISO: no se encontro " + PAGINAS)
        print("  El indice sale con numeros provisionales. Hay que correr")
        print("  medir-paginas-entrega2.ps1 y volver a correr este script antes de entregar.")

    shutil.copyfile(CARATULA, SALIDA)
    d = docx.Document(SALIDA)

    # 30 parrafos es la caratula del reporte anterior, hasta justo antes de su
    # indice. Se comprueba mirando que el ultimo que se conserva sea la fecha.
    limpiar_cuerpo(d, 30)

    ultimo = d.paragraphs[-1].text.strip()
    if "2026" not in ultimo:
        print("  AVISO: el ultimo parrafo de la caratula es [" + ultimo[:60] + "]")
        print("  Se esperaba la linea de la fecha. Revisa el corte de limpiar_cuerpo.")

    # El titulo de la portada dice "Reporte Primera Entrega" porque viene del
    # archivo clonado. Hay que cambiarlo, y si no se encuentra hay que decirlo
    # en vez de entregar una portada que miente.
    cambiado = False
    for p in d.paragraphs:
        if p.text.strip() == "Reporte Primera Entrega":
            for r in p.runs:
                r.text = ""
            p.runs[0].text = "Reporte Segunda Entrega"
            cambiado = True
            break
    if not cambiado:
        print("  AVISO: no se encontro el titulo 'Reporte Primera Entrega' en la portada.")

    for p in d.paragraphs:
        if p.text.strip().startswith("Guatemala,"):
            for r in p.runs:
                r.text = ""
            p.runs[0].text = "Guatemala, domingo 6 de septiembre del 2026"
            break

    # ---------------- el indice ----------------
    p = parrafo()
    p.paragraph_format.page_break_before = True
    parrafo("INDICE", tam=T_TITULO, negrita=True,
            alineado=WD_ALIGN_PARAGRAPH.CENTER, despues=12)

    for i, s in enumerate(secciones, start=1):
        clave = "%d" % i
        entrada_indice("%d. %s" % (i, s["titulo"]), paginas.get(clave, "-"))
        for sub in s.get("subsecciones", []):
            entrada_indice(sub["titulo"], paginas.get(sub["titulo"], "-"), sangria=True)

    # ---------------- el cuerpo ----------------
    for i, s in enumerate(secciones, start=1):
        h1(s["titulo"], numero=i)
        for sub in s.get("subsecciones", []):
            h2(sub["titulo"])
            for texto in sub.get("parrafos", []):
                parrafo(texto, alineado=WD_ALIGN_PARAGRAPH.JUSTIFY, despues=6)
            bl = (sub.get("bloque") or "").strip()
            if bl:
                bloque_fijo(bl, (sub.get("leyenda") or "").strip())

    d.save(SALIDA)

    total_sub = sum(len(s.get("subsecciones", [])) for s in secciones)
    print("  Escrito: " + SALIDA)
    print("  %d secciones, %d subsecciones, %d parrafos en el documento"
          % (len(secciones), total_sub, len(d.paragraphs)))
    if not paginas:
        print("  El indice todavia lleva guiones. Segunda pasada pendiente.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
