#!/usr/bin/env bash
#
# AVISO, ESTE ARNES NO PASA POR EL BACKEND, y no puede todavia: las consultas de
# clickhouse/consultas/ son un DISENO para aprobar. Prueba el texto del
# repositorio contra ClickHouse. Cuando se implementen, la prueba de punta a
# punta manda los eventos por HTTP (POST /eventos/...) como pruebas/tendencias.sh.
#
# correr_consultas.sh -- recomendaciones, tendencias y operaciones sospechosas
#
# Uso:  bash clickhouse/correr_consultas.sh          (desde Git Bash)
#
# QUE HACE
#   1. Crea una base APARTE, mesh_prueba_consultas, con el mismo
#      clickhouse/001_esquema.sql que la real, y le carga
#      clickhouse/pruebas/siembra_consultas.sql (cada escenario con su control).
#   2. Corre las 13 consultas con los parametros de consultas/parametros.txt y
#      comprueba con clickhouse/pruebas/comprobar.py que cada escenario salio y
#      cada control no.
#   3. Borra la base de prueba.
#   4. Corre las mismas 13 contra la base REAL (mesh_eventos), solo leyendo, e
#      imprime lo que encuentran.
#
# La base real no se toca porque ClickHouse no tiene transacciones que deshacer,
# y borrar filas de vista_producto no le quita nada a su resumen materializado
# (clickhouse/README.md). Una base entera que se tira es lo unico limpio.

set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$RAIZ/.env"
set +a

CONSULTAS="$RAIZ/clickhouse/consultas"
PRUEBA=mesh_prueba_consultas
TMP="$(mktemp -d)"

PYTHON=""
for candidato in python python3 py; do
    if "$candidato" -c 'import sys' >/dev/null 2>&1; then PYTHON="$candidato"; break; fi
done
[ -n "$PYTHON" ] || { echo "Hace falta Python 3 (solo la biblioteca estandar)" >&2; exit 1; }

# $1 = base. La consulta entra por la entrada estandar, que se cierra sola al
# terminar el archivo: con -i y un --query, clickhouse-client se queda esperando
# mas filas para siempre (clickhouse/README.md, trampa 3).
ch() {
    local base="$1"; shift
    MSYS_NO_PATHCONV=1 docker exec -i mesh-clickhouse clickhouse-client \
        --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
        --database "$base" --multiquery "$@"
}

# Los parametros de parametros.txt, como --param_nombre=valor.
PARAMS=()
while IFS='=' read -r nombre valor; do
    case "$nombre" in ''|\#*) continue ;; esac
    PARAMS+=("--param_${nombre}=${valor}")
done < "$CONSULTAS/parametros.txt"

borrar_prueba() {
    echo "DROP DATABASE IF EXISTS $PRUEBA" | ch default >/dev/null
}
trap 'borrar_prueba; rm -rf "$TMP"' EXIT

# $1 = base, $2 = carpeta de salida, $3.. = parametros por consulta ya armados
correr_todas() {
    local base="$1" dir="$2"
    mkdir -p "$dir"
    for archivo in "$CONSULTAS"/[RTF][0-9]_*.sql; do
        nombre="$(basename "$archivo" .sql)"
        ch "$base" "${PARAMS[@]}" "${EXTRA[@]}" --format TSVWithNames \
            < "$archivo" > "$dir/$nombre.tsv"
    done
}


echo "============================================================"
echo " 1. BASE DE PRUEBA SEMBRADA ($PRUEBA)"
echo "============================================================"
borrar_prueba
echo "CREATE DATABASE $PRUEBA" | ch default
ch "$PRUEBA" < "$RAIZ/clickhouse/001_esquema.sql" >/dev/null
ch "$PRUEBA" < "$RAIZ/clickhouse/pruebas/siembra_consultas.sql"
echo "  sembradas: $(echo "SELECT sum(rows) FROM system.parts WHERE database = '$PRUEBA' AND active" | ch default) filas"

# Quien pregunta, en cada consulta que lo necesita: lo que el backend pondria.
EXTRA=(--param_usuario=1001 --param_sesion=u1001 --param_producto=3
       "--param_candidatos=[10,11,12,15,99]")
correr_todas "$PRUEBA" "$TMP/prueba"
# R1 otra vez, como visitante sin cuenta.
ch "$PRUEBA" "${PARAMS[@]}" --param_usuario=0 --param_sesion=anonima --format TSVWithNames \
    < "$CONSULTAS/R1_vistos_recientemente.sql" > "$TMP/prueba/R1_vistos_recientemente_anonima.tsv"

FALLAS=0
"$PYTHON" "$RAIZ/clickhouse/pruebas/comprobar.py" "$TMP/prueba" || FALLAS=1

if [ -n "${GUARDAR:-}" ]; then cp -r "$TMP/prueba" "$GUARDAR"; fi
borrar_prueba
QUEDA="$(echo "SELECT count() FROM system.databases WHERE name = '$PRUEBA'" | ch default)"
[ "$QUEDA" = "0" ] && echo "  OK     la base de prueba se borro" \
                   || { echo "  FALLA  la base de prueba sigue ahi"; FALLAS=1; }


echo
echo "============================================================"
echo " 2. BASE REAL ($CLICKHOUSE_DB), solo lectura"
echo "============================================================"
# Para las consultas personales se elige, en la base real, la cuenta y el
# producto con mas vistas: asi la corrida muestra algo en vez de vacio.
USUARIO="$(echo "SELECT id_usuario FROM vista_producto WHERE lote = 'real' AND id_usuario IS NOT NULL GROUP BY id_usuario ORDER BY count() DESC LIMIT 1" | ch "$CLICKHOUSE_DB")"
PRODUCTO="$(echo "SELECT id_producto FROM vista_producto WHERE lote = 'real' GROUP BY id_producto ORDER BY uniqExact(sesion) DESC LIMIT 1" | ch "$CLICKHOUSE_DB")"
CANDIDATOS="$(echo "SELECT '[' || arrayStringConcat(groupArray(toString(id_producto)), ',') || ']' FROM (SELECT id_producto FROM vista_producto WHERE lote = 'real' GROUP BY id_producto ORDER BY count() DESC LIMIT 8)" | ch "$CLICKHOUSE_DB")"
echo "  cuenta ${USUARIO:-ninguna}, producto ${PRODUCTO:-ninguno}, candidatos ${CANDIDATOS:-[]}"
EXTRA=("--param_usuario=${USUARIO:-0}" --param_sesion=ninguna "--param_producto=${PRODUCTO:-0}"
       "--param_candidatos=${CANDIDATOS:-[]}")
correr_todas "$CLICKHOUSE_DB" "$TMP/real"
for f in "$TMP"/real/*.tsv; do
    filas=$(( $(wc -l < "$f") - 1 )); [ "$filas" -lt 0 ] && filas=0
    printf '  %-32s %3s fila(s)\n' "$(basename "$f" .tsv)" "$filas"
done
if [ -n "${GUARDAR:-}" ]; then cp -r "$TMP/real" "$GUARDAR-real"; fi

echo
if [ "$FALLAS" -eq 0 ]; then echo "Todo bien."; else echo "Hubo FALLAS."; exit 1; fi
