#!/usr/bin/env bash
# ============================================================
# Le pone id_oferta a la clave de ordenacion de compra_producto y devolucion_producto
# ============================================================
#
#   bash clickhouse/reparar_orden_compras.sh
#
# Para las bases hechas ANTES del 2026-09-18. clickhouse/001_esquema.sql ya trae
# la clave nueva, pero su CREATE TABLE IF NOT EXISTS no toca una tabla que ya
# existe, y ClickHouse no permite cambiar el ORDER BY de una tabla con un ALTER
# (solo agregar columnas nuevas al final). Hay que reconstruirla.
#
# Por que hace falta. Con la clave (id_producto, fecha, id_pedido), dos ofertas
# del mismo producto en el mismo pedido comparten clave y ReplacingMergeTree las
# colapsa: el pedido 121 tenia tres lineas de venta en PostgreSQL y aqui quedaban
# dos. sum(cantidad) -- la metrica de compra y de devolucion en los rankings, y
# la del ranking de mas vendidos -- salia corta. Ver la nota en 001_esquema.sql.
#
# Que hace, por tabla:
#
#   1. Lee la clave actual de system.tables. Si ya lleva id_oferta, no hace nada.
#      Se puede correr cuantas veces se quiera.
#   2. Crea <tabla>_nueva con la misma estructura y la clave nueva.
#   3. Copia TODAS las filas, de cualquier lote: 'real', 'generado-N' y lo que
#      haya. No se filtra nada.
#   4. Comprueba que la copia tiene al menos las filas de la original.
#   5. Las intercambia con EXCHANGE TABLES (atomico) y borra la vieja.
#
# Si algo falla antes del intercambio, la tabla original no se ha tocado y solo
# queda <tabla>_nueva, que se borra sola en la siguiente corrida.
#
# UNA VENTANA PEQUENA, y hay que decirla: entre el paso 3 y el 5 el backend
# puede escribir una compra en la tabla vieja, y esa fila no llegaria a la
# nueva. Son milisegundos, y el ETL de etl/cargar_compras.sh la recupera en la
# siguiente corrida porque compara contra PostgreSQL. Aun asi, mejor correrlo
# sin trafico.
#
# No instala nada: docker y las credenciales del .env de la raiz.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
export MSYS_NO_PATHCONV=1

CH_BASE="${CLICKHOUSE_DB:-mesh_eventos}"
if [ -z "${CLICKHOUSE_USER:-}" ] || [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then
    echo "Faltan CLICKHOUSE_USER o CLICKHOUSE_PASSWORD. Ponlas en el .env de la raiz." >&2
    exit 1
fi

# --database SIEMPRE, y `< /dev/null`: ver etl/cargar_eventos.sh.
ch() {
    docker exec -i mesh-clickhouse clickhouse-client \
        --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
        --database "$CH_BASE" -q "$1" < /dev/null
}

if ! ch "SELECT 1" > /dev/null 2>&1; then
    echo "ClickHouse no contesta. Esta arriba mesh-clickhouse?" >&2
    exit 1
fi

reparar() {
    local tabla="$1" nueva="${1}_nueva"
    local clave
    clave="$(ch "SELECT sorting_key FROM system.tables WHERE database = '$CH_BASE' AND name = '$tabla'")"

    if [ -z "$clave" ]; then
        echo "  $tabla: no existe. Corre primero clickhouse/001_esquema.sql (arrancar.ps1 lo hace)." >&2
        return 1
    fi
    if echo "$clave" | grep -q "id_oferta"; then
        echo "  $tabla: ya tiene id_oferta en la clave ($clave). Nada que hacer."
        return 0
    fi

    echo "  $tabla: clave actual ($clave), se reconstruye..."
    ch "DROP TABLE IF EXISTS $nueva" || return 1
    ch "CREATE TABLE $nueva AS $tabla
        ENGINE = ReplacingMergeTree
        ORDER BY (id_producto, fecha, id_pedido, id_oferta)
        TTL toDateTime(fecha) + INTERVAL 12 MONTH" || return 1
    ch "INSERT INTO $nueva SELECT * FROM $tabla" || return 1

    local antes despues
    antes="$(ch "SELECT count() FROM $tabla")"
    despues="$(ch "SELECT count() FROM $nueva")"
    if [ "${despues:-0}" -lt "${antes:-0}" ]; then
        echo "  $tabla: la copia tiene $despues fila(s) y la original $antes. No se intercambia." >&2
        return 1
    fi

    ch "EXCHANGE TABLES $tabla AND $nueva" || return 1
    ch "DROP TABLE $nueva" || return 1
    echo "  $tabla: hecho. $despues fila(s), clave nueva ($(ch "SELECT sorting_key FROM system.tables WHERE database = '$CH_BASE' AND name = '$tabla'"))."
}

echo "Clave de ordenacion de las tablas de compra en $CH_BASE:"
fallo=0
reparar compra_producto     || fallo=1
reparar devolucion_producto || fallo=1
exit $fallo
