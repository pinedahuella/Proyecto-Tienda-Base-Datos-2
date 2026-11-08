"""comprobar.py -- las aserciones de clickhouse/correr_consultas.sh sobre la base sembrada.

Uso:  python comprobar.py DIR   (DIR tiene un .tsv por consulta, con encabezado)

Cada comprobacion mira la salida de la consulta DEL REPOSITORIO, no una
consulta aparte: preguntar otra vez con otro texto seria tener dos copias de la
regla (la leccion de neo4j/correr_fraude.sh). Cada escenario tiene su control,
un caso parecido que NO tiene que salir. Sale con 1 si algo falla.
Solo usa la biblioteca estandar.
"""
import os
import sys

DIR = sys.argv[1]
FALLAS = 0


def leer(nombre):
    with open(os.path.join(DIR, nombre + '.tsv'), encoding='utf-8') as f:
        lineas = [l.rstrip('\n') for l in f if l.strip()]
    if not lineas:
        return []
    cols = lineas[0].split('\t')
    return [dict(zip(cols, l.split('\t'))) for l in lineas[1:]]


def ids(filas, col='id_producto'):
    return [f[col] for f in filas]


def check(cond, texto, detalle=''):
    global FALLAS
    if cond:
        print('  OK     ' + texto)
    else:
        FALLAS += 1
        print('  FALLA  ' + texto + ('  (' + detalle + ')' if detalle else ''))


print('  Recomendaciones:')
r1 = leer('R1_vistos_recientemente')
check(ids(r1) == ['3', '2', '1'], 'R1 lo visto por 1001, del mas nuevo al mas viejo: 3, 2, 1', str(ids(r1)))
check([f['ya_comprado'] for f in r1] == ['0', '1', '0'], 'R1 marca el 2 como ya comprado', str(r1))
check(r1 and r1[-1]['veces'] == '2', 'R1 cuenta las dos vistas del 1 en una fila')
check('8' not in ids(r1), 'R1 control: lo visto hace 40 dias no sale')
check('4' not in ids(r1), 'R1 control: lo que miro otra sesion sin cuenta no sale')
r1a = leer('R1_vistos_recientemente_anonima')
check(ids(r1a) == ['4'], 'R1 sin cuenta: la sesion anonima ve solo lo suyo', str(ids(r1a)))

r2 = leer('R2_tambien_vieron')
check(ids(r2) == ['10', '15'], 'R2 "tambien vieron" del 3: primero el 10 y despues el 15', str(ids(r2)))
# El 3 lo vieron 8 sesiones: las 7 de arriba y la propia de 1001. La primera
# version de esta asercion decia 7 y fallo; la consulta tenia razon.
check(r2 and r2[0]['afinidad'] == '0.612', 'R2 afinidad del 10 = 3 / raiz(8 x 3) = 0.612', str(r2[:1]))
check(len(r2) > 1 and int(r2[1]['sesiones_en_comun']) > int(r2[0]['sesiones_en_comun']),
      'R2 el 15 tiene MAS sesiones en comun y sale despues: la afinidad castiga lo popular')
check('11' not in ids(r2) and '12' not in ids(r2), 'R2 control: con una sola sesion en comun no sale')

r3 = leer('R3_para_ti')
check(ids(r3)[:1] == ['10'], 'R3 "para ti" de 1001 empieza por el 10', str(ids(r3)))
check(ids(r3)[-1:] == ['15'], 'R3 el popular (15) queda ultimo, no primero', str(ids(r3)))
check(not set(ids(r3)) & {'1', '2', '3'}, 'R3 control: no recomienda lo que acaba de mirar')
check('16' not in ids(r3), 'R3 control: no recomienda lo que ya compro (el 16)')
fila11 = [f for f in r3 if f['id_producto'] == '11']
check(fila11 and fila11[0]['porque_viste'] == '[1,3]', 'R3 dice por que: el 11 llega por haber visto el 1 y el 3',
      str(fila11))

