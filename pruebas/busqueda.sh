#!/usr/bin/env bash
# pruebas/busqueda.sh -- comprueba que el buscador de la Entrega 3 hace lo que
# se dijo que hace.
#
#   bash pruebas/busqueda.sh
#
# Corre CONTRA EL INDICE QUE HAYA, no lo reconstruye. Si algo sale mal, lo
# primero es correr `bash etl/cargar_busqueda.sh` y volver a probar.
#
# No escribe nada en ninguna base: son todas consultas.
#
# LAS DOS QUE IMPORTAN, y no son las de la difusa:
#
#   La parte 3 comprueba que estan los productos que viven SOLO en MongoDB. Es
#   la unica que se rompe si alguien reescribe el extractor contra PostgreSQL,
#   que es el error facil de cometer -- las otras cuatro bases se leen asi.
#   El sintoma sin esta prueba seria un producto que se vende y que el buscador
#   jura que no existe, sin ningun error.
#
#   La parte 4 comprueba que el rechazado NO esta. Y comprueba antes que si
#   existe en Mongo, porque una prueba de ausencia sobre algo que no existe en
#   ningun lado pasa siempre y no mide nada.

set -u

ES="${ES:-http://localhost:9200}"
# Con la seguridad de Elasticsearch encendida: mete el usuario en $ES (ver ahi).
. "$(dirname "$0")/../seguridad/url_elastic.sh"
INDICE="${INDICE:-mesh_productos}"
MONGO="${MONGO:-mesh-mongo}"

# El backend, que desde el 2026-09-04 es quien aplica el filtro de "solo lo
# activo". Ver la parte 4.
#
# La contrasena es la de la semilla, la misma que esta escrita en ARRANCAR.txt:
# esto corre contra la base local de desarrollo, no contra nada de nadie.
API="${API:-http://localhost:3000}"
ADMIN_USUARIO="${ADMIN_USUARIO:-admin@mesh.com}"
ADMIN_CLAVE="${ADMIN_CLAVE:-Admin123}"

# Los dos archivos de trabajo van con nombre RELATIVO, no en /tmp.
#
# Este script exporta MSYS_NO_PATHCONV=1 (lo necesitan las urls de
# Elasticsearch, que si no se convierten en rutas de Windows). El efecto
# colateral es que `curl.exe`, que es un binario de Windows, tampoco recibe
# convertidas las rutas de archivo: con `-c /tmp/algo` no escribe nada y no se
# queja. El login contestaba 200, el tarro de cookies quedaba vacio y la
# peticion siguiente iba sin sesion. Un nombre relativo lo entienden los dos
# mundos. Se borran al terminar.
GALLETAS="${GALLETAS:-.mesh-busqueda-cookies.txt}"
# Donde tirar un cuerpo que no interesa. Ver backend_vivo.
VACIO="${VACIO:-.mesh-busqueda-nada}"

limpiar() { rm -f "$GALLETAS" "$VACIO"; }
trap limpiar EXIT

export MSYS_NO_PATHCONV=1

ok=0; fallo=0; sin_medir=0

OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
# Lo que esta base no deja medir. No es un fallo, pero tampoco un OK.
SIN_MEDIR() { echo "  SIN MEDIR $1"; sin_medir=$((sin_medir+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# Los nombres que devuelve una busqueda, uno por linea.
nombres() {
    curl -s -X GET "$ES/$INDICE/_search" -H 'Content-Type: application/json' \
        --data-binary @- <<JS | python -c "
import sys, json
d = json.load(sys.stdin)
for h in d.get('hits', {}).get('hits', []):
    print(h['_source']['nombre'])
"
$1
JS
}

# Cuantos resultados dio, sin traerlos.
cuantos() {
    curl -s -X GET "$ES/$INDICE/_search" -H 'Content-Type: application/json' \
        --data-binary @- <<JS | python -c "
import sys, json
print(json.load(sys.stdin).get('hits', {}).get('total', {}).get('value', -1))
"
$1
JS
}

mongo_cuenta() {
    docker exec "$MONGO" sh -c "mongosh --quiet \
        -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" \
        --authenticationDatabase admin \"\$MONGO_INITDB_DATABASE\" \
        --eval '$1'" 2>/dev/null | tr -d '\r \n'
}

# Igual que mongo_texto pero con todas las lineas, para listas de ids.
mongo_lineas() {
    docker exec "$MONGO" sh -c "mongosh --quiet \
        -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" \
        --authenticationDatabase admin \"\$MONGO_INITDB_DATABASE\" \
        --eval '$1'" 2>/dev/null | tr -d '\r'
}

# Igual que mongo_cuenta pero para texto: NO se le quitan los espacios, que en
# el nombre de un producto son parte del dato ("Laptop Nimbo 13").
mongo_texto() {
    docker exec "$MONGO" sh -c "mongosh --quiet \
        -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" \
        --authenticationDatabase admin \"\$MONGO_INITDB_DATABASE\" \
        --eval '$1'" 2>/dev/null | tr -d '\r' | head -1
}

# ---------- el backend, para la parte 4 ----------
#
# Desde el cambio del 2026-09-04 el filtro de "solo lo activo" ya no vive en el
# indice sino en la ruta publica del backend, asi que esa regla SOLO se puede
# medir preguntandole al backend. Las partes 1, 2, 3 y 5 siguen midiendo contra
# Elasticsearch directo, que es donde viven las suyas.

# Se mira el CODIGO HTTP y no el codigo de salida de curl.
#
# `curl -s -o /dev/null` sale con 23 ("failed writing body") en el Git Bash de
# Windows aunque la peticion vaya perfecta, asi que preguntarle a `$?` daba
# siempre "el backend no responde" con el backend contestando 200. Medido.
backend_vivo() {
    _codigo=$(curl -s --max-time 4 -w '%{http_code}' -o "$VACIO" "$API/buscador" 2>/dev/null)
    [ "$_codigo" = "200" ]
}

# Los id_producto que devuelve una ruta del buscador, uno por linea.
#   $1  la ruta
#   $2  lo que se busca
#   $3  no vacio para mandar la cookie de sesion
busca_backend() {
    _galleta=''
    [ -n "$3" ] && _galleta="-b $GALLETAS"
    # shellcheck disable=SC2086
    curl -s --max-time 8 $_galleta \
        --get --data-urlencode "nombre=$2" --data 'limite=50' \
        "$API$1" 2>/dev/null | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
p = d.get('payload') or []
# La ruta publica devuelve {resultados, quisiste_decir} desde 3305cf3; la de
# admin sigue devolviendo la lista sola. Recorrer el objeto como lista daba sus
# llaves y ningun id.
if isinstance(p, dict):
    p = p.get('resultados') or []
for r in p:
    print(r.get('id_producto'))
"
}

# Deja la cookie de admin en \$GALLETAS. Devuelve distinto de 0 si no pudo.
#
# Aqui tambien va `-o "$VACIO"` y no `-o /dev/null`, y no es cosmetico: con
# /dev/null, curl en el Git Bash de Windows falla al escribir el cuerpo, ABORTA
# y NO llega a guardar el tarro de cookies. El login contestaba 200, la funcion
# decia que si, y la peticion siguiente iba sin sesion -- "No hay sesion
# activa" con un login que acababa de salir bien.
iniciar_sesion_admin() {
    rm -f "$GALLETAS"
    _codigo=$(curl -s -o "$VACIO" -w '%{http_code}' --max-time 8 -c "$GALLETAS" \
        -X POST "$API/usuario/login" -H 'Content-Type: application/json' \
        -d "{\"identificador\":\"$ADMIN_USUARIO\",\"contrasena\":\"$ADMIN_CLAVE\"}" 2>/dev/null)
    { [ "$_codigo" = "200" ] || [ "$_codigo" = "201" ]; } && [ -s "$GALLETAS" ]
}

# ============================================================
# 0. Que haya algo con que trabajar
# ============================================================
titulo "0. EL INDICE ESTA"

if ! curl -sf --max-time 10 "$ES" > /dev/null; then
    echo "  Elasticsearch no contesta en $ES_VER"
    echo "  Levantalo con:  docker compose up -d elasticsearch"
    exit 1
fi

EN_INDICE=$(curl -s "$ES/$INDICE/_count" | python -c "
import sys, json
try: print(json.load(sys.stdin).get('count', -1))
except Exception: print(-1)")

if [ "$EN_INDICE" -gt 0 ] 2>/dev/null; then
    OK "el indice $INDICE tiene documentos (= $EN_INDICE)"
else
    FALLA "el indice $INDICE esta vacio o no existe"
    echo "  Corre:  bash etl/cargar_busqueda.sh"
    exit 1
fi

# Contra el catalogo ENTERO, no contra los activos.
#
# Hasta el 2026-09-04 el indice guardaba solo lo activo y esta linea comparaba
# contra `countDocuments({estado:"activo"})`. Ahora guarda todos los estados --
# el filtro se mudo a la ruta publica del backend, ver la parte 4 -- asi que
# comparar contra los activos daba FALLA con el indice perfectamente al dia:
# 1105 contra 1104, y el que sobraba era justo el rechazado que ahora tiene que
# estar. Una prueba que se pone roja cuando el sistema hace lo correcto es peor
# que no tenerla, porque ensena a ignorar el rojo.
TODOS=$(mongo_cuenta 'db.productos.countDocuments({})')
if [ "$EN_INDICE" = "$TODOS" ]; then
    OK "cuadra con el catalogo entero de MongoDB (= $TODOS, en cualquier estado)"
else
    FALLA "el indice tiene $EN_INDICE y MongoDB tiene $TODOS productos"
    echo "        El indice guarda TODOS los estados desde el 2026-09-04."
    echo "        Si falta alguno, corre 'bash etl/cargar_busqueda.sh'."
fi

# ============================================================
# 1. La difusa, que es para lo que se trajo el motor
# ============================================================
titulo "1. ESCRIBIENDO MAL ENCUENTRA IGUAL"

SALEN=$(nombres '{"size":5,"query":{"match":{"nombre":{"query":"labtop","fuzziness":"AUTO"}}}}')
CUANTAS=$(echo "$SALEN" | grep -ci "laptop" || true)

if [ "$CUANTAS" -gt 0 ]; then
    OK "buscando 'labtop' salen $CUANTAS producto(s) con Laptop en el nombre"
    echo "$SALEN" | head -3 | sed 's/^/          /'
else
    FALLA "buscando 'labtop' no salio ninguna Laptop"
fi

# El negativo del mismo tiro: la difusa no puede traer CUALQUIER cosa. Si
# "labtop" devolviera medio catalogo, encontrar la laptop no probaria nada.
TOTAL_LABTOP=$(cuantos '{"size":0,"query":{"match":{"nombre":{"query":"labtop","fuzziness":"AUTO"}}}}')
if [ "$TOTAL_LABTOP" -gt 0 ] && [ "$TOTAL_LABTOP" -lt "$EN_INDICE" ] 2>/dev/null; then
    OK "y no devuelve el catalogo entero ($TOTAL_LABTOP de $EN_INDICE)"
else
    FALLA "'labtop' devolvio $TOTAL_LABTOP de $EN_INDICE: la difusa esta trayendo de mas"
fi

# ============================================================
# 2. Las tildes no importan
# ============================================================
titulo "2. CON TILDE ENCUENTRA LO QUE NO LA LLEVA"

# El catalogo escribe "Ambar" sin tilde. Quien busca lo escribe como se dice.
# Sin el asciifolding del analizador, esto no encuentra nada.
CON_TILDE=$(cuantos '{"size":0,"query":{"match":{"nombre":"ambár"}}}')
if [ "$CON_TILDE" -gt 0 ] 2>/dev/null; then
    OK "buscando 'ambár' con tilde encuentra 'Ambar' sin ella (= $CON_TILDE)"
else
    FALLA "buscando 'ambár' no encontro nada: el asciifolding no esta puesto"
fi

# ============================================================
# 3. LOS QUE SOLO VIVEN EN MONGO
# ============================================================
titulo "3. ESTAN LOS PRODUCTOS QUE NO TIENEN FILA EN POSTGRESQL"

# Esta es la parte que se rompe si alguien reescribe el extractor contra
# PostgreSQL. Se buscan en la base que haya, no por id fijo: hasta el
# 2026-10-08 eran el 103, el 104 y el 106 de la base de Meme, y en otra base
# (la de David, con el lote de 1000) esos ids son productos del lote que si
# tienen fila. Una base recien cargada no tiene ninguno, porque solo nacen al
# crear un producto desde el panel; entonces la parte se marca SIN MEDIR.
IDS_PG=$(docker exec mesh-postgres psql -U meme -d mesh -qtAc \
    "SELECT string_agg(id_producto::text, ',') FROM productos" 2>/dev/null | tr -d '\r ')
SOLO_MONGO=""
if [ -n "$IDS_PG" ]; then
    SOLO_MONGO=$(mongo_lineas "db.productos.find({_id:{\$nin:[$IDS_PG]},estado:\"activo\"},{nombre:1}).limit(3).forEach(function(d){print(d._id)})")
fi

if [ -z "$IDS_PG" ]; then
    SIN_MEDIR "no se pudo leer la lista de productos de PostgreSQL"
elif [ -z "$SOLO_MONGO" ]; then
    SIN_MEDIR "esta base no tiene productos activos que vivan solo en MongoDB (se crean desde el panel)"
fi

for ID in $SOLO_MONGO; do
    ESTA=$(curl -s -o /dev/null -w '%{http_code}' "$ES/$INDICE/_doc/$ID")
    if [ "$ESTA" = "200" ]; then
        OK "el $ID esta en el indice, y NO tiene fila en PostgreSQL"
    else
        FALLA "el $ID NO esta en el indice (HTTP $ESTA)"
        echo "        Se vende y el buscador diria que no existe."
        echo "        Mira si etl/extraer_busqueda.js dejo de leer de MongoDB."
    fi
done

# ============================================================
# 4. Lo rechazado se indexa, pero no se le ensena a un comprador
# ============================================================
titulo "4. UN PRODUCTO RECHAZADO NO LO VE UN COMPRADOR"

# ESTA PARTE CAMBIO DE REGLA, y por eso cambio de forma.
#
# Antes se comprobaba que el rechazado NO estuviera en el indice (404), porque
# el extractor filtraba `estado: activo` y lo rechazado no llegaba a entrar.
#
# Ahora el indice guarda TODOS los estados, a proposito: un admin necesita
# poder buscar justo lo que no circula, que es lo que va a revisar. El filtro
# se mudo al backend, donde `GET /buscador/productos` lo lleva FIJO en el
# codigo y `GET /buscador/productos/admin` no lo lleva pero exige rol de admin.
#
# Entonces la ausencia en el indice ya no prueba nada -- de hecho ahora seria
# un fallo. Lo que hay que medir es la regla de verdad: que el documento SI
# este, y que la RUTA PUBLICA no lo devuelva. Medir contra Elasticsearch a
# secas dejaria de medir la regla que protege al comprador.
#
# El rechazado se busca en la base que haya. Hasta el 2026-10-08 era el 105
# fijo, que solo es rechazado en la base de Meme; en otra base el 105 es un
# producto activo y la prueba daba tres FALLA que no eran del buscador. Sin
# ningun rechazado (una base recien cargada no tiene), la parte queda SIN
# MEDIR: se consigue proponiendo un producto como vendedor y rechazandolo
# desde el panel.
RECHAZADO=$(mongo_texto 'db.productos.find({estado:"rechazado"},{_id:1}).limit(1).forEach(function(d){print(d._id)})')

if [ -z "$RECHAZADO" ]; then
    SIN_MEDIR "esta base no tiene ningun producto rechazado (se consigue rechazando una propuesta desde el panel)"
else
    OK "el $RECHAZADO esta rechazado en MongoDB, asi que lo de abajo significa algo"

    NOMBRE_RECHAZADO=$(mongo_texto "db.productos.findOne({_id:$RECHAZADO},{nombre:1}).nombre")

    # 4.1 En el indice SI esta, y con su estado
    DOC_RECHAZADO=$(curl -s "$ES/$INDICE/_doc/$RECHAZADO")
    ESTADO_RECHAZADO=$(printf '%s' "$DOC_RECHAZADO" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('_source', {}).get('estado', '') if d.get('found') else 'no-esta')
except Exception:
    print('no-esta')
")

    if [ "$ESTADO_RECHAZADO" = "rechazado" ]; then
        OK "el $RECHAZADO esta en el indice con estado 'rechazado', que es lo que se pidio"
    elif [ "$ESTADO_RECHAZADO" = "no-esta" ]; then
        FALLA "el $RECHAZADO no esta en el indice"
        echo "        Con el cambio de 2026-09-04 tiene que estar: el filtro vive en el backend."
        echo "        Corre 'bash etl/cargar_busqueda.sh' -- si sigue faltando, mira si"
        echo "        etl/extraer_busqueda.js volvio a filtrar por estado."
    else
        FALLA "el $RECHAZADO esta en el indice pero con estado '$ESTADO_RECHAZADO', no 'rechazado'"
    fi

    # 4.2 Y la ruta PUBLICA del backend no lo devuelve. Esta es la que protege al
    #     comprador, y es la unica que sigue midiendo algo real.
    if [ -z "$NOMBRE_RECHAZADO" ]; then
        FALLA "no se pudo leer el nombre del $RECHAZADO en MongoDB: no hay con que buscarlo"
    elif ! backend_vivo; then
        echo "  (el backend no responde en $API, las partes 4.2 y 4.3 no se corrieron)"
        echo "        Levantalo con 'cd backend ; npm run start:dev' y vuelve a probar."
    else
        PUBLICA=$(busca_backend '/buscador/productos' "$NOMBRE_RECHAZADO" '')
        if printf '%s' "$PUBLICA" | grep -q "^$RECHAZADO\$"; then
            FALLA "la ruta publica devuelve el $RECHAZADO, que esta rechazado"
            echo "        Es el fallo que esta prueba existe para atrapar: un comprador"
            echo "        viendo algo que no circula. Mira el filter fijo de"
            echo "        backend/src/services/buscador/productos.service.ts"
        else
            OK "la ruta publica NO devuelve el $RECHAZADO buscando su propio nombre"
        fi

        # 4.3 El otro lado del filtro. Sin esto, la prueba de arriba pasaria
        #     tambien si la busqueda estuviera rota del todo y no devolviera nada:
        #     un negativo se prueba comprobando que el positivo SI ocurre.
        if iniciar_sesion_admin; then
            ADMIN=$(busca_backend '/buscador/productos/admin' "$NOMBRE_RECHAZADO" 'si')
            if printf '%s' "$ADMIN" | grep -q "^$RECHAZADO\$"; then
                OK "y la de admin SI lo devuelve, asi que lo de arriba es el filtro y no una busqueda rota"
            else
                FALLA "la ruta de admin tampoco devuelve el $RECHAZADO"
                echo "        Entonces lo de arriba no probo el filtro: probo que la"
                echo "        busqueda no encuentra ese producto por ningun lado."
            fi
        else
            echo "  (no se pudo iniciar sesion como admin, la parte 4.3 no se corrio)"
            echo "        Sin ella, la 4.2 no distingue 'filtrado' de 'no lo encuentra nadie'."
        fi
    fi
fi

# ============================================================
# 5. El buscador predictivo
# ============================================================
titulo "5. CONTESTA CON LA PALABRA A MEDIAS"

# search_as_you_type: se escribio "lap" y todavia no se termino la palabra.
A_MEDIAS=$(cuantos '{"size":0,"query":{"multi_match":{"query":"lap","type":"bool_prefix","fields":["nombre.escribiendo","nombre.escribiendo._2gram","nombre.escribiendo._3gram"]}}}')
if [ "$A_MEDIAS" -gt 0 ] 2>/dev/null; then
    OK "con 'lap' a medias ya devuelve $A_MEDIAS producto(s)"
else
    FALLA "con 'lap' no devolvio nada: el campo search_as_you_type no esta"
fi

# ============================================================
# 6. Una locura no deja la pagina vacia, y lo que trae lo elige Elasticsearch
# ============================================================
titulo "6. ASDFFFF TRAE PRODUCTOS, Y SALEN DE ELASTICSEARCH"

# Lo pidio el profesor (2026-10-19): buscar una locura tiene que traer por lo
# menos un producto relacionado. Desde el 2026-10-20 los elige Elasticsearch
# (sugeridos.service.ts, consultaSugeridos); el backend por fuera (vectores,
# lo mas vendido) queda para cuando Elasticsearch no esta, y eso lo mira
# pruebas/caidas.mjs.
if backend_vivo; then
    LOCURA=$(curl -s --max-time 8 --get --data-urlencode 'nombre=asdffff' \
        "$API/buscador/productos/facetado" 2>/dev/null | python -c "
import json, re, sys
try:
    p = json.load(sys.stdin).get('payload') or {}
except Exception:
    p = {}
s = p.get('sugeridos') or []
base = {re.sub(r'(\s+[LM]\d+-\d{4})+$', '', x.get('nombre', '')) for x in s}
activos = all(x.get('estado') == 'activo' for x in s)
print('%s|%s|%s|%s|%s' % (p.get('total'), len(s), len(base), p.get('sugeridos_desde'), 'si' if activos else 'no'))
")
    IFS='|' read -r L_TOTAL L_CUANTOS L_DISTINTOS L_DESDE L_ACTIVOS <<< "$LOCURA"
    if [ "$L_TOTAL" = "0" ]; then
        OK "asdffff sigue contando 0 resultados, para el reporte de busquedas sin resultados"
    else
        FALLA "asdffff dio total $L_TOTAL, se esperaba 0"
    fi
    if [ "${L_CUANTOS:-0}" -gt 0 ] 2>/dev/null; then
        OK "y trae $L_CUANTOS sugeridos"
    else
        FALLA "asdffff no trajo ningun sugerido: la pagina queda vacia"
    fi
    if [ "$L_DESDE" = "elasticsearch" ]; then
        OK "los sugeridos salen de Elasticsearch (sugeridos_desde = $L_DESDE)"
    else
        FALLA "los sugeridos salen de '$L_DESDE' y no de Elasticsearch, que esta arriba"
    fi
    if [ -n "$L_CUANTOS" ] && [ "$L_DISTINTOS" = "$L_CUANTOS" ] && [ "$L_ACTIVOS" = "si" ]; then
        OK "son productos distintos (sin copias de lote repetidas) y todos activos"
    else
        FALLA "de $L_CUANTOS sugeridos hay $L_DISTINTOS distintos, activos todos: $L_ACTIVOS"
    fi
else
    SIN_MEDIR "el backend no contesta en $API: los sugeridos son del backend"
fi

# ============================================================
# RESULTADO
# ============================================================
titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA, $sin_medir SIN MEDIR"
if [ "$fallo" -gt 0 ]; then
    echo "  El buscador no esta haciendo lo que se dijo."
    exit 1
fi
echo "  Encuentra con la palabra mal escrita, con tilde de mas, y a medias."
if [ "$sin_medir" -gt 0 ]; then
    echo "  Lo marcado SIN MEDIR depende de los datos de esta base, no del buscador."
else
    echo "  Y alcanza a los productos que solo viven en MongoDB."
fi
exit 0
