#!/usr/bin/env bash
# cargar_grafo.sh
# Corre el ETL del grafo: aplica el esquema, extrae de PostgreSQL y carga en
# Neo4j. Es el gemelo de correr.sh, que hace lo mismo contra MongoDB.
#
# En Windows se corre desde Git Bash, no desde PowerShell. Es la misma razon
# que dice correr.sh: PowerShell se come las comillas al llamar a docker y la
# consulta llega partida.
#
# Uso:
#   ./etl/cargar_grafo.sh                 carga sobre lo que haya
#   ./etl/cargar_grafo.sh --limpiar       borra el grafo entero y lo reconstruye
#   ./etl/cargar_grafo.sh --cola          solo lo que la cola tiene pendiente
#   ./etl/cargar_grafo.sh otra_base       extrae de otra base de PostgreSQL
#
# Los tres modos VACIAN la cola del outbox al terminar (ver el paso 3b).
#
# --cola es lo barato de correr a menudo: proyecta solo las resenas que el
# trigger de la 015 encolo desde la ultima vez, en vez de releer las 90 cada
# corrida. Las cuentas y las direcciones se proyectan enteras igual en los dos
# modos, porque el trigger no las vigila y si no fuera asi no llegarian nunca.
#
#
# Nada se instala y nada toca el disco
# ============================================================
# La regla de etl/README.md es "No hay nada que instalar", y aqui se cumple
# igual que con Mongo: PostgreSQL arma el texto y lo carga el cliente que ya
# viene DENTRO del contenedor. Alla es mongosh; aqui es cypher-shell, que la
# imagen neo4j:5-community trae puesto.
#
# Y no hay archivo intermedio: la salida de psql entra por una tuberia directo
# a cypher-shell. Un .cypher tirado en el disco es una foto que envejece, y el
# primero que la encuentre no va a saber de que corrida es.
#
#
# La trampa de Git Bash, esquivada en vez de parcheada
# ============================================================
# Git Bash convierte las rutas que empiezan con "/" cuando se las pasa a
# docker. Un "cypher-shell --file /neo4j/001_esquema.cypher" no busca el
# archivo dentro del contenedor: busca "C:/Program Files/Git/neo4j/..." y
# falla con un "No such file or directory" que ni menciona a Docker.
#
# El parche conocido es exportar MSYS_NO_PATHCONV=1. Aqui no hace falta, y es
# a proposito: TODO entra por la entrada estandar y en este archivo no hay una
# sola ruta absoluta de contenedor. De paso, el ETL deja de depender de que
# ./neo4j este montado en el contenedor -- si alguien toca ese volumen en
# docker-compose.yml, esto sigue cargando.

set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"

# Las credenciales salen del .env de la raiz, el mismo que lee docker compose.
# NEO4J_PASSWORD sale de ahi tambien: no se escribe en este archivo, que si se
# sube al repositorio.
set -a
. "$RAIZ/.env"
set +a

LIMPIAR=no
BASE="$DB_NAME"

SOLO_COLA=0

for ARG in "$@"; do
    case "$ARG" in
        --limpiar) LIMPIAR=si ;;
        --cola)    SOLO_COLA=1 ;;
        -*)        echo "Opcion desconocida: $ARG" >&2; exit 2 ;;
        *)         BASE="$ARG" ;;
    esac
done

# --limpiar y --cola juntos no tienen sentido y se rechazan en vez de hacer algo
# a medias: --limpiar borra el grafo entero, y despues proyectar SOLO lo que la
# cola tiene pendiente lo dejaria practicamente vacio. Quien lo teclee esta
# pidiendo dos cosas contrarias, y adivinar cual queria seria peor que pararse.
if [ "$LIMPIAR" = "si" ] && [ "$SOLO_COLA" = "1" ]; then
    echo "--limpiar y --cola no se pueden usar juntos: --limpiar borra el grafo" >&2
    echo "y --cola solo proyectaria lo pendiente, dejandolo casi vacio." >&2
    exit 2
fi

# cypher-shell se llama tantas veces que la lista de argumentos va aqui una vez.
# --format plain porque la salida la lee una persona o un pipe, no una tabla
# dibujada con guiones.
cypher() {
    docker exec -i mesh-neo4j cypher-shell \
        -u neo4j -p "$NEO4J_PASSWORD" --format plain
}


# ============================================================
# 1. El esquema, SIEMPRE, y antes de cargar
# ============================================================
# Va en cada corrida y no una sola vez porque el MERGE del ETL depende de las
# restricciones de unicidad para no duplicar. Si alguien levanta el contenedor
# con el volumen de datos vacio, las restricciones se fueron con el, y un ETL
# que no las reaplique empieza a crear nodos repetidos sin dar un solo error.
#
# Todo el 001 lleva IF NOT EXISTS, asi que repetirlo cuesta milisegundos.
echo "==> esquema (restricciones e indices)"
cypher < "$RAIZ/neo4j/001_esquema.cypher"