r4 = leer('R4_populares_de_lista')
check(ids(r4) == ['15', '11', '12', '10'], 'R4 ordena la lista: 15 (24), 11 (12), 12 (10), 10 (3)', str(ids(r4)))
check('99' not in ids(r4), 'R4 control: el candidato sin eventos no sale')

print('  Tendencias:')
t1 = leer('T1_en_ascenso')
f20 = [f for f in t1 if f['id_producto'] == '20']
check(f20 and float(f20[0]['veces']) > 4, 'T1 el 20 esta en ascenso (de 1 a 10 vistas por dia)', str(f20))
check('21' not in ids(t1), 'T1 control: el que va parejo no sale')
check('22' not in ids(t1), 'T1 control: el que crecio con 15 vistas no alcanza el minimo')
f27 = [f for f in t1 if f['id_producto'] == '27']
check(f27 and float(f27[0]['vistas_por_persona']) >= 50,
      'T1 el inflado (27) sale, pero con su columna de vistas por persona a la vista', str(f27))

t2 = {f['id_producto']: f for f in leer('T2_embudo')}
check(t2.get('25', {}).get('diagnostico') == 'mucho_interes_poca_compra', 'T2 el 25: lo miran 25 y no lo compra nadie')
check(t2.get('26', {}).get('diagnostico') == 'devolucion_alta', 'T2 el 26: vuelven 4 de 10')
check('24' not in t2, 'T2 control: el 24 convierte al 20 % y no sale')
check(t2.get('30', {}).get('diagnostico') != 'devolucion_alta',
      'T2 control: al 30 la tienda le cancelo 6 de 10, no es devolucion alta', str(t2.get('30')))

t3 = {f['termino']: f for f in leer('T3_busquedas_sin_respuesta')}
check(t3.get('dron acuatico', {}).get('diagnostico') == 'no_tenemos'
      and t3['dron acuatico']['busquedas'] == '4',
      'T3 "dron acuatico": cuatro busquedas sin resultado, contando la escrita con mayusculas')
check(t3.get('cable hdmi', {}).get('diagnostico') == 'no_convence', 'T3 "cable hdmi": hay resultados y nadie hace clic')
check('mouse' not in t3, 'T3 control: "mouse" tiene clics')
check('asdf' not in t3, 'T3 control: una sola sesion no es demanda')

print('  Operaciones sospechosas:')
f1 = leer('F1_vistas_infladas')
check(ids(f1) == ['27'] and f1[0]['vistas_por_sesion'] == '100', 'F1 el 27: 300 vistas de 3 sesiones', str(f1))

f2 = leer('F2_compras_en_rafaga')
check(ids(f2, 'id_usuario') == ['2001'] and f2[0]['pedidos_en_la_peor_rafaga'] == '6',
      'F2 la cuenta 2001: seis pedidos en diez minutos', str(f2))

f3 = leer('F3_ip_multicuenta_compras')
check(ids(f3, 'ip') == ['::ffff:10.9.9.9'] and f3[0]['cuentas_distintas'] == '5',
      'F3 la IP 10.9.9.9 con cinco cuentas; ni la de tres ni la del equipo', str(f3))

f4 = leer('F4_carrito_acaparador')
check([(f['id_usuario'], f['agregadas'], f['compradas']) for f in f4] == [('3001', '40', '0')],
      'F4 la cuenta 3001: 40 unidades al carrito y ninguna comprada', str(f4))

f5 = leer('F5_devoluciones_seriales')
check([(f['id_usuario'], f['devueltas'], f['tasa_devolucion']) for f in f5] == [('4001', '4', '0.8')],
      'F5 la cuenta 4001: devuelve 4 de 5; ni la de 1 de 5, ni la de 2 de 2, ni la 4004 a la que la tienda le cancelo 4', str(f5))

f6 = leer('F6_granja_de_registros')
check(ids(f6, 'ip') == ['::ffff:10.7.7.7'] and f6[0]['cuentas'] == '[6001,6002,6003,6004,6005,6006]',
      'F6 la IP 10.7.7.7: seis cuentas en media hora; ni la de una por dia ni la del equipo', str(f6))

sys.exit(1 if FALLAS else 0)
