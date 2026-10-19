#!/usr/bin/env bash
# ============================================================
# El ETL de compras y devoluciones: PostgreSQL -> ClickHouse
# ============================================================
#
#   bash pruebas/etl_compras.sh
#
# Mide etl/cargar_compras.sh, que copia stock_movimiento (motivos venta y
# devolucion) a compra_producto y devolucion_producto con lote 'real'.
#
# Lo que se comprueba:
#
#   1. QUE CUADRA, y no solo por conteo. Filas, unidades sumadas y pares
#      (pedido, oferta) iguales entre PostgreSQL y ClickHouse.
#   2. LA COLISION QUE SE PERDIA. El pedido 121 compro el producto 11 a dos
#      vendedores (ofertas 46 y 51) en el mismo instante. Con la clave de
#      ordenacion vieja, ReplacingMergeTree colapsaba una de las dos y los
#      rankings salian cortos. Aqui se comprueba que las tres lineas del pedido
#      estan.
#   3. LA FECHA. El mismo instante en los dos lados, al milisegundo. No depende de
#      la zona del servidor de ClickHouse porque viaja como epoca.
#   4. QUE NO DUPLICA. Una segunda corrida copia cero.
#   5. QUE CURA. Se BORRAN filas del destino a proposito y se comprueba que la
#      siguiente corrida las trae de vuelta, y solo esas. Sin este paso, un ETL
#      que ya lo copio todo pasaria por bueno sin haber copiado nunca nada (un
#      verde sobre una linea que no se ejecuta no es un verde).
#   6. QUE RESPETA LO AJENO. Las filas de otro lote (las que siembra
#      clickhouse/lote) y las que el backend escribio con su IP no cambian.
#   7. QUE BORRA LO QUITADO, Y SOLO ESO. Una linea de un pedido que no existe en
#      PostgreSQL se queda mientras nadie lo anote; anotado en pedido_quitado
#      (la 046, lo que hacen los quitar.sql de las semillas), el ETL la borra y
#      marca la fila. Un pedido que SI existe, anotado por error, no se borra.
#
# LO QUE BORRA Y RESTAURA. Del destino borra los pedidos 10 y 11 (compras) y el
# 18 (devoluciones), que son filas puramente copiadas por el ETL: ninguna del
# backend, asi que se pueden recuperar SIN perder nada. De PostgreSQL solo LEE,
# salvo en la parte 7: dos filas de pedido_quitado que borra al terminar.
#
# LO QUE NO CUBRE. La negativa a correr con la clave de ordenacion vieja: para
# probarla habria que rehacer la tabla y esta prueba no toca la estructura.
#
# No instala nada: docker y el .env de la raiz. Corre de a uno.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
export MSYS_NO_PATHCONV=1

CH_BASE="${CLICKHOUSE_DB:-mesh_eventos}"
PEDIDO_COLISION=121
PEDIDOS_BORRADOS="10, 11"
PEDIDO_DEVOLUCION=18

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
igual() { if [ "$3" = "$2" ]; then OK "$1 ($3)"; else FALLA "$1 -- esperado $2, salio $3"; fi; }

# --database SIEMPRE, y `< /dev/null`: ver etl/cargar_compras.sh.
ch() {
    docker exec -i mesh-clickhouse clickhouse-client \
        --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
        --database "$CH_BASE" --query "$1" < /dev/null | tr -d '\r'
}
pg() { docker exec mesh-postgres psql -U "$DB_USER" -d "$DB_NAME" -qtAX -c "$1" | tr -d '\r'; }

# Los pedidos de la parte 5 son los de la base de Meme (10, 11 y la devolucion
# del 18). En otra base -- la de David, con su propio historial -- esos ids no
# tienen filas y la parte no mediria nada. Si los fijos no estan, se eligen de
# lo que ya copio el ETL (ip '::'), no de lo que escribio el backend, que la
# parte 6 exige que no se mueva.
if [ "$(ch "SELECT count() FROM compra_producto WHERE lote = 'real' AND id_pedido IN ($PEDIDOS_BORRADOS)")" = "0" ]; then
    PEDIDOS_BORRADOS=$(ch "SELECT arrayStringConcat(groupArray(toString(id_pedido)), ', ') FROM (SELECT DISTINCT id_pedido FROM compra_producto WHERE lote = 'real' AND ip = toIPv6('::') ORDER BY id_pedido LIMIT 2)")
