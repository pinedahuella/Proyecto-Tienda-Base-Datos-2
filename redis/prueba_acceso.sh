#!/usr/bin/env bash
# prueba_acceso.sh -- la evidencia del control de acceso de la Entrega final.
#
# El enunciado pide autenticacion y autorizacion configuradas en al menos un
# componente NoSQL, "con evidencia de que un usuario sin los permisos
# correspondientes no puede ejecutar operaciones fuera de su alcance". Esto es
# esa evidencia, sobre los cuatro usuarios de ACL que define docker-compose.yml.
#
#   backend     el backend (desde el 2026-10-23). Lee y escribe solo claves mesh:*
#   default     los scripts y pruebas. Lee y escribe cualquier clave, no administra
#   inspeccion  RedisInsight. Solo lee
#   operador    mantenimiento. Todo
#
# Cada negativa tiene su control. Que `inspeccion` no pueda escribir solo
# significa algo si `default` si puede escribir la misma clave, y que `default`
# no pueda leer la configuracion solo significa algo si `operador` si puede.
# Sin el control, un Redis caido haria pasar todas las negativas.
#
# Uso:  bash redis/prueba_acceso.sh
# No toca ninguna clave de la tienda. Escribe una sola, con prefijo propio, y
# la borra al final.

set -u
export MSYS_NO_PATHCONV=1

DIR="$(cd "$(dirname "$0")" && pwd)"
REDIS="${CONTENEDOR_REDIS:-mesh-redis}"

leer_env() { grep -E "^$1=" "$DIR/../.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r'; }
P_DEFAULT="${REDIS_PASSWORD:-$(leer_env REDIS_PASSWORD)}"
P_BACKEND="${REDIS_BACKEND_PASSWORD:-$(leer_env REDIS_BACKEND_PASSWORD)}"
P_INSPECCION="${REDIS_INSPECCION_PASSWORD:-$(leer_env REDIS_INSPECCION_PASSWORD)}"
P_OPERADOR="${REDIS_OPERADOR_PASSWORD:-$(leer_env REDIS_OPERADOR_PASSWORD)}"
for v in P_DEFAULT P_BACKEND P_INSPECCION P_OPERADOR; do
    if [ -z "${!v}" ]; then
        echo "Faltan contrasenas de Redis en el .env. Corre .\\arrancar.ps1, que las agrega." >&2
        exit 1
    fi
done

CLAVE="prueba:acceso:$$"
# La del usuario backend tiene que empezar con mesh:, como todas las de la tienda
CLAVE_MESH="mesh:prueba:acceso:$$"
ok=0; fallo=0

# como USUARIO CONTRASENA COMANDO...   la salida de redis-cli, en una linea
como() {
    local u="$1" p="$2"; shift 2
    docker exec "$REDIS" redis-cli --no-auth-warning --user "$u" --pass "$p" "$@" 2>&1 | tr -d '\r' | head -3 | tr '\n' ' ' | sed 's/ $//'
}
bien()  { ok=$((ok+1));     printf '  OK     %s\n' "$1"; }
mal()   { fallo=$((fallo+1)); printf '  FALLA  %s  (salio: %s)\n' "$1" "$2"; }
niega() { case "$2" in *NOPERM*) bien "$1";; *) mal "$1" "$2";; esac; }

# Los comandos que destruyen algo (FLUSHALL, SHUTDOWN, CONFIG SET, ACL SETUSER)
# NO se intentan a ciegas. Si la configuracion estuviera mal, la prueba misma
# vaciaria Redis o lo apagaria. Primero se le pregunta a Redis con ACL DRYRUN,
# que contesta sin ejecutar, y solo si dice que lo negaria se intenta de verdad
# para ver el NOPERM. Si DRYRUN dice que lo dejaria pasar, falla sin tocar nada.
#   niega_sin_riesgo DESCRIPCION USUARIO CONTRASENA COMANDO...
niega_sin_riesgo() {
    local que="$1" u="$2" p="$3"; shift 3
    local previo
    previo=$(como operador "$P_OPERADOR" ACL DRYRUN "$u" "$@")
    case "$previo" in
        *"no permissions"*) niega "$que" "$(como "$u" "$p" "$@")";;
        *) mal "$que" "ACL DRYRUN dice que lo dejaria pasar, no se intento. $previo";;
    esac
}
deja()  { case "$2" in *NOPERM*|*WRONGPASS*|*ERR*) mal "$1" "$2";; *) bien "$1";; esac; }

