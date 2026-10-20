#!/usr/bin/env bash
# pruebas/carrito.sh -- las rutas del carrito: Redis delante, PostgreSQL la verdad.
#
#   bash pruebas/carrito.sh
#
# Desde el 2026-10-17 (carrito-postgres-verdad.md de Jose David, a pedido del
# profesor: "Redis nunca es la fuente de verdad") cada escritura va a Redis y se
# contesta, y debajo, sin hacer esperar a nadie, se copia al pedido `pendiente`
# de la cuenta en PostgreSQL. Hasta esa fecha esta prueba afirmaba lo contrario
# (que agregar y quitar NO tocaban PostgreSQL) y pasaba solo porque media antes
# de que terminara la copia.
#
# Comprueba, todo por HTTP y mirando las bases sin tocarlas:
#
#   - el carrito nace con el primer producto, en Redis y en PostgreSQL
#   - agregar y quitar SI llegan a PostgreSQL (el pedido pendiente y sus
#     lineas, con la version que Redis conoce), y no reservan stock
#   - un solo pedido pendiente por cuenta
#   - el TTL de Redis esta puesto y se RENUEVA en cada toque, igual que
#     fecha_ultima_actividad en PostgreSQL (expira por inactividad)
#   - una linea que no se puede comprar se marca, no se esconde; una oferta
#     que no existe da 404
#   - cada linea guarda una FOTO del precio que se vio
#   - si Redis pierde el carrito, se reconstruye desde PostgreSQL
#   - vaciar lo borra de las dos
#
# La unica escritura a mano es acelerar el reloj de Redis con EXPIRE y quitar
# la clave para simular que Redis la perdio (lo que pasa si se reinicia). Deja
# el carrito de la cuenta como estaba.

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

# La contrasena de Redis sale del .env de la raiz, nunca escrita aqui: este
# archivo se sube al repositorio y el .env no.
if [ -z "${REDIS_PASSWORD:-}" ] && [ -f "$DIR/../.env" ]; then
    REDIS_PASSWORD=$(grep -E "^REDIS_PASSWORD=" "$DIR/../.env" | head -1 | cut -d= -f2-)
fi
if [ -z "${REDIS_PASSWORD:-}" ]; then
    echo "Falta REDIS_PASSWORD. Ponla en el .env de la raiz o exportala." >&2
    exit 1
fi

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

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
codigo(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }

# Lo que dice PostgreSQL del carrito de la cuenta: cuantos pendientes, y de la
# linea pedida su cantidad (vacio si no esta).
PENDIENTE="(SELECT id_estado_pedido FROM estado_pedido WHERE estado_pedido_nombre='pendiente')"
pendientes() { sql "SELECT count(*) FROM pedido WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;"; }
cantidad_pg() {
    sql "SELECT pp.cantidad FROM pedido p JOIN pedido_producto pp USING (id_pedido)
          JOIN precio_historial ph USING (id_precio_historial)
         WHERE ph.id_oferta=$1 AND p.id_usuario=$ID_USUARIO AND p.id_estado_pedido=$PENDIENTE;"
}
# La copia a PostgreSQL es asincrona: se espera hasta 6 s a que diga $2.
esperar_cantidad() {
    local i
    for i in $(seq 1 30); do
        [ "$(cantidad_pg "$1")" = "$2" ] && return 0
        sleep 0.2
    done
    return 1
}
esperar_pendientes() {
    local i
    for i in $(seq 1 30); do
        [ "$(pendientes)" = "$1" ] && return 0
        sleep 0.2
    done
    return 1
}

