# -*- coding: utf-8 -*-
"""Construye el Reporte de Entrega 2 de Mesh clonando la caratula del de Entrega 1.

    python generar-reporte-entrega2.py

El contenido vive en contenido-entrega2.json y este archivo solo lo maqueta. La
separacion es a proposito, el texto se revisa leyendolo y el formato abriendo el
Word, y mezclarlos obliga a rehacer las dos cosas cada vez que cambia una.

FORMATO DEL JSON
----------------
Una lista de secciones. Cada seccion tiene titulo y subsecciones, y cada
subseccion tiene titulo (con su numero, "2.1. ...") y una lista ordenada de
bloques. Cada bloque es un objeto con UNA de estas claves.

    {"p": "texto"}                          parrafo justificado
    {"vin": ["a", "b"]}                     lista con vinetas
    {"tabla": {"cabecera": [...], "filas": [[...]], "anchos": [...], "leyenda": "..."}}
    {"figura": {"archivo": "...", "leyenda": "...", "ancho": 6.0, "horizontal": false}}
    {"codigo": "salida medida", "leyenda": "..."}
    {"adr": {"id": "ADR-4", "titulo": "...", "contexto": "...", "alternativas": "...",
             "decision": "...", "justificacion": "...", "consecuencias": "..."}}

Dentro de un texto, `asi` sale en fuente fija y **asi** en negrita.

DOS PASADAS PARA EL INDICE. La primera deja el indice con guiones porque
python-docx no sabe cuantas paginas ocupa nada. medir-paginas-entrega2.ps1 abre
el documento con Word, apunta en que pagina empieza cada seccion y escribe
paginas-entrega2.json. La segunda pasada de este script lee ese archivo y pone los
numeros de verdad. Si el archivo no existe se avisa y se sigue: un indice con
numeros inventados que nadie avisa es peor que uno vacio.

EL TEXTO SE VALIDA ANTES DE ESCRIBIR. Lo que Meme entrega no lleva dos puntos,
punto y coma, comillas angulares, rayas largas ni puntos suspensivos, ni nada que
delate como se escribio. Si aparece alguno el script no genera el documento y
dice en que parrafo esta. Lo que va entre acentos graves y los bloques de salida
medida quedan fuera, porque una ruta o una consola llevan dos puntos de verdad.
"""
import io
import json
import os
import re
import shutil
import sys

import docx
from docx.enum.section import WD_ORIENT, WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT, WD_TAB_LEADER
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor

BASE = os.path.dirname(os.path.abspath(__file__))
CARATULA = os.path.join(BASE, "Reporte Primera Entrega - DABD2 - Mesh.docx")
SALIDA = os.path.join(BASE, "Reporte Segunda Entrega - DABD2 - Mesh.docx")
CONTENIDO = os.path.join(BASE, "contenido-entrega2.json")
PAGINAS = os.path.join(BASE, "paginas-entrega2.json")
FIGURAS = os.path.join(BASE, "docs", "informe-entrega2")

FUENTE = "Times New Roman"
FUENTE_FIJA = "Consolas"
T_TITULO = Pt(18)
T_CUERPO = Pt(12)
T_SUB = Pt(13)
T_TABLA = Pt(10)
T_FIJA = Pt(9)
GRIS = RGBColor(0x44, 0x44, 0x44)

FECHA = "Guatemala, sábado 19 de septiembre del 2026"

d = None
MARGENES = None
n_figura = 0
n_tabla = 0

# ------------------------------------------------------------ el validador

PROHIBIDO = re.compile(r"[:;«»—–…]|\.\.\.")
HUELLA = re.compile(r"\bIA\b|Claude|Anthropic|ChatGPT|OpenAI|inteligencia artificial|asistente virtual", re.I)
EMOJI = re.compile("[\U00010000-\U0010ffff☀-➿⭐⬆✅❌]")
CODIGO = re.compile(r"`[^`]*`")


def revisar_texto(texto, donde, fallos):
    limpio = CODIGO.sub("", texto)
    limpio = limpio.replace("**", "")
    m = PROHIBIDO.search(limpio)
    if m:
        ini = max(0, m.start() - 30)
        fallos.append("%s tiene [%s] cerca de [%s]" % (donde, m.group(0), limpio[ini:m.end() + 30].replace("\n", " ")))
    if HUELLA.search(texto):
        fallos.append("%s menciona algo que delata el origen del texto" % donde)
    if EMOJI.search(texto):
        fallos.append("%s lleva un emoji" % donde)
    if texto.count("`") % 2:
        fallos.append("%s tiene un acento grave sin cerrar" % donde)
    if texto.count("**") % 2:
        fallos.append("%s tiene una negrita sin cerrar" % donde)


