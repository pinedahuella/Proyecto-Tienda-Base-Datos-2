#!/usr/bin/env bash
# pruebas/falla_checkout.sh -- la prueba de falla simulada sobre el checkout.
#
#   bash pruebas/falla_checkout.sh
#
# Cierra el requisito de la Entrega 3 que pide evidencia de al menos una falla
# provocada sobre el flujo de compra y del comportamiento que resulta. Se
# provoca parando un contenedor con `docker stop` y volviendolo a levantar.
#
# Tarda unos tres o cuatro minutos. Casi todo ese tiempo es esperar a que las
# bases vuelvan a estar sanas, que es tiempo bien gastado.
#
#
# # ============================================================================
# # QUE SE ROMPE, Y POR QUE ASI
# # ============================================================================
#
# Se corre el mismo checkout cinco veces, cambiando solo que hay debajo:
#
#   linea base   todo vivo               tiene que comprar
#   escenario A  Redis parado            el carrito vive ahi
#   escenario B  MongoDB parado          solo aporta nombres, no esta en el COMMIT
#   escenario C  PostgreSQL parado       el dinero y el stock viven ahi
#   recuperacion todo vivo otra vez      tiene que volver a comprar
#
# La linea base no es adorno y es lo primero que corre. Sin ella, un escenario
# que no compra no prueba nada: podria ser que la falla lo impidiera o que el
# arnes nunca supiera comprar. Con ella, la diferencia entre las dos corridas
# es la falla y nada mas.
#
# "A mitad del checkout" aqui quiere decir que el componente esta caido en el
# instante en que se pide la compra. Se hace asi a proposito. Matar el
# contenedor durante el vuelo de la peticion daria un resultado distinto cada
# vez -- el checkout tarda milisegundos -- y una evidencia que no se puede
# repetir no sirve para una entrega. Esta forma es determinista y cualquiera la
# vuelve a correr.
#
# LO QUE ESTA PRUEBA NO CUBRE, dicho antes de que alguien se confie. `docker
# stop` es una parada ORDENADA: manda SIGTERM y la base cierra sus archivos
# como es debido. Un corte de luz o un `docker kill -s KILL` son mas brutos y
# pueden dejar cosas que esto no toca -- un archivo de Redis a medio escribir,
# una recuperacion de PostgreSQL al arrancar. Lo que si cubre, que es lo que
# pide la entrega, es la vista desde el checkout: la base no esta, y que hace
# el sistema con eso.
#
#
# # ============================================================================
# # ESTA PRUEBA COMPRA DE VERDAD. NO DEJA POSTGRESQL COMO ESTABA
# # ============================================================================
#
# No hay forma de medir un checkout sin hacer un checkout. Cada compra que sale
# bien deja, en PostgreSQL:
#
#   una fila en `pedido`, con su estado
#   sus filas en `pedido_producto`
#   una fila en `pago`
#   una fila en `stock_movimiento` por linea, y el `stock` de la oferta bajado
#
# Eso NO se deshace al terminar, y no se intenta deshacer. Borrar a mano las
# filas de una compra dejaria el kardex mintiendo, que es peor que un pedido de
# mas. Al final el arnes imprime los `id_pedido` que creo, para poder mirarlos
# o cancelarlos despues desde la aplicacion.
#
# Lo que SI se devuelve como estaba es el carrito de Redis de la cuenta, que es
# compartida y puede tener algo a medias de otra persona.
#
#
# # ============================================================================
# # EL trap, QUE ES LA PARTE QUE NO SE PUEDE OLVIDAR
# # ============================================================================
#
# Los contenedores del proyecto llevan `restart: unless-stopped`. Eso quiere
# decir que un `docker stop` se queda parado DE VERDAD y para siempre: Docker no
# lo vuelve a levantar solo. Si este arnes muriera entre el stop y el start --
# un Ctrl+C, un `set -u` que muerde, la maquina que se duerme -- la siguiente
# persona que corra cualquier prueba del proyecto veria rojos que no son suyos y
# perderia la tarde buscandolos en su codigo.
#
# Por eso hay un `trap ... EXIT` que levanta los tres contenedores, espera a que
# respondan y devuelve el carrito, y se registra ANTES del primer stop. Corre
# tambien cuando todo sale bien.
#
#
# # ============================================================================
# # LAS TRAMPAS DEL ARNES, QUE YA MORDIERON
# # ============================================================================
#
# 1. `curl` aqui es el binario de Windows y este archivo exporta
#    MSYS_NO_PATHCONV=1 (hace falta para que las urls no se conviertan en rutas).
#    El efecto colateral es que `-o /dev/null` NO se traduce y curl sale con 23
#    aunque la peticion diera 200, y `-c /tmp/algo` no escribe el tarro de
#    cookies sin quejarse -- el login contesta 200, el tarro queda vacio y la
#    sesion se pierde en silencio. Aqui no se usa ninguno de los dos: la sesion
#    se saca de la cabecera Set-Cookie como en pruebas/carrito.sh, y el codigo
#    HTTP viaja pegado al cuerpo con un separador, sin `-o`.
#
# 2. EL PRECIO YA NO SE MANDA. Hasta el 2026-09-23 la compra llevaba
#    `lineas_precio_visto` con el precio de la pantalla, y pasarlo por un numero
#    ("4269.00" -> 4269) hacia que el backend contestara comprado false SIN
#    COBRAR. Esa lista ya no existe: cada linea del carrito guarda en Redis la
#    foto del precio que se vio, y el backend la compara el solo contra el de
#    hoy. El arnes solo manda direccion y metodo de pago. Si aun asi sale
#    comprado false, es que el precio de la oferta de verdad se movio entre
#    preparar el carrito y pagar, y `clasificar` lo separa de una caida.
#
# 3. POST /carrito/comprar TIENE CUATRO FINALES y solo uno es un fallo. Mirar
#    solo el booleano `ok` confunde "no compre porque el precio cambio" con "no
#    compre porque la base se cayo". Se discrimina por el codigo HTTP MAS el
#    campo `comprado` del cuerpo, en la funcion `clasificar`.
#
# 4. El metodo de pago va en 'transferencia'. Con 'tarjeta' el cobro simulado
#    rechaza con 402 por motivos suyos, y ese ruido se confundiria con la falla
#    provocada.
#
# 5. El candado de checkout se llama `mesh:checkout:<id_usuario>`. El nombre
#    `carrito:lock:<usuario>` que aparece en la tabla de docs/CONSISTENCIA-
#    CHECKOUT.md no existe en Redis. La buena es la primera, que es la unica
#    medida.
#
#
# # ============================================================================
# # LOS HUECOS DEL DOCUMENTO QUE ESTO CONTESTA
# # ============================================================================
#
# docs/CONSISTENCIA-CHECKOUT.md dice que pasa cuando falla Redis DESPUES del
# COMMIT (punto 5) y que pasa si el proceso muere entre el COMMIT y el vaciado
# del carrito (punto 6). No dice, en ningun sitio, que pasa si Redis o MongoDB
# estan caidos ANTES de empezar. Este arnes es lo que contesta esas dos.
#
# Y manda una regla por encima de cualquier expectativa: SE IMPRIME LO QUE
# SALGA. Si el sistema se comporta distinto de lo que insinua el documento, eso
# es un hallazgo de la entrega y se dice, no un fallo de la prueba. Por eso hay
# un contador de HALLAZGO aparte del de FALLA.
#
#
# # ============================================================================
# # LO QUE SALIO EL 2026-09-06, CONTRA EL SISTEMA VIVO
# # ============================================================================
#
# Se deja escrito para que el que lo lea sepa que esperar, y para que se note
# el dia que deje de salir esto. No sustituye a correrlo.
#
#   linea base    HTTP 201  comprado true   pedido 108, stock 12 -> 11
#   Redis parado  HTTP 503  "No se pudo conectar con Redis"
#   Mongo parado  HTTP 503  "No se pudo conectar con MongoDB"   (hasta 6f89237)
#   PG parado     HTTP 503  "No se pudo conectar con PostgreSQL"
#   recuperacion  HTTP 201  comprado true   pedido 109, stock 11 -> 10
#
# En las tres caidas, PostgreSQL quedo EXACTAMENTE igual -- mismos pedidos,
# mismos pagos, mismas filas de kardex, mismo stock -- el candado quedo suelto
# y el carrito sobrevivio entero. Ninguna caida cobro a medias.
#
# EL HALLAZGO, y es el que hay que llevar a la entrega:
#
#   Con MongoDB parado el checkout contesta 503 y no cobra. Pero MongoDB NO
#   participa del COMMIT: segun la tabla de docs/CONSISTENCIA-CHECKOUT.md solo
#   aporta el nombre del producto y de la variante al armar el carrito, y
#   recalcula los agregados del catalogo al final. O sea que una base que solo
#   pone TEXTO para la pantalla es hoy capaz de impedir una venta que
#   PostgreSQL y Redis podrian cerrar perfectamente.
#
#   Eso convierte a MongoDB en una dependencia dura del cobro sin que nadie lo
#   haya decidido, y sube la superficie de caida del checkout de dos bases a
#   tres. No es un fallo del codigo -- nada queda inconsistente -- pero si es
#   una decision que el documento de consistencia todavia no declara.
#
# Que Redis pare la venta era de esperar, porque el carrito vive ahi. Que
# PostgreSQL la pare tambien, porque es la base que manda. Que MongoDB la pare
# es lo unico que no se sigue del diseno escrito.
#
# CERRADO CON 6f89237 (Jose David, 2026-09-30). El nombre, el estado y la
# portada de la variante se copian a PostgreSQL (migracion 029,
# producto_catalogo y variante_catalogo) y el recalculo del catalogo en Mongo
# va por el outbox evento_producto (migracion 030). Desde ahi el escenario B
# EXIGE que la compra salga con MongoDB parado, y es FALLA si no sale.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
REDIS="${REDIS:-mesh-redis}"
MONGO="${MONGO:-mesh-mongo}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
CUENTA="${CUENTA:-compradora.norte@mesh.com}"
CLAVE="${CLAVE:-Comprador123}"

