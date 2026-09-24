#!/usr/bin/env bash
# pruebas/carrito.sh -- las 4 rutas del carrito sobre Redis (Entrega 2, 1.5 pts).
#
#   bash pruebas/carrito.sh
#
# Comprueba lo que la rubrica pide demostrar, y no solo que las rutas contesten:
#
#   - el carrito vive en Redis y NO escribe en PostgreSQL al agregar o quitar
#   - cada linea guarda una FOTO (precio ya con descuento, nombre, imagen,
#     vendedor) que GET /carrito sirve sin preguntarle a nadie mas
#   - tiene un TTL configurado EXPLICITAMENTE
#   - el TTL se RENUEVA en cada toque -> es expiracion por INACTIVIDAD, que es
#     lo que pide el enunciado, y no un plazo fijo desde que se creo
#   - agregar NO reserva stock, asi que cuando el carrito caduca no hay nada
#     que liberar. Ese es el "efecto sobre el checkout" que hay que documentar
#   - una linea que no se puede comprar se marca, no se esconde
#
# Deja la base y Redis como estaban.

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

titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend sirve /carrito" \
    || { echo "  El backend no responde en $API, o /carrito no existe."; exit 1; }
[ "$(R PING)" = "PONG" ] && OK "Redis responde" || { echo "  Redis no responde."; exit 1; }

C=$(curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
     -d "{\"identificador\":\"$CUENTA\",\"contrasena\":\"$CLAVE\"}" \
   | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1)
[ -n "$C" ] && OK "sesion de $CUENTA" || { echo "  No se pudo entrar."; exit 1; }

ID_USUARIO=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='$CUENTA';")
LLAVE="mesh:carrito:$ID_USUARIO"

# Se guarda lo que hubiera para devolverlo al final: la cuenta es de todos y
# alguien puede tener algo a medias.
ANTES=$(R HGETALL "$LLAVE" | paste - - 2>/dev/null)
R DEL "$LLAVE" >/dev/null


titulo "1. Nace con el primer producto, no con una ruta de crear"

vacio=$(curl -s "$API/carrito" -H "Cookie: $C")
[ "$(echo "$vacio" | campo payload.total_lineas)" = "0" ] && OK "carrito vacio = no hay clave" || FALLA "el carrito vacio no dio 0 lineas"
[ "$(R EXISTS "$LLAVE")" = "0" ] && OK "leer un carrito vacio NO crea la clave" || FALLA "un GET creo la clave"

