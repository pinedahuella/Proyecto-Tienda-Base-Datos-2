#!/usr/bin/env bash
# pruebas/descuentos.sh -- los descuentos de una oferta, de punta a punta y A
# TRAVES DEL BACKEND: el vendedor lo pone, el catalogo lo ensena, el carrito lo
# guarda en su foto de Redis y el checkout lo cobra.
#
#   bash pruebas/descuentos.sh
#   DESCUENTO=35 bash pruebas/descuentos.sh
#   OFERTA=549 bash pruebas/descuentos.sh      una oferta concreta
#
# ESTA PRUEBA COMPRA DE VERDAD. Deja UN pedido en PostgreSQL, con su pago, su
# fila de kardex y una unidad menos de stock en la oferta usada. Igual que
# pruebas/falla_checkout.sh, no se deshace: borrar a mano las filas de una
# compra dejaria el kardex mintiendo. Al final se imprime el id del pedido.
#
# POR QUE EXISTE
# ============================================================
# El 2026-09-23 el backend gano descuentos por oferta (POST y DELETE
# /vendedor/ofertas/:id/descuento). La regla es que oferta.precio sigue siendo
# el precio de LISTA y el precio final se calcula en cada consulta, nunca se
# guarda:
#
#     ROUND(precio * (1 - COALESCE(porcentaje_descuento, 0) / 100), 2)
#
# Esa formula vive en muchos sitios a la vez (la ficha, los campos calculados
# de Mongo, la foto del carrito, comprar_pedido(), el pedido). Una copia que se
# escriba distinta cobra otra cosa de la que ensena. Esta prueba pasa por todos
# y compara cada uno contra la misma cuenta.
#
# Toda accion va por HTTP. PostgreSQL, Redis y MongoDB solo se MIRAN.
#
# QUE COMPRUEBA
# ============================================================
#   1. Quien puede. Sin sesion 401, un comprador 403, una oferta ajena 404.
#   2. Las validaciones. 0, 91, 100, -5, 15.505 y "20" como texto dan 400.
#   3. Venta relampago sin descuento da 409 (regla del 2026-09-23).
#   4. Aplicar el descuento da 201. El precio de lista NO cambia y precio_final
#      es la formula. Un segundo descuento da 409.
#   5. precio_historial gana una fila con el % y el precio de lista.
#   6. MongoDB. hay_descuento en true en la variante y en la raiz, y
#      precio_desde y precio_tienda recalculados con el precio final.
#   7. La ficha GET /productos/:id trae el precio final y ordena por el.
#   8. Con el descuento puesto, la venta relampago SI abre, y con ella abierta
#      quitar el descuento da 409. Se cierra la venta antes de seguir.
#   9. El carrito guarda en su foto de Redis el precio con descuento y el %, y
#      GET /carrito los devuelve.
#  10. El vendedor cambia el precio con la linea en el carrito. GET /carrito
#      sigue ensenando la foto (no le pregunta a PostgreSQL), POST
#      /carrito/comprar contesta comprado false con el aviso, y con
#      confirmar_cambios true cobra el precio final NUEVO.
#  11. pago.monto, la fila de precio_historial del pedido y GET
#      /comprador/pedidos/:id cuadran con la formula.
#  12. Quitar el descuento da 200, hay_descuento vuelve a false, y quitarlo
#      otra vez da 409.
#  13. El vencimiento vive en PostgreSQL, `oferta.fecha_vencimiento_descuento`
#      (migracion 028, desde 37ad2e6 de David el 2026-09-26). Un descuento sin
#      duracion la deja en NULL (permanente) y quitarlo la limpia. La clave
#      vieja de Redis `mesh:oferta:<id>:descuento` ya no se crea: era la que
#      hacia que un Redis vaciado se llevara los descuentos permanentes.
#  14. La expiracion. duracion_segundos -1, 604801 y "60" dan 400. Con 6
#      segundos la fecha queda de 1 a 6 s en el futuro, y el worker del backend
#      (cada minuto) quita solo el descuento: porcentaje_descuento vuelve a
#      NULL, la fecha tambien y Mongo a hay_descuento false. Tarda hasta
#      ~70 s.
#
# LO QUE DEJA COMO ESTABA, aunque falle a la mitad (hay un trap): la venta
# relampago cerrada, el precio de lista devuelto, el descuento quitado (en ese
# orden, porque con la venta abierta el backend no deja quitarlo) y el carrito
# de la cuenta compradora como lo tenia. Todo por la API.
#
# La oferta se elige sola: activa, aprobada, de una cuenta ventas.*@mesh.com,
# sin descuento, sin venta relampago, sin ninguna regla de descuento ACTIVA
# (automatica o por periodo: desde el 2026-09-24 excluyen el descuento manual
# con 409), con stock, y de un producto donde
# NINGUNA oferta tenga descuento (si no, hay_descuento no volveria a false al
# quitar el nuestro y la prueba mediria otra oferta). Entre las que cumplen,
# la de la variante con mas ofertas activas, para que el orden de la ficha
# signifique algo.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
REDIS="${REDIS:-mesh-redis}"
MONGO="${MONGO:-mesh-mongo}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
CLAVE_VENDEDOR="${CLAVE_VENDEDOR:-Vendedor123}"
CUENTA="${CUENTA:-compradora.norte@mesh.com}"
CLAVE="${CLAVE:-Comprador123}"
DESCUENTO="${DESCUENTO:-20}"
OFERTA="${OFERTA:-}"
# Nunca 'tarjeta': el cobro simulado rechaza con 402 por motivos suyos (ver
# pruebas/falla_checkout.sh).
METODO="${METODO:-transferencia}"

export MSYS_NO_PATHCONV=1
# Que python lea y escriba UTF-8 aunque la consola de Windows no lo sea: un
# nombre de producto con tilde rompia json.load con el codec por defecto.
export PYTHONUTF8=1

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