def validar(secciones):
    fallos = []
    for i, s in enumerate(secciones, 1):
        revisar_texto(s["titulo"], "titulo de la seccion %d" % i, fallos)
        for sub in s["subsecciones"]:
            donde = sub["titulo"][:40]
            revisar_texto(sub["titulo"], "titulo " + donde, fallos)
            for k, b in enumerate(sub["bloques"], 1):
                lugar = "%s, bloque %d" % (donde, k)
                if "p" in b:
                    revisar_texto(b["p"], lugar, fallos)
                elif "vin" in b:
                    for x in b["vin"]:
                        revisar_texto(x, lugar + " (vineta)", fallos)
                elif "tabla" in b:
                    t = b["tabla"]
                    for c in t["cabecera"]:
                        revisar_texto(c, lugar + " (cabecera)", fallos)
                    for f in t["filas"]:
                        if len(f) != len(t["cabecera"]):
                            fallos.append("%s, una fila tiene %d celdas y la cabecera %d" % (lugar, len(f), len(t["cabecera"])))
                        for c in f:
                            revisar_texto(c, lugar + " (celda)", fallos)
                    revisar_texto(t.get("leyenda", ""), lugar + " (leyenda)", fallos)
                elif "figura" in b:
                    revisar_texto(b["figura"]["leyenda"], lugar + " (leyenda)", fallos)
                    if not os.path.exists(os.path.join(FIGURAS, b["figura"]["archivo"])):
                        fallos.append("%s, falta la figura %s" % (lugar, b["figura"]["archivo"]))
                elif "codigo" in b:
                    revisar_texto(b.get("leyenda", ""), lugar + " (leyenda)", fallos)
                elif "adr" in b:
                    for campo in ("titulo", "contexto", "alternativas", "decision", "justificacion", "consecuencias"):
                        v = b["adr"][campo]
                        for parte in (v if isinstance(v, list) else [v]):
                            revisar_texto(parte, lugar + " (" + campo + ")", fallos)
                else:
                    fallos.append("%s, bloque sin clave conocida %s" % (lugar, list(b)))
    return fallos


# ---------------------------------------------------------------- el formato


def fmt(p, alineado=None, interlineado=1.5, antes=0, despues=0):
    pf = p.paragraph_format
    pf.space_before = Pt(antes)
    pf.space_after = Pt(despues)
    pf.line_spacing = interlineado
    if alineado is not None:
        p.alignment = alineado
    return p


def run(p, texto, tam=T_CUERPO, negrita=False, cursiva=False, fuente=FUENTE, color=None):
    r = p.add_run(texto)
    r.font.name = fuente
    r._element.rPr.rFonts.set(qn("w:eastAsia"), fuente)
    r.font.size = tam
    r.bold = negrita
    r.italic = cursiva
    if color is not None:
        r.font.color.rgb = color
    return r


def con_marcas(p, texto, tam=T_CUERPO, negrita=False):
    """Escribe un texto con `codigo` en fuente fija y **negrita** dentro."""
    for trozo in re.split(r"(`[^`]*`|\*\*[^*]*\*\*)", texto):
        if not trozo:
            continue
        if trozo.startswith("`"):
            run(p, trozo[1:-1], tam=Pt(tam.pt - 1.5), fuente=FUENTE_FIJA, negrita=negrita)
        elif trozo.startswith("**"):
            run(p, trozo[2:-2], tam=tam, negrita=True)
        else:
            run(p, trozo, tam=tam, negrita=negrita)


def parrafo(texto="", tam=T_CUERPO, negrita=False, alineado=None, interlineado=1.5,
            color=None, antes=0, despues=0, marcas=False):
    p = d.add_paragraph()
    fmt(p, alineado, interlineado, antes, despues)
    if texto:
        if marcas:
            con_marcas(p, texto, tam, negrita)
        else:
            run(p, texto, tam=tam, negrita=negrita, color=color)
    return p


def h1(texto, numero=None):
    """Titulo de seccion. Empieza en pagina nueva, como en el reporte anterior."""
    p = parrafo()
    p.paragraph_format.page_break_before = True
    etiqueta = ("%d. %s" % (numero, texto)) if numero else texto
    parrafo(etiqueta, tam=T_TITULO, negrita=True, despues=10)


def h2(texto):
    p = parrafo(texto, tam=T_SUB, negrita=True, antes=10, despues=4)
    p.paragraph_format.keep_with_next = True


