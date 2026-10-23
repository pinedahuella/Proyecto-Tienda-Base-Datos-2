#!/usr/bin/env bash
# pruebas/alertas_login.sh -- el fraude de inicio de sesion de punta a punta:
# el evento que deja un login fallido, las tres alertas de Redis con su umbral
# exacto, la ruta del admin que las lista y la pregunta que contesta
# Elasticsearch.
#
#   bash pruebas/alertas_login.sh
#
# QUE PRUEBA
#
#   Parte 0  que el terreno este: el backend, senal_fraude con su catalogo
#            de tipos y el de estados, la plantilla de Elasticsearch y el campo
#            ip del indice de tipo ip. Si falta algo se para, porque lo de abajo mediria
#            sobre otra cosa.
#   Parte 1  un login fallido deja su evento en MongoDB, el worker lo copia a
#            Elasticsearch con el mismo _id, y el 401 no dice POR QUE fallo.
#   Parte 2  fuerza_bruta_cuenta.
#   Parte 3  multi_cuenta_ip.
#   Parte 4  fuerza_bruta_ip.
#   Parte 5  GET /admin/fraude/alertas-login: lo que trae, su filtro, sus 400
#            y quien NO la puede ver.
#   Parte 6  la agregacion de Elasticsearch que contesta "desde que IP se
#            teclearon muchos correos o usuarios distintos".
#
# LOS UMBRALES SE LEEN DEL SERVICIO, no se copian aqui. Salen de
# backend/src/services/fraude-login/fraude-login.service.ts. Si alguien sube el
# umbral de 5 a 6, este arnes sigue midiendo el umbral de verdad en vez de
# aprobar o reprobar uno que ya no existe.
#
# UN UMBRAL SE PRUEBA POR LOS DOS LADOS. "Con 5 fallos hay alerta" pasaria
# igual con un umbral de 1. Por eso cada deteccion comprueba primero que con
# uno menos la senal NO suma ninguna deteccion, y despues que el intento que
# cruza suma exactamente UNA: si hubiera saltado un intento antes, el que cruza
# la habria subido dos.
#
# UNA SENAL POR (TIPO, CLAVE). Desde el refactor de fraude (7453ffe, migraciones
# 031 a 033) el login ya no escribe en alerta_fraude, que tenia una fila por
# minuto. Escribe en senal_fraude, una fila por (tipo, clave) para siempre, y
# cada vez que el detector la vuelve a ver suma 1 a total_detecciones. Por eso
# esta prueba mide cuanto SUBE total_detecciones, y no si nace una fila: las
# dos senales de ip tienen como clave la ip de todo el trafico local, y en una
# base usada ya existen de antes. La de cuenta si nace, porque su clave es un
# identificador inventado de esta corrida.
#
# LA IP ES UNA SOLA PARA TODO. El backend no tiene trustProxy, asi que
# request.ip es la del proceso que conecta, y en local todo llega desde la
# misma direccion. Los contadores de IP de Redis son entonces los mismos para
# esta prueba, para el portal abierto en el navegador y para cualquier otro
# arnes. Por eso cada deteccion borra antes sus claves y despues comprueba que
# el contador dice EXACTAMENTE lo que se mando: si dice mas, alguien mas estaba
# entrando y esa parte no midio lo suyo. DE UNO EN UNO, como pruebas/eventos.sh.
#
# LA MARCA. Todo identificador inventado empieza por "prueba.alertas." y
# termina en "@mesh.test" (.test es un dominio reservado, no puede ser una
# cuenta de nadie). Ademas cada peticion va con el user-agent
# mesh-prueba-alertas, que el backend guarda en el evento. Con eso la limpieza
# encuentra casi todo lo suyo sin guardar ningun id, incluido lo que haya dejado
# una corrida anterior que murio. Casi: las dos senales de ip no llevan la marca
# en la clave, que es la ip (ver mas abajo).
#
# LO QUE BORRA AL TERMINAR, aunque algo falle: las senales que nacieron de esta
# prueba (con sus cuentas, sus ip y sus avisos, que se van en cascada), sus
# claves de Redis, sus eventos de MongoDB y sus documentos de Elasticsearch. Lo
# que NO borra: los logins que SI entraron (el admin y el comprador de la parte
# 5), que son uso real y no suciedad, y las senales de ip que ya existian antes
# de empezar. A esas la prueba les suma detecciones y les cambia el detalle; se
# avisa con su id al final.
#
# "Aunque algo falle" es el trap de salida, y el trap no corre si el proceso
# muere de golpe: Windows lo mata cuando se queda sin RAM, o lo corta un tope de
# tiempo. Entonces una senal de ip nacida en la corrida se quedaria para
# siempre, porque la de fuerza_bruta_ip no tiene NADA de la prueba (clave la ip,
# detalle dos numeros). Por eso cada senal que nace se anota en
# .mesh-alertas-nacidas.txt, en la raiz del repo, y la corrida siguiente, al
# empezar, borra lo anotado solo si la senal sigue con la misma clave y el mismo
# total_detecciones. Si subio, alguien la vio despues y ya no es solo de la
# prueba: se queda. Queda un hueco de un instante, entre que la senal nace y se
# anota; si muere justo ahi, esa fila la tiene que borrar una persona.
#
# No instala nada: curl, docker y python, que ya estan.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
ES="${ES:-http://localhost:9200}"
# Con la seguridad de Elasticsearch encendida: mete el usuario en $ES (ver ahi).
. "$(dirname "$0")/../seguridad/url_elastic.sh"
INDICE_EVENTOS="${INDICE_EVENTOS:-mesh_eventos_autenticacion}"
PLANTILLA_EVENTOS="${PLANTILLA_EVENTOS:-mesh_eventos_autenticacion}"
PG="${PG:-mesh-postgres}"
MONGO="${MONGO:-mesh-mongo}"
REDIS="${REDIS:-mesh-redis}"
SERVICIO="$RAIZ/backend/src/services/fraude-login/fraude-login.service.ts"

# Las cuentas de la semilla, las mismas de ARRANCAR.txt: esto corre contra la
# base local de desarrollo.
ADMIN_USUARIO="${ADMIN_USUARIO:-admin@mesh.com}"
ADMIN_CLAVE="${ADMIN_CLAVE:-Admin123}"
COMPRADOR_USUARIO="${COMPRADOR_USUARIO:-comprador.sur@mesh.com}"
COMPRADOR_CLAVE="${COMPRADOR_CLAVE:-Comprador123}"

# La contrasena de Redis sale del .env y NO lleva valor por defecto, por lo
# mismo que explica pruebas/eventos.sh: un respaldo escrito aqui quedaria
# publicado en el repositorio y taparia un .env mal puesto.
if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
PG_USUARIO="${PG_USUARIO:-${DB_USER:-meme}}"
PG_BASE="${PG_BASE:-${DB_NAME:-mesh}}"
if [ -z "${REDIS_PASSWORD:-}" ]; then
    echo "Falta REDIS_PASSWORD. Ponla en el .env de la raiz o exportala." >&2
    exit 1
fi

# Git Bash convierte las rutas que empiezan con / al pasarlas a docker, y las
# urls de Elasticsearch tambien. Ver pruebas/busqueda.sh.
export MSYS_NO_PATHCONV=1

# Archivos de trabajo con nombre RELATIVO y nunca /dev/null: con
# MSYS_NO_PATHCONV, curl.exe no puede escribir en /dev/null, sale con 23 y no
# guarda el tarro de cookies. Esta explicado entero en pruebas/busqueda.sh.
TARRO_ADMIN=".mesh-alertas-admin.txt"
TARRO_COMPRADOR=".mesh-alertas-comprador.txt"
CUERPO=".mesh-alertas-cuerpo.txt"
CUERPO_B=".mesh-alertas-cuerpo-b.txt"
VACIO=".mesh-alertas-nada"

# Las alertas que nacieron, anotadas por si el proceso muere sin limpiar (ver la
# cabecera). Este si va con ruta fija, la raiz del repo, y no relativa: lo tiene
# que encontrar la corrida siguiente aunque se lance desde otra carpeta, y no lo
# lee curl sino bash. Lo tapa el .mesh-* del .gitignore.
ANOTADAS="$RAIZ/.mesh-alertas-nacidas.txt"

# ---------- la marca ----------
MARCA="prueba.alertas."
UA="mesh-prueba-alertas"
CORRIDA="$(date +%s)$$"
PREFIJO="${MARCA}${CORRIDA}."
# Para las expresiones regulares de Mongo el punto hay que escaparlo.
RE_MARCA='^prueba\.alertas\.'
RE_CORRIDA="^$(printf '%s' "$PREFIJO" | sed 's/\./\\./g')"
CLAVE_MALA="NoEsLaClave-${CORRIDA}"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# ---------- ayudantes de las bases ----------

