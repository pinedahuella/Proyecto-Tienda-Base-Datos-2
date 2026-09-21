#!/usr/bin/env bash
#
# AVISO, ESTE ARNES NO PASA POR LAS RUTAS DEL BACKEND. Le manda 1000 solicitudes con
# redis-benchmark directo al script redis/inventario_limitado.lua, que es el MISMO
# archivo que carga el backend, asi que prueba la decision atomica a una escala que
# el HTTP no alcanza. Pero se salta la ruta, el servicio y las cuentas. La prueba
# con cuentas reales por HTTP, 60 compradores sobre 20 unidades, es
# pruebas/oferta_limitada.sh.
#
# prueba_concurrencia.sh -- la evidencia de que la oferta de inventario
# limitado NO se sobrevende, con muchas mas solicitudes que unidades y sin un
# solo bloqueo a nivel de aplicacion.
#
# Esto es lo que valen los puntos, no el codigo. El codigo puede estar bien
# escrito y sobrevender igual: lo unico que lo demuestra es lanzarle mas gente
# de la que cabe y contar.
#
#
# COMO SE SIMULA LA CONCURRENCIA, Y POR QUE ASI
# ============================================================
# Con `redis-benchmark`, que ya viene dentro del contenedor mesh-redis. No se
# instalo nada.
#
# Abre N conexiones DE VERDAD contra el servidor y les manda el mismo comando.
# No es un bucle rapido: son 50 sockets distintos hablando a la vez, que es
# justo el escenario donde la version ingenua se rompe. Un `for` en bash
# mandaria una solicitud, esperaria la respuesta y mandaria la siguiente --
# nunca habria dos en el aire y jamas encontraria la carrera.
#
# El problema de redis-benchmark es que solo informa velocidad: no dice que
# contesto cada solicitud. Por eso el conteo NO se hace desde afuera, se hace
# DENTRO del script Lua: `ticket` cuenta las que ganaron y `rechazos` las que
# no, y los dos se escriben en el mismo paso atomico que decide.
#
# Y para que ese conteo no sea el acusado midiendose a si mismo, se comprueba
# contra tres numeros que se escriben en lugares distintos:
#   - ZCARD del ZSET de reservas (lo llena ZADD, no un contador)
#   - el campo `reservado` (lo llena HINCRBY)
#   - el campo `stock`, que tiene que haber bajado exactamente lo mismo
# Si el script tuviera un agujero, los cuatro numeros no podrian mentir igual.
#
# Ademas cada solicitud llega con un id_usuario distinto: redis-benchmark
# reemplaza el testigo __rand_int__ por un numero al azar. Son 1000 compradores
# peleandose, no uno reintentando.
#
#
# COMO SE COMPRUEBA QUE LA CARGA FUE CONCURRENTE DE VERDAD
# ============================================================
# Se MIDE, y hace falta decir por que, porque antes se DEDUCIA y estaba mal.
#
# Este archivo afirmaba: "si la carga estuviera mal armada y no hubiera
# concurrencia real, el control tampoco se romperia, y su -900 seria un 0". Es
# falso. DECRBY no tiene comprobacion adentro, asi que 1000 DECRBY sobre un
# contador en 100 terminan en -900 aunque se ejecuten uno detras de otro.
# Medido: `redis-benchmark -c 1 -n 1000 decrby` -- una sola conexion, una
# peticion en el aire, cero concurrencia por construccion -- dejo el contador en
# -900 igual. Y el arnes entero corrido con CLIENTES=1 daba 20 OK, cero FALLA,
# incluida la linea que afirmaba por escrito que hubo concurrencia.
#
# O sea que la evidencia de los 3 puntos ("se sostiene bajo solicitudes
# concurrentes simuladas") descansaba en una comprobacion que no podia fallar.
#
# Lo que se mide ahora es `total_connections_received` de INFO stats, antes y
# despues de cada carga: la resta dice cuantos SOCKETS abrio esa carga.
# redis-benchmark abre -c conexiones y las sostiene todas durante la corrida,
# con una peticion en el aire en cada una, asi que ese numero ES la concurrencia
# simulada. Medido en este entorno: 52 conexiones nuevas con -c 50 y 3 con -c 1.
# Un solo comando, sin instalar nada, y separa los dos casos sin ambiguedad.
#
#
# LA RONDA DE CONTROL, y lo que si demuestra
# ============================================================
# La ronda 'ingenua' corre DECRBY pelado sobre un contador con las mismas 1000
# solicitudes. DECRBY es atomico -- es un solo comando de Redis -- y aun asi
# termina en negativo. Eso demuestra UNA cosa, que es la del titulo del archivo:
# lo que falta no es la atomicidad del descuento sino que la COMPROBACION este
# adentro del mismo paso. No demuestra que haya habido concurrencia, y ya no
# dice que la demuestre.
#
# Uso:  bash redis/prueba_concurrencia.sh
#       RONDAS=3 bash redis/prueba_concurrencia.sh

