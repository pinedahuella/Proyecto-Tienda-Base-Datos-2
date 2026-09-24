#!/usr/bin/env bash
#
# AVISO, ESTE ARNES NO PASA POR EL BACKEND, y no puede todavia: las consultas
# B.1 a B.7 son un DISENO para aprobar y el backend aun no las corre. Prueba el
# texto del repositorio contra Neo4j y contra PostgreSQL. Cuando se implementen
# (docs/fraude-entrega3/02-reglas-backend.md), la prueba de punta a punta se
# escribe como pruebas/anillos.sh: cuentas, compras y resenas por HTTP.
#
# correr_patrones.sh -- las consultas de patrones de la Entrega 3, probadas dos veces
#
# Uso:  bash neo4j/correr_patrones.sh          (desde Git Bash)
#
# QUE HACE
# ============================================================
#   1. DATOS REALES. Corre neo4j/consultas/B1..B7 contra el grafo tal como
#      esta, y las siete equivalentes de neo4j/pruebas/equivalentes.sql contra
#      PostgreSQL. Las dos listas tienen que ser IGUALES fila por fila.
#
#   2. DATOS SEMBRADOS. Abre una transaccion en PostgreSQL, mete
#      neo4j/pruebas/siembra_patrones.sql (60 resenas, cada patron con su
#      control), y DENTRO de esa misma transaccion corre el extractor del grafo
#      y las equivalentes. Despues ROLLBACK: PostgreSQL no guarda nada. Lo
#      extraido se carga en Neo4j, se corren las mismas siete consultas, se
#      comparan contra el SQL y se comprueba con aserciones que cada patron
#      salio y cada control NO.
#
#   3. LIMPIEZA. Borra del grafo todo lo que tenga id negativo (la siembra) y
#      compara los conteos de nodos y relaciones contra los de antes.
#
# Sale con 1 si una comparacion o una asercion falla.
#
# Por que la siembra va a PostgreSQL y no directo al grafo, como la vieja
# neo4j/consultas/siembra.cypher: porque asi las dos bases ven lo mismo y se
# pueden comparar. Sembrar solo en Neo4j prueba que la consulta encuentra lo que
# se sembro; sembrar en la fuente y proyectar prueba ademas que el ETL lo lleva
# y que el SQL, con la misma regla, da lo mismo.

set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$RAIZ/.env"
set +a

CONSULTAS="$RAIZ/neo4j/consultas"
PRUEBAS="$RAIZ/neo4j/pruebas"
TMP="$(mktemp -d)"

# Git Bash convierte los argumentos que empiezan con "/" en rutas de Windows
# antes de pasarselos a docker ("/tmp/x" llega como "C:/Program Files/Git/tmp/x").
# Se apaga SOLO para docker: a Python si hay que darle la ruta convertida, y
# exportarlo para todo el script lo dejaba sin encontrar comparar.py.
dk() { MSYS_NO_PATHCONV=1 docker "$@"; }

# En Windows "python3" puede ser el atajo de la tienda de Microsoft, que existe
# y no corre nada. Se elige el primero que de verdad ejecuta.
PYTHON=""
for candidato in python python3 py; do
    if "$candidato" -c 'import sys' >/dev/null 2>&1; then PYTHON="$candidato"; break; fi
done
[ -n "$PYTHON" ] || { echo "Hace falta Python 3 (solo la biblioteca estandar)" >&2; exit 1; }

cypher() {
    dk exec -i mesh-neo4j cypher-shell -u neo4j -p "$NEO4J_PASSWORD" --format plain
}
psql_mesh() {
    dk exec -i mesh-postgres psql -U "$DB_USER" -d "$DB_NAME" -qtAX -v ON_ERROR_STOP=1 -f - "$@"
}

# Los umbrales, en una sola fuente: B0_parametros.cypher. Aqui se traducen a
# variables de psql para el SQL (":param dias_cadena => 30;" -> "\set dias_cadena 30").
PARAMS_PSQL="$(sed -n 's/^:param \([a-z_]*\) => \([0-9.]*\);.*$/\\set \1 \2/p' "$CONSULTAS/B0_parametros.cypher")"
if [ "$(printf '%s\n' "$PARAMS_PSQL" | wc -l)" -lt 14 ]; then
    echo "No pude leer los 14 parametros de B0_parametros.cypher" >&2
    exit 1
fi

