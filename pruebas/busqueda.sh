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
INDICE="${INDICE:-mesh_productos}"
MONGO="${MONGO:-mesh-mongo}"

export MSYS_NO_PATHCONV=1

ok=0; fallo=0

OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
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

# ============================================================
# 0. Que haya algo con que trabajar
# ============================================================
titulo "0. EL INDICE ESTA"

if ! curl -sf --max-time 10 "$ES" > /dev/null; then
    echo "  Elasticsearch no contesta en $ES"
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

ACTIVOS=$(mongo_cuenta 'db.productos.countDocuments({estado:"activo"})')
if [ "$EN_INDICE" = "$ACTIVOS" ]; then
    OK "cuadra con los productos activos de MongoDB (= $ACTIVOS)"
else
    FALLA "el indice tiene $EN_INDICE y MongoDB tiene $ACTIVOS activos"
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
# PostgreSQL. Los tres existen, estan activos y se venden.
for par in "103:tecnokid" "104:barbuchin" "106:crepas"; do
    ID="${par%%:*}"
    NOMBRE="${par##*:}"

    EN_PG=$(docker exec mesh-postgres psql -U meme -d mesh -qtAc \
        "SELECT count(*) FROM productos WHERE id_producto = $ID" 2>/dev/null | tr -d '\r ')

    ESTA=$(curl -s -o /dev/null -w '%{http_code}' "$ES/$INDICE/_doc/$ID")

    if [ "$EN_PG" != "0" ]; then
        echo "  (el $ID ya tiene fila en PostgreSQL, esta prueba dejo de medir lo suyo)"
        continue
    fi

    if [ "$ESTA" = "200" ]; then
        OK "el $ID ($NOMBRE) esta en el indice, y NO tiene fila en PostgreSQL"
    else
        FALLA "el $ID ($NOMBRE) NO esta en el indice (HTTP $ESTA)"
        echo "        Se vende y el buscador diria que no existe."
        echo "        Mira si etl/extraer_busqueda.js dejo de leer de MongoDB."
    fi
done

# ============================================================
# 4. Lo rechazado no se busca
# ============================================================
titulo "4. UN PRODUCTO RECHAZADO NO APARECE"

# Primero que EXISTE en Mongo. Sin esto, la comprobacion de abajo pasaria
# igual sobre un id inventado y no estaria midiendo nada.
EXISTE=$(mongo_cuenta 'db.productos.countDocuments({_id:105})')
if [ "$EXISTE" = "1" ]; then
    OK "el 105 existe en MongoDB, asi que su ausencia abajo significa algo"
else
    FALLA "el 105 no esta en MongoDB: esta prueba no puede medir nada"
fi

ESTA_105=$(curl -s -o /dev/null -w '%{http_code}' "$ES/$INDICE/_doc/105")
if [ "$ESTA_105" = "404" ]; then
    OK "y no esta en el indice (HTTP 404), que es lo que se pidio"
else
    FALLA "el 105 esta rechazado y SI esta en el indice (HTTP $ESTA_105)"
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
# RESULTADO
# ============================================================
titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
if [ "$fallo" -gt 0 ]; then
    echo "  El buscador no esta haciendo lo que se dijo."
    exit 1
fi
echo "  Encuentra con la palabra mal escrita, con tilde de mas, y a medias."
echo "  Y alcanza a los productos que solo viven en MongoDB."
exit 0