set -u
export MSYS_NO_PATHCONV=1   # Git Bash convierte las rutas con / al pasarlas a
                            # docker exec y las vuelve C:/Program Files/...

DIR="$(cd "$(dirname "$0")" && pwd)"

CONTENEDOR_REDIS="${CONTENEDOR_REDIS:-mesh-redis}"
CONTENEDOR_PG="${CONTENEDOR_PG:-mesh-postgres}"
# La contrasena sale del .env de la raiz, NUNCA escrita aqui: este archivo
# se sube al repositorio y el .env no. Si falta, el script para y lo dice,
# en vez de intentar con un valor por defecto y fallar con "WRONGPASS".
if [ -z "${REDIS_PASSWORD:-}" ] && [ -f "$DIR/../.env" ]; then
    REDIS_PASSWORD=$(grep -E "^REDIS_PASSWORD=" "$DIR/../.env" | head -1 | cut -d= -f2-)
fi
if [ -z "${REDIS_PASSWORD:-}" ]; then
    echo "Falta REDIS_PASSWORD. Ponla en el .env de la raiz o exportala." >&2
    exit 1
fi
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"

UNIDADES="${UNIDADES:-100}"       # lo que hay para vender
SOLICITUDES="${SOLICITUDES:-1000}" # diez veces mas gente que unidades
CLIENTES="${CLIENTES:-50}"         # conexiones simultaneas
RONDAS="${RONDAS:-2}"              # se corre mas de una vez: un verde que solo
                                   # aparece una vez no es un verde

CORREO_VENDEDOR="${CORREO_VENDEDOR:-ventas.norte@mesh.com}"
PREFIJO="prueba:oferta"

fallos=0