limpiar() { como operador "$P_OPERADOR" DEL "$CLAVE" "$CLAVE_MESH" >/dev/null; }
trap limpiar EXIT
trap 'exit 130' INT TERM HUP

echo "1. Los cuatro usuarios existen y se identifican"
deja "operador ve la lista de usuarios" "$(como operador "$P_OPERADOR" ACL USERS)"
# Sin `como`, que se queda con tres lineas: son cuatro usuarios.
USUARIOS=$(docker exec "$REDIS" redis-cli --no-auth-warning --user operador --pass "$P_OPERADOR" ACL USERS 2>&1 | tr -d '\r' | tr '\n' ' ')
case "$USUARIOS" in *backend*default*inspeccion*operador*) bien "son backend, default, inspeccion y operador";; *) mal "son backend, default, inspeccion y operador" "$USUARIOS";; esac
[ "$(como default "$P_DEFAULT" ACL WHOAMI)" = "default" ] && bien "default entra con su contrasena" || mal "default entra con su contrasena" "$(como default "$P_DEFAULT" ACL WHOAMI)"
[ "$(como inspeccion "$P_INSPECCION" PING)" = "PONG" ] && bien "inspeccion entra con la suya" || mal "inspeccion entra con la suya" "$(como inspeccion "$P_INSPECCION" PING)"
case "$(como inspeccion "$P_DEFAULT" PING)" in *WRONGPASS*) bien "inspeccion no entra con la contrasena del backend";; *) mal "inspeccion no entra con la contrasena del backend" "$(como inspeccion "$P_DEFAULT" PING)";; esac
case "$(docker exec "$REDIS" redis-cli PING 2>&1)" in *NOAUTH*|*WRONGPASS*) bien "sin contrasena no se entra";; *) mal "sin contrasena no se entra" "$(docker exec "$REDIS" redis-cli PING 2>&1)";; esac

echo "2. default, los scripts del equipo, trabaja con datos y no administra"
deja "escribe una clave" "$(como default "$P_DEFAULT" SET "$CLAVE" uno EX 120)"
[ "$(como default "$P_DEFAULT" GET "$CLAVE")" = "uno" ] && bien "la lee" || mal "la lee" "$(como default "$P_DEFAULT" GET "$CLAVE")"
deja "le pone vencimiento, como al carrito" "$(como default "$P_DEFAULT" EXPIRE "$CLAVE" 120)"
deja "corre un script Lua, como la venta relampago" "$(como default "$P_DEFAULT" EVAL "return redis.call('GET', KEYS[1])" 1 "$CLAVE")"
deja "recorre claves con SCAN" "$(como default "$P_DEFAULT" SCAN 0 MATCH 'prueba:acceso:*' COUNT 100)"
deja "pide INFO, que ioredis usa al conectar" "$(como default "$P_DEFAULT" INFO server)"
niega_sin_riesgo "no puede vaciar la base con FLUSHALL" default "$P_DEFAULT" FLUSHALL
niega "no puede leer la configuracion" "$(como default "$P_DEFAULT" CONFIG GET maxmemory)"
niega_sin_riesgo "no puede cambiar la configuracion" default "$P_DEFAULT" CONFIG SET appendonly no
niega "no puede listar todas las claves con KEYS" "$(como default "$P_DEFAULT" KEYS '*')"
niega_sin_riesgo "no puede tocar los usuarios" default "$P_DEFAULT" ACL SETUSER intruso on '>x' '+@all'
niega_sin_riesgo "no puede apagar el servidor" default "$P_DEFAULT" SHUTDOWN NOSAVE

