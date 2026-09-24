"""comparar.py -- pone la salida de Cypher y la de SQL en el mismo formato y las compara.

Uso (lo llama neo4j/correr_patrones.sh):
    python comparar.py normalizar DIR_CYPHER > cypher.txt
    python comparar.py comparar cypher.txt sql.txt

`normalizar` lee los B*.txt que dejo cypher-shell --format plain y escribe una
linea "B.x|clave|metricas" por fila, con las MISMAS columnas que arma
equivalentes.sql. `comparar` ordena las dos listas y dice que filas sobran de
cada lado; sale con 1 si hay alguna.

Se escribio en Python y no con grep/awk porque la salida de cypher-shell trae
listas entre corchetes con comas adentro ("[\"a\", \"b\"]"), y partir eso por
comas a mano da columnas corridas sin ningun error. Solo usa la biblioteca
estandar: no hay nada que instalar.
"""
import os
import sys

# Que columnas de cada consulta forman la linea comparable. Tienen que ser las
# mismas, en el mismo orden, que el SELECT de equivalentes.sql.
COLUMNAS = {
    'B1_cadena_abierta':      ('B.1', ['clave', 'cuantas_cuentas', 'nacieron_juntas', 'extremos_comparten_casa']),
    'B2_satelites':           ('B.2', ['clave', 'cuantos']),
    'B3_persistente':         ('B.3', ['autor', 'vendedor', 'meses_distintos']),
    'B4_anillo_en_el_tiempo': ('B.4', ['anillo', 'vueltas', 'olas', 'visible_para_el_detector', 'en_orden']),
    'B5_favor_devuelto':      ('B.5', ['clave', 'veces', 'sobre_el_mismo_producto']),
    'B6_coordinados':         ('B.6', ['clave', 'coincidencias']),
    'B7_reputacion_expres':   ('B.7', ['vendedor', 'resenas_expres']),
}


def partir(linea):
    """Parte una fila de --format plain por las comas de primer nivel."""
    campos, actual, nivel, en_cadena = [], '', 0, False
    i = 0
    while i < len(linea):
        c = linea[i]
        if en_cadena:
            actual += c
            if c == '\\' and i + 1 < len(linea):
                actual += linea[i + 1]
                i += 1
            elif c == '"':
                en_cadena = False
        elif c == '"':
            en_cadena = True
            actual += c
        elif c == '[':
            nivel += 1
            actual += c
        elif c == ']':
            nivel -= 1
            actual += c
        elif c == ',' and nivel == 0:
            campos.append(actual.strip())
            actual = ''
        else:
            actual += c
        i += 1
    campos.append(actual.strip())
    return campos


def limpiar(valor):
    """Quita comillas; una lista queda como sus elementos unidos por coma."""
    if valor.startswith('['):
        return ','.join(limpiar(x) for x in partir(valor[1:-1]) if x)
    if valor.startswith('"') and valor.endswith('"'):
        return valor[1:-1]
    return valor


def normalizar(directorio):
    salida = []
    for base, (rotulo, columnas) in COLUMNAS.items():
        ruta = os.path.join(directorio, base + '.txt')
        with open(ruta, encoding='utf-8') as f:
            lineas = [l.rstrip('\n') for l in f if l.strip()]
        # Las dos primeras son el rotulo ("consulta" y "=== B.x ==="). Si la
        # consulta no devolvio filas, no hay encabezado: cero lineas.
        lineas = lineas[2:]
        if not lineas:
            continue
        encabezado = partir(lineas[0])
        indices = [encabezado.index(c) for c in columnas]
        for fila in lineas[1:]:
            valores = partir(fila)
            salida.append(rotulo + '|' + '|'.join(limpiar(valores[i]) for i in indices))
    return sorted(salida)


def comparar(ruta_cypher, ruta_sql):
    with open(ruta_cypher, encoding='utf-8') as f:
        cypher = sorted(l.strip() for l in f if l.strip())
    with open(ruta_sql, encoding='utf-8') as f:
        sql = sorted(l.strip() for l in f if l.strip().startswith('B.'))
    solo_cypher = list(cypher)
    solo_sql = []
    for l in sql:
        if l in solo_cypher:
            solo_cypher.remove(l)
        else:
            solo_sql.append(l)
    por_consulta = {}
    for l in cypher:
        por_consulta[l[:3]] = por_consulta.get(l[:3], 0) + 1
    resumen = ', '.join(f'{k} {v}' for k, v in sorted(por_consulta.items())) or 'ninguna fila'
    if not solo_cypher and not solo_sql:
        print(f'  IGUALES, {len(cypher)} filas ({resumen})')
        return 0
    for l in solo_cypher:
        print('  SOLO EN CYPHER  ' + l)
    for l in solo_sql:
        print('  SOLO EN SQL     ' + l)
    return 1


if __name__ == '__main__':
    if sys.argv[1] == 'normalizar':
        sys.stdout.write(''.join(l + '\n' for l in normalizar(sys.argv[2])))
    else:
        sys.exit(comparar(sys.argv[2], sys.argv[3]))
