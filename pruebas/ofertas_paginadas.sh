#!/usr/bin/env bash
# pruebas/ofertas_paginadas.sh -- las dos rutas paginadas de ofertas, medidas
# contra las que ya existian sin paginar.
#
#   bash pruebas/ofertas_paginadas.sh
#
# QUE PRUEBA
#
#   Parte 0  que el backend conteste y que las dos cuentas entren.
#   Parte 1  GET /vendedor/ofertas/paginado como ventas.norte@mesh.com, con su
#            filtro `estado` medido estado por estado contra la lista completa y
#            contra PostgreSQL.
#   Parte 2  GET /vendedor/ofertas/pendientes/paginado como la tienda, y como
#            un vendedor cualquiera que no la puede ver.
#   Parte 3  cuanto pesa la lista entera contra una pagina de 20. Solo imprime.
#
# EL FILTRO CAMBIO EL 2026-09-19: `activo` YA NO EXISTE. Jose David lo reemplazo
# por `estado` (uno de pendiente, activa, pausada, retirada, rechazada). `activo`
# era un booleano que separaba "activa" de "todo lo demas junto"; con `estado`
# se puede pedir cada uno por separado, y por eso el panel ya puede contar cada
# estado con una peticion de limite=1 y leer total_ofertas. Lo que mide esta
# parte ahora:
#
#   - cada uno de los cinco estados: su total_ofertas contra la lista completa Y
#     contra un count directo en PostgreSQL, y que ninguna oferta de la pagina
#     sea de otro estado;
#   - que los cinco sumen el total sin filtro (si suman menos, hay un estado que
#     el filtro no conoce);
#   - estado=lateral da 400 y el mensaje lista los cinco; estado vacio es "sin
#     filtro";
#   - una pagina fuera de rango CON filtro da lista vacia y el total de ESE estado;
#   - activo=true se IGNORA (200 con todas, no 400): un parametro que la ruta no
#     conoce no avisa. Queda medido para que nadie crea que el filtro viejo sigue
#     vivo.
#
# LA REFERENCIA ES LA RUTA VIEJA. Las dos rutas sin paginar se quedaron tal
# cual y ya las usa el frontend, asi que son la verdad contra la que se mide la
# nueva: el mismo total, los mismos id_oferta y en el mismo orden. Una
# paginacion que repite una oferta en dos paginas, o que se salta una, da un
# total correcto y una lista mala. Por eso se RECORRE entera y se compara
# oferta por oferta, no solo el total_ofertas.
#
# El recorrido va de 37 en 37 y no de 20 o de 100 a proposito: 37 no divide al
# total de ventas.norte (976 ofertas el 2026-09-10), asi que la ultima pagina
# queda a medias, que es donde se esconde el error de uno de mas o de menos. Si
# el total cambia y 37 pasa a dividirlo, el arnes lo avisa. Se cambia con
# LIMITE_RECORRIDO=... si hiciera falta.
#
# LOS CODIGOS DE ERROR SE MIDIERON antes de escribirlos, no se supusieron. Donde
# el backend no da 400 aunque uno lo esperaria (un limite de mas se recorta, una
# pagina de mas da lista vacia), el arnes lo dice con su numero para que nadie
# lo tome por un fallo.
#
# LA LISTA SE TIENE QUE QUEDAR QUIETA mientras se recorre, y por eso se corre
# de uno en uno: sin el portal abierto comprando y sin otro arnes a la vez. Si
# se mueve, el arnes lo nota (vuelve a pedir la lista al terminar), repite una
# vez, y si se sigue moviendo lo dice como SIN MEDIR en vez de culpar a la
# paginacion. Ver recorrer_y_comparar.
#
# LO QUE ESCRIBE. Las rutas que mide son todas lecturas, pero el arnes no deja
# las bases como estaban: cada uno de sus dos logins deja un evento en la
# coleccion eventos_autenticacion de MongoDB, y ademas suma su cuenta al
# contador de multi_cuenta_ip de Redis (identificadores distintos desde la
# misma ip en 300 s; cuenta el login que entra igual que el que falla). Con
# otros dos identificadores probados desde esta maquina en esos 5 minutos,
# nace una alerta en alerta_fraude. No borra nada de eso, porque es
# uso real: son logins de verdad con cuentas de verdad. Pero al final dice si
# nacio (o se engordo) alguna multi_cuenta_ip mientras corria, con sus cuentas,
# para que nadie la tome por un ataque.
#
# No instala nada: curl, python y docker, que ya estan. docker solo para ese
# aviso del final; si no contesta, el aviso dice que no pudo mirar.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
LIMITE_RECORRIDO="${LIMITE_RECORRIDO:-37}"
PG="${PG:-mesh-postgres}"

# El usuario y la base de PostgreSQL, del .env de la raiz como en
# pruebas/alertas_login.sh. Solo para el aviso de alerta_fraude del final.
if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
PG_USUARIO="${PG_USUARIO:-${DB_USER:-meme}}"
PG_BASE="${PG_BASE:-${DB_NAME:-mesh}}"