# La -q es la de pruebas/eventos.sh: sin ella un DELETE ... RETURNING trae
# tambien la etiqueta del comando pegada al valor.
sql() { docker exec "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -qtAc "$1" 2>/dev/null | tr -d '\r'; }

# El JavaScript entra por una variable de entorno y no pegado en la linea de
# sh -c. Asi puede llevar comillas dobles y $regex sin que ninguna de las dos
# shells se lo coma por el camino.
mongo() {
    docker exec -e JS="$1" "$MONGO" sh -c 'mongosh --quiet \
        -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
        --authenticationDatabase admin "$MONGO_INITDB_DATABASE" --eval "$JS"' 2>/dev/null | tr -d '\r'
}
mongo_num() { mongo "$1" | tr -d ' \n'; }

rcli() { docker exec "$REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'; }

# El campo de un JSON leido de la entrada, sin depender de jq. El mismo de
# pruebas/resenas.sh.
campo() { python -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
for k in sys.argv[1].split('.'):
    if d is None: break
    d = d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" "$1"; }

# Un intento de login. Deja el cuerpo en $CUERPO y escribe el codigo HTTP.
#   $1 identificador   $2 contrasena   $3 tarro de cookies (opcional)
intentar_login() {
    if [ -n "${3:-}" ]; then
        rm -f "$3"
        curl -s --max-time 8 -A "$UA" -o "$CUERPO" -w '%{http_code}' -c "$3" \
            -X POST "$API/usuario/login" -H 'Content-Type: application/json' \
            --data-binary "{\"identificador\":\"$1\",\"contrasena\":\"$2\"}" 2>/dev/null
    else
        curl -s --max-time 8 -A "$UA" -o "$CUERPO" -w '%{http_code}' \
            -X POST "$API/usuario/login" -H 'Content-Type: application/json' \
            --data-binary "{\"identificador\":\"$1\",\"contrasena\":\"$2\"}" 2>/dev/null
    fi
}

# GET con o sin tarro. Deja el cuerpo en $CUERPO y escribe el codigo HTTP.
pedir() {
    if [ -n "${2:-}" ]; then
        curl -s --max-time 10 -A "$UA" -b "$2" -o "$CUERPO" -w '%{http_code}' "$API$1" 2>/dev/null
    else
        curl -s --max-time 10 -A "$UA" -o "$CUERPO" -w '%{http_code}' "$API$1" 2>/dev/null
    fi
}

ms() { echo $(( $(date +%s%N) / 1000000 )); }

# Espera por sondeo, con tope. Repite "$@" cada medio segundo hasta que salga
# con 0 o se acabe el tope en segundos. Deja en ESPERO lo que tardo, en
# segundos con un decimal, para poder decirlo.
#
# No hay sleeps fijos largos a proposito: el worker corre cada 5 s y el
# backend escribe el evento y los contadores sin await, asi que el momento
# exacto cambia de una corrida a otra. Un sleep fijo o sobra o se queda corto.
ESPERO=0
esperar() {
    _tope=$1; shift
    _t0=$(ms)
    while :; do
        if "$@"; then
            _d=$(( $(ms) - _t0 )); ESPERO="$((_d / 1000)).$(( (_d % 1000) / 100 ))"
            return 0
        fi
        if [ $(( $(ms) - _t0 )) -ge $(( _tope * 1000 )) ]; then
            ESPERO="$_tope"
            return 1
        fi
        sleep 0.5
    done
}

# ---------- ayudantes de las senales ----------

ahora_pg() { sql "SELECT now()"; }

# Desde la migracion 031 todo va por senal_fraude y el tipo se nombra por su
# nombre en el catalogo unico, no por un id. El FROM de todas las consultas.
DESDE_SENAL="senal_fraude s JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude)"

# Cuantas veces se detecto la senal (tipo, clave). 0 si no existe. Es lo que
# miden las partes 2 a 4: cuanto sube entre antes y despues.
#   $1 tipo   $2 clave
detecciones() {
    sql "SELECT coalesce(sum(s.total_detecciones), 0) FROM $DESDE_SENAL
          WHERE t.tipo_senal_fraude_nombre = '$1' AND s.clave = '$2'"
}
# Sale con 0 cuando la senal ya sumo N detecciones desde BASE.
#   $1 tipo   $2 clave   $3 base   $4 n
sube_al_menos() {
    _d=$(detecciones "$1" "$2")
    [ -n "$_d" ] && [ $((_d - $3)) -ge "$4" ] 2>/dev/null
}

# La senal: id|total_detecciones|cuentas|detalle. cuentas es cuantas tiene en
# senal_fraude_cuenta (las victimas del login).
fila_senal() {
    sql "SELECT s.id_senal_fraude||'|'||s.total_detecciones||'|'
                ||(SELECT count(*) FROM senal_fraude_cuenta c WHERE c.id_senal_fraude = s.id_senal_fraude)
                ||'|'||s.detalle::text
           FROM $DESDE_SENAL
          WHERE t.tipo_senal_fraude_nombre = '$1' AND s.clave = '$2'"
}

# Redis: el valor de un contador (vacio si no existe) y el tamano de un conjunto.
contador_llega() { _v=$(rcli GET "$1"); [ -n "$_v" ] && [ "$_v" -ge "$2" ] 2>/dev/null; }
conjunto_llega() { _v=$(rcli SCARD "$1"); [ "${_v:-0}" -ge "$2" ] 2>/dev/null; }

# Antes de cada deteccion se borran las claves que la afectan, para que la
# cuenta empiece en cero y el umbral se cruce en el intento que se espera.
#   $@  los identificadores que va a usar esa parte
reiniciar_contadores() {
    rcli DEL "mesh:fraude:fallos_ip:$IP" "mesh:fraude:cuentas_ip:$IP" > /dev/null
    for _i in "$@"; do
        rcli DEL "mesh:fraude:fallos_cuenta:$_i" > /dev/null
    done
    _quedan=$(rcli EXISTS "mesh:fraude:fallos_ip:$IP" "mesh:fraude:cuentas_ip:$IP")
    if [ "$_quedan" = "0" ]; then
        echo "  (contadores de la ip $IP y de ${#} identificador(es) en cero)"
    else
        FALLA "no se pudieron borrar las claves de Redis de la ip $IP"
    fi
}

# Ya no hace falta esperar a un minuto sin alerta ni alejarse del cambio de
# minuto. Con alerta_fraude la llave era (tipo, clave, minuto): partir el
# minuto abria otra fila, y una fila ajena del mismo minuto se engordaba. La
# senal es una por (tipo, clave) siempre, asi que el minuto no cambia nada.

# Una senal que la prueba hizo saltar es propia si nacio en esta corrida, con
# id mayor que el max de antes. Si ya existia, la prueba le sumo detecciones:
# es lo normal con las de ip, se dice y no se cuenta como de la prueba, para
# que nada la borre.
#   $1 id   $2 nombre de la senal
senal_propia() {
    if [ -n "$1" ] && [ "$1" -le "$MAX_ANTES" ] 2>/dev/null; then
        echo "  (la senal $2 $1 ya existia antes de empezar: la prueba le sumo detecciones"
        echo "   y le cambio el detalle. No se borra al final)"
        return 1
    fi
    return 0
}

# Anota una senal apenas nace: id|clave|total_detecciones. Solo si nacio en
# esta corrida; una de antes de empezar no se anota nunca, porque lo anotado lo
# borra la corrida siguiente.
anotar_senal() {
    [ -n "${1:-}" ] && [ -n "$MAX_ANTES" ] || return 0
    sql "SELECT id_senal_fraude||'|'||clave||'|'||total_detecciones
           FROM senal_fraude
          WHERE id_senal_fraude = $1 AND id_senal_fraude > $MAX_ANTES" >> "$ANOTADAS"
}

# Borra las senales anotadas que siguen tal como se anotaron: mismo id, misma
# clave y el mismo total_detecciones. Escribe cuantas borro, o nada si la base
# no contesto.
borrar_anotadas() {
    if [ ! -s "$ANOTADAS" ]; then echo 0; return; fi
    _cond=""
    while IFS='|' read -r _id _clave _total; do
        # Lo que no tenga forma de linea anotada no llega al SQL.
        case "$_id" in ''|*[!0-9]*) continue ;; esac
        case "$_total" in ''|*[!0-9]*) continue ;; esac
        case "$_clave" in *"'"*|*\\*) continue ;; esac
        [ -n "$_clave" ] || continue
        _cond="$_cond OR (id_senal_fraude = $_id AND clave = '$_clave' AND total_detecciones = $_total)"
    done < "$ANOTADAS"
    if [ -z "$_cond" ]; then echo 0; return; fi
    sql "WITH d AS (DELETE FROM senal_fraude WHERE false $_cond RETURNING 1) SELECT count(*) FROM d"
}

# Un valor del detalle jsonb de una fila leida con fila_senal.
detalle() { printf '%s' "$1" | cut -d'|' -f4- | campo "$2"; }

# ============================================================
# Limpieza, registrada ANTES de tocar nada
# ============================================================
#
# Va en un trap para que corra tambien si el arnes muere a la mitad. Borra por
# la MARCA y no por los ids que va anotando: si muere justo antes de anotar uno,
# una limpieza por id no lo encontraria. Lo anotado en $ANOTADAS se borra
# ademas, para lo que no tiene marca y quedo de una corrida que murio sin trap.
#
# El orden es MongoDB antes que Elasticsearch. Al reves, un evento todavia
# pendiente lo volveria a copiar el worker justo despues del borrado. Y antes
# de borrar se espera a que no quede ninguno pendiente, para que el worker no
# este a medio copiar uno cuando se borra el indice.
#
# En senal_fraude la clave de dos de los tres tipos es la ip, que es la de
# todo el trafico local. Por eso se borra asi, solo en la familia login:
#   clave con la marca   se borra siempre, sea de esta corrida o de una que
#                        murio. Es fuerza_bruta_cuenta y cualquier otra senal
#                        cuya clave sea un identificador inventado.
#   clave = la ip        solo las que nacieron DESPUES del max id leido al
#                        empezar. Antes de cada deteccion se borraron sus
#                        contadores, asi que lo que nace en la corrida es de la
#                        corrida. Si en esos segundos alguien mas fallo 8 veces
#                        desde la misma ip, esa senal tambien se va: no hay
#                        forma de distinguirla, y queda dicho aqui.
# Las senales de ip que ya existian NO se borran nunca: no nacieron de la
# prueba. Se avisa con su id y su total.
# Sus cuentas, sus ip y sus avisos se van en cascada. La fila de direccion_ip
# se borra solo si nacio en la corrida y ya ninguna senal la usa.
IP=""
MAX_ANTES=""
MAX_IP_ANTES=""
PROPIA_MULTI=""
PROPIA_IP=""
INICIO=""
LIMPIADO="no"

