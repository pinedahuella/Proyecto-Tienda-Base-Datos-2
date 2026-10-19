#!/usr/bin/env bash
# ============================================================
# R1, R2 y R3 por HTTP: vistos hace poco, tambien vieron y para ti
# ============================================================
#
#   bash pruebas/recomendaciones.sh
#
# Las tres rutas de recomendaciones que el backend conecto el 2026-09-25:
#
#   GET /productos/vistos-recientemente   R1, publica. Consulta ClickHouse en
#                                         cada peticion, sin cache.
#   GET /productos/:id/tambien-vieron     R2, publica. Solo lee Redis,
#                                         mesh:producto:<id>:tambien-vieron.
#   GET /productos/para-ti                R3, con sesion. Desde el 2026-10-16
#                                         sale del GRAFO de compras de Neo4j,
#                                         en vivo (grafo-compras.md de David).
#
# R2 la calcula un worker cada 15 minutos (TambienVieronSyncService). Esta
# prueba NO espera al worker: mide que la ruta lee la clave que el worker
# escribe, tal cual, y que sin clave contesta []. El calculo en si ya lo prueba
# clickhouse/correr_consultas.sh contra el SQL.
#
# R3 ya no lee Redis ni ClickHouse: ParaTiSyncService y la clave
# mesh:cuenta:<id>:para-ti se borraron. Es "lo que compraron las cuentas que
# compraron lo mismo que tu, y tu todavia no", un recorrido de dos saltos en el
# grafo. Aqui se comprueban sus reglas contra las compras de PostgreSQL; el
# grafo en si lo prueba pruebas/grafo_compras.sh.
#
# QUE COMPRUEBA
# ============================================================
#   1. R1. Sin cuenta y sin `sesion`, 200 y []. Con una `sesion` que vio dos
#      productos, los dos, el mas reciente primero, con cuantas veces se vio
#      cada uno y ya_comprado false. dias_historial 0 da 400.
#   2. R2. Un id que no es numero da 400. Sin clave, 200 y []. Con la clave
#      puesta, devuelve lo que dice la clave, en el mismo orden.
#   3. R3. Sin sesion 401. Con sesion, 200: nada que la cuenta ya compro, cada
#      porque_compraste es algo que si compro, ordenado por compradores, a lo
#      sumo 10. max_productos fuera de 1..50 da 400.
#
# LO QUE SIEMBRA Y LO QUE LIMPIA
# ============================================================
# ClickHouse: vistas con lote 'real' de dos productos ficticios (987654501 y
# 987654502) y una sesion con marcador 'prueba-reco-'. Se borran por marcador Y
# lote real, tambien del resumen vistas_por_producto_dia.
# Redis: la clave de R2 de un producto ficticio, que se borra. R3 solo lee.
# Hay un trap: si el proceso muere, limpia.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
CH_CONTENEDOR="${CH_CONTENEDOR:-mesh-clickhouse}"
REDIS="${REDIS:-mesh-redis}"
PG="${PG:-mesh-postgres}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
COMPRADOR_USUARIO="${COMPRADOR_USUARIO:-comprador.sur@mesh.com}"
COMPRADOR_CLAVE="${COMPRADOR_CLAVE:-Comprador123}"

if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
CH_USUARIO="${CLICKHOUSE_USER:-}"
CH_BASE="${CLICKHOUSE_DB:-mesh_eventos}"
if [ -z "${REDIS_PASSWORD:-}" ] || [ -z "${CLICKHOUSE_PASSWORD:-}" ] || [ -z "$CH_USUARIO" ]; then
    echo "Faltan REDIS_PASSWORD, CLICKHOUSE_USER o CLICKHOUSE_PASSWORD. Ponlas en el .env de la raiz." >&2
    exit 1
fi

export MSYS_NO_PATHCONV=1

TARRO=".mesh-reco-comprador.txt"
CUERPO=".mesh-reco-cuerpo.txt"

VIEJO=987654501
NUEVO=987654502
FALSOS="$VIEJO,$NUEVO"
SESION="prueba-reco-$$"
PRODUCTO_R2=987654503
CLAVE_R2="mesh:producto:$PRODUCTO_R2:tambien-vieron"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
igual() { if [ "$3" = "$2" ]; then OK "$1 ($3)"; else FALLA "$1 -- esperado $2, salio $3"; fi; }