# Las cuentas de la semilla, las mismas de ARRANCAR.txt.
VENDEDOR_USUARIO="${VENDEDOR_USUARIO:-ventas.norte@mesh.com}"
VENDEDOR_CLAVE="${VENDEDOR_CLAVE:-Vendedor123}"
TIENDA_USUARIO="${TIENDA_USUARIO:-tienda@mesh.com}"
TIENDA_CLAVE="${TIENDA_CLAVE:-Vendedor123}"

# Nombres RELATIVOS y nunca /dev/null como destino de curl. Explicado en
# pruebas/busqueda.sh: con MSYS_NO_PATHCONV, curl.exe no puede escribir ahi,
# sale con 23 y no guarda el tarro de cookies.
export MSYS_NO_PATHCONV=1
TARRO_VENDEDOR=".mesh-ofertas-vendedor.txt"
TARRO_TIENDA=".mesh-ofertas-tienda.txt"
CUERPO=".mesh-ofertas-cuerpo.txt"
COMPLETA=".mesh-ofertas-completa.txt"
RECORRIDO=".mesh-ofertas-recorrido.txt"

limpiar() { rm -f "$TARRO_VENDEDOR" "$TARRO_TIENDA" "$CUERPO" "$COMPLETA" "$COMPLETA.vendedor" "$RECORRIDO" "$RECORRIDO.ref" "$RECORRIDO.despues"; }

# SIN MEDIR no es ni OK ni FALLA, y no entra en ninguna de las dos cuentas: es
# una comprobacion que salio bien sin haber tenido con que fallar. Contarla
# como OK inflaria el verde con algo que no se midio.
ok=0; fallo=0; sin_medir=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
SIN_MEDIR() { echo "  SIN MEDIR $1"; sin_medir=$((sin_medir+1)); }

# Una comprobacion que salio bien cuenta como OK solo si habia con que medirla
# (MEDIBLE=si). Si no, sale SIN MEDIR con el motivo de SIN_MOTIVO. Lo que sale
# MAL sigue siendo FALLA aunque no hubiera con que medir: con una sola
# pendiente, un total que dice 3 ya es un error.
#   $1 texto del OK   $2 que se dejo sin medir
MEDIBLE="si"; SIN_MOTIVO=""
medida() {
    if [ "$MEDIBLE" = "si" ]; then OK "$1"; else SIN_MEDIR "$2: $SIN_MOTIVO"; fi
}

# Consulta de PostgreSQL, como en pruebas/alertas_login.sh. Vacio si docker o
# la base no contestan.
sql() { docker exec "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -qtAc "$1" 2>/dev/null | tr -d '\r'; }

# El aviso de LO QUE ESCRIBE (cabecera): las multi_cuenta_ip que nacieron o se
# engordaron mientras corria el arnes, con las cuentas de su detalle. Solo
# mira, no borra nada. Nacio es id mayor que el max de antes; se engordo es una
# de antes con fecha_actualizacion desde INICIO, porque la llave del UPSERT es
# (tipo, ip, minuto) y un login en un minuto que ya tenia fila suma en esa.
INICIO=""; MAX_ANTES=""; LOGINS="no"; AVISADO="no"
avisar_alertas() {
    AVISADO="si"
    if [ -z "$INICIO" ] || [ -z "$MAX_ANTES" ]; then
        echo "  (no se pudo leer alerta_fraude con docker: no se sabe si los logins dejaron una alerta)"
        return
    fi
    _donde="a.id_tipo_alerta_fraude = 3
            AND (a.id_alerta_fraude > $MAX_ANTES OR a.fecha_actualizacion >= '$INICIO')"
    # Vacio es que la base no contesto; 0 es que no hubo ninguna.
    _n=$(sql "SELECT count(*) FROM alerta_fraude a WHERE $_donde")
    if [ -z "$_n" ]; then
        echo "  (no se pudo leer alerta_fraude al final: no se sabe si los logins dejaron una alerta)"
        return
    fi
    if [ "$_n" = "0" ]; then
        echo "  ninguna multi_cuenta_ip nacio ni se engordo mientras corria el arnes"
        return
    fi
    echo "  (aviso) $_n multi_cuenta_ip nacieron o se engordaron mientras corria el arnes:"
    sql "SELECT a.id_alerta_fraude
                ||CASE WHEN a.id_alerta_fraude > $MAX_ANTES THEN ' nacio' ELSE ' se engordo' END
                ||' (ip '||a.clave||', contador '||a.contador||'): '
                ||coalesce((SELECT string_agg(x, ', ')
                              FROM jsonb_array_elements_text(
                                   CASE WHEN jsonb_typeof(a.detalle->'identificadores') = 'array'
                                        THEN a.detalle->'identificadores' ELSE '[]'::jsonb END) x),
                           'sin cuentas en el detalle')
           FROM alerta_fraude a
          WHERE $_donde
          ORDER BY a.id_alerta_fraude" | sed 's/^/          /'
    echo "          Los logins de $VENDEDOR_USUARIO y $TIENDA_USUARIO suman para esa senal. Si"
    echo "          estan en la lista, la alerta es en parte de este arnes. No se borra: son"
    echo "          logins de verdad y la alerta dice justo lo que paso."
}

# Si el arnes se corta despues de los logins, el aviso sale igual.
al_salir() {
    if [ "$LOGINS" = "si" ] && [ "$AVISADO" = "no" ]; then
        titulo "LO QUE DEJARON LOS LOGINS (el arnes se corto antes de terminar)"
        avisar_alertas
    fi
    limpiar
}
trap al_salir EXIT

titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# El campo de un JSON leido de la entrada. El mismo de pruebas/resenas.sh.
campo() { python -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
for k in sys.argv[1].split('.'):
    if d is None: break
    d = d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" "$1"; }

# Inicia sesion y deja la cookie en el tarro. Escribe el codigo HTTP.
#   $1 identificador   $2 contrasena   $3 tarro
entrar() {
    rm -f "$3"
    curl -s --max-time 8 -o "$CUERPO" -w '%{http_code}' -c "$3" \
        -X POST "$API/usuario/login" -H 'Content-Type: application/json' \
        --data-binary "{\"identificador\":\"$1\",\"contrasena\":\"$2\"}" 2>/dev/null
}

# GET de una ruta. Escribe el codigo HTTP y deja el cuerpo en $3 ($CUERPO si no).
#   $1 ruta   $2 tarro, o vacio para ir sin sesion   $3 archivo destino
pedir() {
    _destino="${3:-$CUERPO}"
    if [ -n "${2:-}" ]; then
        curl -s --max-time 20 -b "$2" -o "$_destino" -w '%{http_code}' "$API$1" 2>/dev/null
    else
        curl -s --max-time 20 -o "$_destino" -w '%{http_code}' "$API$1" 2>/dev/null
    fi
}

# Los id_oferta de una respuesta, uno por linea, en el orden en que vienen.
# Sirve para las dos formas: la vieja trae la lista en payload, la nueva en
# payload.ofertas.
ids_de() {
    python - "$1" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding='utf-8'))['payload']
lista = d if isinstance(d, list) else d['ofertas']
for o in lista:
    print(o['id_oferta'])
PY
}