pendientes_marca() { mongo_num 'db.eventos_autenticacion.countDocuments({identificador_intentado: {$regex: /'"$RE_MARCA"'/}, pendiente_elastic: true})'; }
sin_pendientes() { [ "$(pendientes_marca)" = "0" ]; }

CONSULTA_MARCA_ES='{"query":{"bool":{"should":[
    {"prefix":{"identificador_intentado":"'"$MARCA"'"}},
    {"bool":{"filter":[{"term":{"user_agent":"'"$UA"'"}},{"term":{"resultado":"fallo"}}]}}
  ],"minimum_should_match":1}}}'
FILTRO_MARCA_MONGO='{$or: [{identificador_intentado: {$regex: /'"$RE_MARCA"'/}}, {user_agent: "'"$UA"'", resultado: "fallo"}]}'

# La condicion SQL "todos los identificadores del detalle son de la marca". El
# CASE no sobra: jsonb_array_elements_text revienta con algo que no sea una
# lista, y un AND no garantiza en SQL que se evalue primero el tipo.
solo_marcados() {
    printf '%s' "(s.detalle->>'identificadores' LIKE '%\"${MARCA}%'
             AND CASE WHEN jsonb_typeof(s.detalle->'identificadores') = 'array'
                      THEN NOT EXISTS (
                           SELECT 1 FROM jsonb_array_elements_text(s.detalle->'identificadores') x
                            WHERE x NOT LIKE '${MARCA}%')
                      ELSE false END)"
}

# Las senales de la familia login.
DE_LOGIN="t.id_familia_senal_fraude = (SELECT id_familia_senal_fraude FROM familia_senal_fraude
                                         WHERE familia_senal_fraude_nombre = 'login')"

