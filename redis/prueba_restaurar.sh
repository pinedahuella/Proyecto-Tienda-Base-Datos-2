#!/usr/bin/env bash
# redis/prueba_restaurar.sh -- la rama `restaurar` de inventario_limitado.lua
# hace lo mismo que el script provisional de Jose David.
#
#   bash redis/prueba_restaurar.sh
#
# El 2026-10-17 Jose David dejo en backend/elementos Generales/plan pendiente/
# un restaurar-venta-relampago.lua aparte, que el backend carga ademas del
# original, y pidio sumarlo como una rama mas de redis/inventario_limitado.lua.
# Se sumo con los mismos argumentos. Esta prueba corre los DOS con las mismas
# entradas, cada uno sobre sus propias claves de prueba, y exige que dejen
# exactamente el mismo estado en Redis y devuelvan lo mismo. Cuando el backend
# pase a llamar la rama (BACKEND-PENDIENTE), el provisional se puede borrar.
#
# Solo usa claves mesh:prueba:restaurar:*, y las borra al final.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
REDIS="${REDIS:-mesh-redis}"
if [ -z "${REDIS_PASSWORD:-}" ] && [ -f "$RAIZ/.env" ]; then
    REDIS_PASSWORD=$(grep -E "^REDIS_PASSWORD=" "$RAIZ/.env" | head -1 | cut -d= -f2- | tr -d '\r')
fi
[ -n "${REDIS_PASSWORD:-}" ] || { echo "Falta REDIS_PASSWORD en el .env de la raiz." >&2; exit 1; }
export MSYS_NO_PATHCONV=1

ORIGINAL="$RAIZ/redis/inventario_limitado.lua"
PROVISIONAL="$RAIZ/backend/elementos Generales/plan pendiente/restaurar-venta-relampago.lua"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
R() { docker exec -i "$REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@" 2>&1 | tr -d '\r'; }

# Los dos scripts se cargan una vez y se llaman por su SHA.
SHA_O=$(R SCRIPT LOAD "$(cat "$ORIGINAL")")
SHA_P=$(R SCRIPT LOAD "$(cat "$PROVISIONAL")")
[ ${#SHA_O} = 40 ] && [ ${#SHA_P} = 40 ] && OK "los dos scripts cargan en Redis" || { echo "  No cargaron: $SHA_O / $SHA_P"; exit 1; }

# El estado de una venta de prueba, ordenado para poder compararlo.
estado() {
    { R HGETALL "mesh:prueba:restaurar:$1" | paste - - | sort; echo '--'; R ZRANGE "mesh:prueba:restaurar:$1:reservas" 0 -1 WITHSCORES | paste - -; } | tr '\n' ' '
}
ttl() { R TTL "mesh:prueba:restaurar:$1"; }

# caso NOMBRE ARGS... : corre los dos, compara respuesta, estado y TTL.
caso() {
    local nombre=$1; shift
    R DEL mesh:prueba:restaurar:o mesh:prueba:restaurar:o:reservas mesh:prueba:restaurar:p mesh:prueba:restaurar:p:reservas >/dev/null
    # Algo de basura antes, para ver que se borra lo que habia.
    R HSET mesh:prueba:restaurar:o stock 99 r:7 1 >/dev/null; R HSET mesh:prueba:restaurar:p stock 99 r:7 1 >/dev/null
    local ro rp
    ro=$(R EVALSHA "$SHA_O" 2 mesh:prueba:restaurar:o mesh:prueba:restaurar:o:reservas restaurar "$@" | tr '\n' ' ')
    rp=$(R EVALSHA "$SHA_P" 2 mesh:prueba:restaurar:p mesh:prueba:restaurar:p:reservas restaurar "$@" | tr '\n' ' ')
    if [ "$ro" = "$rp" ]; then OK "$nombre: la misma respuesta ($ro)"; else FALLA "$nombre: rama '$ro', provisional '$rp'"; fi
    local eo ep
    eo=$(estado o); ep=$(estado p)
    [ "$eo" = "$ep" ] && OK "$nombre: el mismo estado en Redis" || FALLA "$nombre: estado distinto. rama '$eo' / provisional '$ep'"
    local to tp
    to=$(ttl o); tp=$(ttl p)
    [ "$to" = "$tp" ] || [ $((to - tp)) -le 1 ] 2>/dev/null && OK "$nombre: el mismo TTL ($to)" || FALLA "$nombre: TTL $to contra $tp"
}

AHORA=$(( $(date +%s) * 1000 ))
V1=$((AHORA + 600000)); V2=$((AHORA + 900000))

caso "sin reservas" 20 3600 0 0 0
caso "con dos reservas con ticket" 15 3600 4 2 2 3 11 2 "$V1" 5 12 3 "$V2"
caso "una sin ticket se numera despues del mas alto" 10 3600 9 1 2 3 11 2 "$V1" 0 13 1 "$V2"
caso "ticket_base mas alto que todos" 10 0 40 0 1 3 11 2 "$V1"
caso "argumentos que no cuadran" 10 3600 0 0 2 3 11 2 "$V1"
caso "stock negativo" -1 3600 0 0 0

R DEL mesh:prueba:restaurar:o mesh:prueba:restaurar:o:reservas mesh:prueba:restaurar:p mesh:prueba:restaurar:p:reservas >/dev/null
[ "$(R EXISTS mesh:prueba:restaurar:o mesh:prueba:restaurar:p)" = "0" ] && OK "las claves de prueba se borraron" || FALLA "quedaron claves de prueba"

echo
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
exit 0
