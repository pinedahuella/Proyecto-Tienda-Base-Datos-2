#!/usr/bin/env bash
# ============================================================
# El ranking de mas vendidos en Redis: verlo y reconstruirlo
# ============================================================
#
#   bash redis/mas_vendidos.sh                 muestra el ranking que hay ahora
#   bash redis/mas_vendidos.sh --reconstruir   lo recalcula desde ClickHouse, ya
#
# Son dos claves. El ranking es un ZSET, mesh:productos:mas_vendidos: el
# miembro es el id de producto y el puntaje son las unidades vendidas. Desde el
# 2026-09-23 hay ademas un HASH, mesh:productos:mas_vendidos:detalle, con el
# documento completo de cada producto del ranking en JSON (id_producto ->
# documento), que el worker trae de Mongo una vez por corrida. GET
# /productos/mas-vendidos ya no toca Mongo: lee el ZSET, pide el detalle al HASH
# y salta el id que no tenga detalle. Ver la seccion 2b de redis/README.md.
#
# --reconstruir SOLO rehace el ZSET. El HASH de detalle lo sigue escribiendo
# unicamente el worker, porque es una copia del documento de Mongo tal como lo
# serializa el backend y este script no tiene como producir el mismo texto. La
# consecuencia: si el ranking reconstruido trae un producto que el worker no
# cacheo en su ultima corrida, la ruta lo salta hasta la corrida siguiente.
# La vista marca cuales estan en ese caso.
#
# QUIEN LA ESCRIBE DE VERDAD. El worker MasVendidosSyncService del backend, cada
# 10 minutos, y ese es el unico camino de produccion. Este script NO lo
# reemplaza: existe para no esperar esos 10 minutos cuando se esta armando una
# demo o probando el estante de la portada, y para poder MIRAR el ranking sin
# abrir RedisInsight.
#
# POR ESO HACE LO MISMO QUE EL WORKER, y la fuente de verdad es el codigo de
# Jose David (backend/src/services/productos/mas-vendidos-sync.service.ts):
#
#   ventana        compra_producto de las ultimas 24 horas; si no hay ninguna
#                  compra, de los ultimos 7 dias; si tampoco, NO toca Redis y
#                  deja el ranking anterior aunque ya este viejo
#   metrica        sum(cantidad) por id_producto, SOLO filas con lote = 'real'
#   tope           20 productos, aunque la ruta muestre 8
#   reemplazo      se arma en una clave temporal y se publica con RENAME, que es
#                  atomico: nadie lee un ranking a medio reconstruir
#
# Dos copias de una misma regla se separan con el tiempo. Para que no se separen
# EN SILENCIO, antes de escribir el script lee del backend el nombre de la clave
# y el tope, y se niega a seguir si ya no coinciden con los de aqui.
#
# SOLO CUENTA lote = 'real', igual que el worker desde el 2026-09-19. Es decision
# de Jose David y no tiene parametro: las compras sembradas por un generador
# (lote 'generado-N') nunca entran al ranking, ni a los seis de /admin/eventos/*.
# Antes de esa fecha si entraban, y este script las contaba tambien. El candado de
# abajo lee del backend que la consulta siga trayendo ese filtro.
#
# No instala nada: docker y las contrasenas del .env de la raiz.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
REDIS="${REDIS:-mesh-redis}"
CH_CONTENEDOR="${CH_CONTENEDOR:-mesh-clickhouse}"
CLAVE="mesh:productos:mas_vendidos"
CLAVE_TMP="${CLAVE}:tmp"
CLAVE_DETALLE="${CLAVE}:detalle"
TOPE=20
SERVICIO="$RAIZ/backend/src/services/productos/mas-vendidos-sync.service.ts"

if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
CH_BASE="${CLICKHOUSE_DB:-mesh_eventos}"
if [ -z "${REDIS_PASSWORD:-}" ]; then
    echo "Falta REDIS_PASSWORD. Ponla en el .env de la raiz o exportala." >&2
    exit 1
fi

# Git Bash convierte las rutas que empiezan con / al pasarlas a docker.
export MSYS_NO_PATHCONV=1