ch() {
    docker exec -i "$CH_CONTENEDOR" clickhouse-client \
        --user "$CH_USUARIO" --password "$CLICKHOUSE_PASSWORD" \
        --database "$CH_BASE" -q "$1" < /dev/null
}
rcli() { docker exec -i "$REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'; }
sql() { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" 2>/dev/null | tr -d '\r'; }
jx() {
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch(e){console.log("__NO_JSON__");return}try{console.log(eval(process.argv[1]))}catch(e){console.log("__ERROR__")}})' "$1"
}
get() {
    local ruta="$1" tarro="${2:-}"
    if [ -n "$tarro" ]; then
        curl -s -o "$CUERPO" -w '%{http_code}' -b "$tarro" "$API$ruta"
    else
        curl -s -o "$CUERPO" -w '%{http_code}' "$API$ruta"
    fi
}

ID_CUENTA=""
BORRADO=0
limpiar() {
    [ "$BORRADO" = 1 ] && return
    BORRADO=1
    for t in vista_producto vistas_por_producto_dia; do
        ch "ALTER TABLE $t DELETE WHERE lote = 'real' AND id_producto IN ($FALSOS) SETTINGS mutations_sync = 2" >/dev/null 2>&1
    done
    rcli DEL "$CLAVE_R2" >/dev/null
    rm -f "$TARRO" "$CUERPO"
}
trap limpiar EXIT INT TERM

# ============================================================
titulo "0. Todo arriba"
# ============================================================
[ "$(rcli PING)" = "PONG" ] && OK "Redis responde" || { echo "  Redis no responde."; exit 1; }
ch "SELECT 1" >/dev/null 2>&1 && OK "ClickHouse responde" || { echo "  ClickHouse no responde."; exit 1; }
c=$(curl -s -o "$CUERPO" -w '%{http_code}' -c "$TARRO" -X POST "$API/usuario/login" \
    -H 'Content-Type: application/json' \
    -d "{\"identificador\":\"$COMPRADOR_USUARIO\",\"contrasena\":\"$COMPRADOR_CLAVE\"}")
[ "$c" = "200" ] && OK "entra $COMPRADOR_USUARIO" || { echo "  No entro el comprador ($c). Esta el backend en $API?"; exit 1; }
ID_CUENTA=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico = '$COMPRADOR_USUARIO'")
[ -n "$ID_CUENTA" ] || { echo "  No encontre el id de $COMPRADOR_USUARIO."; exit 1; }
# ============================================================
titulo "1. R1, vistos hace poco"
# ============================================================
igual "sin cuenta y sin sesion" 200 "$(get "/productos/vistos-recientemente")"
igual "y la lista viene vacia" 0 "$(jx 'j.payload.length' < "$CUERPO")"
igual "dias_historial 0" 400 "$(get "/productos/vistos-recientemente?sesion=$SESION&dias_historial=0")"

# El viejo se vio dos veces hace dos horas, el nuevo una vez hace una.
ch "INSERT INTO vista_producto (fecha,id_producto,sesion,ip,origen,lote) VALUES
    (now() - INTERVAL 2 HOUR, $VIEJO, '$SESION', '127.0.0.1', 'catalogo', 'real'),
    (now() - INTERVAL 2 HOUR, $VIEJO, '$SESION', '127.0.0.1', 'catalogo', 'real'),
    (now() - INTERVAL 1 HOUR, $NUEVO, '$SESION', '127.0.0.1', 'catalogo', 'real')"

igual "con la sesion que los vio" 200 "$(get "/productos/vistos-recientemente?sesion=$SESION")"
igual "trae los dos" 2 "$(jx 'j.payload.length' < "$CUERPO")"
igual "el mas reciente primero, y las veces de cada uno" "1|2" "$(jx 'j.payload.map(x=>Number(x.veces)).join("|")' < "$CUERPO")"
igual "ninguno comprado" "false|false" "$(jx 'j.payload.map(x=>x.ya_comprado).join("|")' < "$CUERPO")"
igual "otra sesion no los ve" 0 "$(get "/productos/vistos-recientemente?sesion=$SESION-otra" >/dev/null; jx 'j.payload.length' < "$CUERPO")"