# ============================================================
# 2. El borrado, solo si lo piden
# ============================================================
# El ETL es idempotente pero solo AGREGA y ACTUALIZA: nunca resta. Una resena
# borrada en PostgreSQL se queda para siempre en el grafo, y ahi el grafo
# empieza a contestar cosas que ya no son ciertas.
#
# --limpiar es la respuesta, y se puede hacer sin miedo porque el grafo es una
# PROYECCION: no hay ni un dato aqui que no exista en PostgreSQL. Aun asi va
# detras de una bandera y no por defecto -- si alguien sembro un anillo de
# prueba a mano para una demostracion, un borrado automatico se lo lleva en
# medio de la demostracion.
#
# DETACH DELETE y no DELETE: DELETE sobre un nodo con relaciones falla, y con
# 86 resenas todo nodo tiene relaciones.
if [ "$LIMPIAR" = "si" ]; then
    echo "==> limpiando el grafo entero"
    echo 'MATCH (n) DETACH DELETE n;' | cypher
fi


# ============================================================
# 3. Extraer y cargar, en una tuberia
# ============================================================
# -q sin mensajes, -t sin encabezado ni conteo de filas, -A sin relleno de
# columnas, -X ignorando el .psqlrc de quien lo corra. Lo que sale es Cypher.
#
# ON_ERROR_STOP=1 es obligatorio: sin el, psql se salta la sentencia que fallo,
# sigue con las demas y termina en cero. El pipe recibiria un script INCOMPLETO,
# cypher-shell lo cargaria contento, y el grafo quedaria con la mitad de las
# relaciones sin que nadie se entere. Es el peor final posible, porque parece
# que funciono.
if [ "$SOLO_COLA" = "1" ]; then
    echo "==> extrayendo SOLO lo pendiente en la cola ($BASE) y cargando en Neo4j"
else
    echo "==> extrayendo de PostgreSQL ($BASE) y cargando en Neo4j"
fi

docker exec -i mesh-postgres \
    psql -U "$DB_USER" -d "$BASE" -qtAX -v ON_ERROR_STOP=1 -v solo_cola="$SOLO_COLA" -f - \
    < "$RAIZ/etl/extraer_grafo.sql" \
    | cypher


# ============================================================
# 3b. Vaciar la cola del outbox
# ============================================================
# La cola es `evento_grafo`, de la migracion 015: un trigger sobre `resena`
# encola el id de cada resena que se toca, en la misma transaccion.
#
# Se marca DESPUES de cargar y nunca antes. Si el paso de arriba falla, el pipe
# muere, este bloque no llega a correr y los eventos siguen pendientes, que es
# exactamente lo que tiene que pasar: un evento que se marca procesado sin
# haberse proyectado es una resena que nadie va a volver a mirar nunca.
#
# En modo completo se marca TODO lo pendiente, y eso es correcto por definicion:
# una proyeccion completa acaba de aplicar el estado actual de todas las
# resenas, asi que no queda nada de la cola por hacer. Sin esto, una base recien
# creada quedaria con sus 90 eventos pendientes para siempre sobre un grafo
# perfectamente correcto, y la conciliacion los reportaria como si faltara algo.
#
# El `procesado_en IS NULL` del WHERE no es de adorno: sin el, cada corrida
# reescribiria la fecha de todo el historico y se perderia cuando se proyecto
# cada cosa.
#
# Si la tabla no existe (una base que todavia no aplico la 015) esto no es un
# error: se dice y se sigue.
echo "==> vaciando la cola del outbox"
docker exec -i mesh-postgres \
    psql -U "$DB_USER" -d "$BASE" -qtAX -v ON_ERROR_STOP=1 <<'FIN'
SELECT (to_regclass('public.evento_grafo') IS NOT NULL) AS hay_cola \gset
\if :hay_cola
    WITH marcados AS (
        UPDATE evento_grafo SET procesado_en = now()
         WHERE procesado_en IS NULL
        RETURNING 1)
    SELECT count(*) || ' evento(s) marcados como proyectados' FROM marcados;
\else
    SELECT 'la tabla evento_grafo no existe todavia (falta la migracion 015): nada que vaciar';
\endif
FIN


# ============================================================
# 4. Contar lo que quedo
# ============================================================
# El ETL se mide solo. Un ETL que dice "listo" y no dice cuanto cargo es un ETL
# que puede haber cargado cero: la sentencia de resenas empieza con tres MATCH,
# y si los nodos no estuvieran no fallaria, simplemente no crearia nada.
#
# Estos numeros son ademas la prueba de idempotencia: correr el script dos
# veces seguidas tiene que imprimir exactamente lo mismo.
echo "==> lo que quedo en el grafo"
cypher <<'FIN'
MATCH (n)
UNWIND labels(n) AS etiqueta
RETURN etiqueta, count(*) AS nodos
ORDER BY etiqueta;
FIN

cypher <<'FIN'
MATCH ()-[r]->()
RETURN type(r) AS relacion, count(*) AS cantidad
ORDER BY relacion;
FIN
