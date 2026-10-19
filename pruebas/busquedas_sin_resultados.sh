#!/usr/bin/env bash
# pruebas/busquedas_sin_resultados.sh -- GET /admin/eventos/busquedas-sin-resultados,
# con busquedas reales por el buscador de la tienda.
#
#   bash pruebas/busquedas_sin_resultados.sh
#
# De Jose David (25f0fe0, 2026-10-16): lo mas buscado que no encontro nada, con
# las formas de escribir lo mismo juntas. Se apoya en la columna
# termino_normalizado de busqueda_realizada (MATERIALIZED, clickhouse/001_esquema.sql),
# que ClickHouse calcula sola en cada INSERT.
#
# Las busquedas se hacen por la ruta publica GET /buscador/productos/facetado,
# la que usa /buscar, con el parametro `sesion` que manda el navegador. Asi el
# evento lo escribe el backend, y ClickHouse solo se MIRA.
#
# QUE COMPRUEBA
# ============================================================
#   1. La columna termino_normalizado existe y normaliza (minusculas, sin
#      tildes, sin espacios de mas), sin tocar `termino`.
#   2. Cuatro formas de escribir lo mismo, en cuatro sesiones, salen como UN
#      grupo de 4 sesiones, con lo que cada una escribio.
#   3. Un error de tecleo se une al grupo mas buscado.
#   4. La misma sesion buscando dos veces cuenta una.
#   5. Una busqueda con filtro no cuenta. Sin sesion de admin, 401.
#
# Al terminar borra de ClickHouse las busquedas de la prueba (por su marcador
# de sesion), para que no cuenten en las tendencias.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
CH="${CH:-mesh-clickhouse}"
if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
export MSYS_NO_PATHCONV=1
export PYTHONUTF8=1

MARCA="prueba-bsr-$$"
PALABRA="zqxwvy$(date +%s | tail -c 5)"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
ch() { docker exec -i "$CH" clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database "${CLICKHOUSE_DB:-mesh_eventos}" -q "$1" < /dev/null 2>/dev/null; }
url() { python -c "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))" "$1"; }
buscar() { curl -s -o /dev/null -w '%{http_code}' "$API/buscador/productos/facetado?nombre=$(url "$1")&sesion=$2${3:-}"; }

limpiar() {
    ch "ALTER TABLE busqueda_realizada DELETE WHERE sesion LIKE '$MARCA%' SETTINGS mutations_sync = 2" >/dev/null
}
trap limpiar EXIT INT TERM

titulo "0. Todo arriba"
ADMIN=$(curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
        -d '{"identificador":"admin@mesh.com","contrasena":"Admin123"}' \
      | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1)
[ -n "$ADMIN" ] && OK "sesion de admin" || { echo "  No responde el backend en $API."; exit 1; }
[ "$(ch "SELECT count() FROM system.columns WHERE database=currentDatabase() AND table='busqueda_realizada' AND name='termino_normalizado'")" = "1" ] \
    && OK "busqueda_realizada tiene termino_normalizado" || { echo "  Falta la columna. Corre .\\arrancar.ps1"; exit 1; }


titulo "1. La normalizacion la hace ClickHouse"
n=$(ch "SELECT replaceRegexpAll(trimBoth(replaceRegexpAll(lowerUTF8(normalizeUTF8NFD('  Audífonos   INALÁMBRICOS  ')), '\\\\p{Mn}', '')), '\\\\s+', ' ')")
[ "$n" = "audifonos inalambricos" ] && OK "'  Audífonos   INALÁMBRICOS  ' queda '$n'" || FALLA "la expresion da '$n'"


titulo "2. Cuatro formas de escribir lo mismo"
FORMAS=("$PALABRA Pérez" "$PALABRA perez" "  ${PALABRA^^}   PEREZ " "$PALABRA pérez")
i=0
for f in "${FORMAS[@]}"; do
    i=$((i+1))
    c=$(buscar "$f" "$MARCA-$i")
    [ "$c" = "200" ] || FALLA "la busqueda '$f' contesto $c"