# Compara dos listas de ids (archivos, uno por linea): la de referencia y la
# recorrida. Dice que sobra, que falta, que se repite y si el orden coincide.
comparar_ids() {
    python - "$1" "$2" <<'PY'
import sys
ref = [l.strip() for l in open(sys.argv[1]) if l.strip()]
rec = [l.strip() for l in open(sys.argv[2]) if l.strip()]
vistos, repetidos = set(), set()
for i in rec:
    if i in vistos: repetidos.add(i)
    vistos.add(i)
faltan = [i for i in ref if i not in vistos]
sobran = [i for i in vistos if i not in set(ref)]
malas = []
if repetidos: malas.append('repetidos %d (%s)' % (len(repetidos), ' '.join(sorted(repetidos)[:5])))
if faltan:    malas.append('faltan %d (%s)' % (len(faltan), ' '.join(faltan[:5])))
if sobran:    malas.append('sobran %d (%s)' % (len(sobran), ' '.join(sobran[:5])))
if malas:
    print('; '.join(malas))
elif rec != ref:
    primera = next(k for k, (a, b) in enumerate(zip(ref, rec)) if a != b)
    print('ORDEN los mismos %d ids, pero el orden se separa en la posicion %d' % (len(ref), primera + 1))
else:
    print('IGUAL %d' % len(ref))
PY
}

# Recorre una ruta paginada de la primera a la ultima pagina y deja los ids en
# $RECORRIDO. Comprueba de paso que cada pagina diga el numero que se pidio y
# traiga las que tiene que traer: llenas todas menos la ultima.
#   $1 ruta sin query   $2 tarro   $3 limite
# Escribe "bien <paginas>" o lo que salio mal.
recorrer() {
    : > "$RECORRIDO"
    _c=$(pedir "$1?limite=$3&pagina=1" "$2")
    if [ "$_c" != "200" ]; then echo "la pagina 1 dio HTTP $_c"; return; fi
    _total=$(campo payload.total_ofertas < "$CUERPO")
    _paginas=$(campo payload.total_paginas < "$CUERPO")
    _malas=""
    for _p in $(seq 1 "${_paginas:-0}"); do
        [ "$_p" -gt 1 ] && _c=$(pedir "$1?limite=$3&pagina=$_p" "$2")
        if [ "$_c" != "200" ]; then _malas="$_malas pagina $_p HTTP $_c;"; continue; fi
        _r=$(python - "$CUERPO" "$_p" "$3" "$_total" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding='utf-8'))['payload']
p, limite, total = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
esperadas = min(limite, total - (p - 1) * limite)
malas = []
if d['pagina'] != p: malas.append('dice pagina %s' % d['pagina'])
if len(d['ofertas']) != esperadas: malas.append('trae %d y tocaban %d' % (len(d['ofertas']), esperadas))
if d['total_ofertas'] != total: malas.append('total %s' % d['total_ofertas'])
print(('pagina %d: ' % p + ', '.join(malas) + ';') if malas else '')
PY
)
        _malas="$_malas$_r"
        ids_de "$CUERPO" >> "$RECORRIDO"
    done
    if [ -n "$_malas" ]; then echo "$_malas"; else echo "bien ${_paginas:-0}"; fi
}