fi
if [ "$(ch "SELECT count() FROM devolucion_producto WHERE lote = 'real' AND id_pedido = $PEDIDO_DEVOLUCION")" = "0" ]; then
    PEDIDO_DEVOLUCION=$(ch "SELECT toString(min(id_pedido)) FROM devolucion_producto WHERE lote = 'real' AND ip = toIPv6('::')")
fi

# Lo que PostgreSQL tiene, por motivo.
PG_LINEAS="FROM stock_movimiento sm JOIN motivo_movimiento mm USING (id_motivo_movimiento) JOIN oferta o ON o.id_oferta = sm.id_oferta WHERE sm.id_pedido IS NOT NULL AND mm.motivo_nombre ="

# ============================================================
titulo "0. Que esta lo necesario"
# ============================================================
if ! ch "SELECT 1" >/dev/null 2>&1; then FALLA "ClickHouse no contesta"; exit 1; fi
if ! pg "SELECT 1" >/dev/null 2>&1; then FALLA "PostgreSQL no contesta"; exit 1; fi
OK "ClickHouse y PostgreSQL contestan"
for t in compra_producto devolucion_producto; do
    clave="$(ch "SELECT sorting_key FROM system.tables WHERE database = '$CH_BASE' AND name = '$t'")"
    if echo "$clave" | grep -q id_oferta; then OK "$t lleva id_oferta en la clave ($clave)"
    else FALLA "$t lleva la clave vieja ($clave): corre bash clickhouse/reparar_orden_compras.sh"; exit 1; fi
done

ajenas_antes=$(ch "SELECT count() FROM compra_producto WHERE lote != 'real'")
del_backend_antes=$(ch "SELECT count() FROM compra_producto WHERE lote = 'real' AND ip != toIPv6('::')")
echo "  (filas de otros lotes: $ajenas_antes; filas reales con IP, del backend: $del_backend_antes)"

# ============================================================
titulo "1. Se corre el ETL y todo cuadra"
# ============================================================
salida=$(bash "$RAIZ/etl/cargar_compras.sh" 2>&1); codigo=$?
echo "$salida" | sed 's/^/  | /'
igual "el ETL sale con 0" 0 "$codigo"
igual "las dos tablas dicen 'cuadra'" 2 "$(echo "$salida" | grep -c -- '-> cuadra')"

for par in "compra_producto:venta" "devolucion_producto:devolucion"; do
    tabla="${par%%:*}"; motivo="${par##*:}"
    igual "$tabla, filas" "$(pg "SELECT count(*) $PG_LINEAS '$motivo'")" "$(ch "SELECT count() FROM $tabla WHERE lote = 'real'")"
    igual "$tabla, unidades" "$(pg "SELECT coalesce(sum(sm.cantidad),0) $PG_LINEAS '$motivo'")" "$(ch "SELECT coalesce(sum(cantidad),0) FROM $tabla WHERE lote = 'real'")"
    igual "$tabla, pares (pedido, oferta) distintos" \
        "$(pg "SELECT count(DISTINCT sm.id_pedido || ':' || sm.id_oferta) $PG_LINEAS '$motivo'")" \
        "$(ch "SELECT uniqExact(concat(toString(id_pedido), ':', toString(id_oferta))) FROM $tabla WHERE lote = 'real'")"
done

# ============================================================
titulo "2. La colision que se perdia"
# ============================================================
igual "el pedido $PEDIDO_COLISION tiene todas sus lineas de venta" \
    "$(pg "SELECT count(*) $PG_LINEAS 'venta' AND sm.id_pedido = $PEDIDO_COLISION")" \
    "$(ch "SELECT count() FROM compra_producto FINAL WHERE lote = 'real' AND id_pedido = $PEDIDO_COLISION")"
igual "y las unidades de ese pedido" \
    "$(pg "SELECT sum(sm.cantidad) $PG_LINEAS 'venta' AND sm.id_pedido = $PEDIDO_COLISION")" \
    "$(ch "SELECT sum(cantidad) FROM compra_producto FINAL WHERE lote = 'real' AND id_pedido = $PEDIDO_COLISION")"