# Nunca 'tarjeta'. Ver la trampa 4 de la cabecera.
METODO="${METODO:-transferencia}"

# El plazo de una peticion de compra. Es largo a proposito y no es pereza: con
# MongoDB parado, el driver no falla al momento sino que agota su propia espera
# de seleccion de servidor, que ronda los treinta segundos. Con un plazo corto,
# curl cortaria antes y el arnes registraria "sin respuesta" en vez del 503 que
# el backend si acaba dando. Se estaria midiendo la impaciencia del arnes.
ESPERA="${ESPERA:-120}"

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

ok=0; fallo=0; hallazgo=0
OK()       { echo "  OK    $1"; ok=$((ok+1)); }
FALLA()    { echo "  FALLA $1"; fallo=$((fallo+1)); }

# Un hallazgo no es un fallo. Es una conducta del sistema que la entrega tiene
# que declarar y que el documento de consistencia todavia no dice. Se cuenta
# aparte para que no tina el resultado final de rojo.
HALLAZGO() { echo "  OJO   $1"; hallazgo=$((hallazgo+1)); HALLAZGOS="$HALLAZGOS
  - $1"; }
HALLAZGOS=""

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


# ============================================================
# Saber si una base ya revivio
# ============================================================
#
# Se pregunta A LA BASE, no a Docker. `docker start` vuelve en cuanto el
# proceso arranca, y PostgreSQL tarda todavia unos segundos en aceptar
# conexiones. Preguntarle a Docker daria luz verde y la consulta siguiente
# fallaria con la base "arriba".
vivo_redis()    { [ "$(R PING)" = "PONG" ]; }
vivo_mongo()    { [ "$(docker exec "$MONGO" mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null | tr -d '\r\n ')" = "1" ]; }
vivo_postgres() { docker exec "$PG" pg_isready -U "$PG_USUARIO" -d "$PG_BASE" >/dev/null 2>&1; }

# Espera a que la funcion $1 diga que si, hasta $2 SEGUNDOS DE RELOJ. Devuelve
# distinto de 0 si se acabo el plazo, para que quien llame lo pueda decir en
# pantalla en vez de seguir midiendo sobre una base que no esta.
#
# EL PLAZO SE MIDE CON EL RELOJ Y NO CONTANDO VUELTAS, y esto ya mordio. La
# primera version daba noventa vueltas con un `sleep 1` dentro y llamaba a eso
# "90 s". Pero cada vuelta cuesta ademas lo que tarde la comprobacion, y
# `vivo_mongo` levanta un mongosh entero -- casi cuatro segundos con la maquina
# ocupada. Noventa vueltas fueron mas de seis minutos reales, con el arnes
# aparentemente colgado y un mensaje en pantalla que decia 90 s. El plazo que se
# promete y el que se cumple tienen que ser el mismo numero.
#
# Al agotarse se prueba UNA vez mas antes de rendirse. Si la ultima
# comprobacion arranco justo antes del limite, cortarla a media llamada seria
# tirar la respuesta que ya venia.
esperar_a() {
    _limite=$(( $(date +%s) + ${2:-90} ))
    while [ "$(date +%s)" -lt "$_limite" ]; do
        "$1" && return 0
        sleep 1
    done
    "$1"
}

# Si el contenedor esta corriendo AHORA MISMO, segun Docker.
#
# Aqui si se le pregunta a Docker y no a la base, porque lo que se quiere saber
# es lo contrario: que esta parado. Una base que no contesta puede estar
# arrancando; un contenedor que Docker da por parado, esta parado.
parado() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "false" ]
}