R() { docker exec -i "$CONTENEDOR_REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@"; }
PSQL() { docker exec -i "$CONTENEDOR_PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAF'|' "$@"; }

titulo() { echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
ok()  { echo "  OK    $1"; }
mal() { echo "  FALLA $1"; fallos=$((fallos + 1)); }

igual() {
    local etiqueta="$1" valor="$2" esperado="$3"
    if [ "$valor" = "$esperado" ]; then
        ok "$etiqueta = $valor"
    else
        mal "$etiqueta = $valor  (se esperaba $esperado)"
    fi
}

# Deja el estado de la oferta en variables E_*. `estado` es de solo lectura: no
# cosecha ni renueva nada, asi que medir no cambia lo medido.
leer_estado() {
    local salida
    salida=$(R EVALSHA "$SHA" 2 "$K1" "$K2" estado)
    E_STOCK=$(echo "$salida"     | sed -n '2p')
    E_RESERVADO=$(echo "$salida" | sed -n '3p')
    E_VENDIDAS=$(echo "$salida"  | sed -n '4p')
    E_RECHAZOS=$(echo "$salida"  | sed -n '5p')
    E_TICKET=$(echo "$salida"    | sed -n '6p')
    E_PENDIENTES=$(echo "$salida"| sed -n '7p')
}

# Cuantas conexiones lleva aceptadas Redis desde que arranco. La resta de este
# numero antes y despues de una carga dice cuantos SOCKETS abrio esa carga.
conexiones_aceptadas() {
    R INFO stats | tr -d '\r' | sed -n 's/^total_connections_received://p'
}

# Lanza la carga y deja DOS cosas en variables globales: $VELOCIDAD (la linea de
# peticiones por segundo de redis-benchmark) y $CONEXIONES (cuantos sockets
# abrio).
#
# Deja globales y no imprime para que lo capture un $(...), y eso es a
# proposito: una subshell se lleva las variables que le pongas adentro, asi que
# la medicion de concurrencia se habria perdido justo al salir.
#
# -q para que no pinte la barra de progreso entera; el ultimo renglon es el que
# trae las peticiones por segundo.
cargar() {
    local antes despues
    antes=$(conexiones_aceptadas)
    VELOCIDAD=$(docker exec -i "$CONTENEDOR_REDIS" redis-benchmark \
        -a "$REDIS_PASSWORD" -q -n "$SOLICITUDES" -c "$CLIENTES" -r 1000000 \
        "$@" 2>&1 | tr '\r' '\n' | grep "requests per second" | tail -1)
    despues=$(conexiones_aceptadas)
    CONEXIONES=$((despues - antes))
}

# La comprobacion que antes no existia: que la carga haya sido concurrente.
#
# Son DOS preguntas y hacen falta las dos, porque cada una tapa un agujero
# distinto:
#
#   1. Se PIDIO concurrencia? Con CLIENTES=1 no hay nada que probar: una sola
#      conexion con una peticion en el aire es ejecucion en serie por
#      construccion. Sin esta pregunta, correr el arnes con CLIENTES=1 daba 20
#      OK, cero FALLA, y una linea afirmando por escrito que hubo concurrencia.
#      Medido, tal cual.
#
#   2. Se CONSIGUIO? Que redis-benchmark abriera de verdad los sockets que se le
#      pidieron. Si algun dia serializara, o si el -c se perdiera, aqui se ve.
#
# Los 2 que se restan son las dos lecturas de INFO que hace la propia funcion
# `cargar`, una antes y otra despues: cada docker exec de redis-cli es una
# conexion mas y no es de la carga. Si alguien agrega otra llamada a Redis
# dentro de `cargar`, este numero se queda corto y la comprobacion se pone
# estricta de mas -- que es el lado bueno para equivocarse.
concurrencia_real() {
    local de_la_carga=$(( CONEXIONES - 2 ))

    if [ "$CLIENTES" -lt 2 ]; then
        mal "CLIENTES=$CLIENTES: con una sola conexion no hay concurrencia que probar, y esta ronda no es evidencia de nada"
        return
    fi

    if [ "$de_la_carga" -ge "$CLIENTES" ]; then
        ok "la carga abrio $de_la_carga conexiones simultaneas (se pidieron $CLIENTES): concurrencia real"
    else
        mal "la carga abrio $de_la_carga conexiones y se pidieron $CLIENTES: la carga se serializo, asi que esta ronda no demuestra nada"
    fi
}


titulo "0. Preparativos"

SHA=$(R -x SCRIPT LOAD < "$DIR/inventario_limitado.lua")
if [ -z "$SHA" ]; then
    echo "No se pudo cargar inventario_limitado.lua. Esta levantado $CONTENEDOR_REDIS?"
    exit 1
fi
echo "  inventario_limitado.lua cargado, sha $SHA"

# Ningun id a mano: la oferta sale de la base, buscada por el correo del
# vendedor. Las claves de Redis llevan el prefijo de prueba, asi que la oferta
# de verdad no se toca -- lo que se usa es su id, para que el escenario sea el
# de una oferta que existe.
ID_OFERTA=$(PSQL -c "
SELECT o.id_oferta
FROM oferta o
JOIN usuarios u ON u.id_usuario = o.id_usuario
JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
WHERE u.correo_electronico = '$CORREO_VENDEDOR'
  AND eo.estado_oferta_nombre = 'activa'
ORDER BY o.id_oferta
LIMIT 1;")

if [ -z "$ID_OFERTA" ]; then
    echo "No hay ofertas activas de $CORREO_VENDEDOR en la base $PG_BASE."
    exit 1
fi

K1="$PREFIJO:$ID_OFERTA"
K2="$PREFIJO:$ID_OFERTA:reservas"
K_INGENUO="$PREFIJO:$ID_OFERTA:ingenuo"

echo "  oferta de $CORREO_VENDEDOR -> id $ID_OFERTA"
echo "  claves: $K1  y  $K2"
echo "  carga:  $SOLICITUDES solicitudes, $CLIENTES clientes a la vez, $UNIDADES unidades"
echo "  version de Redis: $(R INFO server | tr -d '\r' | grep redis_version | cut -d: -f2)"


# ============================================================
# Una ronda: sembrar, machacar, contar.
# ============================================================
# $1 = etiqueta, $2 = cuantas unidades pide cada solicitud
ronda() {
    local etiqueta="$1" por_solicitud="$2"

    # Cuantas reservas caben, y cuanto stock tiene que sobrar. Con 100 unidades
    # y pedidos de 3 son 33 reservas y sobra 1: ese "sobra 1" es la parte que
    # importa. Un script que comprobara `stock > 0` en vez de
    # `stock >= cantidad` daria 34 reservas y dejaria el contador en -2.
    local reservas_esperadas=$(( UNIDADES / por_solicitud ))
    local vendidas_esperadas=$(( reservas_esperadas * por_solicitud ))
    local stock_esperado=$(( UNIDADES - vendidas_esperadas ))
    local rechazos_esperados=$(( SOLICITUDES - reservas_esperadas ))

    titulo "$etiqueta -- $por_solicitud unidad(es) por solicitud"

    # ttl de reserva 0 = las reservas NO vencen durante la carga.
    #
    # Es a proposito: si vencieran, la cosecha devolveria unidades en el medio y
    # se podrian entregar mas de $UNIDADES reservas en total, legitimamente. El
    # conteo dejaria de ser comprobable con un numero fijo. El vencimiento se
    # prueba aparte, mas abajo.
    R EVALSHA "$SHA" 2 "$K1" "$K2" sembrar "$UNIDADES" 600 | tr '\n' ' '
    echo

    cargar evalsha "$SHA" 2 "$K1" "$K2" reservar __rand_int__ "$por_solicitud" 0
    echo "  $VELOCIDAD"
    concurrencia_real

    leer_estado
    echo
    echo "  stock final      $E_STOCK"
    echo "  reservado        $E_RESERVADO"
    echo "  tickets dados    $E_TICKET"
    echo "  reservas vivas   $E_PENDIENTES   (ZCARD, contador independiente)"
    echo "  rechazos         $E_RECHAZOS"
    echo

    igual "reservas entregadas" "$E_TICKET" "$reservas_esperadas"
    igual "unidades reservadas" "$E_RESERVADO" "$vendidas_esperadas"
    igual "stock final"         "$E_STOCK" "$stock_esperado"
    igual "rechazos"            "$E_RECHAZOS" "$rechazos_esperados"
    igual "ZCARD contra contador de tickets" "$E_PENDIENTES" "$E_TICKET"
    igual "conservacion: stock + reservado" \
          "$(( E_STOCK + E_RESERVADO ))" "$UNIDADES"

    # La comprobacion que de verdad importa: el contador NUNCA quedo negativo.
    # Es la definicion de sobreventa en este diseno.
    if [ "$E_STOCK" -lt 0 ]; then
        mal "SOBREVENTA: el stock quedo en $E_STOCK"
    else
        ok "sin sobreventa: el stock nunca bajo de 0"
    fi

    if [ "$(( E_TICKET * por_solicitud ))" -gt "$UNIDADES" ]; then
        mal "SOBREVENTA: se entregaron $E_TICKET reservas de $por_solicitud sobre $UNIDADES unidades"
    else
        ok "se entregaron $E_TICKET reservas y no cabia ninguna mas"
    fi

    igual "solicitudes contestadas (reservas + rechazos)" \
          "$(( E_TICKET + E_RECHAZOS ))" "$SOLICITUDES"
}


for n in $(seq 1 "$RONDAS"); do
    ronda "RONDA $n.A  todos piden 1" 1
    ronda "RONDA $n.B  todos piden 3" 3
done


titulo "CONTROL -- la forma ingenua, con la misma carga"
# DECRBY es un comando atomico de Redis. Aqui sobrevende igual, y por eso el
# argumento no es "Redis es de un solo hilo" sino "la comprobacion tiene que
# estar dentro del mismo paso que el descuento".
#
# OJO CON LO QUE ESTA RONDA NO DICE, que es lo que decia antes: que el contador
# termine en -900 NO demuestra que hubo concurrencia. DECRBY no comprueba nada,
# asi que 1000 DECRBY sobre 100 dan -900 aunque corran en fila india -- medido
# con -c 1. La concurrencia la comprueba `concurrencia_real`, contando
# conexiones, y esta ronda solo demuestra que un comando atomico sin la
# comprobacion adentro sobrevende igual.

R SET "$K_INGENUO" "$UNIDADES" > /dev/null
cargar decrby "$K_INGENUO" 1
echo "  $VELOCIDAD"
concurrencia_real
INGENUO=$(R GET "$K_INGENUO")
echo
echo "  contador ingenuo al final: $INGENUO"

if [ "$INGENUO" -lt 0 ]; then
    ok "la forma ingenua SI sobrevendio ($INGENUO): un comando atomico sin la comprobacion adentro no alcanza"
else
    mal "la forma ingenua termino en $INGENUO y deberia ser negativo: o la carga no llego, o alguien le puso una comprobacion al control"
fi


titulo "VENCIMIENTO DE RESERVAS -- lo abandonado vuelve solo"
# La contracara de reservar: el que gana una unidad y no paga no se la queda
# para siempre. La cosecha corre dentro del mismo script atomico de la reserva
# siguiente, sin proceso de fondo y sin escuchar eventos de expiracion (que se
# pierden si nadie esta suscrito en ese momento, y el stock se perderia en
# silencio).

VENCE_EN=6

R EVALSHA "$SHA" 2 "$K1" "$K2" sembrar 2 600 > /dev/null

# Las tres reservas van en UN SOLO docker exec, por stdin de redis-cli.
#
# Esto no es una optimizacion: es la unica forma de que la prueba mida lo que
# dice. Cada `docker exec` cuesta cerca de un segundo, asi que mandarlas en tres
# llamadas separadas hacia que las dos primeras reservas ya hubieran VENCIDO
# cuando salia la tercera. La tercera entonces recibia una unidad cosechada y
# contestaba VENDIDO, y el renglon de arriba seguia diciendo "se va con las
# manos vacias". La prueba no fallaba: narraba otra cosa de la que pasaba.
echo "  2 unidades, tres personas, reservas que vencen en $VENCE_EN segundos:"
SALIDA=$(printf '%s\n' \
    "EVALSHA $SHA 2 $K1 $K2 reservar abandona1 1 $VENCE_EN" \
    "EVALSHA $SHA 2 $K1 $K2 reservar abandona2 1 $VENCE_EN" \
    "EVALSHA $SHA 2 $K1 $K2 reservar tarde 1 $VENCE_EN" \
    | docker exec -i "$CONTENEDOR_REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning)
echo "$SALIDA" | paste - - - | sed 's/^/    /'

igual "la primera"  "$(echo "$SALIDA" | sed -n '1p')" "VENDIDO"
igual "la segunda"  "$(echo "$SALIDA" | sed -n '4p')" "VENDIDO"
igual "la tercera (no quedaban)" "$(echo "$SALIDA" | sed -n '7p')" "AGOTADO"

leer_estado
igual "stock con las dos reservadas" "$E_STOCK" "0"

echo "  nadie paga; esperando $((VENCE_EN + 2)) segundos a que las reservas venzan..."
sleep $((VENCE_EN + 2))

echo "  el que llega tarde ahora SI encuentra unidades:"
TARDE=$(R EVALSHA "$SHA" 2 "$K1" "$K2" reservar despues 1 600)
echo "$TARDE" | paste - - - | sed 's/^/    /'
igual "reserva despues del vencimiento" "$(echo "$TARDE" | sed -n '1p')" "VENDIDO"

leer_estado
igual "unidades recuperadas (stock + reservado)" \
      "$(( E_STOCK + E_RESERVADO ))" "2"


titulo "CONFIRMAR Y DEVOLVER -- el puente con PostgreSQL"
# confirmar = el pago paso, las unidades salen de "reservado" y entran a
# "vendidas". devolver = el pago fallo, vuelven al stock. El stock NO se toca
# al confirmar: ya se habia descontado al reservar.

R EVALSHA "$SHA" 2 "$K1" "$K2" sembrar 5 600 > /dev/null
T1=$(R EVALSHA "$SHA" 2 "$K1" "$K2" reservar u_paga 2 600 | sed -n '2p')
T2=$(R EVALSHA "$SHA" 2 "$K1" "$K2" reservar u_falla 2 600 | sed -n '2p')
echo "  tickets $T1 (va a pagar) y $T2 (se le cae el pago)"
R EVALSHA "$SHA" 2 "$K1" "$K2" confirmar u_paga  "$T1" | tr '\n' ' '; echo
R EVALSHA "$SHA" 2 "$K1" "$K2" devolver  u_falla "$T2" | tr '\n' ' '; echo
leer_estado
igual "stock (1 que sobraba + 2 devueltas)" "$E_STOCK" "3"
igual "vendidas"  "$E_VENDIDAS" "2"
igual "reservado" "$E_RESERVADO" "0"
echo "  confirmar dos veces el mismo ticket:"
R EVALSHA "$SHA" 2 "$K1" "$K2" confirmar u_paga "$T1" | tr '\n' ' '; echo
leer_estado
igual "vendidas despues del reintento (no se duplica)" "$E_VENDIDAS" "2"


titulo "EL TICKET ES DE SU DUENO -- nadie mas lo toca"
# Los tickets son enteros consecutivos que salen de HINCRBY: no son secretos,
# adivinarlos es contar. Antes ni `confirmar` ni `devolver` miraban de quien era
# el ticket que recibian, y un cuarto llamador que no habia reservado nada podia
# correr `devolver 1`, `devolver 2`, `devolver 3` y soltar las reservas de los
# tres compradores. El campo u:<ticket> se escribia y no se leia nunca.
#
# Esta ronda es la que impide que eso vuelva: si alguien quita la comprobacion
# de dueno, las dos primeras lineas se ponen rojas.

R EVALSHA "$SHA" 2 "$K1" "$K2" sembrar 5 600 > /dev/null
T3=$(R EVALSHA "$SHA" 2 "$K1" "$K2" reservar victima 3 600 | sed -n '2p')
echo "  victima reserva 3 unidades y se lleva el ticket $T3"

echo "  un tercero, que no reservo nada, intenta devolver ese ticket:"
AJENO=$(R EVALSHA "$SHA" 2 "$K1" "$K2" devolver ladron "$T3")
echo "$AJENO" | tr '\n' ' '; echo
igual "devolver un ticket ajeno" "$(echo "$AJENO" | sed -n '1p')" "TICKET_AJENO"

echo "  y confirmarlo:"
AJENO2=$(R EVALSHA "$SHA" 2 "$K1" "$K2" confirmar ladron "$T3")
echo "$AJENO2" | tr '\n' ' '; echo
igual "confirmar un ticket ajeno" "$(echo "$AJENO2" | sed -n '1p')" "TICKET_AJENO"

# Y lo que de verdad importa: que el rechazo no haya movido nada. La
# comprobacion de dueno cae ANTES de la primera escritura justamente para esto,
# porque Redis no deshace lo que un script ya escribio.
leer_estado
igual "el stock no se movio con los dos intentos ajenos" "$E_STOCK" "2"
igual "la reserva de la victima sigue en pie"            "$E_RESERVADO" "3"

echo "  la victima si puede con el suyo:"
R EVALSHA "$SHA" 2 "$K1" "$K2" confirmar victima "$T3" | tr '\n' ' '; echo
leer_estado
igual "vendidas tras confirmar la propia" "$E_VENDIDAS" "3"


titulo "LAS DOS CLAVES VENCEN JUNTAS"
# El ZSET de reservas nace en el ZADD de `reservar`, no en `sembrar`: alli el
# EXPIRE caia sobre una clave que el DEL de la linea anterior acababa de borrar,
# devolvia 0 y no creaba nada. Resultado medido: el hash vencia y el ZSET quedaba
# con TTL -1, o sea INMORTAL, con sus tickets adentro para siempre. Cada venta
# limitada con fecha de cierre dejaba una clave permanente, y como el README
# exige maxmemory-policy noeviction esas claves no se desalojan nunca.

R EVALSHA "$SHA" 2 "$K1" "$K2" sembrar 5 300 > /dev/null
igual "TTL del ZSET justo despues de sembrar (aun no existe)" "$(R TTL "$K2")" "-2"
R EVALSHA "$SHA" 2 "$K1" "$K2" reservar quien_sea 1 600 > /dev/null
TTL_HASH=$(R TTL "$K1")
TTL_ZSET=$(R TTL "$K2")
echo "  tras la primera reserva: TTL del hash $TTL_HASH, TTL del ZSET $TTL_ZSET"
if [ "$TTL_ZSET" -gt 0 ]; then
    ok "el ZSET tiene vencimiento ($TTL_ZSET s), no quedo inmortal"
else
    mal "el ZSET quedo con TTL $TTL_ZSET: no vence nunca y la clave es basura permanente"
fi
# Se comparan con tolerancia porque entre los dos docker exec pasa cerca de un
# segundo, y exigir el numero exacto haria fallar la prueba por la latencia de
# la herramienta y no por un bug.
DIF=$(( TTL_HASH - TTL_ZSET )); [ "$DIF" -lt 0 ] && DIF=$(( -DIF ))
if [ "$DIF" -le 2 ]; then
    ok "las dos claves vencen juntas (se llevan $DIF s de diferencia)"
else
    mal "el hash vence en $TTL_HASH s y el ZSET en $TTL_ZSET s: no vencen juntas"
fi


titulo "LIMPIEZA"

R DEL "$K1" "$K2" "$K_INGENUO" > /dev/null
SOBRANTES=$(R --scan --pattern "prueba:*" | grep -c . || true)
igual "claves con prefijo prueba: que quedaron" "$SOBRANTES" "0"

# La oferta de verdad no se toco en ningun momento: todo paso sobre claves con
# prefijo, y PostgreSQL solo se leyo. Se comprueba igual, porque afirmarlo sin
# medirlo es como no decirlo.
STOCK_PG=$(PSQL -c "SELECT stock FROM oferta WHERE id_oferta = $ID_OFERTA;")
echo "  stock en PostgreSQL de la oferta $ID_OFERTA: $STOCK_PG (nunca se escribio)"


titulo "RESULTADO"
if [ "$fallos" = "0" ]; then
    echo "  Sin sobreventa. $SOLICITUDES solicitudes con $CLIENTES clientes a la"
    echo "  vez sobre $UNIDADES unidades, $RONDAS ronda(s), y el contador no bajo"
    echo "  de 0 ni una sola vez. Sin candados, sin reintentos, sin compensar."
    exit 0
else
    echo "  $fallos comprobacion(es) FALLARON."
    exit 1
fi
