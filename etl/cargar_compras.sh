#!/usr/bin/env bash
# ============================================================
# ETL de compras y devoluciones: PostgreSQL -> ClickHouse
# ============================================================
#
#   bash etl/cargar_compras.sh
#
# Copia las ventas y las devoluciones que ya estan en PostgreSQL a
# compra_producto y devolucion_producto, con lote = 'real'.
#
# POR QUE EXISTE. Esas dos tablas nacieron para que el backend las escribiera
# "al instante", y el backend solo lo hace por UN camino: el carrito
# (carrito.service.ts). Lo demas nunca llega:
#
#   * los 44 pedidos de la semilla y todo lo comprado antes del 2026-09-06, que
#     es cuando se enchufo la escritura;
#   * los pedidos pendientes que se pagan despues con comprarPedido, que no
#     anota nada;
#   * cualquier fila que se pierda por una caida de ClickHouse (la escritura es
#     fire-and-forget a proposito: la venta de verdad ya esta en PostgreSQL).
#
# Medido el 2026-09-18: 141 lineas de venta en 44 pedidos en PostgreSQL y DOS
# filas en compra_producto. El ranking de mas vendidos y el de compras de
# Tendencias arrancaban en casi cero teniendo meses de ventas guardadas.
#
# COMO NO DUPLICA. No usa una marca de agua sino el CONJUNTO de pares
# (id_pedido, id_oferta) que ClickHouse ya tiene con lote 'real'; ver la
# explicacion larga en etl/extraer_compras.sql. Lo que el backend ya escribio se
# respeta, y solo se agrega lo que falta. Se puede correr cuantas veces se quiera.
#
# LA FECHA VIAJA COMO EPOCA, no como texto, para no depender de la zona del
# servidor de ClickHouse. Tambien explicado en extraer_compras.sql.
#
# LO QUE NO HACE
#   * No pone la IP: PostgreSQL no la guarda (queda '::').
#   * No escribe vista_producto, carrito_producto ni las busquedas: no hay de
#     donde sacarlas hacia atras. Para eso esta clickhouse/lote.
#   * No toca lo que tenga otro lote: el generado no se mira ni se mezcla.
#
# Requiere que compra_producto y devolucion_producto lleven id_oferta en su clave
# de ordenacion (001_esquema.sql). Si no, se niega y dice como arreglarlo: con la
# clave vieja, una linea de un mismo producto en un mismo pedido se llevaba a la
# otra al fusionarse.
#
# En Windows se corre desde Git Bash. arrancar.ps1 tiene su gemelo en PowerShell
# y lo corre en cada arranque.

set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$RAIZ/.env"
set +a
export MSYS_NO_PATHCONV=1

CH_BASE="${CLICKHOUSE_DB:-mesh_eventos}"
SQL="$RAIZ/etl/extraer_compras.sql"
TRABAJO=".mesh-compras-filas.tsv"
trap 'rm -f "$TRABAJO"' EXIT

# --database SIEMPRE: sin ella el cliente entra a `default`, donde estas tablas
# tambien existen, el INSERT sale bien y el backend no ve una fila.
# Y `< /dev/null`: un docker exec -i deja la entrada abierta y cuelga al cliente.
ch() {
    docker exec -i mesh-clickhouse clickhouse-client \
        --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
        --database "$CH_BASE" --query "$1" < /dev/null | tr -d '\r'
}

# Se pregunta ANTES de leer nada: un ClickHouse caido devolveria "nada" y "nada"
# se leeria como "no he copiado nada todavia", y se recopiaria todo.
if ! ch "SELECT 1" > /dev/null 2>&1; then
    echo "ClickHouse no contesta: no se copia nada." >&2
    exit 1
fi

copiar() { # tabla, motivo, etiqueta
    local tabla="$1" motivo="$2" etiqueta="$3"

    local clave
    clave="$(ch "SELECT sorting_key FROM system.tables WHERE database = '$CH_BASE' AND name = '$tabla'")"
    if ! echo "$clave" | grep -q "id_oferta"; then
        echo "$tabla lleva la clave vieja ($clave)." >&2
        echo "Corre  bash clickhouse/reparar_orden_compras.sh  y vuelve a intentar." >&2
        return 1
    fi

    # Lo que ya hay, solo del lote real.
    local ya
    ya="$(ch "SELECT arrayStringConcat(groupArray(concat(toString(id_pedido), ':', toString(id_oferta))), ',') FROM $tabla WHERE lote = 'real'")"

    docker exec -i mesh-postgres psql -U "$DB_USER" -d "$DB_NAME" \
        -qtAX -F $'\t' -v ON_ERROR_STOP=1 -v "motivo=$motivo" -v "ya=$ya" -f - \
        < "$SQL" | tr -d '\r' > "$TRABAJO"

    local filas
    filas="$(grep -c . "$TRABAJO" || true)"
    if [ "$filas" -gt 0 ]; then
        docker exec -i mesh-clickhouse clickhouse-client \
            --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
            --database "$CH_BASE" \
            --query "INSERT INTO $tabla (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip, lote) FORMAT TabSeparated" \
            < "$TRABAJO"
    fi

    # La cuenta que dice si quedo cuadrado: lo de PostgreSQL contra lo de
    # ClickHouse, por pares. Un ETL que copia y no cuenta es un ETL que se cree.
    local en_pg en_ch
    en_pg="$(docker exec mesh-postgres psql -U "$DB_USER" -d "$DB_NAME" -qtAX -c \
        "SELECT count(*) FROM stock_movimiento sm JOIN motivo_movimiento mm USING (id_motivo_movimiento) WHERE mm.motivo_nombre = '$motivo' AND sm.id_pedido IS NOT NULL" | tr -d '\r')"
    en_ch="$(ch "SELECT count() FROM $tabla WHERE lote = 'real'")"

    printf '  %-20s %s: %s nueva(s). PostgreSQL %s, ClickHouse (real) %s' "$tabla" "$etiqueta" "$filas" "$en_pg" "$en_ch"
    if [ "$en_pg" = "$en_ch" ]; then
        echo "  -> cuadra"
    else
        echo "  -> NO CUADRA"
        return 2
    fi
}

echo "Copia de compras y devoluciones a ClickHouse ($CH_BASE)"
fallo=0
copiar compra_producto     venta      "ventas"      || fallo=1
copiar devolucion_producto devolucion "devoluciones" || fallo=1
exit $fallo