# ============================================================
titulo "3. La fecha es el mismo instante, al milisegundo"
# ============================================================
# Sobre los pedidos que copio el ETL, no los del backend: el backend escribe su
# propia hora, unos milisegundos despues de la del movimiento.
#
# Los pedidos del backend NO son solo el 121. Cualquier compra hecha por el carrito
# mientras la base esta viva deja filas con la IP de quien compro, y esta prueba
# fallaba en cuanto alguien compraba algo (2026-09-19: dos ventas nuevas). Se sacan
# de ClickHouse: son los pedidos reales cuya fila NO lleva la IP comodin '::'.
DEL_BACKEND="$(ch "SELECT arrayStringConcat(arrayMap(x -> toString(x), groupUniqArray(id_pedido)), ',') FROM compra_producto WHERE lote = 'real' AND ip != toIPv6('::')")"
DEL_BACKEND="${DEL_BACKEND:-0}"
igual "instante maximo de las ventas copiadas (ms desde la epoca)" \
    "$(pg "SELECT max(round(extract(epoch FROM sm.fecha_movimiento) * 1000)::bigint) $PG_LINEAS 'venta' AND sm.id_pedido NOT IN ($DEL_BACKEND)")" \
    "$(ch "SELECT max(toUnixTimestamp64Milli(fecha)) FROM compra_producto WHERE lote = 'real' AND ip = toIPv6('::') AND id_pedido NOT IN ($DEL_BACKEND)")"
igual "ninguna venta cae en el futuro" 0 "$(ch "SELECT countIf(fecha > now() + INTERVAL 1 MINUTE) FROM compra_producto WHERE lote = 'real'")"

# ============================================================
titulo "4. Una segunda corrida no copia nada"
# ============================================================
salida=$(bash "$RAIZ/etl/cargar_compras.sh" 2>&1)
igual "las dos tablas dicen 0 nuevas" 2 "$(echo "$salida" | grep -c ': 0 nueva(s)')"

# ============================================================
titulo "5. Se borra del destino y el ETL lo recupera, y solo eso"
# ============================================================
c_antes=$(ch "SELECT count() FROM compra_producto WHERE lote = 'real'")
d_antes=$(ch "SELECT count() FROM devolucion_producto WHERE lote = 'real'")
c_borradas=$(ch "SELECT count() FROM compra_producto WHERE lote = 'real' AND id_pedido IN ($PEDIDOS_BORRADOS)")
d_borradas=$(ch "SELECT count() FROM devolucion_producto WHERE lote = 'real' AND id_pedido = $PEDIDO_DEVOLUCION")
echo "  (se van a borrar $c_borradas compra(s) y $d_borradas devolucion(es))"

if [ "$c_borradas" -eq 0 ] || [ "$d_borradas" -eq 0 ]; then
    FALLA "no hay filas de los pedidos elegidos para borrar: esta parte no mediria nada"
else
    ch "ALTER TABLE compra_producto DELETE WHERE lote = 'real' AND id_pedido IN ($PEDIDOS_BORRADOS) SETTINGS mutations_sync = 2" >/dev/null
    ch "ALTER TABLE devolucion_producto DELETE WHERE lote = 'real' AND id_pedido = $PEDIDO_DEVOLUCION SETTINGS mutations_sync = 2" >/dev/null
    igual "tras borrar, faltan las compras" $((c_antes - c_borradas)) "$(ch "SELECT count() FROM compra_producto WHERE lote = 'real'")"

    salida=$(bash "$RAIZ/etl/cargar_compras.sh" 2>&1)
    echo "$salida" | sed 's/^/  | /'
    igual "el ETL trae de vuelta exactamente las compras borradas" "$c_antes" "$(ch "SELECT count() FROM compra_producto WHERE lote = 'real'")"
    igual "y exactamente las devoluciones borradas" "$d_antes" "$(ch "SELECT count() FROM devolucion_producto WHERE lote = 'real'")"
    igual "copio solo las compras que faltaban" 1 "$(echo "$salida" | grep -c "ventas: $c_borradas nueva(s)")"
fi

# ============================================================
titulo "6. Lo ajeno no se mueve"
# ============================================================
igual "las filas de otros lotes no cambiaron" "$ajenas_antes" "$(ch "SELECT count() FROM compra_producto WHERE lote != 'real'")"
igual "las filas que escribio el backend con su IP siguen igual" "$del_backend_antes" "$(ch "SELECT count() FROM compra_producto WHERE lote = 'real' AND ip != toIPv6('::')")"

