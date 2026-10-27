#!/usr/bin/env bash
# pruebas/carrito_vencimiento.sh -- el carrito VENCE de verdad, medido a traves
# del backend (Entrega 2, carrito con expiracion, 1.5 pts).
#
#   bash pruebas/carrito_vencimiento.sh
#
# POR QUE EXISTE
# ============================================================
# redis/prueba_carrito.sh prueba redis/carrito.lua, un diseno con script Lua que
# el backend TODAVIA NO USA (cero referencias en backend/src). El servicio real
# escribe con HSET y EXPIRE por separado. Aquella prueba demuestra el diseno,
# no lo que corre. Esta demuestra lo que corre: TODA accion pasa por las rutas
# HTTP del backend, y Redis y PostgreSQL solo se MIRAN.
#
# Lo unico que se toca a mano es el reloj. El TTL real es de 24 horas y no hay
# forma de esperarlas dentro de una prueba, asi que se le baja el TTL a la
# clave con EXPIRE, y de ahi en adelante todo lo hace Redis y el backend.
# Es la misma trampa que ya usa pruebas/carrito.sh, y se dice aqui de frente.
#
# DESDE EL 2026-10-17 EL RELOJ DE VERDAD ESTA EN POSTGRESQL. El carrito es el
# pedido `pendiente` de la cuenta (migracion 045) y Redis es su copia rapida:
# si Redis lo pierde, el backend lo reconstruye desde PostgreSQL. Las 24 h las
# decide pedido.fecha_ultima_actividad. Por eso, para que venza de verdad, el
# paso 3 atrasa tambien ese reloj 25 horas (es el mismo truco que el EXPIRE,
# sobre la otra copia). Antes de esa fecha la prueba solo bajaba el TTL de
# Redis, y con el carrito nuevo terminaba comprando un carrito "vencido".
#
# QUE COMPRUEBA
# ============================================================
#   1. El carrito nace por PUT /carrito/lineas y trae un TTL puesto, no -1.
#   2. QUIEN SIGUE AHI NO LO PIERDE. Con el TTL en 10 s, un GET /carrito a los
#      6 s lo devuelve entero, y la clave sigue viva pasados los 10 s de antes.
#   3. SI REDIS LO PIERDE PERO NO PASARON 24 H, NO SE PIERDE: PostgreSQL lo
#      devuelve.
#   4. QUIEN SE VA LO PIERDE. Con 25 h sin tocarlo, el checkout contesta 409
#      "vencio" y lo borra de PostgreSQL, sin vender nada.
#   5. Se puede volver a empezar con un PUT.
#
# Deja la base y Redis como estaban. No hace ninguna compra.
#
# Tarda alrededor de 40 segundos: hay que esperar de verdad a que venza.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
REDIS="${REDIS:-mesh-redis}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
CUENTA="${CUENTA:-compradora.norte@mesh.com}"
CLAVE="${CLAVE:-Comprador123}"

export MSYS_NO_PATHCONV=1

# La contrasena de Redis sale del .env de la raiz, nunca escrita aqui.
if [ -z "${REDIS_PASSWORD:-}" ] && [ -f "$DIR/../.env" ]; then
    REDIS_PASSWORD=$(grep -E "^REDIS_PASSWORD=" "$DIR/../.env" | head -1 | cut -d= -f2- | tr -d '\r')
fi
if [ -z "${REDIS_PASSWORD:-}" ]; then
    echo "Falta REDIS_PASSWORD. Ponla en el .env de la raiz o exportala." >&2
    exit 1
fi

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# SOLO LECTURA. Ni sql ni R escriben nada, salvo el EXPIRE que baja el reloj.
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

titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend sirve /carrito" \
    || { echo "  El backend no responde en $API."; exit 1; }
[ "$(R PING)" = "PONG" ] && OK "Redis responde" || { echo "  Redis no responde."; exit 1; }

C=$(curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
     -d "{\"identificador\":\"$CUENTA\",\"contrasena\":\"$CLAVE\"}" \
   | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1)
[ -n "$C" ] && OK "sesion de $CUENTA" || { echo "  No se pudo entrar."; exit 1; }

ID_USUARIO=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='$CUENTA';")
LLAVE="mesh:carrito:$ID_USUARIO"

