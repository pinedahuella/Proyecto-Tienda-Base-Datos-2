#!/usr/bin/env bash
# cargar_busqueda.sh
# Reconstruye el indice de busqueda de Elasticsearch desde el catalogo de Mongo.
#
#   bash etl/cargar_busqueda.sh
#
# En Windows se corre desde Git Bash, no desde PowerShell.
#
# TIRA EL INDICE ENTERO Y LO VUELVE A HACER, en cada corrida. No es pereza: el
# indice es una PROYECCION y no guarda nada que no este en las otras bases, asi
# que reconstruirlo deja siempre el mismo resultado sin tener que razonar sobre
# que sobra. Y es la unica forma de que DESAPAREZCA lo que dejo de ser publico:
# un producto que pasa a rechazado simplemente no vuelve a entrar.
#
# El texto no se arma aqui. Lo arma mongosh dentro de su propio contenedor
# (etl/extraer_busqueda.js) y de ahi sale ya en el formato de _bulk. Es la misma
# regla que el resto de esta carpeta: no hay nada que instalar, carga el cliente
# que ya vive dentro del contenedor.

set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"

# La trampa de Git Bash, que aqui muerde por los DOS lados.
#
# Git Bash sobre Windows convierte las rutas que empiezan con `/` al
# pasarselas a un programa: un `/tmp/x` de DENTRO del contenedor se vuelve
# `C:/Program Files/Git/tmp/x` y docker no encuentra nada. El parche es
# MSYS_NO_PATHCONV=1, y hace falta.
#
# Pero ese parche apaga la conversion PARA TODO, tambien para las rutas del
# lado de Windows. Con el puesto, un `docker cp /c/Users/... cont:/tmp/x` falla
# con "GetFileAttributesEx C:\c:". Se arregla un lado y se rompe el otro, y las
# dos veces el error no menciona a Git.
#
# Asi que se hacen las dos cosas: el parche puesto, y NINGUNA ruta de Windows
# viajando como argumento. Todo lo local entra por la entrada estandar (`< `) y
# sale por la salida (`> `), que las maneja bash y no pasan por docker ni por
# curl. Por eso los curl usan `--data-binary @-` en vez de `@archivo`.
#
# Es la misma esquiva de etl/correr.sh y etl/cargar_grafo.sh, contada en
# etl/README.md.
export MSYS_NO_PATHCONV=1

ES="${ES:-http://localhost:9200}"
INDICE="${INDICE:-mesh_productos}"
MONGO="${MONGO:-mesh-mongo}"

echo "==> reconstruyendo el indice $INDICE en $ES"

# ------------------------------------------------------------------
# 0. Que Elasticsearch este de verdad ahi
# ------------------------------------------------------------------
# Se pregunta ANTES de borrar nada. Si el motor no contesta y ya se hubiera
# borrado el indice, la maquina se quedaria sin buscador y con el indice viejo
# perdido, que es peor que no haber empezado.
if ! curl -sf --max-time 10 "$ES" > /dev/null; then
    echo "Elasticsearch no contesta en $ES" >&2
    echo "Levantalo con:  docker compose up -d elasticsearch" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 1. Extraer del catalogo de Mongo
# ------------------------------------------------------------------
docker exec -i "$MONGO" sh -c 'cat > /tmp/extraer_busqueda.js' \
    < "$RAIZ/etl/extraer_busqueda.js"

CUANTOS=$(docker exec "$MONGO" sh -c 'mongosh --quiet \
    -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin "$MONGO_INITDB_DATABASE" \
    /tmp/extraer_busqueda.js' | tr -d '\r')

echo "    $CUANTOS"

# El archivo da un rodeo por el disco local porque mesh-mongo y mesh-elastic no
# comparten volumen, igual que el .cypher del ETL del grafo.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
docker exec "$MONGO" cat /tmp/mesh-busqueda.ndjson > "$TMP/busqueda.ndjson"

# Un archivo vacio aqui quiere decir que la consulta no devolvio nada, y seguir
# dejaria un indice vacio sin un solo error. Es el mismo fallo que ya mordio con
# el ETL de Mongo (ver etl/README.md).
if [ ! -s "$TMP/busqueda.ndjson" ]; then
    echo "El extractor no devolvio ni un producto. No se toca el indice." >&2
    exit 1
fi

