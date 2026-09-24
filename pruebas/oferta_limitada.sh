#!/usr/bin/env bash
# pruebas/oferta_limitada.sh -- la oferta de inventario limitado NO se sobrevende
# con muchos compradores a la vez, medida A TRAVES DEL BACKEND (Entrega 2,
# 3 pts, la parte mas pesada de la rubrica).
#
#   bash pruebas/oferta_limitada.sh            60 compradores sobre 20 unidades
#   N=100 STOCK=10 bash pruebas/oferta_limitada.sh
#
# POR QUE EXISTE
# ============================================================
# redis/prueba_concurrencia.sh lanza 1000 solicitudes con redis-benchmark
# directo contra el script Lua. Es el mismo archivo que carga el backend
# (redis/inventario_limitado.lua), asi que prueba la decision atomica, pero se
# salta la ruta HTTP, el servicio y las cuentas. Esta prueba no se salta nada.
# Cada comprador es una CUENTA REAL con su sesion, y cada solicitud es un
# PUT /carrito/lineas/:idOferta contra el backend en marcha. Redis y
# PostgreSQL solo se MIRAN.
#
# QUE HACE
# ============================================================
#   1. Deja listos 1 vendedor y N compradores (carga01..cargaNN@mesh.com), por
#      la API. Si ya existen de una corrida anterior se reusan.
#   2. El vendedor tiene una oferta con STOCK unidades, le pone un descuento
#      con POST /vendedor/ofertas/:id/descuento (desde el 2026-09-23 una venta
#      relampago sin descuento da 409) y abre la venta relampago con
#      POST /vendedor/ofertas/:id/venta-limitada.
#   3. OLA 1. Los N compradores piden 1 unidad cada uno, TODOS A LA VEZ.
#      Tiene que ganar exactamente STOCK y ser rechazado el resto, con 409.
#      Se mira en Redis que el stock quedo en 0, que lo reservado es STOCK, que
#      hay STOCK tickets y que los rechazos son N menos STOCK.
#   4. Los ganadores sueltan su reserva con DELETE. El stock tiene que volver.
#   5. OLA 2, lo mismo otra vez. Si soltar y volver a tomar dejara el contador
#      torcido, la segunda ola ganaria mas o menos que la primera.
#   6. Se cierra la venta, DESPUES se quita el descuento (con la venta abierta
#      el backend no deja quitarlo) y se retira la oferta. Si el arnes muere a
#      la mitad, un trap cierra la venta y quita el descuento en ese orden.
#
# NO hay candados en la aplicacion ni reintentos. Lo que decide quien gana es
# una sola operacion atomica dentro de Redis, y esta prueba la mira desde
# afuera, con cuentas de verdad.
#
# ADVERTENCIA. La primera corrida REGISTRA N cuentas y entra con cada una, todo
# desde la misma IP, asi que sube las alertas de multi cuenta por IP del panel
# de fraude. Las siguientes reusan las cuentas. Es lo esperado, no un fallo.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
REDIS="${REDIS:-mesh-redis}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
N="${N:-60}"
STOCK="${STOCK:-20}"
PRODUCTO="${PRODUCTO:-83}"
VARIANTE="${VARIANTE:-166}"
CLAVE_CARGA="${CLAVE_CARGA:-Desarrollo123!}"
DESCUENTO="${DESCUENTO:-20}"

export MSYS_NO_PATHCONV=1

if [ -z "${REDIS_PASSWORD:-}" ] && [ -f "$DIR/../.env" ]; then
    REDIS_PASSWORD=$(grep -E "^REDIS_PASSWORD=" "$DIR/../.env" | head -1 | cut -d= -f2- | tr -d '\r')
fi
if [ -z "${REDIS_PASSWORD:-}" ]; then
    echo "Falta REDIS_PASSWORD. Ponla en el .env de la raiz o exportala." >&2
    exit 1
fi
if [ "$N" -le "$STOCK" ]; then
    echo "N ($N) tiene que ser mayor que STOCK ($STOCK), si no no hay competencia." >&2
    exit 1
fi

TMP=$(mktemp -d)