# Lo que la cuenta tuviera a medias se guarda y se devuelve AL FINAL por la API.
ANTES=$(curl -s "$API/carrito" -H "Cookie: $C" | python -c "
import sys,json
try:
    for l in json.load(sys.stdin)['payload']['lineas']: print('%s %s' % (l['id_oferta'], l['cantidad']))
except Exception: pass")
curl -s -X DELETE "$API/carrito" -H "Cookie: $C" >/dev/null

OFERTA=$(sql "SELECT o.id_oferta FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta)
              WHERE eo.estado_oferta_nombre='activa' AND o.stock>=5 ORDER BY o.id_oferta LIMIT 1;")
[ -n "$OFERTA" ] && OK "oferta activa para probar ($OFERTA)" || { echo "  No hay oferta activa con stock."; exit 1; }

# Lo que la prueba controla, y solo eso. Comparar la tabla entera daria falsos
# rojos si alguien compra mientras la prueba duerme (ya paso con el arnes viejo).
ped_antes=$(sql "SELECT count(*) FROM pedido WHERE id_usuario=$ID_USUARIO;")
lin_antes=$(sql "SELECT count(*) FROM pedido_producto pp JOIN pedido p USING(id_pedido) WHERE p.id_usuario=$ID_USUARIO;")
stock_antes=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")
echo "  PostgreSQL antes, stock de la oferta $OFERTA = $stock_antes, pedidos de $CUENTA = $ped_antes, lineas = $lin_antes"


titulo "1. El carrito nace por el backend y trae un TTL puesto"

r=$(curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":2}')
[ "$(echo "$r" | campo ok)" = "True" ] && OK "PUT /carrito/lineas/$OFERTA agrego 2 unidades" || FALLA "PUT: $(echo "$r" | campo mensaje)"
ttl=$(R TTL "$LLAVE")
[ "$ttl" -gt 80000 ] 2>/dev/null && OK "TTL = $ttl s, puesto por el backend y no heredado (sin EXPIRE seria -1)" || FALLA "TTL = $ttl"


titulo "2. Quien sigue ahi NO pierde el carrito (inactividad, no plazo fijo)"

# Se acelera el reloj: el TTL de 24 h pasa a 10 s. De aqui en adelante lo hace
# Redis y lo hace el backend, no la prueba.
R EXPIRE "$LLAVE" 10 >/dev/null
sleep 6
bajo=$(R TTL "$LLAVE")
[ "$bajo" -le 5 ] 2>/dev/null && [ "$bajo" -ge 0 ] && OK "tras 6 s quieto el TTL bajo a $bajo s" || FALLA "el TTL no bajo como se esperaba ($bajo)"
lineas=$(curl -s "$API/carrito" -H "Cookie: $C" | campo payload.total_lineas)
[ "$lineas" = "1" ] && OK "GET /carrito lo devolvio entero ($lineas linea)" || FALLA "GET /carrito dio $lineas lineas"
tras=$(R TTL "$LLAVE")
[ "$tras" -gt 80000 ] 2>/dev/null && OK "y ese toque lo renovo: $bajo s -> $tras s" || FALLA "el GET no renovo el TTL ($bajo -> $tras)"

# La prueba que separa inactividad de plazo fijo, sin trampas: con el TTL en
# 10 s, ya pasaron 6 y se toco. Se espera otros 7, o sea 13 s desde el inicio.
# Con un plazo fijo la clave ya habria muerto. Con inactividad sigue viva.
R EXPIRE "$LLAVE" 10 >/dev/null
sleep 6
curl -s "$API/carrito" -H "Cookie: $C" >/dev/null
sleep 7
[ "$(R EXISTS "$LLAVE")" = "1" ] && OK "sigue viva 13 s despues de haber bajado el TTL a 10, porque alguien la siguio tocando" || FALLA "la clave murio aunque se toco"


PENDIENTE="(SELECT id_estado_pedido FROM estado_pedido WHERE estado_pedido_nombre='pendiente')"

titulo "3. Si Redis lo pierde antes de las 24 h, PostgreSQL lo devuelve"

R EXPIRE "$LLAVE" 8 >/dev/null
echo "  esperando 11 s sin tocar nada..."
sleep 11
[ "$(R EXISTS "$LLAVE")" = "0" ] && OK "la clave de Redis desaparecio sola" || FALLA "la clave sigue en Redis"
[ "$(sql "SELECT count(*) FROM pedido WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;")" = "1" ] \
    && OK "pero el pedido pendiente sigue en PostgreSQL: es la verdad" || FALLA "PostgreSQL ya no tiene el carrito"
lineas=$(curl -s "$API/carrito" -H "Cookie: $C" | campo payload.total_lineas)
[ "$lineas" = "1" ] && OK "GET /carrito lo devuelve entero ($lineas linea) y reconstruye Redis" || FALLA "GET /carrito dio $lineas lineas"
[ "$(R EXISTS "$LLAVE")" = "1" ] && OK "la clave volvio a Redis" || FALLA "Redis no se reconstruyo"


titulo "4. Quien se va, pierde el carrito: con 25 h sin tocarlo vence"

# El reloj, en las dos copias: 25 h atras en PostgreSQL y unos segundos de
# vida en Redis. Es el unico UPDATE a mano de la prueba.
sql "UPDATE pedido SET fecha_ultima_actividad = now() - interval '25 hours'
      WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;" >/dev/null
R EXPIRE "$LLAVE" 2 >/dev/null
sleep 3
[ "$(R EXISTS "$LLAVE")" = "0" ] && OK "Redis ya lo solto" || FALLA "la clave sigue en Redis"

# Se pide comprar el carrito vencido. Tiene que cortar con 409, sin vender nada.
DIRECCION=$(curl -s "$API/direccion-usuario" -H "Cookie: $C" | python -c "
import sys,json
d=json.load(sys.stdin).get('payload') or []
print(d[0]['id_direccion'] if d else '')")
if [ -z "$DIRECCION" ]; then
    FALLA "la cuenta no tiene direccion, no se puede pedir el checkout"
else
    # El barrido del backend (CarritoBarridoService, cada 10 minutos) borra
    # tambien los carritos vencidos. Si pasa justo en los segundos entre el
    # UPDATE de arriba y este checkout, gana el y el carrito ya no existe: el
    # checkout contesta "El carrito esta vacio", que es correcto pero no mide
    # el vencimiento pasivo. Paso el 2026-10-27 a las 07:39:50, 7 s antes del
    # final de la prueba. En ese caso se arma y se vence el carrito una vez mas.
    for intento in 1 2; do
        resp=$(curl -s -w '
%{http_code}' -X POST "$API/carrito/comprar"             -H "Content-Type: application/json" -H "Cookie: $C"             -d "{\"id_direccion\":$DIRECCION,\"metodo_pago\":\"efectivo contra entrega\"}")
        codigo=$(echo "$resp" | tail -1)
        cuerpo=$(echo "$resp" | sed '$d')
        if [ "$intento" = "1" ] && echo "$cuerpo" | campo mensaje | grep -qi "vacio"; then
            echo "        el barrido del backend borro el carrito vencido antes que el checkout; se repite una vez"
            curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":2}' >/dev/null
            sql "UPDATE pedido SET fecha_ultima_actividad = now() - interval '25 hours'
                  WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;" >/dev/null
            R EXPIRE "$LLAVE" 2 >/dev/null
            sleep 3
            continue
        fi
        break
    done
    [ "$codigo" = "409" ] && OK "POST /carrito/comprar con el carrito vencido contesta 409" || FALLA "contesto $codigo y no 409"
    echo "        mensaje del backend, $(echo "$cuerpo" | campo mensaje)"
    echo "$cuerpo" | campo mensaje | grep -qi "venci" && OK "y dice que vencio, no que hubo un error" || FALLA "el 409 no habla de vencimiento"
fi
[ "$(sql "SELECT count(*) FROM pedido WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;")" = "0" ] \
    && OK "el checkout lo borro de PostgreSQL (vencimiento pasivo)" || FALLA "el pendiente vencido sigue en PostgreSQL"
vacio=$(curl -s "$API/carrito" -H "Cookie: $C" | campo payload.total_lineas)
[ "$vacio" = "0" ] && OK "GET /carrito contesta 0 lineas" || FALLA "GET /carrito dio $vacio" 
ped_desp=$(sql "SELECT count(*) FROM pedido WHERE id_usuario=$ID_USUARIO;")
lin_desp=$(sql "SELECT count(*) FROM pedido_producto pp JOIN pedido p USING(id_pedido) WHERE p.id_usuario=$ID_USUARIO;")
stock_desp=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")
[ "$ped_antes" = "$ped_desp" ] && OK "pedidos de la cuenta, $ped_antes antes y $ped_desp despues" || FALLA "pedidos, $ped_antes -> $ped_desp"
[ "$lin_antes" = "$lin_desp" ] && OK "lineas de pedido de la cuenta, $lin_antes antes y $lin_desp despues" || FALLA "lineas, $lin_antes -> $lin_desp"
[ "$stock_antes" = "$stock_desp" ] && OK "stock de la oferta $OFERTA, $stock_antes antes y $stock_desp despues" || FALLA "stock, $stock_antes -> $stock_desp"


titulo "5. Se puede volver a empezar"

r=$(curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":1}')
[ "$(echo "$r" | campo ok)" = "True" ] && OK "un PUT nuevo arma otro carrito" || FALLA "PUT: $(echo "$r" | campo mensaje)"
ttl=$(R TTL "$LLAVE")
[ "$ttl" -gt 80000 ] 2>/dev/null && OK "con su TTL puesto otra vez ($ttl s)" || FALLA "TTL = $ttl"


titulo "LIMPIEZA"

curl -s -X DELETE "$API/carrito" -H "Cookie: $C" >/dev/null
if [ -n "$ANTES" ]; then
    n=0
    # Se devuelve por la API, que vuelve a tomar la foto del precio.
    while read -r of cant; do
        [ -n "$of" ] || continue
        curl -s -X PUT "$API/carrito/lineas/$of" -H "Content-Type: application/json" -H "Cookie: $C" -d "{\"cantidad\":$cant}" >/dev/null
        n=$((n+1))
    done <<< "$ANTES"
    OK "se devolvieron $n lineas del carrito que habia antes, por la API"
else
    OK "no habia carrito previo que devolver"
fi


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
echo "  El carrito del backend vence por inactividad y al vencer no deja nada colgando."
exit 0