# ------------------------------------------------------------------
# 2. Guardar los vectores, borrar el indice y crearlo con su mapeo
# ------------------------------------------------------------------
# Desde el 2026-10-02 el documento de cada producto lleva su vector (vector,
# vector_hash, vector_grupo, vector_modelo), y calcularlos todos son unos 7
# minutos de Ollama. Antes de borrar se copian aparte con _reindex, por dentro
# de Elasticsearch, y etl/cargar_vectores.ps1 los devuelve sin Ollama si el
# texto del producto no cambio. Lo mismo hace Guardar-VectoresPrevios en
# arrancar.ps1. Si falla no corta: lo unico que se pierde es tiempo de Ollama.
PREVIOS="${PREVIOS:-mesh_productos_vectores_previos}"
CON_VECTOR=$(curl -s -X POST "$ES/$INDICE/_count" -H 'Content-Type: application/json' \
    -d '{"query":{"exists":{"field":"vector"}}}' | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
if [ -n "$CON_VECTOR" ] && [ "$CON_VECTOR" != "0" ]; then
    # Con > /dev/null y no con -o /dev/null: arriba se exporta
    # MSYS_NO_PATHCONV=1, y el curl de Windows no encuentra /dev/null y sale
    # con 23 aunque la peticion se haya hecho.
    curl -s -X DELETE "$ES/$PREVIOS" > /dev/null || true
    curl -s -X PUT "$ES/$PREVIOS" -H 'Content-Type: application/json' \
        -d '{"settings":{"number_of_shards":1,"number_of_replicas":0},"mappings":{"dynamic":false,"properties":{"vector":{"type":"dense_vector","dims":768,"index":false},"vector_hash":{"type":"keyword"},"vector_grupo":{"type":"keyword"},"vector_modelo":{"type":"keyword"}}}}' > /dev/null
    COPIADOS=$(curl -s -X POST "$ES/_reindex?wait_for_completion=true&refresh=true" -H 'Content-Type: application/json' \
        -d "{\"source\":{\"index\":\"$INDICE\",\"_source\":[\"vector\",\"vector_hash\",\"vector_grupo\",\"vector_modelo\"],\"query\":{\"exists\":{\"field\":\"vector\"}}},\"dest\":{\"index\":\"$PREVIOS\"}}" \
        | sed -n 's/.*"created":\([0-9]*\).*/\1/p')
    echo "    $COPIADOS de $CON_VECTOR vectores guardados en $PREVIOS"
fi

# El DELETE se traga el 404 a proposito: la primera vez el indice no existe y
# eso no es un fallo.
curl -s -o /dev/null -X DELETE "$ES/$INDICE" || true

CREADO=$(curl -s -w '\n%{http_code}' -X PUT "$ES/$INDICE" \
    -H 'Content-Type: application/json' \
    --data-binary @- < "$RAIZ/elastic/001_indice.json")

CODIGO=$(echo "$CREADO" | tail -1)
if [ "$CODIGO" != "200" ]; then
    echo "No se pudo crear el indice (HTTP $CODIGO):" >&2
    echo "$CREADO" | head -n -1 >&2
    exit 1
fi
echo "    indice creado con el mapeo de elastic/001_indice.json"

# ------------------------------------------------------------------
# 3. Cargar
# ------------------------------------------------------------------
# refresh=true para que lo cargado se pueda buscar EN CUANTO termina esto. Sin
# el, Elasticsearch refresca cuando le parece (un segundo por defecto) y la
# comprobacion de aqui abajo contaria cero sobre un indice que si tiene datos.
RESPUESTA=$(curl -s -X POST "$ES/$INDICE/_bulk?refresh=true" \
    -H 'Content-Type: application/x-ndjson' \
    --data-binary @- < "$TMP/busqueda.ndjson")

# _bulk contesta 200 aunque documentos sueltos hayan fallado. El unico sitio
# donde eso se ve es el campo `errors`, y no mirarlo es como se cargan indices
# a medias creyendo que fueron bien.
if echo "$RESPUESTA" | grep -q '"errors":true'; then
    echo "El bulk acepto la peticion pero algun documento fallo:" >&2
    echo "$RESPUESTA" | head -c 800 >&2
    echo >&2
    exit 1
fi

# ------------------------------------------------------------------
# 4. Comprobar el RESULTADO, no que los pasos parecieran ir bien
# ------------------------------------------------------------------
EN_INDICE=$(curl -s "$ES/$INDICE/_count" | sed 's/.*"count":\([0-9]*\).*/\1/')
ESPERADOS=$(echo "$CUANTOS" | sed 's/[^0-9]//g')

echo "    documentos en el indice: $EN_INDICE"

if [ "$EN_INDICE" != "$ESPERADOS" ]; then
    echo "No cuadra: se extrajeron $ESPERADOS y en el indice hay $EN_INDICE" >&2
    exit 1
fi

echo "==> listo, $EN_INDICE productos buscables"
echo "    Los vectores: powershell -File etl/cargar_vectores.ps1 (devuelve los guardados y calcula el resto)"