# ============================================================
titulo "2. R2, quienes vieron esto tambien vieron"
# ============================================================
rcli DEL "$CLAVE_R2" >/dev/null
igual "un id que no es numero" 400 "$(get "/productos/abc/tambien-vieron")"
igual "sin clave en Redis" 200 "$(get "/productos/$PRODUCTO_R2/tambien-vieron")"
igual "y la lista viene vacia" 0 "$(jx 'j.payload.length' < "$CUERPO")"

# La forma de TambienVieronCacheado, en el orden que la deja el worker.
printf '%s' '[{"id_producto":1,"sesiones_en_comun":3,"afinidad":0.707,"producto":null},{"id_producto":2,"sesiones_en_comun":2,"afinidad":0.5,"producto":null}]' \
    | rcli -x SET "$CLAVE_R2" >/dev/null
igual "con la clave puesta" 200 "$(get "/productos/$PRODUCTO_R2/tambien-vieron")"
igual "devuelve lo de la clave, en su orden" "1:0.707|2:0.5" "$(jx 'j.payload.map(x=>x.id_producto+":"+x.afinidad).join("|")' < "$CUERPO")"
rcli DEL "$CLAVE_R2" >/dev/null

# ============================================================
titulo "3. R3, para ti, desde el grafo de compras"
# ============================================================
igual "sin sesion" 401 "$(get "/productos/para-ti")"
igual "con sesion" 200 "$(get "/productos/para-ti" "$TARRO")"

# Lo que la cuenta compro de verdad, segun PostgreSQL: los estados que cuentan
# como compra en el grafo (comprado, enviado, entregado).
COMPRADOS=$(sql "SELECT string_agg(DISTINCT pp.id_producto_mongo::text, ',')
                   FROM pedido p JOIN pedido_producto pp USING (id_pedido)
                   JOIN estado_pedido e USING (id_estado_pedido)
                  WHERE p.id_usuario = $ID_CUENTA AND e.estado_pedido_nombre IN ('comprado', 'enviado', 'entregado')")
n=$(jx 'j.payload.length' < "$CUERPO")
if [ -z "$COMPRADOS" ]; then
    igual "una cuenta sin compras recibe []" 0 "$n"
else
    [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le 10 ] && OK "$n recomendaciones, a lo sumo 10" || FALLA "$n recomendaciones"
    igual "ninguna es algo que ya compro" "si" "$(C="$COMPRADOS" jx 'j.payload.every(x=>!process.env.C.split(",").includes(String(x.id_producto)))?"si":"no"' < "$CUERPO")"
    igual "cada porque_compraste si lo compro" "si" "$(C="$COMPRADOS" jx 'j.payload.every(x=>x.porque_compraste.length>0&&x.porque_compraste.every(y=>process.env.C.split(",").includes(String(y))))?"si":"no"' < "$CUERPO")"
    igual "ordenadas por compradores, de mas a menos" "si" "$(jx 'j.payload.every((x,i,a)=>i==0||a[i-1].compradores>=x.compradores)?"si":"no"' < "$CUERPO")"
    igual "y sin repetir" "si" "$(jx 'new Set(j.payload.map(x=>x.id_producto)).size===j.payload.length?"si":"no"' < "$CUERPO")"
    igual "cada una con su producto de Mongo, activo" "si" "$(jx 'j.payload.every(x=>x.producto&&x.producto.estado==="activo")?"si":"no"' < "$CUERPO")"
fi
igual "max_productos=0" 400 "$(get "/productos/para-ti?max_productos=0" "$TARRO")"
igual "max_productos=51" 400 "$(get "/productos/para-ti?max_productos=51" "$TARRO")"
igual "max_productos=3" 200 "$(get "/productos/para-ti?max_productos=3" "$TARRO")"

# ============================================================
titulo "4. Limpieza"
# ============================================================
limpiar
igual "no quedo ninguna vista marcada" 0 "$(ch "SELECT count() FROM vista_producto WHERE lote = 'real' AND id_producto IN ($FALSOS)")"
igual "la clave de R2 no quedo" 0 "$(rcli EXISTS "$CLAVE_R2")"

titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
exit 0