# Dos listas de ids iguales, en el mismo orden.
misma_lista() { case "$(comparar_ids "$1" "$2")" in IGUAL*) return 0 ;; esac; return 1; }

# LA LISTA SE PUEDE MOVER MIENTRAS SE RECORRE. /vendedor/ofertas y su paginada
# ordenan por fecha_actualizacion DESC, y el trigger trg_oferta_tocar_fecha (en
# migrations/005_ofertas.sql) la pone en now() con CUALQUIER UPDATE de la
# oferta: una compra que le baja el stock la sube al principio de la lista. La
# cola de pendientes ordena por fecha_creacion, que no se mueve, pero cambia de
# largo cuando la tienda aprueba o rechaza una. Si eso pasa a mitad del
# recorrido, las paginas se corren y la comparacion sale mal sin que la
# paginacion tenga la culpa.
#
# Por eso, al terminar, se vuelve a pedir la lista completa. Si es la misma de
# antes, nada se movio y el recorrido vale. Si no, se repite una vez contra la
# lista nueva; si tampoco se queda quieta, no hay medida.
#   $1 ruta vieja   $2 ruta paginada   $3 tarro   $4 limite
# Espera la lista de antes en $RECORRIDO.ref. Deja lo de recorrer en
# R_RECORRER, lo de comparar_ids en R_COMPARAR, y en QUIETA "si", "no" o
# "http <codigo>" si la lista no se pudo volver a pedir.
recorrer_y_comparar() {
    for _intento in 1 2; do
        R_RECORRER=$(recorrer "$2" "$3" "$4")
        R_COMPARAR=$(comparar_ids "$RECORRIDO.ref" "$RECORRIDO")
        _c=$(pedir "$1" "$3" "$COMPLETA")
        if [ "$_c" != "200" ]; then QUIETA="http $_c"; return; fi
        ids_de "$COMPLETA" > "$RECORRIDO.despues"
        if misma_lista "$RECORRIDO.ref" "$RECORRIDO.despues"; then QUIETA="si"; return; fi
        QUIETA="no"
        mv -f "$RECORRIDO.despues" "$RECORRIDO.ref"
        [ "$_intento" = 1 ] && echo "  ($1 cambio mientras se recorria; se repite una vez)"
    done
}

# Cuenta lo que dejo recorrer_y_comparar.
#   $1 ruta vieja   $2 texto del OK del recorrido   $3 texto del OK de la comparacion
informar_recorrido() {
    case "$QUIETA" in
        si)
            if [ "${R_RECORRER#bien}" != "$R_RECORRER" ]; then
                medida "$2" "el recorrido salio bien"
            else
                FALLA "al recorrer las paginas: $R_RECORRER"
            fi
            if [ "${R_COMPARAR#IGUAL}" != "$R_COMPARAR" ]; then
                medida "$3" "la comparacion con $1 coincide"
            else
                FALLA "recorridas no dan lo mismo que $1: $R_COMPARAR"
            fi
            ;;
        no)
            # Una pagina que no contesta 200 no tiene que ver con el orden.
            case "$R_RECORRER" in
                *HTTP*) FALLA "al recorrer las paginas: $R_RECORRER" ;;
                *)      SIN_MEDIR "el recorrido: $1 cambio mientras se recorria, y otra vez al repetirlo. Correlo solo" ;;
            esac
            SIN_MEDIR "la comparacion con $1, por lo mismo: no hay contra que comparar"
            ;;
        *)
            FALLA "al volver a pedir $1 contesto HTTP ${QUIETA#http }: no se sabe si la lista se movio"
            ;;
    esac
}

# ============================================================
# 0. Que haya con que trabajar
# ============================================================
titulo "0. EL BACKEND CONTESTA Y LAS DOS CUENTAS ENTRAN"

codigo=$(pedir "/productos?limite=1" "")
if [ "$codigo" != "200" ]; then
    echo "  FALLA el backend no contesta en $API (HTTP $codigo)"
    echo "        Levantalo con  .\\arrancar.ps1"
    exit 1
fi
OK "el backend contesta en $API"

# Antes de los dos logins: con esto se sabe al final que alerta nacio o se toco
# mientras corria (ver LO QUE ESCRIBE en la cabecera). INICIO es del reloj de
# PostgreSQL, el mismo que llena fecha_actualizacion.
INICIO=$(sql "SELECT now()")
MAX_ANTES=$(sql "SELECT coalesce(max(id_alerta_fraude), 0) FROM alerta_fraude")

LOGINS="si"
C=$(entrar "$VENDEDOR_USUARIO" "$VENDEDOR_CLAVE" "$TARRO_VENDEDOR")
if [ "$C" = "200" ] && [ -s "$TARRO_VENDEDOR" ]; then
    OK "sesion de $VENDEDOR_USUARIO iniciada"
else
    FALLA "no se pudo iniciar sesion como $VENDEDOR_USUARIO (HTTP $C)"