# ============================================================
# El levantatodo del trap
# ============================================================
#
# Se registra antes del primer stop y corre pase lo que pase. Ver la cabecera.
LEVANTADO=0
levantar() {
    [ "$LEVANTADO" = "1" ] && return 0
    LEVANTADO=1

    echo
    echo "=============================================================="
    echo "DEJANDO LA MAQUINA COMO ESTABA"
    echo "=============================================================="

    docker start "$PG" "$REDIS" "$MONGO" >/dev/null 2>&1

    # Los nombres de estas dos NO pueden empezar por _n. `esperar_a` usa `_n`
    # de contador y en bash no hay variables locales de verdad aqui: la
    # primera version imprimia "3 responde" en vez de "redis responde", porque
    # la llamada de dentro le habia machacado el nombre.
    for _par in "postgres:vivo_postgres" "redis:vivo_redis" "mongo:vivo_mongo"; do
        _cual="${_par%%:*}"
        _func="${_par##*:}"
        if esperar_a "$_func" 90; then
            echo "  $_cual responde"
        else
            echo "  OJO   $_cual no responde despues de 90 s. Miralo con 'docker ps'."
        fi
    done

    # El carrito de la cuenta compartida vuelve a como estaba. Se devuelve
    # DESPUES de esperar a Redis, porque escribirlo mientras arranca se pierde
    # sin dar error.
    if [ -n "${LLAVE_CARRITO:-}" ]; then
        R DEL "$LLAVE_CARRITO" >/dev/null
        if [ -n "${CARRITO_PREVIO:-}" ]; then
            while IFS=$'\t' read -r _of _cant; do
                [ -n "$_of" ] && R HSET "$LLAVE_CARRITO" "$_of" "$_cant" >/dev/null
            done <<< "$CARRITO_PREVIO"
            R EXPIRE "$LLAVE_CARRITO" 86400 >/dev/null
            echo "  se devolvio el carrito que $CUENTA tenia antes"
        else
            echo "  $CUENTA no tenia carrito antes, y sigue sin tenerlo"
        fi
    fi

    if [ -n "${PEDIDOS_CREADOS:-}" ]; then
        # La lista se va armando con " $id" pegado detras, asi que empieza por
        # un espacio. Este `echo` SIN COMILLAS es lo que lo quita: el shell
        # parte por espacios y los vuelve a juntar de uno en uno. Sin el, la
        # consulta de abajo salia con una coma suelta al principio, IN (,108),
        # y no se podia copiar y pegar -- que es lo unico para lo que sirve.
        # shellcheck disable=SC2116,SC2086
        _ids=$(echo $PEDIDOS_CREADOS)
        _en_lista=$(printf '%s' "$_ids" | tr ' ' ',')
        echo
        echo "  Esta corrida compro de verdad. Los pedidos que dejo en PostgreSQL"
        echo "  llevan los id $_ids"
        echo "  Se pueden mirar con"
        echo "    docker exec -it $PG psql -U $PG_USUARIO -d $PG_BASE -c \\"
        echo "      \"SELECT id_pedido, id_usuario, id_estado_pedido FROM pedido WHERE id_pedido IN ($_en_lista);\""
    fi
}
PEDIDOS_CREADOS=""
LLAVE_CARRITO=""
CARRITO_PREVIO=""


