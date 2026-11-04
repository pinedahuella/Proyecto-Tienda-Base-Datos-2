#!/usr/bin/env bash
# pruebas/dos_paises.sh -- dos personas de paises distintos no son un viaje imposible.
#
#   bash pruebas/dos_paises.sh
#
# Lo que se mide, en este orden:
#   1. Una persona se registra desde Guatemala y otra desde Tokio.
#   2. Las dos entran A LA VEZ, cada una desde su pais, dos veces. No debe salir
#      ninguna senal de fraude: son dos cuentas distintas, cada una en su casa.
#   3. Control. La de Guatemala entra ahora desde Tokio, segundos despues. Ahi SI
#      tiene que saltar viaje_imposible (unos 12 000 km en segundos), y la de Tokio
#      sigue sin nada. Sin este paso, un detector apagado pasaria el paso 2.
#
# Las IPs van en X-Forwarded-For, como en demo-evento-fraude.ps1: el backend se la
# cree a lo que viene de esta maquina (trustProxy 'loopback') y geoip-lite las
# ubica igual que a una real. No se les manda nada a esas IPs.
#
# Al final borra lo que sembro (las dos cuentas, sus senales y sus inicios de
# sesion en MongoDB y en Elasticsearch), tambien si se corta a la mitad.
# Necesita el backend arriba. En modo remoto (source remoto/activar.sh) corre
# contra las bases de la otra PC.
set -u
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
ES="${ES:-http://localhost:9200}"
. "$(dirname "$0")/../seguridad/url_elastic.sh"
INDICE_EVENTOS="${INDICE_EVENTOS:-mesh_eventos_autenticacion}"
PG="${PG:-mesh-postgres}"
MONGO="${MONGO:-mesh-mongo}"
if [ -f "$RAIZ/.env" ]; then set -a; . "$RAIZ/.env"; set +a; fi
PG_USUARIO="${PG_USUARIO:-${DB_USER:-meme}}"
PG_BASE="${PG_BASE:-${DB_NAME:-mesh}}"
export MSYS_NO_PATHCONV=1

GT=190.106.200.1    # Guatemala
JP=133.242.1.1      # Tokio
CORRIDA="$(date +%s)$$"
A="prueba.dospaises.gt.${CORRIDA}@mesh.com"
B="prueba.dospaises.jp.${CORRIDA}@mesh.com"
CLAVE='Comprador123!'
SALIDA_A=".mesh-dospaises-a.txt"; SALIDA_B=".mesh-dospaises-b.txt"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
sql() { docker exec "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -qtAc "$1" 2>/dev/null | tr -d '\r'; }
mongo() {
    docker exec -e JS="$1" "$MONGO" sh -c 'mongosh --quiet \
        -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
        --authenticationDatabase admin "$MONGO_INITDB_DATABASE" --eval "$JS"' 2>/dev/null | tr -d '\r'
}

registrar() {
    curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST "$API/usuario/registro" \
        -H 'Content-Type: application/json' -H "X-Forwarded-For: $2" -A 'mesh-prueba-dospaises' \
        --data-binary "{\"correo_electronico\":\"$1\",\"usuario\":\"$(printf '%s' "${1%%@*}" | tr '.' '_')\",\"nombre\":\"Dos\",\"apellido\":\"Paises\",\"contrasena\":\"$CLAVE\"}"
}
entrar() {
    curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST "$API/usuario/login" \
        -H 'Content-Type: application/json' -H "X-Forwarded-For: $2" -A 'mesh-prueba-dospaises' \
        --data-binary "{\"identificador\":\"$1\",\"contrasena\":\"$CLAVE\"}"
}
# Las senales que tocan a estas dos cuentas o a sus IPs desde que empezo la corrida
senales() {
    sql "SELECT t.tipo_senal_fraude_nombre || ' ' || s.clave
           FROM senal_fraude s JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude)
          WHERE (s.fecha_creacion >= '$INICIO' OR s.ultima_deteccion >= '$INICIO')
            AND (s.clave IN ('$A', '$B', '$GT', '$JP') OR s.detalle::text LIKE '%dospaises.%.${CORRIDA}%')"
}