fi
C=$(entrar "$TIENDA_USUARIO" "$TIENDA_CLAVE" "$TARRO_TIENDA")
if [ "$C" = "200" ] && [ -s "$TARRO_TIENDA" ]; then
    OK "sesion de $TIENDA_USUARIO iniciada"
else
    FALLA "no se pudo iniciar sesion como $TIENDA_USUARIO (HTTP $C)"
fi
if [ "$fallo" -gt 0 ]; then
    echo "  Sin las dos sesiones no hay nada que comparar. Se para aqui."
    exit 1
fi

# ============================================================
# 1. /vendedor/ofertas/paginado
# ============================================================
titulo "1. /vendedor/ofertas/paginado CUADRA CON /vendedor/ofertas ($VENDEDOR_USUARIO)"

C=$(pedir "/vendedor/ofertas" "$TARRO_VENDEDOR" "$COMPLETA")
if [ "$C" != "200" ]; then
    FALLA "/vendedor/ofertas contesto $C: sin la referencia no se puede medir la nueva"
    exit 1
fi
ids_de "$COMPLETA" > "$RECORRIDO.ref"
N=$(grep -c . "$RECORRIDO.ref")
ACTIVAS=$(python - "$COMPLETA" <<'PY'
import sys, json
print(sum(1 for o in json.load(open(sys.argv[1], encoding='utf-8'))['payload'] if o['estado'] == 'activa'))
PY
)
NO_ACTIVAS=$((N - ACTIVAS))
# La lista completa del vendedor se guarda aparte: $COMPLETA se sobreescribe cada vez que
# recorrer_y_comparar vuelve a pedirla, y el filtro por estado la necesita como referencia.
cp "$COMPLETA" "$COMPLETA.vendedor"
echo "  (la lista completa trae $N ofertas: $ACTIVAS activas y $NO_ACTIVAS en otro estado)"
if [ $((N % LIMITE_RECORRIDO)) = 0 ]; then
    echo "  (aviso) $LIMITE_RECORRIDO divide a $N: la ultima pagina sale llena y no mide el borde."
fi

C=$(pedir "/vendedor/ofertas/paginado?limite=$LIMITE_RECORRIDO" "$TARRO_VENDEDOR")
TOTAL=$(campo payload.total_ofertas < "$CUERPO")
PAGINAS=$(campo payload.total_paginas < "$CUERPO")
ESPERADAS=$(( (N + LIMITE_RECORRIDO - 1) / LIMITE_RECORRIDO ))
if [ "$C" = "200" ] && [ "$TOTAL" = "$N" ]; then
    OK "total_ofertas es igual al largo de la lista completa (= $TOTAL)"
else
    FALLA "total_ofertas dice '$TOTAL' (HTTP $C) y la lista completa trae $N"
fi
if [ "$PAGINAS" = "$ESPERADAS" ]; then
    OK "total_paginas cuadra con el limite: $N de $LIMITE_RECORRIDO en $LIMITE_RECORRIDO son $PAGINAS"
else
    FALLA "total_paginas dice '$PAGINAS' y $N de $LIMITE_RECORRIDO en $LIMITE_RECORRIDO son $ESPERADAS"
fi

recorrer_y_comparar "/vendedor/ofertas" "/vendedor/ofertas/paginado" "$TARRO_VENDEDOR" "$LIMITE_RECORRIDO"
informar_recorrido "/vendedor/ofertas" \
    "se recorrieron las ${R_RECORRER#bien } paginas: todas llenas menos la ultima, cada una con su numero" \
    "recorridas, dan exactamente los mismos ${R_COMPARAR#IGUAL } id_oferta, sin repetir ni faltar, y en el mismo orden"
rm -f "$RECORRIDO.ref" "$RECORRIDO.despues"

# El filtro `estado`, uno por uno. Cada estado se cuenta por DOS lados que no
# dependen de la ruta que se esta midiendo: la lista completa (la referencia de
# siempre) y PostgreSQL directo. Y ademas se mira que lo que trae sea de verdad
# de ese estado. Desde el 2026-09-19 esto reemplaza al filtro `activo`, que solo
# distinguia "activa" de "todo lo demas junto".
ESTADOS="pendiente activa pausada retirada rechazada"

# Cuantas ofertas de un estado trae la lista completa que se guardo arriba.
cuenta_lista() {
    python - "$COMPLETA.vendedor" "$1" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding='utf-8'))['payload']
print(sum(1 for o in d if o['estado'] == sys.argv[2]))
PY
}

# "<total_ofertas> <cuantas de la pagina NO son de ese estado>".
filtro_estado() {
    python - "$CUERPO" "$1" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding='utf-8'))['payload']
malas = [o['id_oferta'] for o in d['ofertas'] if o['estado'] != sys.argv[2]]
print('%s %d' % (d['total_ofertas'], len(malas)))
PY
}

# Lo que dice PostgreSQL de este vendedor, sin pasar por el backend. Vacio si
# docker o la base no contestan.
cuenta_pg() {
    sql "SELECT count(*) FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
           JOIN usuarios u ON u.id_usuario = o.id_usuario
          WHERE u.correo_electronico = '$VENDEDOR_USUARIO'
            AND eo.estado_oferta_nombre = '$1'"
}