# ============================================================
# Hablar con el checkout
# ============================================================

# Pide la compra y deja el codigo HTTP en CODIGO y el cuerpo entero en CUERPO.
#
# El codigo viaja PEGADO al cuerpo con un separador en vez de salir por
# `-o /dev/null -w`, por la trampa 1 de la cabecera. Sin precios en el cuerpo,
# por la trampa 2: el backend compara con la foto que guardo en Redis.
CODIGO=""
CUERPO=""
comprar() {
    _extra="${1:-}"
    _peticion="{\"id_direccion\":\"$DIRECCION\",\"metodo_pago\":\"$METODO\"$_extra}"
    _todo=$(curl -s -m "$ESPERA" -w $'\n@@@%{http_code}' \
        -X POST "$API/carrito/comprar" \
        -H 'Content-Type: application/json' -H "Cookie: $SESION" \
        -d "$_peticion" 2>/dev/null)
    CODIGO="${_todo##*@@@}"
    CUERPO="${_todo%$'\n'@@@*}"
    # curl escribe 000 cuando no hubo respuesta ninguna. Si ni eso llego, la
    # peticion se corto antes de tiempo y hay que decirlo, no dejarlo vacio.
    [ -z "$CODIGO" ] && CODIGO="000"
    [ "$CUERPO" = "$_todo" ] && CUERPO=""
}

# Los cuatro finales de POST /carrito/comprar, mas los dos que solo salen
# cuando algo esta caido. Ver la trampa 3 de la cabecera.
FINAL=""
COMPRADO=""
clasificar() {
    COMPRADO=$(printf '%s' "$CUERPO" | campo payload.comprado)
    case "$CODIGO" in
        200|201)
            if [ "$COMPRADO" = "True" ]; then
                FINAL="compro"
            else
                FINAL="no-compro-el-precio-cambio"
            fi ;;
        402) FINAL="cobro-rechazado" ;;
        409) FINAL="conflicto-candado-o-stock" ;;
        503) FINAL="una-base-no-responde" ;;
        000) FINAL="sin-respuesta" ;;
        *)   FINAL="otro-$CODIGO" ;;
    esac
}

# Los cuatro numeros que cuentan si hubo cobro. Se leen juntos para que la foto
# sea del mismo instante.
#
# `stock_movimiento` esta aqui y no sobra: es el kardex, y es la unica de las
# cuatro que no se puede rehacer. Un pedido de mas se cancela; una fila de
# kardex que falta deja el historico del stock mintiendo para siempre.
F_PEDIDOS=""; F_PAGOS=""; F_MOV=""; F_STOCK=""
foto() {
    F_PEDIDOS=$(sql "SELECT count(*) FROM pedido;")
    F_PAGOS=$(sql "SELECT count(*) FROM pago;")
    F_MOV=$(sql "SELECT count(*) FROM stock_movimiento;")
    F_STOCK=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;")
}

# Deja el carrito con una sola linea de la oferta de trabajo y devuelve por
# pantalla el precio que el backend acaba de ensenar.
#
# El carrito se arma AQUI, con todo vivo, y no dentro del escenario: el PUT
# toma la foto de la linea (precio, nombre, imagen) contra PostgreSQL y
# MongoDB, asi que con una de las dos caida no se podria ni agregar. Desde el
# 2026-09-23 el GET ya no pregunta a nadie mas que a Redis; el precio que
# devuelve es el de esa foto, y solo sirve para mostrarlo y para saber que el
# carrito quedo listo.
preparar_carrito() {
    curl -s -m 20 -X DELETE "$API/carrito" -H "Cookie: $SESION" >/dev/null 2>&1
    curl -s -m 20 -X PUT "$API/carrito/lineas/$OFERTA" \
        -H 'Content-Type: application/json' -H "Cookie: $SESION" \
        -d '{"cantidad":1}' >/dev/null 2>&1
    curl -s -m 20 "$API/carrito" -H "Cookie: $SESION" | python -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for l in ((d.get('payload') or {}).get('lineas') or []):
    if l.get('id_oferta') == $OFERTA:
        print(l.get('precio', ''))"
}