def vineta(texto):
    p = d.add_paragraph()
    fmt(p, WD_ALIGN_PARAGRAPH.JUSTIFY, 1.5, 0, 3)
    p.paragraph_format.left_indent = Inches(0.55)
    p.paragraph_format.first_line_indent = Inches(-0.25)
    run(p, "-  ")
    con_marcas(p, texto)


def leyenda_pie(texto):
    parrafo(texto, tam=Pt(10), color=GRIS, alineado=WD_ALIGN_PARAGRAPH.LEFT,
            interlineado=1.0, antes=3, despues=10)


def bloque_fijo(texto, leyenda=""):
    """Codigo o salida medida, a ancho fijo y con interlineado 1.

    Con 1.5 una salida de consola parece tener lineas en blanco entre medias y
    deja de parecer una salida de consola.
    """
    lineas = texto.rstrip("\n").split("\n")
    for k, linea in enumerate(lineas):
        p = d.add_paragraph()
        fmt(p, None, 1.0)
        p.paragraph_format.left_indent = Inches(0.3)
        # no partir un bloque corto entre dos paginas
        if len(lineas) <= 24:
            p.paragraph_format.keep_together = True
            if k < len(lineas) - 1:
                p.paragraph_format.keep_with_next = True
        run(p, linea if linea else " ", tam=T_FIJA, fuente=FUENTE_FIJA)
    if leyenda:
        leyenda_pie(leyenda)
    else:
        parrafo(despues=6)


def sombrear(celda, color):
    tcPr = celda._tc.get_or_add_tcPr()
    sh = OxmlElement("w:shd")
    sh.set(qn("w:val"), "clear")
    sh.set(qn("w:color"), "auto")
    sh.set(qn("w:fill"), color)
    tcPr.append(sh)


def bordes(tabla):
    tblPr = tabla._tbl.tblPr
    b = OxmlElement("w:tblBorders")
    for lado in ("top", "left", "bottom", "right", "insideH", "insideV"):
        e = OxmlElement("w:" + lado)
        e.set(qn("w:val"), "single")
        e.set(qn("w:sz"), "4")
        e.set(qn("w:space"), "0")
        e.set(qn("w:color"), "808080")
        b.append(e)
    tblPr.append(b)
    m = OxmlElement("w:tblCellMar")
    for lado, v in (("top", 40), ("left", 90), ("bottom", 40), ("right", 90)):
        e = OxmlElement("w:" + lado)
        e.set(qn("w:w"), str(v))
        e.set(qn("w:type"), "dxa")
        m.append(e)
    tblPr.append(m)


def no_partir_fila(fila):
    trPr = fila._tr.get_or_add_trPr()
    e = OxmlElement("w:cantSplit")
    trPr.append(e)


def repetir_cabecera(fila):
    trPr = fila._tr.get_or_add_trPr()
    e = OxmlElement("w:tblHeader")
    trPr.append(e)


def escribir_celda(celda, texto, negrita=False, tam=T_TABLA):
    partes = texto if isinstance(texto, list) else [texto]
    primera = True
    for parte in partes:
        p = celda.paragraphs[0] if primera else celda.add_paragraph()
        primera = False
        fmt(p, WD_ALIGN_PARAGRAPH.LEFT, 1.0, 0, 3 if len(partes) > 1 else 0)
        con_marcas(p, parte, tam, negrita)


def tabla_simple(t):
    global n_tabla
    n_tabla += 1
    cab = t["cabecera"]
    parrafo("Tabla %d. %s" % (n_tabla, t["leyenda"]), tam=Pt(10), negrita=True, interlineado=1.0,
            antes=6, despues=4).paragraph_format.keep_with_next = True
    tabla = d.add_table(rows=1, cols=len(cab))
    tabla.alignment = WD_TABLE_ALIGNMENT.CENTER
    tabla.autofit = False
    bordes(tabla)
    anchos = t.get("anchos") or [6.3 / len(cab)] * len(cab)
    for i, c in enumerate(cab):
        celda = tabla.rows[0].cells[i]
        escribir_celda(celda, c, negrita=True)
        sombrear(celda, "E7E6E6")
    repetir_cabecera(tabla.rows[0])
    for f in t["filas"]:
        fila = tabla.add_row()
        no_partir_fila(fila)
        for i, c in enumerate(f):
            escribir_celda(fila.cells[i], c)
    for fila in tabla.rows:
        for i, a in enumerate(anchos):
            fila.cells[i].width = Inches(a)
    parrafo(despues=8, interlineado=1.0)