limpiar() {
    local ids
    ids=$(sql "SELECT string_agg(id_usuario::text, ',') FROM usuarios WHERE correo_electronico IN ('$A', '$B')")
    if [ -n "$ids" ]; then
        sql "DELETE FROM senal_fraude WHERE id_senal_fraude IN (SELECT id_senal_fraude FROM senal_fraude_cuenta WHERE id_usuario IN ($ids))
               OR (clave IN ('$A', '$B') AND fecha_creacion >= '$INICIO')" >/dev/null
        sql "DELETE FROM notificacion_fraude WHERE id_usuario IN ($ids)" >/dev/null
        sql "DELETE FROM log_login WHERE id_usuario IN ($ids)" >/dev/null
        sql "DELETE FROM log_registro WHERE id_usuario IN ($ids)" >/dev/null
        sql "DELETE FROM usuarios WHERE id_usuario IN ($ids)" >/dev/null
    fi
    mongo "db.eventos_autenticacion.deleteMany({identificador_intentado: {\$in: ['$A', '$B']}})" >/dev/null
    curl -s -m 30 -X POST "$ES/$INDICE_EVENTOS/_delete_by_query?refresh=true" -H 'Content-Type: application/json' \
        -d "{\"query\":{\"terms\":{\"identificador_intentado\":[\"$A\",\"$B\"]}}}" >/dev/null 2>&1
    rm -f "$SALIDA_A" "$SALIDA_B"
}

INICIO=$(sql "SELECT now()")
if [ -z "$INICIO" ]; then echo "No llego a PostgreSQL (docker exec $PG). Arranca las bases o el modo remoto." >&2; exit 1; fi
trap limpiar EXIT INT TERM

titulo "1. Cada persona se registra desde su pais"
c=$(registrar "$A" $GT); [ "$c" = 201 ] && OK "registro desde Guatemala (201)" || FALLA "registro desde Guatemala ($c)"
c=$(registrar "$B" $JP); [ "$c" = 201 ] && OK "registro desde Tokio (201)" || FALLA "registro desde Tokio ($c)"

titulo "2. Las dos entran a la vez, cada una desde su pais"
for vuelta in 1 2; do
    entrar "$A" $GT > "$SALIDA_A" & entrar "$B" $JP > "$SALIDA_B" & wait
    [ "$(cat "$SALIDA_A")" = 200 ] && [ "$(cat "$SALIDA_B")" = 200 ] \
        && OK "vuelta $vuelta, las dos entran (200 y 200)" || FALLA "vuelta $vuelta: $(cat "$SALIDA_A") y $(cat "$SALIDA_B")"
done
sleep 4
n=$(senales)
[ -z "$n" ] && OK "ninguna senal de fraude por dos personas en paises distintos" || FALLA "salieron senales: $n"

titulo "3. Control. La persona de Guatemala entra ahora desde Tokio"
c=$(entrar "$A" $JP); [ "$c" = 200 ] && OK "entra desde Tokio (200)" || FALLA "no entro desde Tokio ($c)"
sleep 4
v=$(sql "SELECT (s.detalle->>'distancia_km') || ' km, ' || (s.detalle->'ubicacion_anterior'->>'pais') || ' a ' || (s.detalle->'ubicacion_actual'->>'pais')
           FROM senal_fraude s JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude)
          WHERE t.tipo_senal_fraude_nombre = 'viaje_imposible' AND s.clave = '$A'")
[ -n "$v" ] && OK "salta viaje_imposible para esa cuenta ($v)" || FALLA "no salto viaje_imposible"
otras=$(senales | grep -v "^viaje_imposible $A\$" | grep -v "^toma_cuenta $A\$")
[ -z "$otras" ] && OK "la persona de Tokio sigue sin ninguna senal" || FALLA "senales de mas: $otras"

echo
echo "$ok OK, $fallo FALLA"
[ "$fallo" -eq 0 ]