SUMA=0; VACIOS=""
for e in $ESTADOS; do
    C=$(pedir "/vendedor/ofertas/paginado?estado=$e&limite=100" "$TARRO_VENDEDOR")
    R=$(filtro_estado "$e")
    EN_LISTA=$(cuenta_lista "$e")
    EN_PG=$(cuenta_pg "$e")
    TOTAL_E="${R%% *}"
    SUMA=$((SUMA + ${TOTAL_E:-0}))
    if [ "$C" = "200" ] && [ "$R" = "$EN_LISTA 0" ]; then
        OK "estado=$e cuenta lo mismo que la lista completa (= $EN_LISTA), y ninguna de las que trae es de otro estado"
    else
        FALLA "estado=$e: HTTP $C, total y fuera de estado '$R', se esperaba '$EN_LISTA 0'"
    fi
    if [ -z "$EN_PG" ]; then
        SIN_MEDIR "estado=$e contra PostgreSQL: docker no contesto"
    elif [ "$EN_PG" = "$TOTAL_E" ]; then
        OK "estado=$e cuadra con PostgreSQL directo (= $EN_PG)"
    else
        FALLA "estado=$e dice total_ofertas '$TOTAL_E' y PostgreSQL cuenta $EN_PG"
    fi
    [ "$EN_LISTA" = "0" ] && VACIOS="$VACIOS $e"
done

if [ "$SUMA" = "$N" ]; then
    OK "la suma de los cinco estados es igual al total sin filtro (= $SUMA)"
else
    FALLA "los cinco estados suman $SUMA y sin filtro son $N: hay ofertas en un estado que el filtro no conoce"
fi
if [ -n "$VACIOS" ]; then
    echo "  (aviso) sin ofertas en esta cuenta para:$VACIOS. Esos estados solo miden que cuenten cero."
fi

# Vacio es "sin filtro", como en validarFiltroEstadoOferta. Medido.
C=$(pedir "/vendedor/ofertas/paginado?estado=" "$TARRO_VENDEDOR")
T=$(campo payload.total_ofertas < "$CUERPO")
if [ "$C" = "200" ] && [ "$T" = "$N" ]; then
    OK "estado vacio es lo mismo que no mandarlo (= $T)"
else
    FALLA "estado vacio da HTTP $C y total '$T', se esperaba 200 y $N"
fi

# El filtro viejo YA NO EXISTE. Un parametro que la ruta no conoce se ignora: no
# da 400, da todas. Se deja medido para que nadie lo tome por un filtro vivo: el
# frontend que mande `activo` recibiria la lista entera sin ningun aviso.
C=$(pedir "/vendedor/ofertas/paginado?activo=true" "$TARRO_VENDEDOR")
T=$(campo payload.total_ofertas < "$CUERPO")
if [ "$C" = "200" ] && [ "$T" = "$N" ]; then
    OK "activo=true ya no filtra: se ignora y trae todas (= $T), como cualquier parametro desconocido"
else
    FALLA "activo=true da HTTP $C y total '$T'; el filtro viejo se quito y se esperaba 200 y $N (todas)"
fi

# Un estado que no existe da 400, y el mensaje lista los cinco validos. Es
# sensible a mayusculas (Activa no es activa): se mide, no se supone.
C=$(pedir "/vendedor/ofertas/paginado?estado=lateral" "$TARRO_VENDEDOR")
M=$(campo mensaje < "$CUERPO")
CONOCIDOS="si"
for e in $ESTADOS; do
    case "$M" in *"$e"*) ;; *) CONOCIDOS="no" ;; esac
done
if [ "$C" = "400" ] && [ "$CONOCIDOS" = "si" ]; then
    OK "estado=lateral da 400 y el mensaje lista los cinco estados ('$M')"
else
    FALLA "estado=lateral da HTTP $C y mensaje '$M'; se esperaba 400 con los cinco estados"
fi

# Una pagina fuera de rango CON filtro: lista vacia y el total real de ese
# estado, no el general.
for e in activa pausada; do
    EN_LISTA=$(cuenta_lista "$e")
    C=$(pedir "/vendedor/ofertas/paginado?estado=$e&limite=$LIMITE_RECORRIDO&pagina=999999" "$TARRO_VENDEDOR")
    R=$(python - "$CUERPO" <<'PY'
import sys, json
try: d = json.load(open(sys.argv[1], encoding='utf-8'))['payload']
except Exception: print('ilegible'); sys.exit()
print('%d %s' % (len(d['ofertas']), d['total_ofertas']))
PY
)
    if [ "$C" = "200" ] && [ "$R" = "0 $EN_LISTA" ]; then
        OK "estado=$e, pagina fuera de rango: 200 con lista vacia y el total de ese estado (= $EN_LISTA)"
    else
        FALLA "estado=$e, pagina fuera de rango da HTTP $C y '$R' (ofertas, total); se esperaba '0 $EN_LISTA'"
    fi
done