def tabla_adr(a):
    global n_tabla
    n_tabla += 1
    parrafo("Tabla %d. Registro de decisión %s" % (n_tabla, a["id"]), tam=Pt(10), negrita=True,
            interlineado=1.0, antes=6, despues=4).paragraph_format.keep_with_next = True
    tabla = d.add_table(rows=1, cols=2)
    tabla.alignment = WD_TABLE_ALIGNMENT.CENTER
    tabla.autofit = False
    bordes(tabla)
    cab = tabla.rows[0].cells[0].merge(tabla.rows[0].cells[1])
    escribir_celda(cab, "%s %s" % (a["id"], a["titulo"]), negrita=True)
    sombrear(cab, "E7E6E6")
    for etiqueta, clave in (("Contexto", "contexto"), ("Alternativas consideradas", "alternativas"),
                            ("Decisión", "decision"), ("Justificación", "justificacion"),
                            ("Consecuencias", "consecuencias")):
        fila = tabla.add_row()
        escribir_celda(fila.cells[0], etiqueta, negrita=True)
        escribir_celda(fila.cells[1], a[clave])
        sombrear(fila.cells[0], "F2F2F2")
    for fila in tabla.rows:
        fila.cells[0].width = Inches(1.45)
        fila.cells[-1].width = Inches(4.85)
        no_partir_fila(fila)
    # que el registro entero quede en una sola pagina si cabe
    for fila in tabla.rows[:-1]:
        for celda in fila.cells:
            for p in celda.paragraphs:
                p.paragraph_format.keep_with_next = True
    parrafo(despues=8, interlineado=1.0)


def nueva_seccion(horizontal):
    """Abre una seccion en pagina nueva, vertical u horizontal.

    Una seccion nueva hereda las propiedades de la anterior, y eso incluye dos
    cosas que aqui estorban. La portada tiene "primera pagina distinta", y si se
    hereda, la primera pagina de cada seccion nueva sale sin numero. Y la
    numeracion puede venir con reinicio, y entonces la pagina 55 se imprime como
    2. Las dos se quitan.
    """
    global MARGENES
    antes = d.sections[-1]
    sec = d.add_section(WD_SECTION.NEW_PAGE)
    sec.different_first_page_header_footer = False
    pg = sec._sectPr.find(qn("w:pgNumType"))
    if pg is not None:
        sec._sectPr.remove(pg)
    if horizontal:
        sec.orientation = WD_ORIENT.LANDSCAPE
        sec.page_width, sec.page_height = antes.page_height, antes.page_width
        sec.left_margin = sec.right_margin = Inches(0.6)
        sec.top_margin = sec.bottom_margin = Inches(0.6)
    else:
        sec.orientation = WD_ORIENT.PORTRAIT
        sec.page_width, sec.page_height = antes.page_height, antes.page_width
        sec.left_margin, sec.right_margin, sec.top_margin, sec.bottom_margin = MARGENES
    return sec


def figura(f):
    global n_figura
    n_figura += 1
    ruta = os.path.join(FIGURAS, f["archivo"])
    horizontal = f.get("horizontal", False)
    if horizontal:
        nueva_seccion(True)
    p = d.add_paragraph()
    fmt(p, WD_ALIGN_PARAGRAPH.CENTER, 1.0, 0, 4)
    p.paragraph_format.keep_with_next = True
    p.add_run().add_picture(ruta, width=Inches(f.get("ancho", 6.2)))
    parrafo("Figura %d. %s" % (n_figura, f["leyenda"]), tam=Pt(10), color=GRIS,
            alineado=WD_ALIGN_PARAGRAPH.CENTER, interlineado=1.0, antes=2, despues=8)
    if horizontal:
        nueva_seccion(False)


def entrada_indice(texto, pagina, sangria=False):
    p = d.add_paragraph()
    fmt(p, None, 1.0, 0, 1 if sangria else 3)
    if sangria:
        p.paragraph_format.left_indent = Inches(0.35)
    p.paragraph_format.tab_stops.add_tab_stop(Inches(6.2), WD_TAB_ALIGNMENT.RIGHT, WD_TAB_LEADER.DOTS)
    run(p, texto + "\t" + str(pagina), tam=Pt(11) if sangria else T_CUERPO, negrita=not sangria)


def limpiar_cuerpo(doc, dejar):
    """Se queda con los primeros `dejar` parrafos (la caratula) y borra el resto.

    Clonar el documento anterior en vez de crear uno vacio no es pereza, la
    caratula lleva el escudo, los margenes de A4 y los estilos ya puestos, y
    rehacer eso a mano es donde se cuelan las diferencias entre una entrega y la
    siguiente.
    """
    for p in list(doc.paragraphs[dejar:]):
        p._element.getparent().remove(p._element)
    for t in list(doc.tables):
        t._element.getparent().remove(t._element)