FALLAS=0
ok()    { echo "  OK     $1"; }
falla() { echo "  FALLA  $1"; FALLAS=$((FALLAS + 1)); }

contar_grafo() {
    cypher <<'FIN' | tail -n +2 | tr '\n' ' '
MATCH (n) UNWIND labels(n) AS e RETURN e, count(*) ORDER BY e;
FIN
    cypher <<'FIN' | tail -n +2 | tr '\n' ' '
MATCH ()-[r]->() RETURN type(r), count(*) ORDER BY type(r);
FIN
}

limpiar_grafo() {
    cypher <<'FIN' >/dev/null
MATCH (n) WHERE (n:Usuario OR n:Resena OR n:Producto) AND n.id < 0 DETACH DELETE n;
MATCH (d:Direccion) WHERE d.ciudad = 'Prueba Patrones' DETACH DELETE d;
FIN
}

correr_consultas() {   # $1 = carpeta de salida
    mkdir -p "$1"
    for archivo in "$CONSULTAS"/B[1-7]_*.cypher; do
        nombre="$(basename "$archivo" .cypher)"
        cat "$CONSULTAS/B0_parametros.cypher" "$archivo" | cypher > "$1/$nombre.txt"
    done
}

# Si algo corta el script a la mitad, el grafo no se queda sucio.
trap 'limpiar_grafo; [ -n "${GUARDAR:-}" ] && cp -r "$TMP" "$GUARDAR"; rm -rf "$TMP"' EXIT

# Por si una corrida anterior se corto antes de limpiar.
limpiar_grafo
ANTES="$(contar_grafo)"


echo "============================================================"
echo " 1. DATOS REALES: Cypher contra PostgreSQL"
echo "============================================================"
correr_consultas "$TMP/real"
"$PYTHON" "$PRUEBAS/comparar.py" normalizar "$TMP/real" > "$TMP/real_cypher.txt"
{
    printf '%s\n' "$PARAMS_PSQL"
    echo '\o /dev/null'
    cat "$RAIZ/etl/extraer_grafo.sql"
    echo '\o'
    cat "$PRUEBAS/equivalentes.sql"
} | psql_mesh > "$TMP/real_sql.txt"
if "$PYTHON" "$PRUEBAS/comparar.py" comparar "$TMP/real_cypher.txt" "$TMP/real_sql.txt"; then
    ok "las siete consultas dan lo mismo en Neo4j y en PostgreSQL"
else
    falla "Neo4j y PostgreSQL no coinciden sobre los datos reales"
fi
echo
echo "  Lo que encontraron en los datos reales:"
sed 's/^/    /' "$TMP/real_cypher.txt"


echo
echo "============================================================"
echo " 2. DATOS SEMBRADOS (transaccion que se deshace)"
echo "============================================================"
{
    printf '%s\n' "$PARAMS_PSQL"
    echo 'BEGIN;'
    echo '\o /dev/null'
    cat "$PRUEBAS/siembra_patrones.sql"
    echo '\o /tmp/patrones_grafo.cypher'
    cat "$RAIZ/etl/extraer_grafo.sql"
    echo '\o /tmp/patrones_sql.txt'
    cat "$PRUEBAS/equivalentes.sql"
    echo '\o'
    echo 'ROLLBACK;'
} | psql_mesh
dk exec mesh-postgres cat /tmp/patrones_grafo.cypher | cypher > /dev/null
dk exec mesh-postgres cat /tmp/patrones_sql.txt > "$TMP/sem_sql.txt"
dk exec mesh-postgres rm -f /tmp/patrones_grafo.cypher /tmp/patrones_sql.txt

QUEDO="$(echo "SELECT count(*) FROM resena WHERE id_resena < 0;" | psql_mesh)"
[ "$QUEDO" = "0" ] && ok "PostgreSQL no guardo nada de la siembra (ROLLBACK)" \
                   || falla "quedaron $QUEDO resenas sembradas en PostgreSQL"

correr_consultas "$TMP/sem"
"$PYTHON" "$PRUEBAS/comparar.py" normalizar "$TMP/sem" > "$TMP/sem_cypher.txt"
if "$PYTHON" "$PRUEBAS/comparar.py" comparar "$TMP/sem_cypher.txt" "$TMP/sem_sql.txt"; then
    ok "con la siembra, Neo4j y PostgreSQL siguen dando lo mismo"
else
    falla "con la siembra, Neo4j y PostgreSQL no coinciden"
fi