# Lo que el arnes abrio y todavia no cerro. El trap lo deshace por la API si
# la corrida muere a medias, y en este orden: primero la venta y despues el
# descuento, porque con la venta abierta DELETE .../descuento da 409.
VENTA_ABIERTA=0
DESCUENTO_PUESTO=0
limpiar() {
    if [ "$VENTA_ABIERTA" = "1" ]; then
        curl -s -o /dev/null -X DELETE "$API/vendedor/ofertas/$OFERTA/venta-limitada" -H "Cookie: $VEND"
        VENTA_ABIERTA=0
    fi
    if [ "$DESCUENTO_PUESTO" = "1" ]; then
        curl -s -o /dev/null -X DELETE "$API/vendedor/ofertas/$OFERTA/descuento" -H "Cookie: $VEND"
        DESCUENTO_PUESTO=0
    fi
    rm -rf "$TMP"
}
trap limpiar EXIT
# En el bash de Git el trap de EXIT NO corre si al arnes lo matan con una
# senal (timeout, Ctrl+C, cerrar la terminal): se probo el 2026-09-23 y una
# corrida cortada por timeout dejo la oferta con su descuento puesto. Con la
# senal atrapada, el exit de aqui abajo si pasa por limpiar.
trap 'exit 130' INT TERM HUP

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# SOLO LECTURA sobre las bases.
sql()   { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" 2>/dev/null | tr -d '\r'; }
R()     { docker exec "$REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'; }
campo() { python -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
for k in sys.argv[1].split('.'):
    if d is None: break
    d = d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" "$1"; }

# Devuelve la cookie de sesion, o nada si no pudo entrar.
entrar() {
    curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
        -d "{\"identificador\":\"$1\",\"contrasena\":\"$2\"}" \
      | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1
}
registrar() {   # correo usuario nombre contrasena
    curl -s -o /dev/null -X POST "$API/usuario/registro" -H "Content-Type: application/json" \
        -d "{\"correo_electronico\":\"$1\",\"usuario\":\"$2\",\"nombre\":\"$3\",\"apellido\":\"Carga\",\"contrasena\":\"$4\"}"
}
entrar_o_crear() {
    local c; c=$(entrar "$1" "$4")
    if [ -z "$c" ]; then registrar "$1" "$2" "$3" "$4"; c=$(entrar "$1" "$4"); fi
    echo "$c"
}
put_json()   { curl -s -X "$1" "$API$2" -H "Content-Type: application/json" -H "Cookie: $3" -d "$4"; }


titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend sirve /carrito" || { echo "  El backend no responde en $API."; exit 1; }
[ "$(R PING)" = "PONG" ] && OK "Redis responde" || { echo "  Redis no responde."; exit 1; }
ADMIN=$(entrar "admin@mesh.com" "Admin123")
[ -n "$ADMIN" ] && OK "sesion de admin" || { echo "  No se pudo entrar como admin."; exit 1; }


titulo "1. El vendedor y su oferta, todo por la API"

VEND_CORREO="vendcarga@mesh.com"
VEND=$(entrar_o_crear "$VEND_CORREO" "vendcarga" "Vendedor de carga" "$CLAVE_CARGA")
[ -n "$VEND" ] && OK "sesion del vendedor $VEND_CORREO" || { echo "  No se pudo crear al vendedor."; exit 1; }
VID=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='$VEND_CORREO';")
if [ "$(sql "SELECT id_rol_usuario FROM usuarios WHERE id_usuario=$VID;")" != "2" ]; then
    put_json PATCH "/admin/usuarios/$VID" "$ADMIN" '{"id_rol_usuario":2}' >/dev/null
    # El rol viaja dentro del JWT: hay que volver a entrar para que lo lleve.
    VEND=$(entrar "$VEND_CORREO" "$CLAVE_CARGA")
fi
[ "$(sql "SELECT id_rol_usuario FROM usuarios WHERE id_usuario=$VID;")" = "2" ] && OK "es vendedor" || FALLA "no quedo como vendedor"

OFERTA=$(sql "SELECT id_oferta FROM oferta WHERE id_usuario=$VID AND id_producto_mongo=$PRODUCTO AND id_producto_variante_mongo=$VARIANTE LIMIT 1;")
if [ -z "$OFERTA" ]; then
    r=$(put_json POST "/vendedor/ofertas" "$VEND" "{\"id_producto\":$PRODUCTO,\"id_producto_variante\":$VARIANTE,\"precio\":\"15.00\",\"stock_inicial\":$STOCK}")
    OFERTA=$(echo "$r" | campo payload.id_oferta)
    [ -n "$OFERTA" ] && OK "el vendedor publico su oferta ($OFERTA)" || { echo "  No se pudo crear la oferta, $(echo "$r" | campo mensaje)"; exit 1; }
else
    OK "la oferta ya existia de una corrida anterior ($OFERTA)"
fi
put_json PATCH "/vendedor/ofertas/$OFERTA/revision" "$ADMIN" '{"decision":"aprobar"}' >/dev/null
[ "$(sql "SELECT eo.estado_oferta_nombre FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta) WHERE o.id_oferta=$OFERTA;")" != "activa" ] \
    && put_json PATCH "/vendedor/ofertas/$OFERTA" "$VEND" '{"estado":"activa"}' >/dev/null
estado=$(sql "SELECT eo.estado_oferta_nombre FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta) WHERE o.id_oferta=$OFERTA;")
[ "$estado" = "activa" ] && OK "la oferta esta activa" || { echo "  La oferta quedo en '$estado'."; exit 1; }

stock_pg=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")
if [ "$stock_pg" != "$STOCK" ]; then
    put_json PATCH "/vendedor/ofertas/$OFERTA" "$VEND" "{\"ajuste_stock\":$((STOCK - stock_pg))}" >/dev/null
fi
STOCK_PG=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")
[ "$STOCK_PG" = "$STOCK" ] && OK "la oferta tiene $STOCK unidades" || { echo "  El stock quedo en $STOCK_PG y no en $STOCK."; exit 1; }

# Si una corrida anterior murio a medias, la venta puede seguir abierta.
curl -s -o /dev/null -X DELETE "$API/vendedor/ofertas/$OFERTA/venta-limitada" -H "Cookie: $VEND"

# Una venta relampago exige un descuento activo. Si una corrida anterior dejo
# uno puesto se reusa (un segundo POST daria 409); si no, se pone ahora.
DESCUENTO_PUESTO=1
if [ -n "$(sql "SELECT porcentaje_descuento FROM oferta WHERE id_oferta=$OFERTA;")" ]; then
    OK "la oferta ya tenia un descuento de una corrida anterior, se reusa"
else
    r=$(put_json POST "/vendedor/ofertas/$OFERTA/descuento" "$VEND" "{\"porcentaje_descuento\":$DESCUENTO}")
    [ "$(echo "$r" | campo ok)" = "True" ] \
        && OK "descuento del $DESCUENTO% puesto con POST /vendedor/ofertas/$OFERTA/descuento" \
        || { echo "  No se pudo poner el descuento, $(echo "$r" | campo mensaje)"; exit 1; }
fi

VENTA_ABIERTA=1
r=$(put_json POST "/vendedor/ofertas/$OFERTA/venta-limitada" "$VEND" '{}')
[ "$(echo "$r" | campo ok)" = "True" ] && OK "venta relampago abierta con POST /vendedor/ofertas/$OFERTA/venta-limitada" || { echo "  No abrio, $(echo "$r" | campo mensaje)"; exit 1; }

CLAVE_R="mesh:oferta:$OFERTA"
RESERVAS="mesh:oferta:$OFERTA:reservas"
[ "$(R HGET "$CLAVE_R" stock)" = "$STOCK" ] && OK "Redis sembro el contador con el stock ($STOCK)" || FALLA "el contador de Redis no es $STOCK"


titulo "2. $N compradores, cada uno una cuenta real con su sesion"

t0=$(date +%s)
for i in $(seq -w 1 "$N"); do
    correo="carga$i@mesh.com"
    c=$(entrar_o_crear "$correo" "carga$i" "Comprador $i" "$CLAVE_CARGA")
    [ -n "$c" ] && echo "$c" > "$TMP/c_$i" || echo "  no se pudo entrar como $correo"
done
sesiones=$(ls "$TMP"/c_* 2>/dev/null | wc -l)
[ "$sesiones" -eq "$N" ] && OK "$N sesiones abiertas en $(( $(date +%s) - t0 )) s" || { echo "  Solo hay $sesiones sesiones de $N."; exit 1; }


ola() {
    rm -f "$TMP"/r_*
    for i in $(seq -w 1 "$N"); do
        (
            out=$(curl -s -w '\n%{http_code}' -X PUT "$API/carrito/lineas/$OFERTA" \
                -H "Content-Type: application/json" -H "Cookie: $(cat "$TMP/c_$i")" -d '{"cantidad":1}')
            echo "$out" > "$TMP/r_$i"
        ) &
    done
    wait
}

# Cuenta ganadores y rechazados leyendo lo que contesto el backend.
contar() {
    ganaron=0; rechazadas=0; otros=0; http409=0
    : > "$TMP/ganadores"
    for f in "$TMP"/r_*; do
        body=$(sed '$d' "$f"); code=$(tail -1 "$f")
        okv=$(echo "$body" | campo ok)
        if [ "$okv" = "True" ]; then
            ganaron=$((ganaron+1)); basename "$f" | sed 's/^r_//' >> "$TMP/ganadores"
        elif [ "$okv" = "False" ]; then
            rechazadas=$((rechazadas+1)); [ "$code" = "409" ] && http409=$((http409+1))
        else
            otros=$((otros+1))
        fi
    done
}

soltar() {   # los ganadores sueltan su reserva, por la API y en paralelo
    while read -r i; do
        curl -s -o /dev/null -X DELETE "$API/carrito/lineas/$OFERTA" -H "Cookie: $(cat "$TMP/c_$i")" &
    done < "$TMP/ganadores"
    wait
}

revisar_ola() {  # $1 = nombre de la ola
    contar
    [ "$ganaron" -eq "$STOCK" ] && OK "$1, ganaron exactamente $STOCK de $N" || FALLA "$1, ganaron $ganaron y tenian que ser $STOCK"
    [ "$rechazadas" -eq $((N - STOCK)) ] && OK "$1, $rechazadas rechazados, los otros $((N - STOCK))" || FALLA "$1, $rechazadas rechazados y tenian que ser $((N - STOCK))"
    [ "$http409" -eq "$rechazadas" ] && OK "$1, todos los rechazos fueron HTTP 409" || FALLA "$1, solo $http409 de $rechazadas rechazos fueron 409"
    [ "$otros" -eq 0 ] && OK "$1, ninguna solicitud dio un error raro" || FALLA "$1, $otros solicitudes dieron error inesperado"
    stock=$(R HGET "$CLAVE_R" stock); reservado=$(R HGET "$CLAVE_R" reservado)
    tickets=$(R ZCARD "$RESERVAS"); rechazos=$(R HGET "$CLAVE_R" rechazos)
    [ "$stock" = "0" ] && OK "$1, el stock en Redis quedo en 0, sin pasar por debajo" || FALLA "$1, stock en Redis = $stock"
    [ "$reservado" = "$STOCK" ] && OK "$1, reservado = $reservado" || FALLA "$1, reservado = $reservado y tenia que ser $STOCK"
    [ "$tickets" = "$STOCK" ] && OK "$1, hay $tickets tickets en el ZSET de reservas" || FALLA "$1, tickets = $tickets"
    echo "        rechazos contados por Redis, $rechazos"
}


titulo "3. OLA 1, $N solicitudes a la vez sobre $STOCK unidades"

t0=$(date +%s)
ola
echo "  la ola termino en $(( $(date +%s) - t0 )) s"
revisar_ola "ola 1"
[ "$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")" = "$STOCK" ] \
    && OK "PostgreSQL sigue en $STOCK, reservar no es comprar" || FALLA "PostgreSQL cambio de stock"


titulo "4. Los ganadores sueltan su reserva"

soltar
sleep 1
stock=$(R HGET "$CLAVE_R" stock); reservado=$(R HGET "$CLAVE_R" reservado)
[ "$stock" = "$STOCK" ] && OK "el stock volvio a $STOCK" || FALLA "el stock quedo en $stock y tenia que ser $STOCK"
[ "$reservado" = "0" ] && OK "reservado volvio a 0" || FALLA "reservado = $reservado"


titulo "5. OLA 2, soltar y volver a tomar no deja el contador torcido"

ola
revisar_ola "ola 2"
soltar


titulo "6. Se cierra la venta, se quita el descuento y se retira la oferta"

r=$(curl -s -X DELETE "$API/vendedor/ofertas/$OFERTA/venta-limitada" -H "Cookie: $VEND")
[ "$(echo "$r" | campo ok)" = "True" ] && { OK "venta relampago cerrada por la API"; VENTA_ABIERTA=0; } || FALLA "no cerro, $(echo "$r" | campo mensaje)"
[ "$(R EXISTS "$CLAVE_R")" = "0" ] && OK "las claves de Redis de la oferta desaparecieron" || FALLA "las claves de Redis siguen ahi"
# Recien con la venta cerrada el backend deja quitar el descuento.
r=$(curl -s -X DELETE "$API/vendedor/ofertas/$OFERTA/descuento" -H "Cookie: $VEND")
[ "$(echo "$r" | campo ok)" = "True" ] && { OK "descuento quitado por la API, despues de cerrar la venta"; DESCUENTO_PUESTO=0; } || FALLA "no se quito el descuento, $(echo "$r" | campo mensaje)"
put_json PATCH "/vendedor/ofertas/$OFERTA" "$VEND" '{"estado":"retirada"}' >/dev/null
[ "$(sql "SELECT eo.estado_oferta_nombre FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta) WHERE o.id_oferta=$OFERTA;")" = "retirada" ] \
    && OK "la oferta quedo retirada, no ensucia el catalogo" || FALLA "la oferta no quedo retirada"
# Cualquier carrito que haya quedado con la linea
for i in $(seq -w 1 "$N"); do
    curl -s -o /dev/null -X DELETE "$API/carrito" -H "Cookie: $(cat "$TMP/c_$i")" &
done
wait
huerfanos=$(R --scan --pattern "mesh:carrito:*" | wc -l)
echo "  carritos que quedan en Redis, $huerfanos"


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
echo "  $N cuentas reales, $STOCK unidades, dos olas a la vez, y nadie llevo una que no existia."
exit 0