# Imprime el cuerpo de la respuesta tal cual llego, indentado. Nunca resumido,
# nunca partido: el mensaje del backend es la mitad de la evidencia.
#
# La primera version lo pasaba por `fold -w 68 -s` para que cupiera en la
# pantalla, y eso rompia los numeros por la mitad -- el total salia como
# "6" y "263.00" en dos lineas. Una evidencia que hay que reconstruir a mano
# antes de pegarla en la entrega no es una evidencia. Va entero en una linea
# aunque se salga, que la terminal ya sabe desplazarse.
mostrar_respuesta() {
    echo "          HTTP $CODIGO"
    if [ -z "$CUERPO" ]; then
        echo "          (sin cuerpo)"
    else
        printf '%s\n' "$CUERPO" | sed 's/^/          /'
    fi
}

mostrar_foto() {
    echo "          $1  pedidos $F_PEDIDOS   pagos $F_PAGOS   kardex $F_MOV   stock de la oferta $OFERTA es $F_STOCK"
}


# ============================================================
# 0. TODO ARRIBA Y CON QUE SE VA A TRABAJAR
# ============================================================
titulo "0. TODO ARRIBA Y CON QUE SE VA A TRABAJAR"

# Se mira el codigo HTTP y no el codigo de salida de curl, por la trampa 1.
if [ "$(curl -s -m 8 -w '%{http_code}' -X GET "$API/carrito" 2>/dev/null | tail -c 3)" = "401" ]; then
    OK "el backend sirve /carrito y pide sesion"
else
    echo "  El backend no responde en $API. Levantalo y vuelve a probar."
    exit 1
fi

vivo_redis    && OK "Redis responde"      || { echo "  Redis no responde."; exit 1; }
vivo_mongo    && OK "MongoDB responde"    || { echo "  MongoDB no responde."; exit 1; }
vivo_postgres && OK "PostgreSQL responde" || { echo "  PostgreSQL no responde."; exit 1; }

SESION=$(curl -s -m 10 -i -X POST "$API/usuario/login" -H 'Content-Type: application/json' \
     -d "{\"identificador\":\"$CUENTA\",\"contrasena\":\"$CLAVE\"}" \
   | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1)
[ -n "$SESION" ] && OK "sesion de $CUENTA" || { echo "  No se pudo entrar."; exit 1; }

ID_USUARIO=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='$CUENTA';" | tr -d ' ')
LLAVE_CARRITO="mesh:carrito:$ID_USUARIO"
LLAVE_CANDADO="mesh:checkout:$ID_USUARIO"