done
# Un error de tecleo, en otra sesion, y la sesion 1 repitiendo.
buscar "${PALABRA}x perez" "$MARCA-5" >/dev/null
buscar "$PALABRA Pérez" "$MARCA-1" >/dev/null
# Una con filtro de categoria: no tiene que contar.
buscar "$PALABRA perez" "$MARCA-6" "&categoria=1" >/dev/null
for _ in $(seq 1 15); do
    [ "$(ch "SELECT count() FROM busqueda_realizada WHERE sesion LIKE '$MARCA%'")" -ge 7 ] 2>/dev/null && break
    sleep 1
done
filas=$(ch "SELECT count() FROM busqueda_realizada WHERE sesion LIKE '$MARCA%'")
[ "$filas" = "7" ] && OK "el backend escribio las 7 busquedas en ClickHouse" || FALLA "hay $filas busquedas de la prueba"
distintas=$(ch "SELECT uniqExact(termino_normalizado) FROM busqueda_realizada WHERE sesion LIKE '$MARCA%' AND sesion <> '$MARCA-5'")
[ "$distintas" = "1" ] && OK "las cuatro formas tienen el mismo termino_normalizado" || FALLA "salieron $distintas normalizados"
originales=$(ch "SELECT uniqExact(termino) FROM busqueda_realizada WHERE sesion LIKE '$MARCA%'")
[ "${originales:-0}" -ge 4 ] 2>/dev/null && OK "y termino se quedo como lo escribio cada uno ($originales formas)" || FALLA "termino tiene $originales formas"

r=$(curl -s "$API/admin/eventos/busquedas-sin-resultados?dias=1&limite=200" -H "Cookie: $ADMIN")
grupo=$(echo "$r" | python -c "
import sys,json
d=[g for g in json.load(sys.stdin)['payload'] if g['termino'].startswith('$PALABRA')]
if len(d)!=1: print('grupos=%d' % len(d))
else:
    g=d[0]; print('%s|%d|%d' % (g['termino'], g['sesiones'], len(g['como_lo_escribieron'])))")
IFS='|' read -r termino sesiones formas <<< "$grupo"
[ "$termino" = "$PALABRA perez" ] && OK "un solo grupo, '$termino'" || FALLA "grupo: $grupo"
[ "${sesiones:-0}" = "5" ] && OK "con 5 sesiones: las cuatro, mas el error de tecleo, y la que repitio cuenta una vez" || FALLA "sesiones = $sesiones"
[ "${formas:-0}" -ge 4 ] 2>/dev/null && OK "y $formas formas en como_lo_escribieron" || FALLA "como_lo_escribieron trae $formas"
[ "$(echo "$r" | python -c "
import sys,json
d=[g for g in json.load(sys.stdin)['payload'] if g['termino'].startswith('$PALABRA')]
print('si' if d and '${PALABRA}x perez' in d[0]['terminos_agrupados'] else 'no')")" = "si" ] \
    && OK "el error de tecleo quedo dentro del grupo" || FALLA "el error de tecleo no se agrupo"


titulo "3. Lo que no cuenta"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$API/admin/eventos/busquedas-sin-resultados")" = "401" ] && OK "sin sesion, 401" || FALLA "contesto sin sesion"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$API/admin/eventos/busquedas-sin-resultados?dias=0" -H "Cookie: $ADMIN")" = "400" ] && OK "dias=0, 400" || FALLA "dias=0 no dio 400"


titulo "LIMPIEZA"
limpiar
[ "$(ch "SELECT count() FROM busqueda_realizada WHERE sesion LIKE '$MARCA%'")" = "0" ] && OK "las busquedas de la prueba se borraron de ClickHouse" || FALLA "quedaron busquedas de la prueba"
trap - EXIT

titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
exit 0