# Las aserciones miran la salida NORMALIZADA de las consultas del repo, no una
# consulta aparte: preguntar otra vez con otro texto seria tener dos copias.
S="$TMP/sem_cypher.txt"
tiene()    { grep -qxF "$1" "$S" && ok "$2" || falla "$2  (falta: $1)"; }
no_tiene() { ! grep -q -- "$1" "$S" && ok "$2" || falla "$2  (sobra: $(grep -- "$1" "$S" | head -1))"; }

echo
echo "  Cada patron sale:"
tiene 'B.1|-204--203--202--201|4|TRUE|TRUE' \
      "B.1 la cadena c1-c2-c3-c4, una sola fila, nacidas juntas y con los extremos en la misma casa"
tiene 'B.2|-224--223--222--221--220|4' \
      "B.2 la granja de cuatro satelites alrededor de granja0"
tiene 'B.3|constante1@patrones.prueba|constante0@patrones.prueba|5' \
      "B.3 la cuenta que califica una vez al mes, cinco meses"
# El anillo se lista desde su cuenta de id MENOR (el filtro de rotacion de A.1),
# y con ids negativos esa es la tercera: -243 < -242 < -241.
tiene 'B.4|recurrente3@patrones.prueba,recurrente1@patrones.prueba,recurrente2@patrones.prueba|3|3|TRUE|TRUE' \
      "B.4 el anillo recurrente: 3 vueltas, 3 olas, visible y en orden"
tiene 'B.4|lento3@patrones.prueba,lento1@patrones.prueba,lento2@patrones.prueba|1|3|FALSE|FALSE' \
      "B.4 el anillo lento: invisible para el detector de 60 dias y fuera de orden"
tiene 'B.5|-252--251|1|FALSE' \
      "B.5 el favor devuelto en 5 horas, sobre productos distintos"
tiene 'B.6|-262--261|3' \
      "B.6 las dos cuentas que califican lo mismo a la vez, tres veces"
tiene 'B.7|expres0@patrones.prueba|2' \
      "B.7 el vendedor que recibio dos notas de cuentas con minutos de vida"

echo
echo "  Y cada control NO sale:"
no_tiene '^B\.1|.*-203--202--201|3'  "B.1 no lista los tramos de la cadena por separado"
no_tiene '^B\.1|.*-206'              "B.1 la cadena con un 3 en medio"
no_tiene '^B\.1|.*-209'              "B.1 la cadena de 60 dias"
no_tiene '^B\.1|.*-232'              "B.1 el cliente fiel no arma cadenas con nadie"
no_tiene '^B\.2|.*-225'              "B.2 la cuenta nueva que tambien califico a otro vendedor"
no_tiene '^B\.2|.*-226'              "B.2 el vendedor con solo dos satelites"
no_tiene '^B\.3|fiel@'               "B.3 el cliente fiel (exclusividad 0.4)"
no_tiene '^B\.3|coord'               "B.3 las coordinadas, que caben en 20 dias"
no_tiene '^B\.5|-254--253'           "B.5 el intercambio con diez dias de espera"
no_tiene '^B\.6|.*-263'              "B.6 la cuenta que califica lo mismo una semana despues"
no_tiene '^B\.7|coord0@'             "B.7 la cuenta nueva que califica a una tienda vieja"
no_tiene '^B\.7|granja0@'            "B.7 los satelites de tres dias no son expres"
no_tiene '^B\.2|.*-274'              "B.2 la resena anterior al alta de su autor no hace satelite"

echo
echo "  Y lo real sigue ahi con la siembra puesta (sembrar no tapa nada):"
FALTAN="$(grep -vxF -f "$TMP/sem_cypher.txt" "$TMP/real_cypher.txt" || true)"
[ -z "$FALTAN" ] && ok "las $(wc -l < "$TMP/real_cypher.txt") filas reales siguen en la salida sembrada" \
                 || falla "desaparecieron filas reales: $FALTAN"


echo
echo "============================================================"
echo " 3. LIMPIEZA"
echo "============================================================"
limpiar_grafo
DESPUES="$(contar_grafo)"
if [ "$ANTES" = "$DESPUES" ]; then
    ok "el grafo quedo igual que antes: $DESPUES"
else
    falla "el grafo no quedo igual. Antes: $ANTES  Despues: $DESPUES"
fi

echo
if [ "$FALLAS" -eq 0 ]; then
    echo "Todo bien."
else
    echo "$FALLAS FALLA(S)."
    exit 1
fi