titulo "0. Todo arriba"
[ "$(codigo -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend sirve /carrito" \
    || { echo "  El backend no responde en $API, o /carrito no existe."; exit 1; }
[ "$(R PING)" = "PONG" ] && OK "Redis responde" || { echo "  Redis no responde."; exit 1; }
[ "$(sql "SELECT to_regclass('public.reserva_venta_relampago') IS NOT NULL;")" = "t" ] \
    && OK "PostgreSQL tiene el carrito de verdad (migracion 045)" \
    || { echo "  Falta la migracion 045. Corre .\\arrancar.ps1"; exit 1; }

C=$(curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
     -d "{\"identificador\":\"$CUENTA\",\"contrasena\":\"$CLAVE\"}" \
   | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1)
[ -n "$C" ] && OK "sesion de $CUENTA" || { echo "  No se pudo entrar."; exit 1; }

ID_USUARIO=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='$CUENTA';")
LLAVE="mesh:carrito:$ID_USUARIO"

# Se guarda lo que hubiera para devolverlo al final, por la API: la cuenta es
# de todos y alguien puede tener algo a medias.
ANTES=$(curl -s "$API/carrito" -H "Cookie: $C" | python -c "
import sys,json
try:
    for l in json.load(sys.stdin)['payload']['lineas']: print('%s %s' % (l['id_oferta'], l['cantidad']))
except Exception: pass")
curl -s -X DELETE "$API/carrito" -H "Cookie: $C" >/dev/null
ped_comprados=$(sql "SELECT count(*) FROM pedido WHERE id_estado_pedido<>$PENDIENTE;")


titulo "1. Nace con el primer producto, no con una ruta de crear"

vacio=$(curl -s "$API/carrito" -H "Cookie: $C")
[ "$(echo "$vacio" | campo payload.total_lineas)" = "0" ] && OK "carrito vacio = 0 lineas" || FALLA "el carrito vacio no dio 0 lineas"
[ "$(R EXISTS "$LLAVE")" = "0" ] && OK "leer un carrito vacio NO crea la clave de Redis" || FALLA "un GET creo la clave"
[ "$(pendientes)" = "0" ] && OK "ni un pedido pendiente en PostgreSQL" || FALLA "hay $(pendientes) pendiente(s) con el carrito vacio"

OFERTA=$(sql "SELECT o.id_oferta FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta)
              WHERE eo.estado_oferta_nombre='activa' AND o.stock>=5 AND NOT o.es_inventario_limitado
              ORDER BY o.id_oferta LIMIT 1;")
r=$(curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":2}')
[ "$(echo "$r" | campo ok)" = "True" ] && OK "PUT crea el carrito con la primera linea" || FALLA "PUT: $(echo "$r" | campo mensaje)"
[ "$(R TYPE "$LLAVE")" = "hash" ] && OK "en Redis es un HASH (id_oferta -> linea en JSON)" || FALLA "no hay hash en $LLAVE"
esperar_cantidad "$OFERTA" 2 && OK "y debajo llego a PostgreSQL: pedido pendiente con la linea en 2" || FALLA "PostgreSQL dice '$(cantidad_pg "$OFERTA")' y no 2"
[ "$(pendientes)" = "1" ] && OK "un solo pedido pendiente: es el carrito" || FALLA "$(pendientes) pendientes"
[ -z "$(sql "SELECT id_direccion_historial FROM pedido WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;")" ] \
    && OK "sin direccion: se elige al pagar" || FALLA "el pendiente ya tiene direccion"


titulo "2. Agregar y quitar SI escriben en PostgreSQL, y no reservan stock"

version_antes=$(sql "SELECT version FROM pedido WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;")
stock_antes=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")
curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":3}' >/dev/null
esperar_cantidad "$OFERTA" 3 && OK "cambiar a 3 llego a PostgreSQL" || FALLA "PostgreSQL dice '$(cantidad_pg "$OFERTA")' y no 3"
version_desp=$(sql "SELECT version FROM pedido WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;")
[ "${version_desp:-0}" -gt "${version_antes:-0}" ] 2>/dev/null \
    && OK "la version del carrito subio ($version_antes -> $version_desp)" || FALLA "version $version_antes -> $version_desp"
v_redis=$(R HGET "$LLAVE" _v)
[ "$v_redis" = "$version_desp" ] && OK "Redis conoce esa misma version (_v = $v_redis)" || FALLA "_v en Redis = '$v_redis', PostgreSQL = $version_desp"
[ "$(R HEXISTS "$LLAVE" _d)" = "0" ] && OK "y no esta marcado como desincronizado" || FALLA "Redis tiene la marca _d"
[ "$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")" = "$stock_antes" ] \
    && OK "agregar NO reservo stock ($stock_antes) -> caducar no libera nada" || FALLA "el stock se movio"
[ "$(sql "SELECT count(*) FROM pedido WHERE id_estado_pedido<>$PENDIENTE;")" = "$ped_comprados" ] \
    && OK "no nacio ningun pedido comprado" || FALLA "cambio el numero de pedidos comprados"

curl -s -X DELETE "$API/carrito/lineas/$OFERTA" -H "Cookie: $C" >/dev/null
esperar_pendientes 0 && OK "quitar la ultima linea borra el pendiente: un carrito vacio no existe" || FALLA "quedo $(pendientes) pendiente(s)"
[ "$(R EXISTS "$LLAVE")" = "0" ] && OK "ni en Redis" || FALLA "la clave de Redis sobrevivio"
curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":2}' >/dev/null
esperar_cantidad "$OFERTA" 2 || FALLA "no volvio a nacer en PostgreSQL"


titulo "3. Expira por inactividad, en las dos"

ttl=$(R TTL "$LLAVE")
[ "$ttl" -gt 0 ] 2>/dev/null && OK "el carrito tiene TTL en Redis ($ttl s). Sin EXPIRE seria -1" || FALLA "TTL = $ttl (no vence nunca)"

# La prueba que separa "expira por inactividad" de "expira a plazo fijo": se
# baja el TTL a mano, se toca el carrito, y tiene que volver arriba.
R EXPIRE "$LLAVE" 100 >/dev/null
bajo=$(R TTL "$LLAVE")
curl -s "$API/carrito" -H "Cookie: $C" >/dev/null
tras_leer=$(R TTL "$LLAVE")
[ "$tras_leer" -gt "$bajo" ] && OK "un GET lo renovo: $bajo s -> $tras_leer s" || FALLA "el GET no renovo el TTL ($bajo -> $tras_leer)"

act_antes=$(sql "SELECT extract(epoch FROM fecha_ultima_actividad) FROM pedido WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;")
sleep 1
R EXPIRE "$LLAVE" 100 >/dev/null
curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":4}' >/dev/null
tras_put=$(R TTL "$LLAVE")
[ "$tras_put" -gt 100 ] && OK "un PUT tambien lo renovo: 100 s -> $tras_put s" || FALLA "el PUT no renovo el TTL"
esperar_cantidad "$OFERTA" 4 || FALLA "el PUT de 4 no llego a PostgreSQL"
act_desp=$(sql "SELECT extract(epoch FROM fecha_ultima_actividad) FROM pedido WHERE id_usuario=$ID_USUARIO AND id_estado_pedido=$PENDIENTE;")
python -c "import sys; sys.exit(0 if float('$act_desp') > float('$act_antes') else 1)" 2>/dev/null \
    && OK "y en PostgreSQL se movio fecha_ultima_actividad: las 24 h las decide la verdad" \
    || FALLA "fecha_ultima_actividad no se movio ($act_antes -> $act_desp)"


titulo "4. Lo que no se puede comprar se MARCA, no se esconde"

# Otra oferta que la de la parte 1: si fuera la misma (en una base donde la
# primera con stock >= 5 tiene 8 o menos, como la de la PC de Jose David), el
# PUT de aqui le pondria stock+3 y la parte 5 veria esa cantidad y no la suya.
POCA=$(sql "SELECT o.id_oferta FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta)
            WHERE eo.estado_oferta_nombre='activa' AND o.stock BETWEEN 1 AND 8 AND NOT o.es_inventario_limitado
              AND o.id_oferta <> $OFERTA
            ORDER BY o.id_oferta LIMIT 1;")
ST=$(sql "SELECT stock FROM oferta WHERE id_oferta=$POCA;")
curl -s -X PUT "$API/carrito/lineas/$POCA" -H "Content-Type: application/json" -H "Cookie: $C" -d "{\"cantidad\":$((ST+3))}" >/dev/null
motivo=$(curl -s "$API/carrito" -H "Cookie: $C" | python -c "
import sys,json
for l in json.load(sys.stdin)['payload']['lineas']:
    if l['id_oferta']==$POCA: print(l['motivo'] or 'ninguno')")
[ "$motivo" = "stock_insuficiente" ] && OK "pedir mas que el stock -> motivo '$motivo', la linea se ve" || FALLA "motivo inesperado: $motivo"

# Hasta el 2026-10-17 se guardaba con motivo oferta_no_existe. Ahora el PUT la
# rechaza: PostgreSQL no puede guardar una linea de una oferta que no hay.
[ "$(codigo -X PUT "$API/carrito/lineas/999999" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":1}')" = "404" ] \
    && OK "una oferta inventada da 404" || FALLA "una oferta inventada no dio 404"

r=$(curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":9999}')
[ "$(echo "$r" | campo ok)" = "False" ] && OK "una cantidad absurda se rechaza: $(echo "$r" | campo mensaje)" || FALLA "acepto cantidad 9999"


titulo "5. El precio es una FOTO tomada al agregar"

precio_real=$(sql "SELECT ROUND(precio * (1 - COALESCE(porcentaje_descuento,0)/100), 2) FROM oferta WHERE id_oferta=$OFERTA;")
precio_api=$(curl -s "$API/carrito" -H "Cookie: $C" | python -c "
import sys,json
for l in json.load(sys.stdin)['payload']['lineas']:
    if l['id_oferta']==$OFERTA: print(l['precio'])")
[ "$precio_real" = "$precio_api" ] && OK "el precio es el final de la oferta al agregarla ($precio_api)" || FALLA "$precio_real en la base, $precio_api en la API"

foto=$(R HGET "$LLAVE" "$OFERTA" | python -c "
import sys,json
try: d=json.loads(sys.stdin.read())
except Exception: print('no-es-json'); sys.exit()
print('%s|%s|%s' % (d.get('cantidad'), d.get('precio'), 'con-nombre' if d.get('nombre_producto') else 'sin-nombre'))")
[ "$foto" = "4|$precio_api|con-nombre" ] \
    && OK "en Redis la linea es un JSON con cantidad 4, precio $precio_api y nombre" \
    || FALLA "la foto de Redis no cuadra con la API ($foto)"
precio_pg=$(sql "SELECT ROUND(ph.precio * (1 - COALESCE(ph.porcentaje_descuento,0)/100), 2)
                  FROM pedido p JOIN pedido_producto pp USING (id_pedido) JOIN precio_historial ph USING (id_precio_historial)
                 WHERE ph.id_oferta=$OFERTA AND p.id_usuario=$ID_USUARIO AND p.id_estado_pedido=$PENDIENTE;")
[ "$precio_pg" = "$precio_api" ] && OK "y en PostgreSQL la linea apunta a la fila de precio_historial que se vio ($precio_pg)" || FALLA "PostgreSQL guarda $precio_pg y la API ensena $precio_api"


titulo "6. Redis pierde el carrito y PostgreSQL lo devuelve"

# Lo que pasa si Redis se reinicia. Se quita la clave (la segunda escritura a
# mano de esta prueba) y se pide el carrito.
R DEL "$LLAVE" >/dev/null
r=$(curl -s "$API/carrito" -H "Cookie: $C")
[ "$(echo "$r" | campo payload.total_lineas)" = "2" ] && OK "el GET trae las 2 lineas desde PostgreSQL" || FALLA "trajo $(echo "$r" | campo payload.total_lineas) lineas"
[ "$(R EXISTS "$LLAVE")" = "1" ] && OK "y Redis se reconstruyo" || FALLA "Redis no se reconstruyo"
[ "$(echo "$r" | campo payload.sincronizado)" = "True" ] && OK "sincronizado: true" || FALLA "sincronizado = $(echo "$r" | campo payload.sincronizado)"
[ "$(echo "$r" | campo payload.fuente)" = "redis" ] && OK "fuente: redis (Redis responde)" || FALLA "fuente = $(echo "$r" | campo payload.fuente)"
r=$(curl -s -X POST "$API/carrito/sincronizar" -H "Cookie: $C")
[ "$(echo "$r" | campo payload.sincronizado)" = "True" ] && OK "POST /carrito/sincronizar sobre uno sano no cambia nada" || FALLA "sincronizar: $(echo "$r" | campo mensaje)"


titulo "7. Vaciar"

curl -s -X DELETE "$API/carrito" -H "Cookie: $C" >/dev/null
[ "$(R EXISTS "$LLAVE")" = "0" ] && OK "DELETE /carrito borra la clave de Redis" || FALLA "la clave sobrevivio"
esperar_pendientes 0 && OK "y el pedido pendiente de PostgreSQL" || FALLA "quedo $(pendientes) pendiente(s)"
[ "$(curl -s "$API/carrito" -H "Cookie: $C" | campo payload.total_lineas)" = "0" ] && OK "y el GET vuelve a decir 0 lineas" || FALLA "el GET no da 0"


titulo "8. El carrito es de la cuenta, no del navegador"

C2=$(curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
      -d '{"identificador":"comprador.sur@mesh.com","contrasena":"Comprador123"}' \
    | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1)
curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":1}' >/dev/null
otras=$(curl -s "$API/carrito" -H "Cookie: $C2" | python -c "
import sys,json
print(sum(1 for l in json.load(sys.stdin)['payload']['lineas'] if l['id_oferta']==$OFERTA and l['cantidad']==1))" 2>/dev/null)
[ "$otras" = "0" ] && OK "la otra cuenta no ve esta linea" || FALLA "la otra cuenta vio la linea"
[ "$(codigo "$API/carrito")" = "401" ] && OK "sin sesion no hay carrito (401)" || FALLA "contesto sin sesion"


titulo "LIMPIEZA"
curl -s -X DELETE "$API/carrito" -H "Cookie: $C" >/dev/null
esperar_pendientes 0 || FALLA "no se pudo vaciar el carrito de prueba"
if [ -n "$ANTES" ]; then
    while read -r of cant; do
        [ -n "$of" ] && curl -s -X PUT "$API/carrito/lineas/$of" -H "Content-Type: application/json" -H "Cookie: $C" -d "{\"cantidad\":$cant}" >/dev/null
    done <<< "$ANTES"
    OK "se devolvio por la API el carrito que habia antes"
else
    OK "no habia carrito previo que devolver"
fi
[ "$(sql "SELECT count(*) FROM pedido WHERE id_estado_pedido<>$PENDIENTE;")" = "$ped_comprados" ] \
    && OK "PostgreSQL quedo igual ($ped_comprados pedidos que no son carrito)" || FALLA "cambio el numero de pedidos"


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
echo "  El carrito va a Redis y queda guardado en PostgreSQL, expira por inactividad y no reserva stock."
exit 0