# SOLO LECTURA. Ni sql, ni R, ni mongo escriben nada.
sql()   { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" 2>/dev/null | tr -d '\r'; }
R()     { docker exec "$REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'; }
# El JavaScript entra por una variable de entorno, como en pruebas/alertas_login.sh.
mongo() {
    docker exec -e JS="$1" "$MONGO" sh -c 'mongosh --quiet \
        -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
        --authenticationDatabase admin "$MONGO_INITDB_DATABASE" --eval "$JS"' 2>/dev/null | tr -d '\r'
}
campo() { python -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
for k in sys.argv[1].split('.'):
    if d is None: break
    d = d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" "$1"; }

# La formula, en decimal y con el mismo redondeo que ROUND de PostgreSQL
# (la mitad se aleja del cero). Nunca con coma flotante.
final_de() { python -c "
import sys
from decimal import Decimal as D, ROUND_HALF_UP
p = D(sys.argv[1]); c = D(sys.argv[2] or '0')
print((p * (1 - c / 100)).quantize(D('0.01'), rounding=ROUND_HALF_UP))" "$1" "$2"; }

# 1 si los dos textos son el mismo numero ("20" y "20.00" lo son), 0 si no.
# Dos vacios o dos null tambien cuentan como iguales.
mismo_num() { python -c "
import sys
from decimal import Decimal as D
a, b = sys.argv[1], sys.argv[2]
try: print(1 if D(a) == D(b) else 0)
except Exception: print(1 if a == b else 0)" "$1" "$2"; }

entrar() {
    curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
        -d "{\"identificador\":\"$1\",\"contrasena\":\"$2\"}" \
      | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1
}

# Deja el codigo HTTP en CODIGO y el cuerpo en CUERPO. El codigo viaja pegado
# al cuerpo con un separador y sin -o, por la trampa 1 de
# pruebas/falla_checkout.sh. Se llama sin $(...) para que las dos variables
# lleguen a quien llama.
CODIGO=""; CUERPO=""
pedir() {   # METODO RUTA COOKIE [CUERPO_JSON]
    local _args=(-s -m 60 -w $'\n@@@%{http_code}' -X "$1" "$API$2")
    [ -n "$3" ] && _args+=(-H "Cookie: $3")
    [ -n "${4:-}" ] && _args+=(-H "Content-Type: application/json" -d "$4")
    local _todo
    _todo=$(curl "${_args[@]}" 2>/dev/null)
    CODIGO="${_todo##*@@@}"
    CUERPO="${_todo%$'\n'@@@*}"
    [ -z "$CODIGO" ] && CODIGO="000"
    [ "$CUERPO" = "$_todo" ] && CUERPO=""
}
de_cuerpo() { printf '%s' "$CUERPO" | campo "$1"; }

# Lo que MongoDB tiene del producto y la variante de trabajo, en una linea:
#   hay_descuento raiz | hay_descuento variante | precio_desde variante |
#   precio_desde raiz | precio_tienda variante | precio_tienda raiz
mongo_producto() {
    mongo "const d = db.productos.findOne({_id: $PRODUCTO});
           const t = x => (x === null || x === undefined) ? 'null' : x.toString();
           if (!d) { print('sin-producto'); } else {
             const v = (d.variantes || []).find(x => Number(x.id_producto_variante) === $VARIANTE) || {};
             print([t(d.hay_descuento), t(v.hay_descuento), t(v.precio_desde), t(d.precio_desde),
                    t(v.precio_tienda), t(d.precio_tienda)].join('|'));
           }"
}

# Lo mismo, calculado en PostgreSQL con la formula, para comparar. Mismas
# reglas que el recalculo del backend: precio_desde es el menor precio final
# entre las ofertas ACTIVAS; precio_tienda el de la oferta de la tienda.
FORMULA="ROUND(o.precio * (1 - COALESCE(o.porcentaje_descuento, 0) / 100), 2)"
esperado_desde_variante() { sql "SELECT COALESCE(MIN($FORMULA)::text, 'null') FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta)
                                 WHERE o.id_producto_mongo=$PRODUCTO AND o.id_producto_variante_mongo=$VARIANTE AND eo.estado_oferta_nombre='activa';"; }
esperado_desde_raiz()     { sql "SELECT COALESCE(MIN($FORMULA)::text, 'null') FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta)
                                 WHERE o.id_producto_mongo=$PRODUCTO AND eo.estado_oferta_nombre='activa';"; }
esperado_tienda_variante() { sql "SELECT COALESCE(MAX($FORMULA)::text, 'null') FROM oferta o JOIN usuarios u ON u.id_usuario=o.id_usuario
                                  WHERE o.id_producto_mongo=$PRODUCTO AND o.id_producto_variante_mongo=$VARIANTE AND u.correo_electronico='tienda@mesh.com';"; }

# Revisa Mongo contra PostgreSQL. $1 = el hay_descuento que se espera.
revisar_mongo() {
    local foto hd_r hd_v pd_v pd_r pt_v
    foto=$(mongo_producto)
    if [ -z "$foto" ] || [ "$foto" = "sin-producto" ]; then
        FALLA "no se pudo leer el producto $PRODUCTO en MongoDB ($foto)"
        return
    fi
    IFS='|' read -r hd_r hd_v pd_v pd_r pt_v _ <<< "$foto"
    [ "$hd_v" = "$1" ] && OK "Mongo, hay_descuento de la variante $VARIANTE = $hd_v" || FALLA "Mongo, hay_descuento de la variante = $hd_v y se esperaba $1"
    [ "$hd_r" = "$1" ] && OK "Mongo, hay_descuento de la raiz = $hd_r" || FALLA "Mongo, hay_descuento de la raiz = $hd_r y se esperaba $1"
    local e_v e_r e_t
    e_v=$(esperado_desde_variante); e_r=$(esperado_desde_raiz); e_t=$(esperado_tienda_variante)
    [ "$(mismo_num "$pd_v" "$e_v")" = "1" ] && OK "Mongo, precio_desde de la variante = $pd_v, el menor precio final" || FALLA "Mongo, precio_desde de la variante = $pd_v y con la formula da $e_v"
    [ "$(mismo_num "$pd_r" "$e_r")" = "1" ] && OK "Mongo, precio_desde de la raiz = $pd_r" || FALLA "Mongo, precio_desde de la raiz = $pd_r y con la formula da $e_r"
    [ "$(mismo_num "$pt_v" "$e_t")" = "1" ] && OK "Mongo, precio_tienda de la variante = $pt_v" || FALLA "Mongo, precio_tienda de la variante = $pt_v y con la formula da $e_t"
}


# ============================================================
# La limpieza, que corre pase lo que pase
# ============================================================
# El orden importa: con la venta relampago abierta el backend no deja quitar
# el descuento, asi que primero se cierra la venta, despues vuelve el precio y
# al final se quita el descuento. El carrito se devuelve por la API, que vuelve
# a tomar la foto de cada linea.
VENTA_ABIERTA=0
PRECIO_CAMBIADO=0
DESCUENTO_PUESTO=0
CARRITO_TOCADO=0
ANTES=""
PEDIDO=""
LIMPIO=0
limpiar() {
    [ "$LIMPIO" = "1" ] && return
    LIMPIO=1
    echo
    echo "=============================================================="
    echo "DEJANDO LA OFERTA Y EL CARRITO COMO ESTABAN"
    echo "=============================================================="
    if [ "$VENTA_ABIERTA" = "1" ]; then
        pedir DELETE "/vendedor/ofertas/$OFERTA/venta-limitada" "$VEND"
        echo "  venta relampago cerrada (HTTP $CODIGO)"
    fi
    if [ "$PRECIO_CAMBIADO" = "1" ]; then
        pedir PATCH "/vendedor/ofertas/$OFERTA" "$VEND" "{\"precio\":\"$PRECIO\"}"
        echo "  precio de lista devuelto a $PRECIO (HTTP $CODIGO)"
    fi
    if [ "$DESCUENTO_PUESTO" = "1" ]; then
        pedir DELETE "/vendedor/ofertas/$OFERTA/descuento" "$VEND"
        echo "  descuento quitado (HTTP $CODIGO)"
    fi
    if [ "$CARRITO_TOCADO" = "1" ]; then
        pedir DELETE "/carrito" "$C"
        local n=0 of linea cant
        if [ -n "$ANTES" ]; then
            while IFS=$'\t' read -r of linea; do
                case "$of" in ''|*[!0-9]*) continue ;; esac
                cant=$(printf '%s' "$linea" | python -c "
import sys,json
try: print(int(json.loads(sys.stdin.read())['cantidad']))
except Exception: print('')")
                [ -n "$cant" ] || continue
                pedir PUT "/carrito/lineas/$of" "$C" "{\"cantidad\":$cant}"
                n=$((n+1))
            done <<< "$ANTES"
        fi
        echo "  carrito de $CUENTA devuelto por la API ($n lineas)"
    fi
    if [ -n "$PEDIDO" ]; then
        echo
        echo "  Esta corrida compro de verdad. El pedido que dejo es el $PEDIDO."
    fi
}
trap limpiar EXIT
# En el bash de Git el trap de EXIT NO corre si al arnes lo matan con una
# senal (timeout, Ctrl+C, cerrar la terminal): se probo el 2026-09-23 y una
# corrida cortada por timeout dejo la oferta con su descuento puesto. Con la
# senal atrapada, el exit de aqui abajo si pasa por limpiar.
trap 'exit 130' INT TERM HUP


# ============================================================
titulo "0. Todo arriba"
# ============================================================
pedir GET "/carrito" ""
[ "$CODIGO" = "401" ] && OK "el backend sirve /carrito y pide sesion" || { echo "  El backend no responde en $API (HTTP $CODIGO)."; exit 1; }
[ "$(R PING)" = "PONG" ] && OK "Redis responde" || { echo "  Redis no responde."; exit 1; }
[ -n "$(mongo 'print(1)')" ] && OK "MongoDB responde" || { echo "  MongoDB no responde."; exit 1; }
[ "$(sql "SELECT count(*) FROM information_schema.columns WHERE table_name IN ('oferta','precio_historial') AND column_name='porcentaje_descuento';")" = "2" ] \
    && OK "oferta y precio_historial tienen porcentaje_descuento" \
    || { echo "  Falta la columna porcentaje_descuento. Aplica la migracion de descuentos."; exit 1; }


# ============================================================
titulo "1. La oferta de trabajo y las sesiones"
# ============================================================
if [ -n "$OFERTA" ]; then
    CANDIDATAS="$OFERTA"
else
    CANDIDATAS=$(sql "SELECT o.id_oferta
        FROM oferta o
        JOIN estado_oferta eo USING(id_estado_oferta)
        JOIN usuarios u ON u.id_usuario = o.id_usuario
        WHERE eo.estado_oferta_nombre = 'activa'
          AND o.fecha_aprobacion IS NOT NULL
          AND o.porcentaje_descuento IS NULL
          AND NOT o.es_inventario_limitado
          AND o.stock >= 3
          AND u.correo_electronico LIKE 'ventas.%@mesh.com'
          AND NOT EXISTS (SELECT 1 FROM regla_descuento_automatico ra
                          WHERE ra.id_oferta = o.id_oferta AND ra.activa)
          AND NOT EXISTS (SELECT 1 FROM regla_descuento_periodo rp
                          WHERE rp.id_oferta = o.id_oferta AND rp.activa)
          AND NOT EXISTS (SELECT 1 FROM oferta x
                          WHERE x.id_producto_mongo = o.id_producto_mongo
                            AND x.porcentaje_descuento IS NOT NULL)
        ORDER BY (SELECT count(*) FROM oferta y JOIN estado_oferta ey USING(id_estado_oferta)
                  WHERE y.id_producto_mongo = o.id_producto_mongo
                    AND y.id_producto_variante_mongo = o.id_producto_variante_mongo
                    AND ey.estado_oferta_nombre = 'activa') DESC, o.id_oferta
        LIMIT 10;")
fi

# De las candidatas, la primera cuya ficha se ve y cuya variante esta activa:
# si no, el carrito la marcaria como no disponible y no se podria comprar.
OFERTA=""
for cand in $CANDIDATAS; do
    fila=$(sql "SELECT id_producto_mongo || '|' || id_producto_variante_mongo FROM oferta WHERE id_oferta=$cand;")
    p="${fila%%|*}"; v="${fila##*|}"
    [ -n "$p" ] || continue
    pedir GET "/productos/$p" ""
    [ "$CODIGO" = "200" ] || continue
    visible=$(printf '%s' "$CUERPO" | python -c "
import sys,json
d = json.load(sys.stdin)['payload']
var = [x for x in d.get('variantes', []) if str(x.get('id_producto_variante')) == '$v']
ofe = [x for x in d.get('ofertas', []) if str(x.get('id_oferta')) == '$cand']
print('si' if var and var[0].get('estado') == 'activa' and ofe else 'no')" 2>/dev/null)
    if [ "$visible" = "si" ]; then
        OFERTA="$cand"; PRODUCTO="$p"; VARIANTE="$v"
        break
    fi
done
[ -n "$OFERTA" ] || { echo "  No hay ninguna oferta que cumpla las condiciones de la cabecera."; exit 1; }

VID=$(sql "SELECT id_usuario FROM oferta WHERE id_oferta=$OFERTA;")
VEND_CORREO=$(sql "SELECT correo_electronico FROM usuarios WHERE id_usuario=$VID;")
PRECIO=$(sql "SELECT precio FROM oferta WHERE id_oferta=$OFERTA;")
STOCK=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")
OK "oferta $OFERTA de $VEND_CORREO, producto $PRODUCTO variante $VARIANTE, Q$PRECIO de lista, $STOCK unidades"

if [ -n "$(sql "SELECT porcentaje_descuento FROM oferta WHERE id_oferta=$OFERTA;")" ]; then
    echo "  La oferta $OFERTA ya tiene un descuento. Quitalo o elige otra con OFERTA=."
    exit 1
fi
if [ "$(sql "SELECT es_inventario_limitado FROM oferta WHERE id_oferta=$OFERTA;")" = "t" ]; then
    echo "  La oferta $OFERTA esta en venta relampago. Cierrala o elige otra con OFERTA=."
    exit 1
fi

VEND=$(entrar "$VEND_CORREO" "$CLAVE_VENDEDOR")
[ -n "$VEND" ] && OK "sesion del vendedor $VEND_CORREO" || { echo "  No se pudo entrar como $VEND_CORREO."; exit 1; }
C=$(entrar "$CUENTA" "$CLAVE")
[ -n "$C" ] && OK "sesion de $CUENTA" || { echo "  No se pudo entrar como $CUENTA."; exit 1; }
ID_USUARIO=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='$CUENTA';")
LLAVE="mesh:carrito:$ID_USUARIO"

AJENA=$(sql "SELECT id_oferta FROM oferta WHERE id_usuario <> $VID ORDER BY id_oferta LIMIT 1;")
FINAL_1=$(final_de "$PRECIO" "$DESCUENTO")
echo "  con $DESCUENTO% el precio final tiene que ser $FINAL_1"


# ============================================================
titulo "2. Quien puede poner un descuento"
# ============================================================
pedir POST "/vendedor/ofertas/$OFERTA/descuento" "" "{\"porcentaje_descuento\":$DESCUENTO}"
[ "$CODIGO" = "401" ] && OK "sin sesion, 401" || FALLA "sin sesion contesto $CODIGO"
pedir DELETE "/vendedor/ofertas/$OFERTA/descuento" ""
[ "$CODIGO" = "401" ] && OK "quitarlo sin sesion, 401" || FALLA "quitarlo sin sesion contesto $CODIGO"
pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$C" "{\"porcentaje_descuento\":$DESCUENTO}"
[ "$CODIGO" = "403" ] && OK "con sesion de comprador, 403" || FALLA "un comprador obtuvo $CODIGO"
if [ -n "$AJENA" ]; then
    pedir POST "/vendedor/ofertas/$AJENA/descuento" "$VEND" "{\"porcentaje_descuento\":$DESCUENTO}"
    [ "$CODIGO" = "404" ] && OK "sobre la oferta ajena $AJENA, 404 (no confirma que exista)" || FALLA "sobre una oferta ajena contesto $CODIGO"
fi


# ============================================================
titulo "3. Las validaciones dan 400 y no tocan nada"
# ============================================================
for malo in 0 91 100 -5 15.505 '"20"'; do
    pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$VEND" "{\"porcentaje_descuento\":$malo}"
    [ "$CODIGO" = "400" ] && OK "porcentaje_descuento $malo, 400" || FALLA "porcentaje_descuento $malo contesto $CODIGO"
done
[ -z "$(sql "SELECT porcentaje_descuento FROM oferta WHERE id_oferta=$OFERTA;")" ] \
    && OK "la oferta sigue sin descuento tras los rechazos" \
    || FALLA "un rechazo dejo un descuento puesto"


# ============================================================
titulo "4. Venta relampago sin descuento, 409"
# ============================================================
pedir POST "/vendedor/ofertas/$OFERTA/venta-limitada" "$VEND" '{}'
if [ "$CODIGO" = "409" ]; then
    OK "abrir la venta relampago sin descuento da 409"
    echo "        $(de_cuerpo mensaje)"
else
    FALLA "abrir la venta relampago sin descuento contesto $CODIGO y no 409"
    [ "$CODIGO" = "201" ] && VENTA_ABIERTA=1
    if [ "$VENTA_ABIERTA" = "1" ]; then
        pedir DELETE "/vendedor/ofertas/$OFERTA/venta-limitada" "$VEND"
        [ "$CODIGO" = "200" ] && VENTA_ABIERTA=0
    fi
fi


# ============================================================
titulo "5. Aplicar el descuento"
# ============================================================
H0=$(sql "SELECT count(*) FROM precio_historial WHERE id_oferta=$OFERTA;")
DESDE_ANTES=$(esperado_desde_variante)

pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$VEND" "{\"porcentaje_descuento\":$DESCUENTO}"
if [ "$CODIGO" = "201" ]; then
    DESCUENTO_PUESTO=1
    OK "POST /vendedor/ofertas/$OFERTA/descuento, 201"
else
    FALLA "aplicar el descuento contesto $CODIGO, $(de_cuerpo mensaje)"
    echo "  Sin descuento lo que sigue no mide nada."
    exit 1
fi
r_precio=$(de_cuerpo payload.precio); r_pct=$(de_cuerpo payload.porcentaje_descuento); r_final=$(de_cuerpo payload.precio_final)
[ "$r_precio" = "$PRECIO" ] && OK "el precio de lista no cambio ($r_precio)" || FALLA "el precio de lista paso de $PRECIO a $r_precio"
[ "$(mismo_num "$r_pct" "$DESCUENTO")" = "1" ] && OK "porcentaje_descuento = $r_pct" || FALLA "porcentaje_descuento = $r_pct"
[ "$r_final" = "$FINAL_1" ] && OK "precio_final = $r_final, la formula" || FALLA "precio_final = $r_final y la formula da $FINAL_1"
[ "$(sql "SELECT precio FROM oferta WHERE id_oferta=$OFERTA;")" = "$PRECIO" ] \
    && OK "en PostgreSQL oferta.precio sigue en $PRECIO" || FALLA "oferta.precio cambio en PostgreSQL"

pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$VEND" '{"porcentaje_descuento":10}'
[ "$CODIGO" = "409" ] && OK "un segundo descuento sobre la misma oferta, 409" || FALLA "el segundo descuento contesto $CODIGO"
[ "$(mismo_num "$(sql "SELECT porcentaje_descuento FROM oferta WHERE id_oferta=$OFERTA;")" "$DESCUENTO")" = "1" ] \
    && OK "y el descuento sigue siendo el primero" || FALLA "el segundo descuento piso al primero"

# Lo que mira el worker de vencimiento: la fecha en PostgreSQL. Sin duracion,
# NULL. Y ninguna clave en Redis, que era la que se perdia con un FLUSHALL.
CLAVE_DESC="mesh:oferta:$OFERTA:descuento"
VENCE="SELECT COALESCE(fecha_vencimiento_descuento::text, 'null') FROM oferta WHERE id_oferta=$OFERTA;"
[ "$(sql "$VENCE")" = "null" ] && OK "fecha_vencimiento_descuento en NULL, permanente, porque no se pidio duracion" \
    || FALLA "fecha_vencimiento_descuento es '$(sql "$VENCE")' y el descuento era sin duracion (falta la 028?)"
sleep 1
[ "$(R EXISTS "$CLAVE_DESC")" = "0" ] && OK "y no depende de Redis, no hay $CLAVE_DESC" \
    || FALLA "aparecio $CLAVE_DESC: el backend corriendo es anterior a 37ad2e6"


# ============================================================
titulo "6. precio_historial gana una fila con el %"
# ============================================================
H1=$(sql "SELECT count(*) FROM precio_historial WHERE id_oferta=$OFERTA;")
[ "$H1" = "$((H0+1))" ] && OK "una fila nueva ($H0 -> $H1)" || FALLA "precio_historial paso de $H0 a $H1 filas"
ult=$(sql "SELECT precio || '|' || COALESCE(porcentaje_descuento::text, 'null') FROM precio_historial WHERE id_oferta=$OFERTA ORDER BY id_precio_historial DESC LIMIT 1;")
[ "${ult%%|*}" = "$PRECIO" ] && OK "la fila guarda el precio de lista ($PRECIO)" || FALLA "la fila guarda precio ${ult%%|*}"
[ "$(mismo_num "${ult##*|}" "$DESCUENTO")" = "1" ] && OK "y el % aparte (${ult##*|})" || FALLA "la fila guarda porcentaje ${ult##*|}"


# ============================================================
titulo "7. MongoDB recalculo el catalogo"
# ============================================================
revisar_mongo true
DESDE_AHORA=$(esperado_desde_variante)
[ "$DESDE_AHORA" != "$DESDE_ANTES" ] && echo "        precio_desde de la variante bajo de $DESDE_ANTES a $DESDE_AHORA con el descuento"


# ============================================================
titulo "8. La ficha publica ensena el precio final y ordena por el"
# ============================================================
pedir GET "/productos/$PRODUCTO" ""
ficha=$(printf '%s' "$CUERPO" | python -c "
import sys,json
from decimal import Decimal as D
d = json.load(sys.stdin)['payload']
ofe = [x for x in d.get('ofertas', []) if str(x.get('id_producto_variante_mongo')) == '$VARIANTE']
mia = [x for x in ofe if str(x.get('id_oferta')) == '$OFERTA']
finales = [D(x['precio_final']) for x in ofe]
en_orden = all(finales[i] <= finales[i+1] for i in range(len(finales)-1))
if not mia: print('no-esta'); sys.exit()
m = mia[0]
print('|'.join([str(m.get('precio')), str(m.get('porcentaje_descuento')), str(m.get('precio_final')),
                'si' if en_orden else 'no', str(ofe.index(m)+1), str(len(ofe)),
                'si' if d.get('hay_descuento') else 'no']))" 2>/dev/null)
if [ -z "$ficha" ] || [ "$ficha" = "no-esta" ]; then
    FALLA "la oferta $OFERTA no sale en GET /productos/$PRODUCTO (HTTP $CODIGO)"
else
    IFS='|' read -r f_precio f_pct f_final f_orden f_pos f_total f_hd <<< "$ficha"
    [ "$f_precio" = "$PRECIO" ] && OK "la ficha trae el precio de lista ($f_precio)" || FALLA "la ficha trae precio $f_precio"
    [ "$(mismo_num "$f_pct" "$DESCUENTO")" = "1" ] && OK "y porcentaje_descuento $f_pct" || FALLA "la ficha trae porcentaje $f_pct"
    [ "$f_final" = "$FINAL_1" ] && OK "y precio_final $f_final" || FALLA "la ficha trae precio_final $f_final y la formula da $FINAL_1"
    [ "$f_orden" = "si" ] && OK "las $f_total ofertas de la variante van de menor a mayor precio FINAL (la nuestra es la $f_pos)" || FALLA "las ofertas de la variante no van ordenadas por precio final"
    [ "$f_hd" = "si" ] && OK "la ficha trae hay_descuento en true" || FALLA "la ficha no trae hay_descuento en true"
fi


# ============================================================
titulo "9. Venta relampago con descuento: abre, y el descuento no se quita"
# ============================================================
pedir POST "/vendedor/ofertas/$OFERTA/venta-limitada" "$VEND" '{}'
if [ "$CODIGO" = "201" ]; then
    VENTA_ABIERTA=1
    OK "con el descuento puesto la venta relampago abre (201, $(de_cuerpo payload.stock_sembrado) unidades sembradas)"

    pedir DELETE "/vendedor/ofertas/$OFERTA/descuento" "$VEND"
    if [ "$CODIGO" = "409" ]; then
        OK "quitar el descuento con la venta abierta da 409"
        echo "        $(de_cuerpo mensaje)"
    else
        FALLA "quitar el descuento con la venta abierta contesto $CODIGO"
        [ "$CODIGO" = "200" ] && DESCUENTO_PUESTO=0
    fi
    [ "$(mismo_num "$(sql "SELECT porcentaje_descuento FROM oferta WHERE id_oferta=$OFERTA;")" "$DESCUENTO")" = "1" ] \
        && OK "el descuento sigue puesto" || FALLA "el descuento desaparecio con la venta abierta"

    pedir DELETE "/vendedor/ofertas/$OFERTA/venta-limitada" "$VEND"
    if [ "$CODIGO" = "200" ]; then
        VENTA_ABIERTA=0
        OK "venta relampago cerrada (200) antes de seguir"
    else
        FALLA "no se pudo cerrar la venta relampago ($CODIGO), lo que sigue no se puede creer"
        exit 1
    fi
    [ "$(R EXISTS "mesh:oferta:$OFERTA")" = "0" ] && OK "sus claves de Redis ya no estan" || FALLA "las claves mesh:oferta:$OFERTA siguen en Redis"
else
    FALLA "con el descuento puesto la venta relampago no abrio ($CODIGO), $(de_cuerpo mensaje)"
fi

# Si el descuento se cayo en el paso anterior, lo que sigue ya no mide nada.
[ "$DESCUENTO_PUESTO" = "1" ] || { echo "  El descuento ya no esta puesto, no se sigue."; exit 1; }


# ============================================================
titulo "10. El carrito guarda el precio con descuento en su foto de Redis"
# ============================================================
# Lo que la cuenta tuviera a medias se guarda y vuelve al final por la API.
ANTES=$(R HGETALL "$LLAVE" | paste - - 2>/dev/null)
CARRITO_TOCADO=1
pedir DELETE "/carrito" "$C"

pedir PUT "/carrito/lineas/$OFERTA" "$C" '{"cantidad":1}'
[ "$(de_cuerpo ok)" = "True" ] && OK "PUT /carrito/lineas/$OFERTA, 1 unidad" || FALLA "PUT al carrito: $(de_cuerpo mensaje)"

foto=$(R HGET "$LLAVE" "$OFERTA" | python -c "
import sys,json
try: d = json.loads(sys.stdin.read())
except Exception: print('no-es-json'); sys.exit()
print('%s|%s|%s' % (d.get('precio'), d.get('porcentaje_descuento'), d.get('cantidad')))")
IFS='|' read -r fo_precio fo_pct fo_cant <<< "$foto"
[ "$fo_precio" = "$FINAL_1" ] && OK "la foto de Redis guarda precio $fo_precio, ya con el descuento" || FALLA "la foto de Redis guarda precio $fo_precio ($foto)"
[ "$(mismo_num "$fo_pct" "$DESCUENTO")" = "1" ] && OK "y el % aparte ($fo_pct)" || FALLA "la foto guarda porcentaje $fo_pct"

pedir GET "/carrito" "$C"
lin=$(printf '%s' "$CUERPO" | python -c "
import sys,json
for l in json.load(sys.stdin)['payload']['lineas']:
    if str(l['id_oferta']) == '$OFERTA':
        print('%s|%s|%s|%s' % (l['precio'], l['porcentaje_descuento'], l['subtotal'], l['disponible']))" 2>/dev/null)
IFS='|' read -r g_precio g_pct g_sub g_disp <<< "$lin"
[ "$g_precio" = "$FINAL_1" ] && OK "GET /carrito devuelve precio $g_precio" || FALLA "GET /carrito devuelve precio $g_precio"
[ "$(mismo_num "$g_pct" "$DESCUENTO")" = "1" ] && OK "y porcentaje_descuento $g_pct" || FALLA "GET /carrito devuelve porcentaje $g_pct"
[ "$g_sub" = "$FINAL_1" ] && OK "subtotal $g_sub para 1 unidad" || FALLA "subtotal $g_sub"
[ "$g_disp" = "True" ] && OK "la linea esta disponible" || FALLA "la linea salio no disponible, no se podra comprar"


# ============================================================
titulo "11. El vendedor cambia el precio con la linea en el carrito"
# ============================================================
NUEVO=$(python -c "from decimal import Decimal as D; print(D('$PRECIO') + D('10.00'))")
FINAL_2=$(final_de "$NUEVO" "$DESCUENTO")
pedir PATCH "/vendedor/ofertas/$OFERTA" "$VEND" "{\"precio\":\"$NUEVO\"}"
if [ "$CODIGO" = "200" ]; then
    PRECIO_CAMBIADO=1
    OK "PATCH del precio de lista a $NUEVO (200)"
else
    FALLA "no se pudo cambiar el precio ($CODIGO), $(de_cuerpo mensaje)"
    exit 1
fi
[ "$(de_cuerpo payload.precio_final)" = "$FINAL_2" ] \
    && OK "la oferta responde precio_final $FINAL_2, el descuento sigue sobre el precio nuevo" \
    || FALLA "precio_final $(de_cuerpo payload.precio_final) y la formula da $FINAL_2"

# GET /carrito solo lee Redis: tiene que seguir ensenando la foto.
pedir GET "/carrito" "$C"
visto=$(printf '%s' "$CUERPO" | python -c "
import sys,json
for l in json.load(sys.stdin)['payload']['lineas']:
    if str(l['id_oferta']) == '$OFERTA': print(l['precio'])" 2>/dev/null)
[ "$visto" = "$FINAL_1" ] && OK "GET /carrito sigue en $visto, la foto, sin preguntarle a PostgreSQL" || FALLA "GET /carrito ensena $visto y la foto era $FINAL_1"

DIRECCION=$(curl -s "$API/direccion-usuario" -H "Cookie: $C" | python -c "
import sys,json
try: d = json.load(sys.stdin).get('payload') or []
except Exception: d = []
print(d[0]['id_direccion'] if d else '')")
[ -n "$DIRECCION" ] || { FALLA "$CUENTA no tiene direccion, no se puede pagar"; exit 1; }

ped_antes=$(sql "SELECT count(*) FROM pedido WHERE id_usuario=$ID_USUARIO;")
pedir POST "/carrito/comprar" "$C" "{\"id_direccion\":\"$DIRECCION\",\"metodo_pago\":\"$METODO\"}"
aviso=$(printf '%s' "$CUERPO" | python -c "
import sys,json
p = json.load(sys.stdin).get('payload') or {}
av = [a for a in (p.get('avisos') or []) if str(a.get('id_oferta')) == '$OFERTA']
print('%s|%s|%s' % (p.get('comprado'), av[0]['precio_visto'] if av else '', av[0]['precio_actual'] if av else ''))" 2>/dev/null)
IFS='|' read -r a_comprado a_visto a_actual <<< "$aviso"
[ "$CODIGO" = "201" ] && [ "$a_comprado" = "False" ] && OK "POST /carrito/comprar sin confirmar, comprado false" || FALLA "sin confirmar contesto $CODIGO con comprado $a_comprado"
[ "$a_visto" = "$FINAL_1" ] && [ "$a_actual" = "$FINAL_2" ] \
    && OK "el aviso dice $a_visto visto y $a_actual ahora, los dos con descuento" \
    || FALLA "el aviso dice visto '$a_visto' y actual '$a_actual'; se esperaba $FINAL_1 y $FINAL_2"
[ "$(sql "SELECT count(*) FROM pedido WHERE id_usuario=$ID_USUARIO;")" = "$ped_antes" ] && OK "no se creo ningun pedido" || FALLA "se creo un pedido sin confirmar"
[ "$(R EXISTS "$LLAVE")" = "1" ] && OK "el carrito sigue entero" || FALLA "el carrito se perdio sin comprar"

pedir POST "/carrito/comprar" "$C" "{\"id_direccion\":\"$DIRECCION\",\"metodo_pago\":\"$METODO\",\"confirmar_cambios\":true}"
if [ "$CODIGO" = "201" ] && [ "$(de_cuerpo payload.comprado)" = "True" ]; then
    PEDIDO=$(de_cuerpo payload.id_pedido)
    OK "con confirmar_cambios true compro (pedido $PEDIDO)"
else
    FALLA "con confirmar_cambios true contesto $CODIGO, $(de_cuerpo mensaje)"
fi
TOTAL=$(de_cuerpo payload.total)
[ "$(mismo_num "$TOTAL" "$FINAL_2")" = "1" ] && OK "cobro $TOTAL, el precio final NUEVO" || FALLA "cobro $TOTAL y el precio final nuevo es $FINAL_2"
[ "$(R EXISTS "$LLAVE")" = "0" ] && OK "el carrito se vacio tras comprar" || FALLA "el carrito sigue lleno despues de comprar"


# ============================================================
titulo "12. El pedido cuadra con la formula"
# ============================================================
if [ -n "$PEDIDO" ]; then
    MONTO=$(sql "SELECT monto FROM pago WHERE id_pedido=$PEDIDO;")
    [ "$(mismo_num "$MONTO" "$FINAL_2")" = "1" ] && OK "pago.monto = $MONTO" || FALLA "pago.monto = $MONTO y el precio final es $FINAL_2"
    ph=$(sql "SELECT ph.precio || '|' || COALESCE(ph.porcentaje_descuento::text, 'null') || '|' ||
                     (ROUND(ph.precio * (1 - COALESCE(ph.porcentaje_descuento, 0) / 100), 2) * pp.cantidad)
              FROM pedido_producto pp JOIN precio_historial ph USING(id_precio_historial)
              WHERE pp.id_pedido=$PEDIDO;")
    IFS='|' read -r ph_precio ph_pct ph_linea <<< "$ph"
    [ "$ph_precio" = "$NUEVO" ] && OK "la linea apunta a la fila de precio_historial con el precio de lista nuevo ($ph_precio)" || FALLA "la linea apunta a precio $ph_precio"
    [ "$(mismo_num "$ph_pct" "$DESCUENTO")" = "1" ] && OK "y con el % guardado aparte ($ph_pct)" || FALLA "la fila de la linea guarda porcentaje $ph_pct"
    [ "$(mismo_num "$ph_linea" "$MONTO")" = "1" ] && OK "la formula sobre esa fila da $ph_linea, lo mismo que se cobro" || FALLA "la formula sobre la fila da $ph_linea y se cobro $MONTO"

    pedir GET "/comprador/pedidos/$PEDIDO" "$C"
    det=$(printf '%s' "$CUERPO" | python -c "
import sys,json
d = (json.load(sys.stdin).get('payload') or {}).get('detalles') or []
print('%s|%s' % (d[0].get('precio_unitario'), d[0].get('porcentaje_descuento_aplicado')) if d else '')" 2>/dev/null)
    IFS='|' read -r d_unit d_pct <<< "$det"
    [ "$d_unit" = "$FINAL_2" ] && OK "GET /comprador/pedidos/$PEDIDO trae precio_unitario $d_unit" || FALLA "el pedido trae precio_unitario $d_unit"
    [ "$(mismo_num "$d_pct" "$DESCUENTO")" = "1" ] && OK "y porcentaje_descuento_aplicado $d_pct" || FALLA "el pedido trae porcentaje_descuento_aplicado $d_pct"
else
    FALLA "no hubo pedido, no hay nada que cuadrar"
fi


# ============================================================
titulo "13. El precio vuelve y el descuento se quita"
# ============================================================
pedir PATCH "/vendedor/ofertas/$OFERTA" "$VEND" "{\"precio\":\"$PRECIO\"}"
[ "$CODIGO" = "200" ] && { PRECIO_CAMBIADO=0; OK "precio de lista devuelto a $PRECIO"; } || FALLA "no se pudo devolver el precio ($CODIGO)"

pedir DELETE "/vendedor/ofertas/$OFERTA/descuento" "$VEND"
if [ "$CODIGO" = "200" ]; then
    DESCUENTO_PUESTO=0
    OK "DELETE /vendedor/ofertas/$OFERTA/descuento, 200"
else
    FALLA "quitar el descuento contesto $CODIGO, $(de_cuerpo mensaje)"
fi
[ -z "$(de_cuerpo payload.porcentaje_descuento)" ] && OK "porcentaje_descuento en null" || FALLA "porcentaje_descuento quedo en $(de_cuerpo payload.porcentaje_descuento)"
[ "$(de_cuerpo payload.precio_final)" = "$PRECIO" ] && OK "precio_final vuelve a ser el de lista ($PRECIO)" || FALLA "precio_final $(de_cuerpo payload.precio_final)"
[ "$(sql "SELECT COALESCE(porcentaje_descuento::text, 'null') FROM precio_historial WHERE id_oferta=$OFERTA ORDER BY id_precio_historial DESC LIMIT 1;")" = "null" ] \
    && OK "precio_historial registra la fila sin descuento" || FALLA "la ultima fila de precio_historial sigue con descuento"

revisar_mongo false

pedir DELETE "/vendedor/ofertas/$OFERTA/descuento" "$VEND"
[ "$CODIGO" = "409" ] && OK "quitar un descuento que ya no esta, 409" || FALLA "quitarlo otra vez contesto $CODIGO"
sleep 1
[ "$(sql "$VENCE")" = "null" ] && OK "quitarlo deja fecha_vencimiento_descuento en NULL" || FALLA "fecha_vencimiento_descuento quedo en $(sql "$VENCE") despues de quitar el descuento"


# ============================================================
titulo "14. Un descuento con duracion se quita solo"
# ============================================================
# Lo quita VentasLimitadasService.revisarDescuentosVencidos, un @Interval de
# 60 s. Se espera hasta 90 s: un minuto del worker y margen para el recalculo
# de Mongo.
for malo in -1 604801 '"60"'; do
    pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$VEND" "{\"porcentaje_descuento\":$DESCUENTO,\"duracion_segundos\":$malo}"
    [ "$CODIGO" = "400" ] && OK "duracion_segundos $malo, 400" || FALLA "duracion_segundos $malo contesto $CODIGO"
done
[ -z "$(sql "SELECT porcentaje_descuento FROM oferta WHERE id_oferta=$OFERTA;")" ] \
    && OK "ninguna de esas puso descuento" || FALLA "una duracion invalida dejo el descuento puesto"

pedir POST "/vendedor/ofertas/$OFERTA/descuento" "$VEND" "{\"porcentaje_descuento\":$DESCUENTO,\"duracion_segundos\":6}"
if [ "$CODIGO" = "201" ]; then
    DESCUENTO_PUESTO=1
    OK "descuento con duracion_segundos 6, 201"
    faltan=$(sql "SELECT ceil(extract(epoch FROM fecha_vencimiento_descuento - now()))::int FROM oferta WHERE id_oferta=$OFERTA;")
    case "$faltan" in
        [0-6]) OK "fecha_vencimiento_descuento a $faltan s (6 como mucho)" ;;
        *)     FALLA "fecha_vencimiento_descuento a '$faltan' s y se pidieron 6 segundos" ;;
    esac

    quitado=0
    for _ in $(seq 1 18); do
        sleep 5
        if [ -z "$(sql "SELECT porcentaje_descuento FROM oferta WHERE id_oferta=$OFERTA;")" ]; then
            quitado=1; break
        fi
    done
    if [ "$quitado" = "1" ]; then
        DESCUENTO_PUESTO=0
        OK "el worker lo quito solo al llegar la fecha"
        [ "$(sql "$VENCE")" = "null" ] && OK "y limpio fecha_vencimiento_descuento" || FALLA "fecha_vencimiento_descuento quedo en $(sql "$VENCE")"
        [ "$(sql "SELECT COALESCE(porcentaje_descuento::text, 'null') FROM precio_historial WHERE id_oferta=$OFERTA ORDER BY id_precio_historial DESC LIMIT 1;")" = "null" ] \
            && OK "precio_historial registra la fila sin descuento" || FALLA "precio_historial no registro el vencimiento"
        # El recalculo de Mongo va despues del UPDATE, en la misma vuelta del worker.
        sleep 2
        revisar_mongo false
    else
        FALLA "a los 90 s el descuento sigue puesto. Esta corriendo el backend con el worker de vencimiento?"
    fi
else
    FALLA "el descuento con duracion contesto $CODIGO, $(de_cuerpo mensaje)"
fi


# ============================================================
titulo "LIMPIEZA"
# ============================================================
limpiar
[ -z "$(sql "SELECT porcentaje_descuento FROM oferta WHERE id_oferta=$OFERTA;")" ] && OK "la oferta $OFERTA quedo sin descuento" || FALLA "la oferta $OFERTA quedo con descuento"
[ "$(sql "SELECT precio FROM oferta WHERE id_oferta=$OFERTA;")" = "$PRECIO" ] && OK "y con su precio de lista ($PRECIO)" || FALLA "el precio de lista no volvio a $PRECIO"
[ "$(sql "SELECT es_inventario_limitado FROM oferta WHERE id_oferta=$OFERTA;")" = "f" ] && OK "y sin venta relampago" || FALLA "la oferta quedo en venta relampago"


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
echo "  El descuento se ve igual en la oferta, el catalogo, el carrito y el cobro."
exit 0