# La direccion de entrega viaja EN el cuerpo de la compra, porque en el modo
# carrito no hay pedido todavia al que ponersela.
DIRECCION=$(curl -s -m 10 "$API/direccion-usuario" -H "Cookie: $SESION" | python -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
p = d.get('payload') or []
if p: print(p[0]['id_direccion'])")
if [ -n "$DIRECCION" ]; then
    OK "hay direccion de entrega (id $DIRECCION)"
else
    echo "  $CUENTA no tiene ninguna direccion, y sin una no se puede comprar."
    exit 1
fi

# Una oferta activa con holgura. Se piden 5 unidades y se compra 1 cada vez,
# para que las cuatro compras de esta corrida quepan sin quedarse sin stock a
# la mitad y confundir "no compro por la falla" con "no compro por el stock".
OFERTA=$(sql "SELECT o.id_oferta FROM oferta o JOIN estado_oferta eo USING(id_estado_oferta)
              WHERE eo.estado_oferta_nombre='activa' AND o.stock>=5
              ORDER BY o.id_oferta LIMIT 1;" | tr -d ' ')
if [ -n "$OFERTA" ]; then
    OK "oferta de trabajo $OFERTA con $(sql "SELECT stock FROM oferta WHERE id_oferta=$OFERTA;" | tr -d ' ') unidades"
else
    echo "  No hay ninguna oferta activa con stock suficiente."
    exit 1
fi

# La cuenta es compartida y puede tener algo a medias. Se guarda para
# devolverlo, igual que hace pruebas/carrito.sh.
CARRITO_PREVIO=$(R HGETALL "$LLAVE_CARRITO" | paste - - 2>/dev/null)
if [ -n "$CARRITO_PREVIO" ]; then
    OK "se respaldo el carrito que ya tenia $CUENTA"
else
    OK "$CUENTA no tenia carrito, no hay nada que respaldar"
fi

# ---- EL trap, REGISTRADO ANTES DEL PRIMER stop ----
trap levantar EXIT
OK "trap puesto. Pase lo que pase, los tres contenedores vuelven"

echo
echo "  Esta prueba COMPRA de verdad y deja pedidos, pagos y kardex en"
echo "  PostgreSQL. Al final se imprime cuales."


# ============================================================
# 1. LINEA BASE, CON TODO VIVO
# ============================================================
titulo "1. LINEA BASE. CON TODO VIVO, LA COMPRA SE HACE"

# Sin esto, un escenario que no compra no distingue "la falla lo impidio" de
# "el arnes nunca supo comprar". Es la mitad que da sentido a la otra.
PRECIO=$(preparar_carrito)
if [ -z "$PRECIO" ]; then
    echo "  No se pudo dejar el carrito listo. Sin carrito no hay checkout que romper."
    exit 1
fi
echo "  precio que se vio en pantalla   $PRECIO"
echo "  no se manda: el backend lo compara con la foto de Redis. Ver la trampa 2."

foto; mostrar_foto "antes  "
BASE_PEDIDOS="$F_PEDIDOS"; BASE_PAGOS="$F_PAGOS"; BASE_MOV="$F_MOV"; BASE_STOCK="$F_STOCK"

comprar
clasificar
BASE_FINAL="$FINAL"
mostrar_respuesta
foto; mostrar_foto "despues"

if [ "$FINAL" = "compro" ]; then
    OK "con todo vivo compro. El final fue '$FINAL'"
else
    FALLA "con todo vivo NO compro. El final fue '$FINAL'"
    echo "        Todo lo que viene despues mediria el arnes y no la falla."
    echo "        Mira que $CUENTA pueda comprar a mano antes de seguir."
    exit 1
fi

_id=$(printf '%s' "$CUERPO" | campo payload.id_pedido)
[ -n "$_id" ] && PEDIDOS_CREADOS="$PEDIDOS_CREADOS $_id"

if [ "$F_PEDIDOS" = "$((BASE_PEDIDOS+1))" ] && [ "$F_PAGOS" = "$((BASE_PAGOS+1))" ] \
   && [ "$F_MOV" -gt "$BASE_MOV" ] && [ "$F_STOCK" = "$((BASE_STOCK-1))" ]; then
    OK "y las cuatro cosas se movieron juntas. Pedido, pago, kardex y stock"
else
    FALLA "compro pero los cuatro numeros no cuadran"
    echo "        pedidos $BASE_PEDIDOS a $F_PEDIDOS, pagos $BASE_PAGOS a $F_PAGOS,"
    echo "        kardex $BASE_MOV a $F_MOV, stock $BASE_STOCK a $F_STOCK"
fi

[ "$(R EXISTS "$LLAVE_CANDADO")" = "0" ] \
    && OK "el candado $LLAVE_CANDADO quedo suelto" \
    || FALLA "el candado $LLAVE_CANDADO quedo tomado tras una compra buena"


# ============================================================
# El molde de un escenario de falla
# ============================================================
#
# Los tres escenarios hacen lo mismo cambiando el contenedor, asi que van en
# una funcion y no en tres copias. Tres copias de sesenta lineas se separan
# solas en la primera correccion, y entonces dejan de ser comparables entre si
# -- que es justo lo unico que hace util correr tres.
#
#   $1  el contenedor que se para
#   $2  como se llama en pantalla
#   $3  la funcion que dice si ya revivio
#   $4  la regla, y tiene tres valores
#         no-debe-comprar        comprar sin el seria un fallo grave
#         debe-comprar           esa base no hace falta para cobrar; no
#                                comprar sin ella es FALLA
#         el-documento-no-dice   pase lo que pase se declara como hallazgo
#   $5  por que esa regla, para el que lea la salida sin leer este archivo
escenario() {
    _cont="$1"; _nombre="$2"; _vivo="$3"; _regla="$4"; _porque="$5"

    titulo "$_nombre"
    echo "  $_porque"
    echo

    # El carrito se deja listo ANTES de parar nada. Ver preparar_carrito.
    _precio=$(preparar_carrito)
    if [ -z "$_precio" ]; then
        FALLA "no se pudo dejar el carrito listo, este escenario no se corrio"
        return
    fi
    echo "  carrito listo con la oferta $OFERTA a $_precio"

    foto
    _p0="$F_PEDIDOS"; _g0="$F_PAGOS"; _m0="$F_MOV"; _s0="$F_STOCK"
    mostrar_foto "antes  "

    echo "  parando $_cont ..."
    docker stop "$_cont" >/dev/null 2>&1

    # Sin esta comprobacion todo el escenario podria estar midiendo el sistema
    # sano y dar verde. Es el ancla que separa "medi la falla" de "no medi
    # nada".
    if parado "$_cont"; then
        OK "$_cont esta parado de verdad, segun Docker"
    else
        FALLA "$_cont NO se paro. Este escenario no midio ninguna falla"
        docker start "$_cont" >/dev/null 2>&1
        esperar_a "$_vivo" 90
        return
    fi

    comprar
    clasificar
    _final="$FINAL"
    mostrar_respuesta

    # Con PostgreSQL parado no se puede leer la foto de despues hasta que
    # vuelva. Lo mismo con el carrito y Redis. Asi que primero se levanta y
    # despues se mira: la comparacion cubre la caida MAS el rearranque, y eso
    # es exactamente lo que le pasaria a la tienda de verdad.
    echo "  levantando $_cont ..."
    docker start "$_cont" >/dev/null 2>&1
    if esperar_a "$_vivo" 90; then
        OK "$_cont volvio a responder"
    else
        FALLA "$_cont no volvio en 90 s, lo de abajo no se puede creer"
        return
    fi

    foto
    mostrar_foto "despues"

    _carrito=$(R EXISTS "$LLAVE_CARRITO")
    _candado=$(R EXISTS "$LLAVE_CANDADO")
    _ttl=$(R TTL "$LLAVE_CANDADO")
    echo "          carrito en Redis $_carrito   candado $_candado   ttl del candado $_ttl"

    echo
    echo "  El final fue '$_final', y con todo vivo habia sido '$BASE_FINAL'"

    # ---- 1. la regla del escenario ----
    if [ "$_final" = "compro" ]; then
        _id=$(printf '%s' "$CUERPO" | campo payload.id_pedido)
        [ -n "$_id" ] && PEDIDOS_CREADOS="$PEDIDOS_CREADOS $_id"
        if [ "$_regla" = "no-debe-comprar" ]; then
            FALLA "compro con $_cont parado, y sin el no deberia haber podido"
        elif [ "$_regla" = "debe-comprar" ]; then
            OK "compro con $_cont parado, que es lo que se pide: esa base no hace falta para cobrar"
        else
            HALLAZGO "el checkout compra con $_cont parado. Esa base no hace falta para cobrar"
        fi
    else
        if [ "$_regla" = "no-debe-comprar" ]; then
            OK "no compro con $_cont parado, que es lo unico correcto"
        elif [ "$_regla" = "debe-comprar" ]; then
            FALLA "no compro con $_cont parado, y esa base ya no deberia hacer falta para cobrar"
        else
            HALLAZGO "$_cont parado impide comprar, y esa base no participa del COMMIT"
        fi
    fi

    # ---- 2. todo o nada, que es la garantia que el proyecto no negocia ----
    #
    # Esta es la comprobacion que de verdad puede ponerse roja. Falla si el
    # sistema cobro a medias -- un pedido sin su pago, un stock bajado sin su
    # fila de kardex -- que es la unica forma en que una caida deja dinero
    # mal contado.
    if [ "$_final" = "compro" ]; then
        if [ "$F_PEDIDOS" = "$((_p0+1))" ] && [ "$F_PAGOS" = "$((_g0+1))" ] \
           && [ "$F_MOV" -gt "$_m0" ] && [ "$F_STOCK" = "$((_s0-1))" ]; then
            OK "compro y las cuatro se movieron juntas"
        else
            FALLA "compro a medias. Pedidos $_p0 a $F_PEDIDOS, pagos $_g0 a $F_PAGOS, kardex $_m0 a $F_MOV, stock $_s0 a $F_STOCK"
        fi
    else
        if [ "$F_PEDIDOS" = "$_p0" ] && [ "$F_PAGOS" = "$_g0" ] \
           && [ "$F_MOV" = "$_m0" ] && [ "$F_STOCK" = "$_s0" ]; then
            OK "no compro y PostgreSQL quedo intacto. Ni pedido, ni pago, ni kardex, ni stock"
        else
            FALLA "no compro pero PostgreSQL se movio. Pedidos $_p0 a $F_PEDIDOS, pagos $_g0 a $F_PAGOS, kardex $_m0 a $F_MOV, stock $_s0 a $F_STOCK"
            echo "        Esto es un cobro a medias y es lo peor que puede salir de aqui."
        fi
    fi

    # ---- 3. que la caida no dejo a la cuenta sin poder comprar ----
    #
    # El candado se suelta en un finally y ademas vence a los 30 s. Si quedara
    # tomado SIN vencimiento, esa cuenta no volveria a comprar nunca y eso no
    # se arregla solo.
    if [ -z "$_candado" ]; then
        FALLA "no se pudo leer Redis para mirar el candado, esta parte no midio nada"
    elif [ "$_candado" = "0" ]; then
        OK "el candado quedo suelto, la cuenta puede volver a intentarlo ya"
    elif [ "$_ttl" -gt 0 ] 2>/dev/null; then
        HALLAZGO "el candado quedo tomado con $_ttl s de vida. Se suelta solo, pero la cuenta espera"
    else
        FALLA "el candado quedo tomado y SIN vencimiento. Esa cuenta no vuelve a comprar"
        echo "        Se suelta a mano con  docker exec $REDIS redis-cli DEL $LLAVE_CANDADO"
    fi

    # ---- 4. que el carrito no se perdio sin haber comprado ----
    #
    # Perder el carrito sin cobrar es la peor cara de una caida para quien
    # esta comprando: paga el precio de la falla dos veces, una por no poder
    # pagar y otra por tener que rehacerlo todo.
    if [ "$_final" = "compro" ]; then
        [ "$_carrito" = "0" ] \
            && OK "compro y el carrito se vacio, como toca" \
            || HALLAZGO "compro y el carrito sigue lleno. Es la ventana del punto 6 del documento"
    else
        [ "$_carrito" = "1" ] \
            && OK "no compro y el carrito sigue entero, no hay que rehacerlo" \
            || HALLAZGO "no compro y ademas se perdio el carrito"
    fi
}


# ============================================================
# 2. ESCENARIO A. REDIS PARADO
# ============================================================
#
# Redis es donde vive el carrito y donde se toma el candado que evita el doble
# cobro. Sin el no hay nada que comprar, asi que comprar de todos modos seria
# haber cobrado por algo que no se pudo leer.
escenario "$REDIS" \
    "2. ESCENARIO A. REDIS PARADO A LA HORA DE PAGAR" \
    vivo_redis \
    "no-debe-comprar" \
    "El carrito y el candado del checkout viven en Redis. Sin Redis no hay que cobrar."


# ============================================================
# 3. ESCENARIO B. MONGODB PARADO
# ============================================================
#
# Antes de 6f89237 MongoDB entraba en el checkout dos veces, sin estar en el
# COMMIT: ponia el nombre del producto y de la variante, y al final se le
# recalculaban los agregados del catalogo. Con Mongo parado la compra daba 503.
#
# Ahora los nombres salen de producto_catalogo y variante_catalogo (029) y el
# recalculo va por el outbox evento_producto (030), asi que la compra TIENE que
# salir. Es la fila 11 de docs/CONSISTENCIA-CHECKOUT.md, cerrada.
escenario "$MONGO" \
    "3. ESCENARIO B. MONGODB PARADO A LA HORA DE PAGAR" \
    vivo_mongo \
    "debe-comprar" \
    "MongoDB no participa del COMMIT, y los nombres y el estado ya estan copiados en PostgreSQL."


# ============================================================
# 4. ESCENARIO C. POSTGRESQL PARADO
# ============================================================
#
# La contraprueba dura. PostgreSQL es la unica base transaccional del flujo, la
# que guarda el pedido, el pago y el kardex. Si el checkout consiguiera dar por
# comprado algo sin ella, la postura entera del proyecto -- el dinero y el
# stock son transaccionales y no se negocian -- seria falsa.
escenario "$PG" \
    "4. ESCENARIO C. POSTGRESQL PARADO A LA HORA DE PAGAR" \
    vivo_postgres \
    "no-debe-comprar" \
    "PostgreSQL guarda el pedido, el pago y el kardex. Es la base que manda."


# ============================================================
# 5. DESPUES DE LAS TRES CAIDAS, EL SISTEMA VUELVE A VENDER
# ============================================================
titulo "5. CON TODO ARRIBA OTRA VEZ, LA TIENDA VUELVE A VENDER"

# Sin esta parte, la prueba demostraria que el sistema aguanta una caida y no
# que se recupera de ella. Son cosas distintas y la segunda es la que importa
# al dia siguiente: un candado pegado, un pool de conexiones que no reconecta o
# un carrito corrupto solo se ven aqui.
PRECIO=$(preparar_carrito)
if [ -z "$PRECIO" ]; then
    FALLA "tras las tres caidas ya no se puede ni dejar el carrito listo"
else
    echo "  carrito listo otra vez con la oferta $OFERTA a $PRECIO"
    foto
    _p0="$F_PEDIDOS"; _g0="$F_PAGOS"; _s0="$F_STOCK"
    mostrar_foto "antes  "

    comprar
    clasificar
    mostrar_respuesta
    foto; mostrar_foto "despues"

    if [ "$FINAL" = "compro" ]; then
        _id=$(printf '%s' "$CUERPO" | campo payload.id_pedido)
        [ -n "$_id" ] && PEDIDOS_CREADOS="$PEDIDOS_CREADOS $_id"
        OK "vuelve a comprar. Las tres caidas no dejaron nada roto"
        [ "$F_STOCK" = "$((_s0-1))" ] \
            && OK "y el stock volvio a bajar de $_s0 a $F_STOCK" \
            || FALLA "compro pero el stock no bajo bien, $_s0 a $F_STOCK"
    else
        FALLA "tras las tres caidas ya no compra. El final fue '$FINAL'"
        echo "        Mira el candado $LLAVE_CANDADO y el log del backend."
    fi
fi


# ============================================================
# RESULTADO
# ============================================================
titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA, $hallazgo para declarar en la entrega"

if [ "$hallazgo" -gt 0 ]; then
    echo
    echo "  LO QUE HAY QUE DECLARAR, porque el documento de consistencia"
    echo "  todavia no lo dice$HALLAZGOS"
fi

echo
if [ "$fallo" -gt 0 ]; then
    echo "  Una caida dejo el checkout en un estado que no se puede defender."
    echo "  Lee las lineas FALLA de arriba antes de tocar nada."
    exit 1
fi

echo "  Se paro Redis, MongoDB y PostgreSQL a la hora de pagar, una por una."
echo "  Ninguna caida cobro a medias, ninguna dejo la cuenta bloqueada, y con"
echo "  las tres arriba otra vez la tienda vuelve a vender."
exit 0