for q in "estado=basura" "estado=Activa" "estado=true" "limite=0" "limite=-5" "limite=abc" "pagina=0" "pagina=abc"; do
    C=$(pedir "/vendedor/ofertas/paginado?$q" "$TARRO_VENDEDOR")
    if [ "$C" = "400" ]; then
        OK "$q da 400 ('$(campo mensaje < "$CUERPO")')"
    else
        FALLA "$q da $C, se esperaba 400"
    fi
done

# Lo que NO es un 400, medido el 2026-09-10.
C=$(pedir "/vendedor/ofertas/paginado?limite=1000" "$TARRO_VENDEDOR")
L=$(campo payload.limite < "$CUERPO")
if [ "$C" = "200" ] && [ "$L" = "100" ]; then
    OK "limite=1000 no es error: contesta 200 y lo recorta a $L (validarLimite)"
else
    FALLA "limite=1000 da HTTP $C con limite '$L', se medio 200 y 100"
fi

for p in $((ESPERADAS + 1)) 999999; do
    C=$(pedir "/vendedor/ofertas/paginado?limite=$LIMITE_RECORRIDO&pagina=$p" "$TARRO_VENDEDOR")
    R=$(python - "$CUERPO" <<'PY'
import sys, json
try: d = json.load(open(sys.argv[1], encoding='utf-8'))['payload']
except Exception: print('ilegible'); sys.exit()
print('%d %s %s' % (len(d['ofertas']), d['total_ofertas'], d['pagina']))
PY
)
    if [ "$C" = "200" ] && [ "$R" = "0 $N $p" ]; then
        OK "la pagina $p, fuera de rango, da 200 con lista vacia y el total real (= $N)"
    else
        FALLA "la pagina $p da HTTP $C y '$R' (ofertas, total, pagina); se medio 200 y '0 $N $p'"
    fi
done

# Misma autorizacion que la ruta vieja: sin sesion, el mismo codigo.
C_VIEJA=$(pedir "/vendedor/ofertas" "")
C_NUEVA=$(pedir "/vendedor/ofertas/paginado" "")
if [ "$C_NUEVA" = "$C_VIEJA" ] && [ "$C_NUEVA" != "200" ]; then
    OK "sin sesion da lo mismo que la ruta sin paginar (= $C_NUEVA)"
else
    FALLA "sin sesion la paginada da $C_NUEVA y la vieja $C_VIEJA"
fi

# ============================================================
# 2. /vendedor/ofertas/pendientes/paginado
# ============================================================
titulo "2. /vendedor/ofertas/pendientes/paginado CUADRA CON /pendientes"

C=$(pedir "/vendedor/ofertas/pendientes" "$TARRO_TIENDA" "$COMPLETA")
if [ "$C" = "200" ]; then
    ids_de "$COMPLETA" > "$RECORRIDO.ref"
    NP=$(grep -c . "$RECORRIDO.ref")
    echo "  (la cola de revision tiene $NP oferta(s) pendiente(s))"

    # De una en una mientras la cola sea corta: asi cada oferta queda en el
    # borde de una pagina, que es donde se pierden o se repiten.
    LP=1
    [ "$NP" -gt 50 ] && LP="$LIMITE_RECORRIDO"

    # Con 0 o 1 pendientes no hay nada que medir: ningun borde entre paginas
    # donde perder o repetir una oferta, ningun orden que comparar, y un total
    # de 0 o de 1 que coincide con casi cualquier implementacion. Lo que salga
    # bien sale SIN MEDIR y no entra en la cuenta; lo que salga mal es FALLA
    # igual. Hacen falta 2 pendientes: las deja un vendedor normal que publica
    # con POST /vendedor/ofertas, porque desde la 010 esas nacen pendientes.
    if [ "$NP" -lt 2 ]; then
        MEDIBLE="no"
        SIN_MOTIVO="con $NP pendiente(s) no prueba nada, hacen falta 2 (faltan $((2 - NP)))"
    fi

    C=$(pedir "/vendedor/ofertas/pendientes/paginado?limite=$LP" "$TARRO_TIENDA")
    TOTAL=$(campo payload.total_ofertas < "$CUERPO")
    if [ "$C" = "200" ] && [ "$TOTAL" = "$NP" ]; then
        medida "como la tienda, total_ofertas es igual al largo de /pendientes (= $TOTAL)" \
               "el total coincide con /pendientes (= $TOTAL)"
    else
        FALLA "como la tienda, total_ofertas dice '$TOTAL' (HTTP $C) y /pendientes trae $NP"
    fi

    recorrer_y_comparar "/vendedor/ofertas/pendientes" "/vendedor/ofertas/pendientes/paginado" "$TARRO_TIENDA" "$LP"
    informar_recorrido "/vendedor/ofertas/pendientes" \
        "se recorrieron las ${R_RECORRER#bien } paginas de $LP en $LP" \
        "recorridas, dan los mismos ${R_COMPARAR#IGUAL } id_oferta que /pendientes, y en el mismo orden"
    MEDIBLE="si"; SIN_MOTIVO=""
    rm -f "$RECORRIDO.ref" "$RECORRIDO.despues"
else
    FALLA "como la tienda, /vendedor/ofertas/pendientes contesto $C"
fi