def numero_de_pagina(seccion):
    """Pone 'pagina N' centrado en el pie. La portada no lleva."""
    seccion.different_first_page_header_footer = True
    pie = seccion.footer
    pie.is_linked_to_previous = False
    p = pie.paragraphs[0] if pie.paragraphs else pie.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    for txt, tipo in (("", "begin"), (" PAGE ", "instr"), ("", "end")):
        r = p.add_run()
        r.font.name = FUENTE
        r.font.size = Pt(10)
        if tipo == "instr":
            it = OxmlElement("w:instrText")
            it.set(qn("xml:space"), "preserve")
            it.text = txt
            r._r.append(it)
        else:
            fc = OxmlElement("w:fldChar")
            fc.set(qn("w:fldCharType"), tipo)
            r._r.append(fc)


def main():
    global d

    if not os.path.exists(CONTENIDO):
        print("  FALTA " + CONTENIDO)
        return 1
    with io.open(CONTENIDO, encoding="utf-8") as f:
        secciones = json.load(f)

    fallos = validar(secciones)
    if fallos:
        print("  El texto no cumple el estilo y no se genero el documento.")
        for x in fallos:
            print("  FALLA " + x)
        print("  %d problema(s)." % len(fallos))
        return 1

    paginas = {}
    if os.path.exists(PAGINAS):
        with io.open(PAGINAS, encoding="utf-8-sig") as f:
            paginas = json.load(f)
    else:
        print("  AVISO: no se encontro " + PAGINAS)
        print("  El indice sale con guiones. Corre medir-paginas-entrega2.ps1 y vuelve a correr este script.")

    shutil.copyfile(CARATULA, SALIDA)
    d = docx.Document(SALIDA)
    limpiar_cuerpo(d, 30)

    ultimo = d.paragraphs[-1].text.strip()
    if "2026" not in ultimo:
        print("  AVISO: el ultimo parrafo de la caratula es [" + ultimo[:60] + "]")
        print("  Se esperaba la linea de la fecha. Revisa el corte de limpiar_cuerpo.")

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

    fechado = False
    for p in d.paragraphs:
        if p.text.strip().startswith("Guatemala,"):
            for r in p.runs:
                r.text = ""
            p.runs[0].text = FECHA
            fechado = True
            break
    if not fechado:
        print("  AVISO: no se encontro la linea de fecha de la portada.")

    global MARGENES
    s0 = d.sections[0]
    MARGENES = (s0.left_margin, s0.right_margin, s0.top_margin, s0.bottom_margin)
    numero_de_pagina(d.sections[0])

    # ---------------- el indice ----------------
    p = parrafo()
    p.paragraph_format.page_break_before = True
    parrafo("INDICE", tam=T_TITULO, negrita=True, alineado=WD_ALIGN_PARAGRAPH.CENTER, despues=12)
    for i, s in enumerate(secciones, start=1):
        entrada_indice("%d. %s" % (i, s["titulo"]), paginas.get("%d" % i, "-"))
        for sub in s["subsecciones"]:
            entrada_indice(sub["titulo"], paginas.get(sub["titulo"], "-"), sangria=True)

    # ---------------- el cuerpo ----------------
    for i, s in enumerate(secciones, start=1):
        h1(s["titulo"], numero=i)
        for sub in s["subsecciones"]:
            h2(sub["titulo"])
            for b in sub["bloques"]:
                if "p" in b:
                    parrafo(b["p"], alineado=WD_ALIGN_PARAGRAPH.JUSTIFY, despues=6, marcas=True)
                elif "vin" in b:
                    for x in b["vin"]:
                        vineta(x)
                    parrafo(despues=4, interlineado=1.0)
                elif "tabla" in b:
                    tabla_simple(b["tabla"])
                elif "figura" in b:
                    figura(b["figura"])
                elif "codigo" in b:
                    bloque_fijo(b["codigo"], (b.get("leyenda") or "").strip())
                elif "adr" in b:
                    tabla_adr(b["adr"])

    d.core_properties.title = "Reporte Segunda Entrega, Mesh"
    d.core_properties.author = "José Manuel González Corado, José David Navichoque Pineda, Juan Pablo Torres García"
    d.save(SALIDA)

    total_sub = sum(len(s["subsecciones"]) for s in secciones)
    print("  Escrito: " + SALIDA)
    print("  %d secciones, %d subsecciones, %d figuras, %d tablas" % (len(secciones), total_sub, n_figura, n_tabla))
    if not paginas:
        print("  El indice todavia lleva guiones. Segunda pasada pendiente.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