echo "3. backend, el usuario del backend, solo las claves de la tienda"
deja "escribe una clave mesh:" "$(como backend "$P_BACKEND" SET "$CLAVE_MESH" uno EX 120)"
[ "$(como backend "$P_BACKEND" GET "$CLAVE_MESH")" = "uno" ] && bien "la lee" || mal "la lee" "$(como backend "$P_BACKEND" GET "$CLAVE_MESH")"
deja "le pone vencimiento, como al carrito" "$(como backend "$P_BACKEND" EXPIRE "$CLAVE_MESH" 120)"
deja "corre un script Lua sobre ella" "$(como backend "$P_BACKEND" EVAL "return redis.call('GET', KEYS[1])" 1 "$CLAVE_MESH")"
deja "pide INFO, que ioredis usa al conectar" "$(como backend "$P_BACKEND" INFO server)"
niega "NO lee una clave fuera de mesh: (la de default existe)" "$(como backend "$P_BACKEND" GET "$CLAVE")"
niega "NO escribe fuera de mesh:" "$(como backend "$P_BACKEND" SET "$CLAVE" dos)"
niega "un script Lua tampoco sale de mesh:" "$(como backend "$P_BACKEND" EVAL "return redis.call('GET', KEYS[1])" 1 "$CLAVE")"
niega_sin_riesgo "no puede vaciar la base con FLUSHALL" backend "$P_BACKEND" FLUSHALL
niega "no puede leer la configuracion" "$(como backend "$P_BACKEND" CONFIG GET maxmemory)"
niega_sin_riesgo "no puede tocar los usuarios" backend "$P_BACKEND" ACL SETUSER intruso on '>x' '+@all'
case "$(como backend "$P_DEFAULT" PING)" in *WRONGPASS*) bien "no entra con la contrasena de default";; *) mal "no entra con la contrasena de default" "$(como backend "$P_DEFAULT" PING)";; esac

echo "4. inspeccion, RedisInsight, solo mira"
[ "$(como inspeccion "$P_INSPECCION" GET "$CLAVE")" = "uno" ] && bien "lee la clave" || mal "lee la clave" "$(como inspeccion "$P_INSPECCION" GET "$CLAVE")"
deja "ve cuanto le falta para vencer" "$(como inspeccion "$P_INSPECCION" TTL "$CLAVE")"
deja "recorre claves con SCAN" "$(como inspeccion "$P_INSPECCION" SCAN 0 COUNT 10)"
niega "no puede escribir" "$(como inspeccion "$P_INSPECCION" SET "$CLAVE" dos)"
niega_sin_riesgo "no puede borrar" inspeccion "$P_INSPECCION" DEL "$CLAVE"
niega "no puede cambiar el vencimiento" "$(como inspeccion "$P_INSPECCION" PERSIST "$CLAVE")"
niega "no puede correr scripts" "$(como inspeccion "$P_INSPECCION" EVAL "return 1" 0)"
niega_sin_riesgo "no puede vaciar la base" inspeccion "$P_INSPECCION" FLUSHALL
[ "$(como default "$P_DEFAULT" GET "$CLAVE")" = "uno" ] && bien "control, la clave sigue intacta" || mal "control, la clave sigue intacta" "$(como default "$P_DEFAULT" GET "$CLAVE")"

echo "5. operador puede lo que a los otros se les niega"
deja "lee la configuracion" "$(como operador "$P_OPERADOR" CONFIG GET maxmemory)"
deja "ve las reglas de cada usuario" "$(como operador "$P_OPERADOR" ACL GETUSER inspeccion)"
deja "borra la clave de la prueba" "$(como operador "$P_OPERADOR" DEL "$CLAVE")"
[ "$(como default "$P_DEFAULT" EXISTS "$CLAVE")" = "0" ] && bien "control, ya no existe" || mal "control, ya no existe" "$(como default "$P_DEFAULT" EXISTS "$CLAVE")"

echo
echo "=============================================================="
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -eq 0 ]