C=$(pedir "/vendedor/ofertas/pendientes/paginado?pagina=0" "$TARRO_TIENDA")
if [ "$C" = "400" ]; then
    OK "como la tienda, pagina=0 da 400"
else
    FALLA "como la tienda, pagina=0 da $C"
fi

# Un vendedor cualquiera no ve la cola. El codigo se midio: 404, el mismo
# "no existe" generico de la ruta vieja, para no confirmar que la ruta esta. La
# comparacion es entre las dos rutas y no contra un numero escrito aqui: lo
# que se promete es que la nueva no cuente nada que la vieja calla.
C_VIEJA=$(pedir "/vendedor/ofertas/pendientes" "$TARRO_VENDEDOR")
M_VIEJA=$(campo mensaje < "$CUERPO")
C_NUEVA=$(pedir "/vendedor/ofertas/pendientes/paginado" "$TARRO_VENDEDOR")
M_NUEVA=$(campo mensaje < "$CUERPO")
if [ "$C_NUEVA" = "$C_VIEJA" ] && [ "$M_NUEVA" = "$M_VIEJA" ] && [ "$C_NUEVA" != "200" ]; then
    OK "como $VENDEDOR_USUARIO da lo mismo que la ruta sin paginar: $C_NUEVA '$M_NUEVA'"
else
    FALLA "como $VENDEDOR_USUARIO la paginada da $C_NUEVA '$M_NUEVA' y la vieja $C_VIEJA '$M_VIEJA'"
fi

# Y con una paginacion invalida, tambien. El permiso se revisa ANTES que la
# query: si saliera un 400, el vendedor sabria que la ruta existe y que solo
# le fallo el numero.
C=$(pedir "/vendedor/ofertas/pendientes/paginado?limite=abc" "$TARRO_VENDEDOR")
if [ "$C" = "$C_VIEJA" ]; then
    OK "con limite=abc sigue dando $C y no 400: el permiso va antes que la validacion"
else
    FALLA "con limite=abc da $C; sin paginar da $C_VIEJA"
fi

# ============================================================
# 3. Lo que pesa
# ============================================================
titulo "3. LA LISTA ENTERA CONTRA UNA PAGINA DE 20"

# Solo informa, salvo una cosa: si hay mas de 20, la pagina tiene que pesar
# menos que la lista. Es la razon de ser de estas rutas.
peso() { curl -s --max-time 30 -b "$2" -o "$CUERPO" -w '%{size_download} %{time_total}' "$API$1" 2>/dev/null; }

comparar_peso() {
    _quien="$1"; _tarro="$2"; _entera="$3"; _pagina="$4"
    _a=$(peso "$_entera" "$_tarro")
    _b=$(peso "$_pagina" "$_tarro")
    _total=$(campo payload.total_ofertas < "$CUERPO")
    _ba=${_a% *}; _bb=${_b% *}
    printf '  %-22s %-50s %9s bytes  %6s s\n' "$_quien" "$_entera" "$_ba" "${_a#* }"
    printf '  %-22s %-50s %9s bytes  %6s s\n' "" "$_pagina" "$_bb" "${_b#* }"
    if [ "${_total:-0}" -gt 20 ] 2>/dev/null; then
        if [ "$_bb" -lt "$_ba" ] 2>/dev/null; then
            OK "con $_total ofertas, la pagina de 20 pesa $(( _ba / (_bb > 0 ? _bb : 1) )) veces menos"
        else
            FALLA "con $_total ofertas, la pagina de 20 ($_bb bytes) no pesa menos que la lista ($_ba)"
        fi
    fi
    echo
}

comparar_peso "$TIENDA_USUARIO" "$TARRO_TIENDA" "/vendedor/ofertas" "/vendedor/ofertas/paginado?limite=20"
comparar_peso "$TIENDA_USUARIO" "$TARRO_TIENDA" "/vendedor/ofertas/pendientes" "/vendedor/ofertas/pendientes/paginado?limite=20"
comparar_peso "$VENDEDOR_USUARIO" "$TARRO_VENDEDOR" "/vendedor/ofertas" "/vendedor/ofertas/paginado?limite=20"

# ============================================================
# RESULTADO
# ============================================================
titulo "LO QUE DEJARON LOS LOGINS"
avisar_alertas

titulo "RESULTADO"
if [ "$sin_medir" -gt 0 ]; then
    echo "  $ok OK, $fallo FALLA, y $sin_medir SIN MEDIR que no cuentan para ninguno de los dos"
else
    echo "  $ok OK, $fallo FALLA"
fi
if [ "$fallo" -gt 0 ]; then
    echo "  Las rutas paginadas no dan lo mismo que las que ya existian."
    exit 1
fi
if [ "$sin_medir" -gt 0 ]; then
    # El mensaje de siempre prometeria lo que no se midio.
    echo "  Lo que se midio da lo mismo que las rutas sin paginar, pero no todo se"
    echo "  midio: arriba dice que quedo SIN MEDIR y que hace falta para medirlo."
    exit 0
fi
echo "  Recorridas pagina por pagina dan las mismas ofertas, en el mismo orden,"
echo "  que las rutas sin paginar, y dicen que no a lo mismo que ellas."
exit 0