rcli() { docker exec "$REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'; }

# --database SIEMPRE: sin ella clickhouse-client entra a `default`, donde las
# tablas tambien existen y estan vacias, y todo sale en cero sin ningun error.
# Y `< /dev/null`, por lo del docker exec -i (ver TRASPASO).
ch() {
    docker exec -i "$CH_CONTENEDOR" clickhouse-client \
        --user "${CLICKHOUSE_USER:-}" --password "${CLICKHOUSE_PASSWORD:-}" \
        --database "$CH_BASE" -q "$1" < /dev/null
}

mostrar() {
    local n
    n=$(rcli ZCARD "$CLAVE")
    echo "Clave: $CLAVE"
    if [ "${n:-0}" = "0" ]; then
        echo "  No existe o esta vacia. El worker todavia no la ha llenado, o no hay compras."
        return
    fi
    echo "  $n producto(s), de mas a menos vendido (el puntaje son unidades):"
    local pos=0 id total marca
    while IFS=$'\t' read -r id total; do
        [ -n "$id" ] || continue
        pos=$((pos + 1))
        if [ "$(rcli HEXISTS "$CLAVE_DETALLE" "$id")" = "1" ]; then
            marca=""
        else
            marca="  (sin detalle cacheado, la ruta lo salta)"
        fi
        printf "    %2d. producto %-6s %s unidades%s\n" "$pos" "$id" "$total" "$marca"
    done <<< "$(rcli ZREVRANGE "$CLAVE" 0 -1 WITHSCORES | paste - -)"
    local ttl
    ttl=$(rcli TTL "$CLAVE")
    [ "$ttl" = "-1" ] && echo "  Sin vencimiento: se queda hasta que el worker la reemplace."
    echo "Clave: $CLAVE_DETALLE"
    echo "  $(rcli HLEN "$CLAVE_DETALLE") producto(s) con el documento cacheado por el worker."
}

if [ "${1:-}" != "--reconstruir" ]; then
    mostrar
    exit 0
fi

# ---------- el candado contra la deriva ----------
if [ ! -f "$SERVICIO" ]; then
    echo "No encuentro $SERVICIO." >&2
    echo "El worker cambio de sitio: revisa este script antes de escribir nada." >&2
    exit 1
fi
clave_backend=$(grep -o "CLAVE_RANKING = '[^']*'" "$SERVICIO" | sed "s/.*= '//; s/'//")
detalle_backend=$(grep -o "CLAVE_DETALLE = '[^']*'" "$SERVICIO" | sed "s/.*= '//; s/'//")
tope_backend=$(grep -o "TOPE_ALMACENADO = [0-9]*" "$SERVICIO" | sed 's/.*= //')
# El filtro por lote real. Si el worker lo pierde, este script seguiria contando lo
# sembrado y el ranking que arma dejaria de parecerse al que arma el backend.
if ! grep -qF "lote = 'real'" "$SERVICIO"; then
    echo "El worker del backend ya no filtra por lote = 'real'." >&2
    echo "Este script si lo hace: revisalo antes de escribir nada." >&2
    exit 1
fi
if [ "$clave_backend" != "$CLAVE" ] || [ "$tope_backend" != "$TOPE" ] \
   || [ "$detalle_backend" != "$CLAVE_DETALLE" ]; then
    echo "El worker del backend ya no coincide con este script." >&2
    echo "  clave    backend: ${clave_backend:-?}   aqui: $CLAVE" >&2
    echo "  detalle  backend: ${detalle_backend:-?}   aqui: $CLAVE_DETALLE" >&2
    echo "  tope     backend: ${tope_backend:-?}   aqui: $TOPE" >&2
    echo "Actualiza redis/mas_vendidos.sh y su seccion del README antes de seguir." >&2
    exit 1
fi

consulta() { # ventana, ej: "24 HOUR"
    ch "SELECT id_producto, sum(cantidad) AS total FROM compra_producto
         WHERE fecha >= now() - INTERVAL $1
           AND lote = 'real'
         GROUP BY id_producto ORDER BY total DESC LIMIT $TOPE FORMAT TSV"
}

filas=$(consulta "24 HOUR")
ventana="ultimas 24 horas"
if [ -z "$filas" ]; then
    filas=$(consulta "7 DAY")
    ventana="ultimos 7 dias (sin compras en 24 horas)"
fi
if [ -z "$filas" ]; then
    echo "Sin compras en 24 horas ni en 7 dias: no se toca Redis, como hace el worker."
    echo
    mostrar
    exit 0
fi

# Un ZADD con todos los pares, en la clave temporal, y despues el RENAME.
args=()
while IFS=$'\t' read -r id total; do
    [ -n "$id" ] && args+=("$total" "$id")
done <<< "$filas"

rcli DEL "$CLAVE_TMP" > /dev/null
rcli ZADD "$CLAVE_TMP" "${args[@]}" > /dev/null
rcli RENAME "$CLAVE_TMP" "$CLAVE" > /dev/null

echo "Reconstruido con $((${#args[@]} / 2)) producto(s), ventana $ventana."
echo
mostrar