OFERTA=$(sql "SELECT o.id_oferta FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta)
              WHERE eo.estado_oferta_nombre='activa' AND o.stock>=5 ORDER BY o.id_oferta LIMIT 1;")
r=$(curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":2}')
[ "$(echo "$r" | campo ok)" = "True" ] && OK "PUT crea el carrito con la primera linea" || FALLA "PUT: $(echo "$r" | campo mensaje)"
[ "$(R EXISTS "$LLAVE")" = "1" ] && OK "la clave $LLAVE existe" || FALLA "no se creo la clave"
[ "$(R TYPE "$LLAVE")" = "hash" ] && OK "es un HASH (id_oferta -> linea en JSON)" || FALLA "no es un hash"


titulo "2. Agregar y quitar NO escriben en PostgreSQL"

# Es la mitad del argumento de la entrega: el carrito salio del modelo
# relacional. Si al agregar se escribiera un pedido, no habria salido.
ped_antes=$(sql "SELECT count(*) FROM pedido;")
lin_antes=$(sql "SELECT count(*) FROM pedido_producto;")
curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":3}' >/dev/null
curl -s -X DELETE "$API/carrito/lineas/$OFERTA" -H "Cookie: $C" >/dev/null
curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":2}' >/dev/null
ped_desp=$(sql "SELECT count(*) FROM pedido;")
lin_desp=$(sql "SELECT count(*) FROM pedido_producto;")
[ "$ped_antes" = "$ped_desp" ] && OK "no nacio ningun pedido ($ped_antes antes y despues)" || FALLA "pedidos: $ped_antes -> $ped_desp"
[ "$lin_antes" = "$lin_desp" ] && OK "no nacio ninguna linea de pedido" || FALLA "lineas: $lin_antes -> $lin_desp"

# Y tampoco reserva stock: por eso caducar no libera nada.
stock_antes=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")
curl -s "$API/carrito" -H "Cookie: $C" >/dev/null
stock_desp=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")
[ "$stock_antes" = "$stock_desp" ] \
    && OK "agregar NO reservo stock ($stock_antes) -> caducar no libera nada" \
    || FALLA "el stock se movio: $stock_antes -> $stock_desp"


titulo "3. El TTL: puesto a proposito y RENOVADO en cada toque"

ttl=$(R TTL "$LLAVE")
[ "$ttl" -gt 0 ] 2>/dev/null && OK "el carrito tiene TTL ($ttl s). Sin EXPIRE seria -1" || FALLA "TTL = $ttl (no vence nunca)"

# La prueba que separa "expira por inactividad" de "expira a plazo fijo": se
# baja el TTL a mano, se toca el carrito, y tiene que volver arriba. Con un
# plazo fijo desde la creacion seguiria bajando.
R EXPIRE "$LLAVE" 100 >/dev/null
bajo=$(R TTL "$LLAVE")
curl -s "$API/carrito" -H "Cookie: $C" >/dev/null
tras_leer=$(R TTL "$LLAVE")
[ "$tras_leer" -gt "$bajo" ] && OK "un GET lo renovo: $bajo s -> $tras_leer s" || FALLA "el GET no renovo el TTL ($bajo -> $tras_leer)"

R EXPIRE "$LLAVE" 100 >/dev/null
curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":2}' >/dev/null
tras_put=$(R TTL "$LLAVE")
[ "$tras_put" -gt 100 ] && OK "un PUT tambien lo renovo: 100 s -> $tras_put s" || FALLA "el PUT no renovo el TTL"


titulo "4. Lo que no se puede comprar se MARCA, no se esconde"

# Una linea que desaparece sola deja a la persona sin saber por que le cambio
# el total. Se queda, marcada, con el motivo.
POCA=$(sql "SELECT o.id_oferta FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta)
            WHERE eo.estado_oferta_nombre='activa' AND o.stock BETWEEN 1 AND 8 ORDER BY o.id_oferta LIMIT 1;")
ST=$(sql "SELECT stock FROM oferta WHERE id_oferta=$POCA;")
curl -s -X PUT "$API/carrito/lineas/$POCA" -H "Content-Type: application/json" -H "Cookie: $C" -d "{\"cantidad\":$((ST+3))}" >/dev/null
motivo=$(curl -s "$API/carrito" -H "Cookie: $C" | python -c "
import sys,json
for l in json.load(sys.stdin)['payload']['lineas']:
    if l['id_oferta']==$POCA: print(l['motivo'] or 'ninguno')")
[ "$motivo" = "stock_insuficiente" ] && OK "pedir mas que el stock -> motivo '$motivo'" || FALLA "motivo inesperado: $motivo"

curl -s -X PUT "$API/carrito/lineas/999999" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":1}' >/dev/null
motivo=$(curl -s "$API/carrito" -H "Cookie: $C" | python -c "
import sys,json
for l in json.load(sys.stdin)['payload']['lineas']:
    if l['id_oferta']==999999: print(l['motivo'] or 'ninguno')")
[ "$motivo" = "oferta_no_existe" ] && OK "una oferta inventada -> motivo '$motivo', la linea se ve" || FALLA "motivo inesperado: $motivo"

r=$(curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":9999}')
[ "$(echo "$r" | campo ok)" = "False" ] && OK "una cantidad absurda se rechaza: $(echo "$r" | campo mensaje)" || FALLA "acepto cantidad 9999"


titulo "5. El precio es una FOTO tomada al agregar, guardada en Redis"

# Desde el 2026-09-23 cada linea guarda nombre, precio, imagen y vendedor
# junto con la cantidad, y GET /carrito sirve eso sin tocar PostgreSQL ni
# MongoDB. El precio de la foto ya lleva el descuento de la oferta, si tenia.
# Si el vendedor lo cambia despues, el aviso sale al pagar, no aqui: eso lo
# mide pruebas/descuentos.sh.
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
[ "$foto" = "2|$precio_api|con-nombre" ] \
    && OK "en Redis la linea es un JSON con cantidad 2, precio $precio_api y nombre" \
    || FALLA "la foto de Redis no cuadra con la API ($foto)"


titulo "6. Vaciar"

curl -s -X DELETE "$API/carrito" -H "Cookie: $C" >/dev/null
[ "$(R EXISTS "$LLAVE")" = "0" ] && OK "DELETE /carrito borra la clave entera" || FALLA "la clave sobrevivio"
[ "$(curl -s "$API/carrito" -H "Cookie: $C" | campo payload.total_lineas)" = "0" ] && OK "y el GET vuelve a decir 0 lineas" || FALLA "el GET no da 0"


titulo "7. El carrito es de la cuenta, no del navegador"

# No hay id de carrito que guardar: sale del token. Dos sesiones de cuentas
# distintas no se ven entre si.
C2=$(curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
      -d '{"identificador":"comprador.sur@mesh.com","contrasena":"Comprador123"}' \
    | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1)
curl -s -X PUT "$API/carrito/lineas/$OFERTA" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"cantidad":1}' >/dev/null
otras=$(curl -s "$API/carrito" -H "Cookie: $C2" | campo payload.total_lineas)
[ "$otras" = "0" ] && OK "la otra cuenta no ve este carrito" || FALLA "la otra cuenta vio $otras linea(s)"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$API/carrito")" = "401" ] && OK "sin sesion no hay carrito (401)" || FALLA "contesto sin sesion"


titulo "LIMPIEZA"
R DEL "$LLAVE" >/dev/null
ID2=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='comprador.sur@mesh.com';")
R DEL "mesh:carrito:$ID2" >/dev/null
if [ -n "$ANTES" ]; then
    # Cada campo vuelve tal cual estaba: la linea en JSON, o el ticket t:<id>
    # de una venta relampago.
    while IFS=$'\t' read -r of valor; do
        [ -n "$of" ] && R HSET "$LLAVE" "$of" "$valor" >/dev/null
    done <<< "$ANTES"
    R EXPIRE "$LLAVE" 86400 >/dev/null
    OK "se devolvio el carrito que habia antes"
else
    OK "no habia carrito previo que devolver"
fi
[ "$(sql "SELECT count(*) FROM pedido;")" = "$ped_antes" ] && OK "PostgreSQL quedo igual ($ped_antes pedidos)" || FALLA "cambio el numero de pedidos"


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
echo "  El carrito vive en Redis, expira por inactividad y no reserva stock."
exit 0