limpiar() {
    LIMPIADO="si"

    _filtro_ip="false"
    if [ -n "$IP" ] && [ -n "$MAX_ANTES" ]; then
        _filtro_ip="(s.clave = '$IP' AND s.id_senal_fraude > $MAX_ANTES)"
    fi
    _anotadas=$(borrar_anotadas)
    _alertas=$(sql "WITH d AS (
                      DELETE FROM senal_fraude s USING tipo_senal_fraude t
                       WHERE t.id_tipo_senal_fraude = s.id_tipo_senal_fraude AND $DE_LOGIN
                         AND (s.clave LIKE '${MARCA}%' OR $_filtro_ip)
                   RETURNING 1)
                    SELECT count(*) FROM d")
    if [ -n "$_alertas" ] && [ -n "$_anotadas" ]; then
        echo "  senal_fraude: $((_alertas + _anotadas)) senal(es) de la prueba borradas ($_anotadas por lo anotado)"
        # Solo si las dos contestaron. Si no, el archivo se queda y lo intenta
        # la corrida siguiente.
        rm -f "$ANOTADAS"
    else
        echo "  senal_fraude: la base no contesto (${_alertas:-?} y ${_anotadas:-?}); $ANOTADAS se queda"
    fi
    if [ -n "$MAX_IP_ANTES" ]; then
        sql "DELETE FROM direccion_ip d WHERE d.id_direccion_ip > $MAX_IP_ANTES
               AND NOT EXISTS (SELECT 1 FROM senal_fraude_ip x WHERE x.id_direccion_ip = d.id_direccion_ip)" > /dev/null
    fi

    # Lo que NO se borra, pero se dice. ultima_deteccion es el inicio de la
    # ventana, truncado al minuto, asi que se compara con INICIO truncado igual.
    if [ -n "$IP" ] && [ -n "$MAX_ANTES" ] && [ -n "$INICIO" ]; then
        _tocadas=$(sql "SELECT string_agg(s.id_senal_fraude||' '||t.tipo_senal_fraude_nombre||' con '||s.total_detecciones||' detecciones', ', ' ORDER BY s.id_senal_fraude)
                          FROM $DESDE_SENAL
                         WHERE $DE_LOGIN AND s.clave = '$IP'
                           AND s.id_senal_fraude <= $MAX_ANTES
                           AND s.ultima_deteccion >= date_trunc('minute', '$INICIO'::timestamptz)")
        if [ -n "$_tocadas" ]; then
            echo "  (aviso) senales de ANTES de empezar que se detectaron durante la corrida: $_tocadas."
            echo "          Si fue la prueba, les sumo detecciones y les cambio el detalle."
            echo "          No se borran: no nacieron de ella."
        fi
    fi
    if [ -n "$MAX_ANTES" ] && [ -n "$INICIO" ]; then
        _viejas=$(sql "SELECT string_agg(s.id_senal_fraude::text, ', ' ORDER BY s.id_senal_fraude)
                         FROM $DESDE_SENAL
                        WHERE t.tipo_senal_fraude_nombre = 'multi_cuenta_ip' AND s.id_senal_fraude <= $MAX_ANTES
                          AND s.ultima_deteccion < date_trunc('minute', '$INICIO'::timestamptz) AND $(solo_marcados)")
        if [ -n "$_viejas" ]; then
            echo "  (aviso) multi_cuenta_ip de antes de empezar con solo identificadores de la marca: $_viejas."
            echo "          Puede ser una senal ajena cuyo ultimo detalle dejo una corrida anterior,"
            echo "          o la sobra de una que murio sin anotarla. No se borran solas; si se sabe"
            echo "          que son de la prueba: DELETE FROM senal_fraude WHERE id_senal_fraude IN ($_viejas);"
        fi
    fi

    _claves=0
    _claves=0
    for _k in $(rcli --scan --pattern "mesh:fraude:fallos_cuenta:${MARCA}*"); do
        rcli DEL "$_k" > /dev/null; _claves=$((_claves+1))
    done
    if [ -n "$IP" ]; then
        _n=$(rcli DEL "mesh:fraude:fallos_ip:$IP" "mesh:fraude:cuentas_ip:$IP")
        _claves=$((_claves + ${_n:-0}))
    fi
    echo "  Redis: $_claves clave(s) de la prueba borradas"

    if ! esperar 15 sin_pendientes; then
        echo "  (quedaban eventos pendientes del worker; se borran igual)"
    fi
    _mongo=$(mongo_num 'print(db.eventos_autenticacion.deleteMany('"$FILTRO_MARCA_MONGO"').deletedCount)')
    echo "  MongoDB: ${_mongo:-?} evento(s) de la prueba borrados"

    _es=$(curl -s --max-time 20 -X POST -H 'Content-Type: application/json' \
            "$ES/$INDICE_EVENTOS/_delete_by_query?refresh=true&conflicts=proceed" \
            --data-binary "$CONSULTA_MARCA_ES" 2>/dev/null | campo deleted)
    echo "  Elasticsearch: ${_es:-?} documento(s) de la prueba borrados"

    rm -f "$TARRO_ADMIN" "$TARRO_COMPRADOR" "$CUERPO" "$CUERPO_B" "$VACIO"
}

al_salir() {
    if [ "$LIMPIADO" != "si" ]; then
        titulo "LIMPIEZA (el arnes se corto antes de terminar)"
        limpiar
    fi
    rm -f "$TARRO_ADMIN" "$TARRO_COMPRADOR" "$CUERPO" "$CUERPO_B" "$VACIO"
}
trap al_salir EXIT

# ============================================================
# 0. Que haya con que trabajar
# ============================================================
titulo "0. EL TERRENO ESTA: backend, tabla, catalogos, plantilla e indice"

codigo=$(pedir "/productos?limite=1")
if [ "$codigo" != "200" ]; then
    echo "  FALLA el backend no contesta en $API (HTTP $codigo)"
    echo "        Levantalo con  .\\arrancar.ps1"
    exit 1
fi
OK "el backend contesta en $API"

# Los umbrales y las ventanas, del propio servicio.
leer_constante() { sed -n "s/.*static readonly $1 = \([0-9][0-9]*\);.*/\1/p" "$SERVICIO" 2>/dev/null | head -1; }
UMBRAL_IP=$(leer_constante UMBRAL_FALLOS_IP)
UMBRAL_CUENTA=$(leer_constante UMBRAL_FALLOS_CUENTA)
UMBRAL_MULTI=$(leer_constante UMBRAL_MULTICUENTA)
VENTANA_IP=$(leer_constante VENTANA_FALLOS_IP_SEGUNDOS)
VENTANA_CUENTA=$(leer_constante VENTANA_FALLOS_CUENTA_SEGUNDOS)
VENTANA_MULTI=$(leer_constante VENTANA_MULTICUENTA_SEGUNDOS)
if [ -n "$UMBRAL_IP" ] && [ -n "$UMBRAL_CUENTA" ] && [ -n "$UMBRAL_MULTI" ] \
   && [ -n "$VENTANA_IP" ] && [ -n "$VENTANA_CUENTA" ] && [ -n "$VENTANA_MULTI" ]; then
    OK "umbrales leidos del servicio: ip $UMBRAL_IP/${VENTANA_IP}s, cuenta $UMBRAL_CUENTA/${VENTANA_CUENTA}s, multi $UMBRAL_MULTI/${VENTANA_MULTI}s"
else
    FALLA "no se pudieron leer los umbrales de $SERVICIO"
    echo "        Si el servicio cambio de nombre o de forma, este arnes tiene que"
    echo "        aprender a leerlo antes de medir nada."
    exit 1
fi

EXISTE_TABLA=$(sql "SELECT to_regclass('public.senal_fraude') IS NOT NULL")
if [ "$EXISTE_TABLA" = "t" ]; then
    OK "existe la tabla senal_fraude"
else
    FALLA "no existe la tabla senal_fraude"
    echo "        Corre  .\\arrancar.ps1  que aplica migrations/031_senales_fraude.sql"
fi

# Los tipos de login que el backend registra salen de su modelo, no se copian
# aqui: el tipo TipoAlertaFraude de backend/src/models/alerta-fraude.ts. Desde el
# refactor de fraude registrarAlertaFraude busca cada uno por su NOMBRE en
# tipo_senal_fraude; si falta uno, ese registro falla. Antes se comparaban ids
# fijos (ID_TIPO_ALERTA_FRAUDE_*), que ya no existen.
TIPOS=$(sql "SELECT string_agg(t.tipo_senal_fraude_nombre, ' ' ORDER BY t.tipo_senal_fraude_nombre COLLATE \"C\")
               FROM tipo_senal_fraude t WHERE $DE_LOGIN")
ESPERADOS=$(sed -n '/export type TipoAlertaFraude/,/;/p' "$RAIZ/backend/src/models/alerta-fraude.ts" \
    | grep -oE "'[a-z_]+'" | tr -d "'" | LC_ALL=C sort | paste -sd' ')
if [ -z "$ESPERADOS" ]; then
    FALLA "no se pudieron leer los tipos de alerta de backend/src/models/alerta-fraude.ts"
fi
if [ -n "$ESPERADOS" ] && [ "$TIPOS" = "$ESPERADOS" ]; then
    OK "tipo_senal_fraude tiene los $(echo "$ESPERADOS" | wc -w) tipos de login del backend"
else
    FALLA "tipo_senal_fraude tiene de login '$TIPOS', el backend registra '$ESPERADOS'"
fi
# Los estados si siguen con id fijo en el backend (ID_ESTADO_ALERTA_FRAUDE_*).
ESTADOS=$(sql "SELECT string_agg(id_estado_alerta_fraude||'='||estado_alerta_fraude_nombre, ' ' ORDER BY id_estado_alerta_fraude) FROM estado_alerta_fraude")
# La 026 (casos de fraude) agrega `confirmada` como cuarta fila. Las alertas de login
# solo usan las tres primeras, que son las que el backend fija por id.
if [ "$ESTADOS" = "1=pendiente 2=revisada 3=descartada" ] || [ "$ESTADOS" = "1=pendiente 2=revisada 3=descartada 4=confirmada" ]; then
    OK "estado_alerta_fraude tiene las filas con los ids del backend ($ESTADOS)"
else
    FALLA "estado_alerta_fraude dice '$ESTADOS', se esperaba 1=pendiente 2=revisada 3=descartada, y 4=confirmada desde la 026"
fi

CODIGO_PLANTILLA=$(curl -s --max-time 10 -o "$CUERPO" -w '%{http_code}' "$ES/_index_template/$PLANTILLA_EVENTOS" 2>/dev/null)
if [ "$CODIGO_PLANTILLA" = "200" ]; then
    OK "existe la plantilla $PLANTILLA_EVENTOS en Elasticsearch"
else
    FALLA "no existe la plantilla $PLANTILLA_EVENTOS (HTTP $CODIGO_PLANTILLA)"
    echo "        Sin ella el indice nace con mapeo dinamico y la ip queda como texto."
    echo "        La pone  .\\arrancar.ps1  desde elastic/002_eventos_autenticacion.json"
fi

# El tipo de ip importa por la parte 6: con ip de texto, 127.0.0.1 y
# ::ffff:127.0.0.1 son dos cubos distintos y no se puede buscar por rango.
tipo_ip_del_indice() {
    curl -s --max-time 10 "$ES/$INDICE_EVENTOS/_mapping/field/ip" 2>/dev/null | python -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: print('sin-respuesta'); sys.exit()
if 'error' in d: print('no-existe'); sys.exit()
for idx in d.values():
    m = idx.get('mappings', {}).get('ip', {}).get('mapping', {}).get('ip', {})
    print(m.get('type', 'sin-campo')); break
else: print('sin-campo')"
}
TIPO_IP=$(tipo_ip_del_indice)
if [ "$TIPO_IP" = "ip" ]; then
    OK "el campo ip de $INDICE_EVENTOS es de tipo ip"
elif [ "$TIPO_IP" = "no-existe" ] && [ "$CODIGO_PLANTILLA" = "200" ]; then
    echo "  (el indice $INDICE_EVENTOS no existe todavia; lo creara el worker con la"
    echo "   plantilla en el primer evento, y la parte 1 vuelve a mirar el tipo)"
else
    FALLA "el campo ip de $INDICE_EVENTOS es '$TIPO_IP', no ip"
    echo "        El indice nacio sin la plantilla. .\\arrancar.ps1 lo rehace."
fi

if [ "$fallo" -gt 0 ]; then
    echo
    echo "  El terreno no esta como lo pide el backend. Lo de abajo mediria sobre"
    echo "  otra cosa, asi que se para aqui."
    exit 1
fi

# Lo que dejo anotado una corrida que murio sin trap. Va antes del max id: asi
# sus filas no cuentan como "de antes de empezar" en los avisos del final.
if [ -f "$ANOTADAS" ]; then
    _anotadas=$(grep -c . "$ANOTADAS")
    _borradas=$(borrar_anotadas)
    if [ -n "$_borradas" ]; then
        echo "  (una corrida anterior murio sin limpiar y dejo $_anotadas senal(es) anotada(s):"
        echo "   se borraron $_borradas; si falta alguna, cambio despues de anotarse y se queda)"
        rm -f "$ANOTADAS"
    else
        echo "  (hay senales anotadas de una corrida que murio y la base no dejo borrarlas;"
        echo "   $ANOTADAS se queda y se vuelve a intentar en la limpieza)"
    fi
fi

# INICIO sale del reloj de PostgreSQL: con el se sabe al final que senales de
# antes detecto la corrida.
INICIO=$(ahora_pg)
MAX_ANTES=$(sql "SELECT coalesce(max(id_senal_fraude), 0) FROM senal_fraude")
MAX_IP_ANTES=$(sql "SELECT coalesce(max(id_direccion_ip), 0) FROM direccion_ip")
echo "  (max id de senal_fraude antes de empezar: $MAX_ANTES; marca de esta corrida: $PREFIJO)"

SOBRAS=$(mongo_num 'db.eventos_autenticacion.countDocuments({identificador_intentado: {$regex: /'"$RE_MARCA"'/}})')
if [ "${SOBRAS:-0}" != "0" ]; then
    echo "  (hay $SOBRAS evento(s) de una corrida anterior que no limpio; se van al final)"
fi

# ============================================================
# 1. El evento
# ============================================================
titulo "1. UN LOGIN FALLIDO DEJA SU EVENTO, Y NO DICE POR QUE FALLO"

ID_EVENTO="${PREFIJO}evento@mesh.test"

# Estos dos fallos van sin borrar antes los contadores, porque la ip todavia no
# se sabe: sale del evento que dejan. Si otro trafico ya tenia los contadores de
# la ip por encima del umbral, estos dos cruzarian y sumarian una deteccion a su
# senal de ip. No cambia lo que mide esta parte, y las partes 3 y 4 cuentan
# desde lo que haya cuando empiezan.

T_LOGIN=$(ms)
C_INVENTADO=$(intentar_login "$ID_EVENTO" "$CLAVE_MALA")
cp "$CUERPO" "$CUERPO_B"
C_REAL=$(intentar_login "$COMPRADOR_USUARIO" "$CLAVE_MALA")

if [ "$C_INVENTADO" = "401" ]; then
    OK "un identificador que no existe contesta 401"
else
    FALLA "un identificador que no existe contesta $C_INVENTADO, se esperaba 401"
fi

# El cuerpo entero, no solo el mensaje. Si el backend dijera "no existe" en un
# caso y "contrasena mala" en el otro, esta ruta serviria para averiguar que
# correos tienen cuenta en la tienda. El motivo fino va solo al evento.
MENSAJE=$(campo mensaje < "$CUERPO_B")
if [ "$C_REAL" = "401" ] && cmp -s "$CUERPO" "$CUERPO_B"; then
    OK "y el mismo 401, byte por byte, que una cuenta real con contrasena mala ('$MENSAJE')"
else
    FALLA "el 401 de la cuenta inexistente no es igual al de contrasena mala"
    echo "        inexistente ($C_INVENTADO): $(head -c 200 "$CUERPO_B")"
    echo "        real        ($C_REAL): $(head -c 200 "$CUERPO")"
fi
if grep -qi 'inexistente\|no existe\|usuario_' "$CUERPO_B"; then
    FALLA "la respuesta deja ver el motivo del fallo: $(head -c 200 "$CUERPO_B")"
fi

# El evento lo escribe LogService sin await, asi que se espera a que aparezca.
leer_evento() {
    EVENTO=$(mongo 'const e = db.eventos_autenticacion.findOne({identificador_intentado: "'"$ID_EVENTO"'"});
        if (e) print([e._id.toString(), e.tipo, e.resultado, e.motivo, e.ip, e.user_agent,
                      e.pendiente_elastic === true ? "pendiente" : "sincronizado"].join("|"))')
    [ -n "$EVENTO" ]
}
EVENTO=""
if esperar 8 leer_evento; then
    OK "el evento esta en MongoDB, eventos_autenticacion (${ESPERO} s)"
else
    FALLA "no aparecio ningun evento con identificador $ID_EVENTO en MongoDB"
    echo "        Sin el no hay ip que leer, y todo lo de abajo depende de ella."
    exit 1
fi

ID_MONGO=$(echo "$EVENTO" | cut -d'|' -f1)
E_TIPO=$(echo "$EVENTO" | cut -d'|' -f2)
E_RESULTADO=$(echo "$EVENTO" | cut -d'|' -f3)
E_MOTIVO=$(echo "$EVENTO" | cut -d'|' -f4)
IP=$(echo "$EVENTO" | cut -d'|' -f5)
E_UA=$(echo "$EVENTO" | cut -d'|' -f6)

if [ "$E_TIPO" = "login" ] && [ "$E_RESULTADO" = "fallo" ] && [ "$E_MOTIVO" = "usuario_inexistente" ]; then
    OK "con tipo login, resultado fallo y motivo usuario_inexistente"
else
    FALLA "el evento dice tipo '$E_TIPO', resultado '$E_RESULTADO', motivo '$E_MOTIVO'"
fi
if [ -n "$IP" ] && [ "$IP" != "null" ]; then
    OK "con la ip tal como la vio el backend (= $IP), que es la clave de los contadores"
else
    FALLA "el evento no trae ip, y sin ella no hay contadores de ip que medir"
    exit 1
fi
if [ "$E_UA" = "$UA" ]; then
    OK "y con el user-agent que se mando (= $E_UA)"
else
    FALLA "el user-agent guardado es '$E_UA', se mando '$UA'"
fi

# El worker corre cada 5 s. Se da un tope de 20: cuatro vueltas.
en_elastic() { [ "$(curl -s --max-time 5 -o "$VACIO" -w '%{http_code}' "$ES/$INDICE_EVENTOS/_doc/$ID_MONGO" 2>/dev/null)" = "200" ]; }
if esperar 20 en_elastic; then
    DESDE_LOGIN=$(( ($(ms) - T_LOGIN) / 1000 ))
    OK "esta en Elasticsearch con el mismo _id ($ID_MONGO), a ~${DESDE_LOGIN} s del login"
    DOC=$(curl -s --max-time 5 "$ES/$INDICE_EVENTOS/_doc/$ID_MONGO")
    DOC_IDENT=$(printf '%s' "$DOC" | campo _source.identificador_intentado)
    DOC_IP=$(printf '%s' "$DOC" | campo _source.ip)
    if [ "$DOC_IDENT" = "$ID_EVENTO" ] && [ "$DOC_IP" = "$IP" ]; then
        OK "y el documento trae el mismo identificador y la misma ip"
    else
        FALLA "el documento dice identificador '$DOC_IDENT' e ip '$DOC_IP'"
    fi
else
    FALLA "el evento $ID_MONGO no llego a Elasticsearch en 20 s"
    echo "        Mira el log del backend: EventosAutenticacionSyncService."
fi

# Y en Mongo perdio la bandera. El $unset va justo despues del index, asi que
# puede tardar un instante mas que el documento.
sin_bandera() { leer_evento && [ "$(echo "$EVENTO" | cut -d'|' -f7)" = "sincronizado" ]; }
if esperar 6 sin_bandera; then
    OK "y en MongoDB ya no tiene pendiente_elastic"
else
    FALLA "el evento sigue con pendiente_elastic en MongoDB"
fi

TIPO_IP=$(tipo_ip_del_indice)
if [ "$TIPO_IP" = "ip" ]; then
    OK "el indice que lo recibio tiene ip de tipo ip"
else
    FALLA "el indice que lo recibio tiene ip de tipo '$TIPO_IP'"
fi

# ============================================================
# 2. fuerza_bruta_cuenta
# ============================================================
titulo "2. FUERZA BRUTA CONTRA UNA CUENTA: $UMBRAL_CUENTA fallos en ${VENTANA_CUENTA} s"

ID_CUENTA="${PREFIJO}cuenta@mesh.test"
CLAVE_CUENTA="mesh:fraude:fallos_cuenta:$ID_CUENTA"

reiniciar_contadores "$ID_CUENTA"
# Lo que habia antes de esta parte. La de cuenta empieza en 0 (su clave es de
# esta corrida); las dos de ip, en lo que traigan, para ver que no se movieron.
B_CUENTA=$(detecciones fuerza_bruta_cuenta "$ID_CUENTA")
B_IP=$(detecciones fuerza_bruta_ip "$IP")
B_MULTI=$(detecciones multi_cuenta_ip "$IP")

ANTES=$((UMBRAL_CUENTA - 1))
for _n in $(seq 1 "$ANTES"); do intentar_login "$ID_CUENTA" "$CLAVE_MALA" > /dev/null; done

# El punto de sincronia es el contador: cuando dice N, el intento N ya paso por
# el servicio. El segundo de despues es para darle tiempo al registro que NO
# deberia llegar; sin el, un umbral roto se veria verde por mirar demasiado
# pronto.
esperar 6 contador_llega "$CLAVE_CUENTA" "$ANTES"
VALOR=$(rcli GET "$CLAVE_CUENTA")
if [ "$VALOR" = "$ANTES" ]; then
    OK "el contador de Redis dice $VALOR tras $ANTES fallos"
else
    FALLA "el contador $CLAVE_CUENTA dice '$VALOR' tras $ANTES fallos"
fi
sleep 1
N=$(detecciones fuerza_bruta_cuenta "$ID_CUENTA")
if [ "$N" = "$B_CUENTA" ]; then
    OK "con $ANTES fallos NO hay senal (detecciones = $N)"
else
    FALLA "con $ANTES fallos la senal ya tiene $N deteccion(es): el umbral se cruza antes de tiempo"
fi

intentar_login "$ID_CUENTA" "$CLAVE_MALA" > /dev/null
if esperar 8 sube_al_menos fuerza_bruta_cuenta "$ID_CUENTA" "$B_CUENTA" 1; then
    FILA=$(fila_senal fuerza_bruta_cuenta "$ID_CUENTA")
    ALERTA_CUENTA=$(echo "$FILA" | cut -d'|' -f1)
    # Mas abajo el fallo de mas le suma otra deteccion a proposito y lo anotado
    # deja de coincidir. No importa: su clave lleva la marca y la borra la
    # limpieza.
    anotar_senal "$ALERTA_CUENTA"
    TOTAL=$(echo "$FILA" | cut -d'|' -f2)
    CUENTAS_FILA=$(echo "$FILA" | cut -d'|' -f3)
    if [ "$((TOTAL - B_CUENTA))" = "1" ] 2>/dev/null; then
        OK "el fallo $UMBRAL_CUENTA SI deja la senal $ALERTA_CUENTA, con 1 deteccion (${ESPERO} s)"
    else
        FALLA "tras el fallo $UMBRAL_CUENTA la senal tiene '$TOTAL' detecciones, se esperaba 1"
    fi
    FALLOS_DET=$(detalle "$FILA" fallos)
    if [ "$FALLOS_DET" = "$UMBRAL_CUENTA" ] && [ "$CUENTAS_FILA" = "0" ]; then
        OK "detalle.fallos = $FALLOS_DET y sin cuenta victima, porque el identificador no existe"
    else
        FALLA "detalle.fallos = '$FALLOS_DET' y $CUENTAS_FILA cuenta(s) victima"
    fi
else
    ALERTA_CUENTA=""
    FALLA "tras el fallo $UMBRAL_CUENTA no aparecio ninguna senal fuerza_bruta_cuenta en 8 s"
fi

# Un fallo mas: la misma senal, con 2 detecciones. Ya no importa si cae en otro
# minuto: la senal es una por (tipo, clave).
intentar_login "$ID_CUENTA" "$CLAVE_MALA" > /dev/null
if esperar 6 sube_al_menos fuerza_bruta_cuenta "$ID_CUENTA" "$B_CUENTA" 2; then
    FILAS=$(fila_senal fuerza_bruta_cuenta "$ID_CUENTA" | grep -c .)
    TOTAL=$(detecciones fuerza_bruta_cuenta "$ID_CUENTA")
    if [ "$FILAS" = "1" ] && [ "$((TOTAL - B_CUENTA))" = "2" ] 2>/dev/null; then
        OK "un fallo mas sube la senal a 2 detecciones y no abre otra fila"
    else
        FALLA "tras otro fallo hay $FILAS fila(s) con $TOTAL detecciones"
    fi
else
    FALLA "otro fallo no le sumo una deteccion a la senal"
    fila_senal fuerza_bruta_cuenta "$ID_CUENTA" | sed 's/^/          /'
fi

# Las otras dos senales no se disparan con esto: son independientes.
A_IP=$(( $(detecciones fuerza_bruta_ip "$IP") - B_IP ))
A_MULTI=$(( $(detecciones multi_cuenta_ip "$IP") - B_MULTI ))
OTRAS="$A_IP+$A_MULTI"
if [ "$OTRAS" = "0+0" ]; then
    OK "y ni fuerza_bruta_ip ni multi_cuenta_ip se enteraron ($((UMBRAL_CUENTA + 1)) fallos, 1 cuenta)"
else
    FALLA "$UMBRAL_CUENTA fallos contra una cuenta dispararon senales de ip (fuerza_bruta_ip+multi = $OTRAS)"
fi

# ============================================================
# 3. multi_cuenta_ip
# ============================================================
titulo "3. MUCHAS CUENTAS DESDE UNA IP: $UMBRAL_MULTI distintas en ${VENTANA_MULTI} s"

MULTI=()
for _n in $(seq 1 "$UMBRAL_MULTI"); do MULTI+=("${PREFIJO}multi${_n}@mesh.test"); done
CLAVE_MULTI="mesh:fraude:cuentas_ip:$IP"

reiniciar_contadores "${MULTI[@]}"
B_MULTI=$(detecciones multi_cuenta_ip "$IP")

ANTES=$((UMBRAL_MULTI - 1))
for _n in $(seq 0 $((ANTES - 1))); do intentar_login "${MULTI[$_n]}" "$CLAVE_MALA" > /dev/null; done

esperar 6 conjunto_llega "$CLAVE_MULTI" "$ANTES"
VALOR=$(rcli SCARD "$CLAVE_MULTI")
if [ "$VALOR" = "$ANTES" ]; then
    OK "el conjunto de Redis tiene $VALOR identificadores tras $ANTES cuentas"
else
    FALLA "el conjunto $CLAVE_MULTI tiene '$VALOR' identificadores tras $ANTES cuentas"
    echo "        Si son mas, alguien mas estaba entrando al backend: esta parte"
    echo "        no midio lo suyo. Vuelve a correrla sola."
fi
sleep 1
N=$(detecciones multi_cuenta_ip "$IP")
if [ "$N" = "$B_MULTI" ]; then
    OK "con $ANTES cuentas distintas la senal multi_cuenta_ip no suma (detecciones = $N)"
else
    FALLA "con $ANTES cuentas distintas la senal multi_cuenta_ip ya sumo $((N - B_MULTI))"
fi

intentar_login "${MULTI[$ANTES]}" "$CLAVE_MALA" > /dev/null
if esperar 8 sube_al_menos multi_cuenta_ip "$IP" "$B_MULTI" 1; then
    FILA=$(fila_senal multi_cuenta_ip "$IP")
    ALERTA_MULTI=$(echo "$FILA" | cut -d'|' -f1)
    PROPIA_MULTI=""
    if senal_propia "$ALERTA_MULTI" multi_cuenta_ip; then
        anotar_senal "$ALERTA_MULTI"
        PROPIA_MULTI="$ALERTA_MULTI"
    fi
    TOTAL=$(echo "$FILA" | cut -d'|' -f2)
    if [ "$((TOTAL - B_MULTI))" = "1" ] 2>/dev/null; then
        OK "la cuenta $UMBRAL_MULTI SI le suma 1 deteccion a la senal $ALERTA_MULTI, clave $IP (${ESPERO} s)"
    else
        FALLA "la senal multi_cuenta_ip subio de $B_MULTI a '$TOTAL', se esperaba 1 mas"
    fi
    # Los identificadores del detalle son la evidencia que va a leer el admin.
    # El detalle es el de la ultima deteccion, la de esta prueba.
    FALTAN=$(printf '%s' "$FILA" | cut -d'|' -f4- | python -c "
import sys, json
d = json.load(sys.stdin)
vistos = set(d.get('identificadores', []))
print(' '.join(i for i in sys.argv[1:] if i not in vistos))" "${MULTI[@]}")
    DISTINTAS=$(detalle "$FILA" cuentas_distintas)
    if [ -z "$FALTAN" ] && [ "$DISTINTAS" = "$UMBRAL_MULTI" ]; then
        OK "el detalle trae cuentas_distintas = $DISTINTAS y los $UMBRAL_MULTI identificadores probados"
    else
        FALLA "el detalle dice cuentas_distintas '$DISTINTAS' y le faltan: $FALTAN"
    fi
else
    ALERTA_MULTI=""; PROPIA_MULTI=""
    FALLA "la cuenta $UMBRAL_MULTI no le sumo ninguna deteccion a multi_cuenta_ip en 8 s"
fi

# ============================================================
# 4. fuerza_bruta_ip
# ============================================================
titulo "4. FUERZA BRUTA DESDE UNA IP: $UMBRAL_IP fallos en ${VENTANA_IP} s"

# Para que salte SOLO la de ip, los fallos se reparten entre pocos
# identificadores: ninguno puede llegar al umbral de cuenta, y no pueden ser
# tantos como el umbral de multi_cuenta. Con 8, 5 y 4 salen 2 identificadores
# de 4 fallos cada uno. Se calcula con los umbrales leidos, no a mano.
K=$(( (UMBRAL_IP + UMBRAL_CUENTA - 2) / (UMBRAL_CUENTA - 1) ))
if [ "$K" -ge "$UMBRAL_MULTI" ]; then
    FALLA "con estos umbrales no se puede disparar fuerza_bruta_ip sola ($K identificadores)"
    ALERTA_IP=""
else
    VARIOS=()
    for _n in $(seq 1 "$K"); do VARIOS+=("${PREFIJO}ip${_n}@mesh.test"); done
    CLAVE_IP="mesh:fraude:fallos_ip:$IP"

    reiniciar_contadores "${VARIOS[@]}"
    B_IP=$(detecciones fuerza_bruta_ip "$IP")
    B_MULTI=$(detecciones multi_cuenta_ip "$IP")
    B_CUENTAS=""
    for _i in "${VARIOS[@]}"; do B_CUENTAS="$B_CUENTAS $(detecciones fuerza_bruta_cuenta "$_i")"; done

    ANTES=$((UMBRAL_IP - 1))
    for _n in $(seq 0 $((ANTES - 1))); do intentar_login "${VARIOS[$((_n % K))]}" "$CLAVE_MALA" > /dev/null; done

    esperar 6 contador_llega "$CLAVE_IP" "$ANTES"
    VALOR=$(rcli GET "$CLAVE_IP")
    if [ "$VALOR" = "$ANTES" ]; then
        OK "el contador de Redis dice $VALOR tras $ANTES fallos, repartidos en $K identificadores"
    else
        FALLA "el contador $CLAVE_IP dice '$VALOR' tras $ANTES fallos"
        echo "        Si dice mas, alguien mas estaba fallando logins contra el backend."
    fi
    sleep 1
    N=$(detecciones fuerza_bruta_ip "$IP")
    if [ "$N" = "$B_IP" ]; then
        OK "con $ANTES fallos la senal fuerza_bruta_ip no suma (detecciones = $N)"
    else
        FALLA "con $ANTES fallos la senal fuerza_bruta_ip ya sumo $((N - B_IP))"
    fi

    intentar_login "${VARIOS[$((ANTES % K))]}" "$CLAVE_MALA" > /dev/null
    if esperar 8 sube_al_menos fuerza_bruta_ip "$IP" "$B_IP" 1; then
        FILA=$(fila_senal fuerza_bruta_ip "$IP")
        ALERTA_IP=$(echo "$FILA" | cut -d'|' -f1)
        PROPIA_IP=""
        if senal_propia "$ALERTA_IP" fuerza_bruta_ip; then
            anotar_senal "$ALERTA_IP"
            PROPIA_IP="$ALERTA_IP"
        fi
        TOTAL=$(echo "$FILA" | cut -d'|' -f2)
        FALLOS_DET=$(detalle "$FILA" fallos)
        if [ "$((TOTAL - B_IP))" = "1" ] 2>/dev/null && [ "$FALLOS_DET" = "$UMBRAL_IP" ]; then
            OK "el fallo $UMBRAL_IP SI le suma 1 deteccion a la senal $ALERTA_IP, clave $IP, detalle.fallos $FALLOS_DET (${ESPERO} s)"
        else
            FALLA "la senal fuerza_bruta_ip subio de $B_IP a '$TOTAL' y detalle.fallos es '$FALLOS_DET'"
        fi
    else
        ALERTA_IP=""; PROPIA_IP=""
        FALLA "el fallo $UMBRAL_IP no le sumo ninguna deteccion a fuerza_bruta_ip en 8 s"
    fi

    # Los :-x no sobran: si una consulta vuelve vacia, una resta sobre nada es
    # un error de sintaxis de bash y no un cero, y la comprobacion tiene que
    # fallar en vez de romper el arnes.
    _m=$(detecciones multi_cuenta_ip "$IP")
    CRUZADAS="$(( ${_m:-0} - B_MULTI ))"
    set -- $B_CUENTAS
    for _i in "${VARIOS[@]}"; do
        _a=$(detecciones fuerza_bruta_cuenta "$_i")
        CRUZADAS="$CRUZADAS+$(( ${_a:-0} - ${1:-0} ))"
        shift
    done
    if [ -z "$(printf '%s' "$CRUZADAS" | tr -d '0+')" ]; then
        OK "y no disparo ni fuerza_bruta_cuenta ni multi_cuenta_ip"
    else
        FALLA "el reparto disparo las otras senales (multi+cuentas = $CRUZADAS)"
    fi
fi

# ============================================================
# 5. La ruta del admin
# ============================================================
titulo "5. GET /admin/fraude/alertas-login"

# Los logins de esta parte SI entran, y un login que entra tambien suma su
# identificador al conjunto de multi_cuenta_ip. Con los de la parte 4 dentro,
# el admin y el comprador lo llevarian al umbral y naceria una alerta que no
# es de nadie. Se borra antes.
rcli DEL "mesh:fraude:fallos_ip:$IP" "mesh:fraude:cuentas_ip:$IP" > /dev/null

C=$(intentar_login "$ADMIN_USUARIO" "$ADMIN_CLAVE" "$TARRO_ADMIN")
if [ "$C" = "200" ] && [ -s "$TARRO_ADMIN" ]; then
    OK "sesion de admin iniciada"
else
    FALLA "no se pudo iniciar sesion como admin (HTTP $C)"
fi

# Las tres senales que la prueba hizo saltar. Un "-" es una que no salto. El id
# de la ruta (id_alerta_fraude) es el de la senal desde el refactor de fraude.
MIAS="${ALERTA_CUENTA:--},${ALERTA_MULTI:--},${ALERTA_IP:--}"

# Las de esas que estan en un estado, segun PostgreSQL. Las dos de ip pueden
# venir de antes y estar revisadas o descartadas: la prueba les suma una
# deteccion, pero solo las reabre si trae evidencia nueva (ver
# registrar-alerta-fraude.ts). Por eso los filtros se comparan con lo que dice
# la base y no con "pendiente" a secas.
#   $1 estado   $2 "si" las que estan en ese estado, "no" las que no
mias_en() {
    _ids=$(echo "$MIAS" | tr ',' '\n' | grep -E '^[0-9]+$' | paste -sd,)
    [ -n "$_ids" ] || return 0
    _op="="; [ "$2" = "no" ] && _op="<>"
    sql "SELECT string_agg(s.id_senal_fraude::text, ',' ORDER BY s.id_senal_fraude)
           FROM senal_fraude s JOIN estado_alerta_fraude e USING (id_estado_alerta_fraude)
          WHERE s.id_senal_fraude IN ($_ids) AND e.estado_alerta_fraude_nombre $_op '$1'"
}

# Revisa una respuesta de la ruta.
#   $1 archivo   $2 ids que tienen que estar (coma; "-" es una que no salto)
#   $3 estado que deben tener todas, o vacio   $4 "no" si los ids NO tienen que
#   estar
revisar_lista() {
    python - "$1" "$2" "$3" "${4:-si}" <<'PY'
import sys, json, math
archivo, ids, estado, deben_estar = sys.argv[1:5]
try:
    d = json.load(open(archivo, encoding='utf-8'))['payload']
except Exception as e:
    print('respuesta ilegible'); sys.exit()
lista = d['alertas']
por_id = {a['id_alerta_fraude']: a for a in lista}
quiero = [i for i in ids.split(',') if i and i != '-']
malas = []
# Si alguna senal no llego a saltar, no hay nada que buscar, y "estan todas" o
# "no esta ninguna" saldrian verdes sobre una lista vacia. Medido con el
# indice unico borrado: las tres de abajo daban OK con "0 de 0".
vacias = ids.split(',').count('-')
if vacias:
    malas.append('%d de las senales de esta prueba no saltaron, no hay que buscar' % vacias)
if deben_estar == 'si':
    malas += ['falta la %s' % i for i in quiero if i not in por_id]
else:
    malas += ['sobra la %s' % i for i in quiero if i in por_id]
if estado:
    malas += ['la %s es %s' % (a['id_alerta_fraude'], a['estado']) for a in lista if a['estado'] != estado]
paginas = 0 if d['total_alertas'] == 0 else math.ceil(d['total_alertas'] / d['limite'])
if d['total_paginas'] != paginas:
    malas.append('total_paginas %s con total %s y limite %s' % (d['total_paginas'], d['total_alertas'], d['limite']))
print('; '.join(malas) if malas else 'bien %d de %d' % (len(lista), d['total_alertas']))
PY
}

C=$(pedir "/admin/fraude/alertas-login?limite=100" "$TARRO_ADMIN")
R=$(revisar_lista "$CUERPO" "$MIAS" "")
if [ "$C" = "200" ] && [ "${R#bien}" != "$R" ]; then
    OK "como admin trae las 3 senales de esta prueba ($R)"
else
    FALLA "como admin: HTTP $C, $R"
fi

# Y cada una con su tipo y su clave, que es lo que el panel ensena.
TIPOS_API=$(python - "$CUERPO" "$ALERTA_CUENTA" "$ALERTA_MULTI" "$ALERTA_IP" <<'PY'
import sys, json
try: lista = json.load(open(sys.argv[1], encoding='utf-8'))['payload']['alertas']
except Exception: print(''); sys.exit()
por_id = {a['id_alerta_fraude']: a for a in lista}
fuera = []
for i in sys.argv[2:]:
    a = por_id.get(i)
    fuera.append('%s=%s' % (a['tipo_alerta'], a['clave']) if a else '-')
print(' '.join(fuera))
PY
)
ESPERADO_API="fuerza_bruta_cuenta=$ID_CUENTA multi_cuenta_ip=$IP fuerza_bruta_ip=$IP"
if [ "$TIPOS_API" = "$ESPERADO_API" ]; then
    OK "con su tipo y su clave (identificador para la de cuenta, ip para las otras dos)"
else
    FALLA "tipos y claves: '$TIPOS_API', se esperaba '$ESPERADO_API'"
fi

# La ruta lista de a 100. Las de esta prueba son las mas recientes, pero una
# senal de ip vieja se ordena por su fecha de revision y puede quedar fuera de
# la primera pagina; con limite 100 y una base de desarrollo no pasa.
C=$(pedir "/admin/fraude/alertas-login?estado=pendiente&limite=100" "$TARRO_ADMIN")
R=$(revisar_lista "$CUERPO" "$(mias_en pendiente si)" "pendiente")
if [ "$C" = "200" ] && [ "${R#bien}" != "$R" ]; then
    OK "estado=pendiente trae las de esta prueba que estan pendientes, y todo lo que trae lo esta ($R)"
else
    FALLA "estado=pendiente: HTTP $C, $R"
fi

# El otro lado del filtro. Sin esto, un filtro que no filtra nada pasaria la
# comprobacion de arriba.
C=$(pedir "/admin/fraude/alertas-login?estado=revisada&limite=100" "$TARRO_ADMIN")
R=$(revisar_lista "$CUERPO" "$(mias_en revisada no)" "revisada" "no")
if [ "$C" = "200" ] && [ "${R#bien}" != "$R" ]; then
    OK "estado=revisada NO trae las que no estan revisadas ($R)"
else
    FALLA "estado=revisada: HTTP $C, $R"
fi

C=$(pedir "/admin/fraude/alertas-login?estado=basura" "$TARRO_ADMIN")
M=$(campo mensaje < "$CUERPO")
if [ "$C" = "400" ]; then
    OK "estado=basura da 400 ('$M')"
else
    FALLA "estado=basura da $C, se esperaba 400"
fi

for q in "limite=0" "limite=-1" "limite=abc" "pagina=0" "pagina=abc"; do
    C=$(pedir "/admin/fraude/alertas-login?$q" "$TARRO_ADMIN")
    if [ "$C" = "400" ]; then
        OK "$q da 400 ('$(campo mensaje < "$CUERPO")')"
    else
        FALLA "$q da $C, se esperaba 400"
    fi
done

# Un limite de mas NO es un 400: validarLimite lo recorta al maximo. Medido el
# 2026-09-10, y se deja escrito para que nadie lo tome por un fallo.
C=$(pedir "/admin/fraude/alertas-login?limite=1000" "$TARRO_ADMIN")
L=$(campo payload.limite < "$CUERPO")
if [ "$C" = "200" ] && [ "$L" = "100" ]; then
    OK "limite=1000 no es error: contesta 200 y lo recorta a $L"
else
    FALLA "limite=1000 da HTTP $C con limite '$L', se medio 200 y 100"
fi

# Quien no es admin. El codigo se midio antes de escribirlo: 403 para una
# sesion que no es admin, 401 sin sesion. Y ademas se mira que el cuerpo no
# lleve ninguna de las alertas, que es lo que de verdad importa.
C=$(intentar_login "$COMPRADOR_USUARIO" "$COMPRADOR_CLAVE" "$TARRO_COMPRADOR")
if [ "$C" = "200" ]; then
    C=$(pedir "/admin/fraude/alertas-login" "$TARRO_COMPRADOR")
    if [ "$C" = "403" ] && ! grep -q "$PREFIJO" "$CUERPO"; then
        OK "como comprador NO las ve: 403 ('$(campo mensaje < "$CUERPO")')"
    else
        FALLA "como comprador contesta $C: $(head -c 200 "$CUERPO")"
    fi
else
    FALLA "no se pudo iniciar sesion como comprador (HTTP $C)"
fi

C=$(pedir "/admin/fraude/alertas-login")
if [ "$C" = "401" ] && ! grep -q "$PREFIJO" "$CUERPO"; then
    OK "sin sesion tampoco: 401 ('$(campo mensaje < "$CUERPO")')"
else
    FALLA "sin sesion contesta $C: $(head -c 200 "$CUERPO")"
fi

# ============================================================
# 6. La pregunta del profesor, contestada por Elasticsearch
# ============================================================
titulo "6. DESDE QUE IP SE PROBARON MUCHAS CUENTAS"

# Primero que esten todos. Si la agregacion corre con la mitad de los eventos
# todavia en la cola del worker, contaria de menos y no se sabria por que.
EN_MONGO=$(mongo_num 'db.eventos_autenticacion.countDocuments({identificador_intentado: {$regex: /'"$RE_CORRIDA"'/}})')
DISTINTOS_MONGO=$(mongo_num 'print(db.eventos_autenticacion.distinct("identificador_intentado", {identificador_intentado: {$regex: /'"$RE_CORRIDA"'/}}).length)')
cuenta_es_corrida() {
    curl -s --max-time 5 -H 'Content-Type: application/json' "$ES/$INDICE_EVENTOS/_count" \
        --data-binary '{"query":{"prefix":{"identificador_intentado":"'"$PREFIJO"'"}}}' 2>/dev/null | campo count
}
todos_en_es() { [ "$(cuenta_es_corrida)" = "$EN_MONGO" ]; }
if esperar 25 todos_en_es; then
    OK "los $EN_MONGO eventos de esta corrida estan en Elasticsearch (${ESPERO} s)"
else
    FALLA "en Elasticsearch hay $(cuenta_es_corrida) eventos de esta corrida y en MongoDB $EN_MONGO"
fi

# LA AGREGACION, la primera del repositorio. Se lee de arriba abajo:
#
#   query            se queda con los logins fallidos de la misma ventana que
#                    usa el contador de Redis (VENTANA_MULTICUENTA_SEGUNDOS).
#   terms ip         un cubo por ip. Como el campo es de tipo ip, 127.0.0.1 y
#                    ::ffff:127.0.0.1 caen en el MISMO cubo; con ip de texto
#                    serian dos y la cuenta se partiria.
#   cardinality      cuantos identificadores DISTINTOS hay en cada cubo. Va
#                    sobre .minusculas para que Admin@mesh.com y
#                    admin@mesh.com cuenten como una sola cuenta. Es un conteo
#                    aproximado, exacto en la practica por debajo de 3000.
#   bucket_selector  tira los cubos que no llegan al umbral. Lo que queda es la
#                    respuesta: las ip sospechosas, de la que mas cuentas probo
#                    a la que menos.
#
# Es la misma pregunta que contesta el contador de Redis en el login, pero
# hecha despues y sobre todo el historial: Redis avisa en el momento y olvida a
# los 5 minutos, Elasticsearch no olvida.
AGREGACION=$(cat <<JSON
{
  "size": 0,
  "query": {
    "bool": {
      "filter": [
        { "term":  { "tipo": "login" } },
        { "term":  { "resultado": "fallo" } },
        { "range": { "fecha": { "gte": "now-${VENTANA_MULTI}s" } } }
      ]
    }
  },
  "aggs": {
    "por_ip": {
      "terms": { "field": "ip", "size": 20, "order": { "cuentas_distintas": "desc" } },
      "aggs": {
        "cuentas_distintas": {
          "cardinality": { "field": "identificador_intentado.minusculas" }
        },
        "solo_las_sospechosas": {
          "bucket_selector": {
            "buckets_path": { "cuentas": "cuentas_distintas" },
            "script": "params.cuentas >= ${UMBRAL_MULTI}"
          }
        }
      }
    }
  }
}
JSON
)

curl -s --max-time 10 -H 'Content-Type: application/json' "$ES/$INDICE_EVENTOS/_search" \
    --data-binary "$AGREGACION" -o "$CUERPO" 2>/dev/null

# Los cubos, y si la ip de esta prueba esta entre ellos. La ip se compara
# normalizada por lo mismo que se explica arriba.
LECTURA=$(python - "$CUERPO" "$IP" "$UMBRAL_MULTI" <<'PY'
import sys, json, ipaddress
def norma(x):
    try:
        a = ipaddress.ip_address(x)
        return str(a.ipv4_mapped or a) if a.version == 6 else str(a)
    except Exception:
        return x
archivo, ip, umbral = sys.argv[1], norma(sys.argv[2]), int(sys.argv[3])
try:
    d = json.load(open(archivo, encoding='utf-8'))
    cubos = d['aggregations']['por_ip']['buckets']
except Exception:
    print('ERROR ' + open(archivo, encoding='utf-8').read()[:300]); sys.exit()
for c in cubos:
    print('      ip %-18s  %4d cuentas distintas  %5d intentos fallidos'
          % (c['key'], c['cuentas_distintas']['value'], c['doc_count']))
mia = [c for c in cubos if norma(c['key']) == ip]
print('ESTA %d' % mia[0]['cuentas_distintas']['value'] if mia and mia[0]['cuentas_distintas']['value'] >= umbral else 'NO')
PY
)
echo "  las ip con $UMBRAL_MULTI o mas cuentas distintas en los ultimos ${VENTANA_MULTI} s:"
echo "$LECTURA" | grep -v '^ESTA\|^NO$'
VEREDICTO=$(echo "$LECTURA" | tail -1)
if [ "${VEREDICTO#ESTA }" != "$VEREDICTO" ]; then
    OK "la agregacion devuelve la ip $IP con ${VEREDICTO#ESTA } identificadores distintos (umbral $UMBRAL_MULTI)"
else
    FALLA "la agregacion no devuelve la ip $IP con $UMBRAL_MULTI o mas identificadores"
    echo "$LECTURA" | head -3 | sed 's/^/        /'
fi

# La misma agregacion recortada a los identificadores de esta corrida tiene que
# dar el numero EXACTO que dice MongoDB. Lo de arriba solo prueba "al menos";
# esto prueba que cuenta bien. Sin la ventana de tiempo: si el arnes fue lento
# y el evento de la parte 1 ya se salio de ella, la cuenta quedaria corta sin
# que nada este mal. La marca de la corrida ya aisla lo suyo.
EXACTA=$(printf '%s' "$AGREGACION" | python -c "
import sys, json
q = json.load(sys.stdin)
f = q['query']['bool']['filter']
q['query']['bool']['filter'] = [x for x in f if 'range' not in x]
q['query']['bool']['filter'].append({'prefix': {'identificador_intentado': sys.argv[1]}})
del q['aggs']['por_ip']['aggs']['solo_las_sospechosas']
print(json.dumps(q))" "$PREFIJO")
R=$(curl -s --max-time 10 -H 'Content-Type: application/json' "$ES/$INDICE_EVENTOS/_search" \
      --data-binary "$EXACTA" 2>/dev/null | python -c "
import sys, json
try:
    c = json.load(sys.stdin)['aggregations']['por_ip']['buckets']
    print('%d %d %d' % (len(c), c[0]['cuentas_distintas']['value'], c[0]['doc_count']) if c else '0 0 0')
except Exception: print('error')")
if [ "$R" = "1 $DISTINTOS_MONGO $EN_MONGO" ]; then
    OK "recortada a esta corrida da un cubo, $DISTINTOS_MONGO identificadores y $EN_MONGO intentos, lo mismo que MongoDB"
else
    FALLA "recortada a esta corrida da '$R' (cubos, distintos, intentos); MongoDB dice 1 $DISTINTOS_MONGO $EN_MONGO"
fi

# ============================================================
# LIMPIEZA
# ============================================================
titulo "LIMPIEZA"

limpiar

# Solo las propias: las de ip que ya existian se quedan a proposito.
QUEDAN_PG=$(sql "SELECT count(*) FROM senal_fraude
                  WHERE clave LIKE '${MARCA}%'
                     OR id_senal_fraude IN (${ALERTA_CUENTA:-0}, ${PROPIA_MULTI:-0}, ${PROPIA_IP:-0})")
if [ "$QUEDAN_PG" = "0" ]; then
    OK "no quedo ninguna senal de la prueba en senal_fraude (= $QUEDAN_PG)"
else
    FALLA "quedaron $QUEDAN_PG senal(es) de la prueba en senal_fraude"
fi
if [ ! -e "$ANOTADAS" ]; then
    OK "y no quedo el archivo de senales anotadas: la corrida siguiente no tiene nada que borrar"
else
    FALLA "quedo $ANOTADAS con $(grep -c . "$ANOTADAS") linea(s): la limpieza no pudo con lo anotado"
fi

QUEDAN_REDIS=$(rcli --scan --pattern "mesh:fraude:fallos_cuenta:${MARCA}*" | grep -c .)
if [ "$QUEDAN_REDIS" = "0" ]; then
    OK "no quedo ninguna clave de la prueba en Redis (= $QUEDAN_REDIS)"
else
    FALLA "quedaron $QUEDAN_REDIS clave(s) de la prueba en Redis"
fi

QUEDAN_MONGO=$(mongo_num 'db.eventos_autenticacion.countDocuments('"$FILTRO_MARCA_MONGO"')')
QUEDAN_ES=$(curl -s --max-time 5 -H 'Content-Type: application/json' "$ES/$INDICE_EVENTOS/_count" \
              --data-binary "$CONSULTA_MARCA_ES" 2>/dev/null | campo count)
if [ "$QUEDAN_MONGO" = "0" ] && [ "$QUEDAN_ES" = "0" ]; then
    OK "no quedo ningun evento de la prueba ni en MongoDB ni en Elasticsearch"
else
    FALLA "quedaron $QUEDAN_MONGO evento(s) en MongoDB y $QUEDAN_ES en Elasticsearch"
fi

SE_QUEDAN=$(mongo_num 'db.eventos_autenticacion.countDocuments({user_agent: "'"$UA"'", resultado: "exito"})')
TTL_REAL=$(rcli TTL "mesh:fraude:fallos_cuenta:$COMPRADOR_USUARIO")
echo "  Lo que se queda, a proposito:"
echo "    los logins que SI entraron (admin y comprador de la parte 5): son uso real."
echo "    Con user-agent $UA hay $SE_QUEDAN, contando todas las corridas."
if [ "${TTL_REAL:--2}" -gt 0 ] 2>/dev/null; then
    echo "    mesh:fraude:fallos_cuenta:$COMPRADOR_USUARIO, con el fallo de la parte 1:"
    echo "    se va sola en $TTL_REAL s. Es una cuenta real y su contador no es solo de la prueba."
fi

titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
if [ "$fallo" -gt 0 ]; then
    echo "  El fraude de login no esta haciendo lo que se dijo. La base quedo limpia igual."
    exit 1
fi
echo "  Un fallo deja su evento y llega a Elasticsearch, las tres senales saltan"
echo "  justo en su umbral y no antes, la ruta solo la ve el admin, y la"
echo "  agregacion encuentra la ip que tecleo muchos identificadores."
exit 0