# ============================================================
titulo "7. Lo quitado de PostgreSQL se borra de ClickHouse, y solo eso"
# ============================================================
# Un pedido que no existe en PostgreSQL: una linea suya en ClickHouse es justo
# lo que dejaba un quitar.sql antes de la 046. Y uno que si existe y que el ETL
# copio, anotado por error, para ver que no se lo lleva.
if [ "$(pg "SELECT to_regclass('pedido_quitado') IS NOT NULL")" != "t" ]; then
    FALLA "no existe pedido_quitado: falta la migracion 046 (corre arrancar.ps1)"
else
    FALSO=$(( $(pg "SELECT coalesce(max(id_pedido), 0) FROM pedido") + 1000000 ))
    while [ "$(ch "SELECT count() FROM compra_producto WHERE id_pedido = $FALSO")" != "0" ] \
          || [ "$(pg "SELECT count(*) FROM pedido_quitado WHERE id_pedido = $FALSO")" != "0" ]; do
        FALSO=$((FALSO + 1))
    done
    VIVO=$(ch "SELECT toString(min(id_pedido)) FROM compra_producto WHERE lote = 'real' AND ip = toIPv6('::')")
    YA_ANOTADO=$(pg "SELECT count(*) FROM pedido_quitado WHERE id_pedido = $VIVO")
    c_vivo=$(ch "SELECT count() FROM compra_producto WHERE lote = 'real' AND id_pedido = $VIVO")
    echo "  (pedido inventado $FALSO; pedido vivo $VIVO con $c_vivo linea(s))"

    ch "INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip, lote) VALUES (now64(3) - INTERVAL 1 DAY, 1, 1, 1, 1, $FALSO, '::', 'real')" >/dev/null
    igual "la linea del pedido inventado esta en ClickHouse" 1 "$(ch "SELECT count() FROM compra_producto WHERE lote = 'real' AND id_pedido = $FALSO")"

    salida=$(bash "$RAIZ/etl/cargar_compras.sh" 2>&1)
    igual "sin anotarlo, el ETL no la toca" 1 "$(ch "SELECT count() FROM compra_producto WHERE lote = 'real' AND id_pedido = $FALSO")"
    igual "y dice que no cuadra" 1 "$(echo "$salida" | grep -c -- '-> NO CUADRA')"

    pg "INSERT INTO pedido_quitado (id_pedido, motivo) VALUES ($FALSO, 'pruebas/etl_compras.sh')" >/dev/null
    if [ "$YA_ANOTADO" = "0" ]; then
        pg "INSERT INTO pedido_quitado (id_pedido, motivo) VALUES ($VIVO, 'pruebas/etl_compras.sh, por error')" >/dev/null
    fi
    salida=$(bash "$RAIZ/etl/cargar_compras.sh" 2>&1); codigo=$?
    echo "$salida" | sed 's/^/  | /'
    igual "anotado, el ETL la borra" 0 "$(ch "SELECT count() FROM compra_producto WHERE lote = 'real' AND id_pedido = $FALSO")"
    igual "y marca la fila como aplicada" 1 "$(pg "SELECT count(*) FROM pedido_quitado WHERE id_pedido = $FALSO AND aplicado_en IS NOT NULL")"
    igual "el pedido vivo anotado por error conserva sus lineas" "$c_vivo" "$(ch "SELECT count() FROM compra_producto WHERE lote = 'real' AND id_pedido = $VIVO")"
    igual "y su fila sigue pendiente, para que alguien la mire" 1 "$(pg "SELECT count(*) FROM pedido_quitado WHERE id_pedido = $VIVO AND aplicado_en IS NULL")"
    igual "el ETL sale con 0 y todo cuadra otra vez" "0 2" "$codigo $(echo "$salida" | grep -c -- '-> cuadra')"

    pg "DELETE FROM pedido_quitado WHERE id_pedido = $FALSO" >/dev/null
    if [ "$YA_ANOTADO" = "0" ]; then
        pg "DELETE FROM pedido_quitado WHERE id_pedido = $VIVO" >/dev/null
    fi
fi

echo
echo "=============================================================="
echo "  $ok OK, $fallo FALLA"
echo "=============================================================="
[ "$fallo" -eq 0 ]
