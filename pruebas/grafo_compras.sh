#!/usr/bin/env bash
# pruebas/grafo_compras.sh -- las compras en el grafo de Neo4j, "para ti" y
# "tambien compraron", con compras REALES por el backend.
#
#   bash pruebas/grafo_compras.sh
#   SIN_CAIDA=1 bash pruebas/grafo_compras.sh   sin parar Neo4j
#
# Lo de grafo-compras.md de Jose David (25f0fe0, 2026-10-16) llevado a una
# prueba que pasa por el camino completo: cuentas, carrito, checkout y
# cancelacion por HTTP; PostgreSQL, Neo4j y ClickHouse solo se MIRAN. La unica
# mano encima es parar y levantar el contenedor de Neo4j (parte 6).
#
#   (:Usuario)-[:HIZO]->(:Compra)-[:DE]->(:Producto)
#   (:Compra)-[:A_VENDEDOR]->(:Usuario)
#
# Cada linea de un pedido comprado, enviado o entregado es un :Compra. La cola
# evento_grafo_compra (migracion 041) va por cuenta, y el worker
# GrafoComprasSyncService la proyecta cada 10 s.
#
# QUE COMPRUEBA
# ============================================================
#   1. La conciliacion cuadra: tantos :Compra como lineas compradas en
#      PostgreSQL, y la cola vacia. La restriccion compra_id existe.
#   2. Tres cuentas nuevas compran: A lleva X e Y en un pedido, B lleva X, Y y
#      Z en otro. Cada linea aparece como :Compra con su producto y su vendedor.
#   3. GET /productos/X/tambien-compraron trae a Y (lo compraron los dos).
#   4. GET /productos/para-ti de A trae a Z, porque B compro lo mismo que A, y
#      nunca X ni Y, que A ya compro.
#   5. ClickHouse tiene las lineas de B: es de donde salen los combos.
#   6. Neo4j caido: la compra de C commitea igual, espera en la cola sin gastar
#      intentos, "para ti" da 503, y al volver se proyecta sola.
#   7. Cancelar el pedido de A se lleva sus :Compra, y la conciliacion vuelve a
#      cuadrar.
#
# NO ES REVERSIBLE del todo, igual que las otras pruebas que compran: deja tres
# cuentas y sus pedidos (el de A cancelado, con el stock devuelto).

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
NEO="${NEO:-mesh-neo4j}"
CH="${CH:-mesh-clickhouse}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
CLAVE="${CLAVE_PRUEBA:-Desarrollo123!}"
SIN_CAIDA="${SIN_CAIDA:-0}"

if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
[ -n "${NEO4J_PASSWORD:-}" ] || { echo "Falta NEO4J_PASSWORD en el .env de la raiz." >&2; exit 1; }

export MSYS_NO_PATHCONV=1
export PYTHONUTF8=1

PREF="gc$(date +%s | tail -c 7)"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

sql()    { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" 2>/dev/null | tr -d '\r'; }
cypher() { docker exec -i "$NEO" cypher-shell -u neo4j -p "$NEO4J_PASSWORD" --format plain "$1" 2>/dev/null | tail -n +2 | tr -d '\r"'; }
ch()     { docker exec -i "$CH" clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database "${CLICKHOUSE_DB:-mesh_eventos}" -q "$1" < /dev/null 2>/dev/null; }
campo() { python -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
for k in sys.argv[1].split('.'):
    if d is None: break
    d = d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" "$1"; }
entrar() {
    curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
        -d "{\"identificador\":\"$1\",\"contrasena\":\"$2\"}" \
      | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1
}
llamar() { curl -s -X "$1" "$API$2" -H "Content-Type: application/json" -H "Cookie: $3" -d "${4:-{\}}"; }

compras_en_grafo() { cypher "MATCH (:Usuario {id: $1})-[:HIZO]->(k:Compra) RETURN count(k);"; }
esperar_compras() {   # ID_USUARIO CUANTAS SEGUNDOS
    local i
    for i in $(seq 1 "$3"); do
        [ "$(compras_en_grafo "$1")" = "$2" ] && return 0
        sleep 1
    done
    return 1
}
conciliacion() {
    curl -s "$API/admin/grafo/conciliacion" -H "Cookie: $ADMIN" | python -c "
import sys,json
try: d=json.load(sys.stdin)['payload']
except Exception: print('sin-respuesta'); sys.exit()
c=[x for x in d['comparacion'] if x['recurso']=='compras']
k=d.get('cola_compras') or {}
print('%s|%s|%s|%s' % (d['cuadra'], c[0]['diferencia'] if c else 'sin-fila', k.get('pendientes'), c[0]['postgres'] if c else ''))"
}

# Una cuenta compradora nueva, con direccion. Deja COOKIE_<n>, ID_<n> y DIR_<n>.
nueva_cuenta() {
    local n=$1 correo="${PREF}$1@mesh.com"
    curl -s -o /dev/null -X POST "$API/usuario/registro" -H "Content-Type: application/json" \
        -d "{\"correo_electronico\":\"$correo\",\"usuario\":\"${PREF}$n\",\"nombre\":\"Grafo\",\"apellido\":\"Compras\",\"contrasena\":\"$CLAVE\"}"
    eval "COOKIE_$n=\$(entrar \"$correo\" \"$CLAVE\")"
    eval "ID_$n=\$(sql \"SELECT id_usuario FROM usuarios WHERE correo_electronico='$correo';\")"
    local c; eval "c=\$COOKIE_$n"
    llamar POST "/direccion-usuario" "$c" \
        '{"pais":"Guatemala","departamento":"Guatemala","ciudad":"Guatemala","direccion_exacta":"Direccion de la prueba del grafo","codigo_postal":"01001"}' >/dev/null
    eval "DIR_$n=\$(curl -s \"$API/direccion-usuario\" -H \"Cookie: \$c\" | python -c \"
import sys,json
d=json.load(sys.stdin).get('payload') or []
print(d[0]['id_direccion'] if d else '')\")"
}
# comprar COOKIE DIRECCION OFERTA... -> deja PEDIDO
comprar() {
    local c=$1 d=$2; shift 2
    curl -s -X DELETE "$API/carrito" -H "Cookie: $c" >/dev/null
    for of in "$@"; do llamar PUT "/carrito/lineas/$of" "$c" '{"cantidad":1}' >/dev/null; done
    local r; r=$(llamar POST "/carrito/comprar" "$c" "{\"id_direccion\":$d,\"metodo_pago\":\"efectivo contra entrega\"}")
    PEDIDO=$(echo "$r" | campo payload.id_pedido)
    [ "$(echo "$r" | campo payload.comprado)" = "True" ]
}


titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend responde" || { echo "  El backend no responde en $API."; exit 1; }
[ "$(sql "SELECT to_regclass('public.evento_grafo_compra') IS NOT NULL;")" = "t" ] \
    && OK "la migracion 041 esta (evento_grafo_compra)" || { echo "  Falta la 041. Corre .\\arrancar.ps1"; exit 1; }
[ -n "$(cypher "SHOW CONSTRAINTS YIELD name WHERE name = 'compra_id' RETURN name;")" ] \
    && OK "Neo4j tiene la restriccion compra_id (neo4j/001_esquema.cypher)" || FALLA "falta la restriccion compra_id"
ADMIN=$(entrar "admin@mesh.com" "Admin123")
[ -n "$ADMIN" ] && OK "sesion de admin" || { echo "  No se pudo entrar como admin."; exit 1; }


titulo "1. La conciliacion cuadra antes de empezar"
for _ in $(seq 1 90); do
    case "$(conciliacion)" in True\|0\|0\|*) break ;; esac
    sleep 2
done
IFS='|' read -r cuadra dif pend lineas <<< "$(conciliacion)"
[ "$dif" = "0" ] && OK "$lineas lineas compradas en PostgreSQL y los mismos :Compra en Neo4j" || FALLA "compras no cuadran: diferencia $dif"
[ "$pend" = "0" ] && OK "la cola evento_grafo_compra esta vacia" || FALLA "quedan $pend cuentas en la cola"
[ "$cuadra" = "True" ] && OK "la conciliacion entera cuadra" || FALLA "la conciliacion no cuadra"


titulo "2. Tres cuentas nuevas compran, prefijo $PREF"
# Tres productos distintos que la tienda vende con stock, fuera de ventas
# relampago y sin compras en el grafo de nadie fuera de esta prueba no hace
# falta: lo que se mide es que ESTAS compras aparezcan.
TIENDA_ID=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='tienda@mesh.com';")
mapfile -t OFS < <(sql "SELECT DISTINCT ON (o.id_producto_mongo) o.id_oferta || ' ' || o.id_producto_mongo
                          FROM oferta o JOIN estado_oferta e USING (id_estado_oferta)
                          JOIN variante_catalogo v ON v.id_producto_mongo=o.id_producto_mongo AND v.id_producto_variante_mongo=o.id_producto_variante_mongo
                         WHERE e.estado_oferta_nombre='activa' AND o.stock >= 5 AND NOT o.es_inventario_limitado
                           AND o.id_usuario=$TIENDA_ID AND v.estado='activa'
                         ORDER BY o.id_producto_mongo DESC, o.id_oferta LIMIT 3;")
read -r OF_X PX <<< "${OFS[0]}"; read -r OF_Y PY <<< "${OFS[1]}"; read -r OF_Z PZ <<< "${OFS[2]}"
[ -n "${PZ:-}" ] && OK "productos X=$PX, Y=$PY, Z=$PZ (ofertas de la tienda $OF_X, $OF_Y, $OF_Z)" || { echo "  No hay tres ofertas de la tienda para probar."; exit 1; }

for n in a b c; do nueva_cuenta "$n"; done
[ -n "$ID_a" ] && [ -n "$ID_b" ] && [ -n "$ID_c" ] && OK "cuentas ${PREF}a ($ID_a), ${PREF}b ($ID_b) y ${PREF}c ($ID_c)" || { echo "  No se crearon las cuentas."; exit 1; }

comprar "$COOKIE_a" "$DIR_a" "$OF_X" "$OF_Y" && PEDIDO_A=$PEDIDO && OK "${PREF}a compro X e Y en el pedido $PEDIDO_A" || FALLA "${PREF}a no pudo comprar"
comprar "$COOKIE_b" "$DIR_b" "$OF_X" "$OF_Y" "$OF_Z" && PEDIDO_B=$PEDIDO && OK "${PREF}b compro X, Y y Z en el pedido $PEDIDO_B" || FALLA "${PREF}b no pudo comprar"

esperar_compras "$ID_a" 2 30 && OK "en menos de 30 s ${PREF}a tiene sus 2 :Compra en el grafo" || FALLA "${PREF}a tiene $(compras_en_grafo "$ID_a") :Compra"
esperar_compras "$ID_b" 3 30 && OK "y ${PREF}b sus 3" || FALLA "${PREF}b tiene $(compras_en_grafo "$ID_b") :Compra"
forma=$(cypher "MATCH (:Usuario {id: $ID_b})-[:HIZO]->(k:Compra)-[:DE]->(p:Producto), (k)-[:A_VENDEDOR]->(v:Usuario)
                RETURN p.id + ':' + v.id + ':' + k.id_pedido ORDER BY p.id;" | tr '\n' ' ' | sed 's/ $//')
esperado=$(printf '%s\n' "$PX:$TIENDA_ID:$PEDIDO_B" "$PY:$TIENDA_ID:$PEDIDO_B" "$PZ:$TIENDA_ID:$PEDIDO_B" | sort -t: -k1,1n | tr '\n' ' ' | sed 's/ $//')
[ "$forma" = "$esperado" ] && OK "cada :Compra va a su producto y a la tienda, con su pedido" || FALLA "el grafo dice '$forma' y se esperaba '$esperado'"
ids_pg=$(sql "SELECT string_agg(pp.id_pedido_producto::text, ',' ORDER BY pp.id_pedido_producto) FROM pedido_producto pp WHERE pp.id_pedido=$PEDIDO_B;")
ids_neo=$(cypher "MATCH (:Usuario {id: $ID_b})-[:HIZO]->(k:Compra) RETURN k.id ORDER BY k.id;" | tr '\n' ',' | sed 's/,$//')
[ "$ids_pg" = "$ids_neo" ] && OK "el id de cada :Compra es el de su linea en pedido_producto ($ids_neo)" || FALLA "PostgreSQL $ids_pg, Neo4j $ids_neo"


titulo "3. Tambien compraron"
r=$(curl -s "$API/productos/$PX/tambien-compraron")
[ "$(echo "$r" | python -c "
import sys,json
d=json.load(sys.stdin)['payload']
f=[x for x in d if x['id_producto']==$PY]
print('si' if f and f[0]['compradores']>=2 and all(x['id_producto']!=$PX for x in d) else 'no')")" = "si" ] \
    && OK "GET /productos/$PX/tambien-compraron trae a $PY con 2 compradores o mas, y no al propio" || FALLA "tambien-compraron de $PX no trae a $PY"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$API/productos/abc/tambien-compraron")" = "400" ] && OK "un id que no es numero, 400" || FALLA "abc no dio 400"


titulo "4. Para ti, desde el grafo"
r=$(curl -s "$API/productos/para-ti" -H "Cookie: $COOKIE_a")
[ "$(echo "$r" | python -c "
import sys,json
d=json.load(sys.stdin)['payload']
ids=[x['id_producto'] for x in d]
z=[x for x in d if x['id_producto']==$PZ]
print('si' if z and $PX not in ids and $PY not in ids and set(z[0]['porque_compraste'])<= {$PX,$PY} else 'no')")" = "si" ] \
    && OK "para ${PREF}a sale Z ($PZ), porque ${PREF}b compro lo mismo; nunca X ni Y" || FALLA "para-ti de ${PREF}a: $(echo "$r" | head -c 300)"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$API/productos/para-ti")" = "401" ] && OK "sin sesion, 401" || FALLA "para-ti contesto sin sesion"


titulo "5. ClickHouse tiene las lineas de B (de ahi salen los combos)"
for _ in $(seq 1 15); do [ "$(ch "SELECT count() FROM compra_producto WHERE id_pedido=$PEDIDO_B")" = "3" ] && break; sleep 1; done
[ "$(ch "SELECT count() FROM compra_producto WHERE id_pedido=$PEDIDO_B")" = "3" ] \
    && OK "las 3 lineas del pedido $PEDIDO_B estan en compra_producto" || FALLA "compra_producto tiene $(ch "SELECT count() FROM compra_producto WHERE id_pedido=$PEDIDO_B") lineas del pedido"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$API/productos/combos")" = "200" ] && OK "GET /productos/combos responde (lo recalcula un worker cada 30 min)" || FALLA "combos no responde"


titulo "6. Neo4j caido y de vuelta"
if [ "$SIN_CAIDA" = "1" ]; then
    echo "  saltado (SIN_CAIDA=1)"
else
    docker stop "$NEO" >/dev/null 2>&1
    comprar "$COOKIE_c" "$DIR_c" "$OF_X" && OK "${PREF}c compra con Neo4j parado: el pedido no espera al grafo" || FALLA "${PREF}c no pudo comprar con Neo4j parado"
    sleep 12
    [ "$(sql "SELECT count(*) || '|' || coalesce(max(intentos),0) FROM evento_grafo_compra WHERE id_usuario=$ID_c AND procesado_en IS NULL;")" = "1|0" ] \
        && OK "su cuenta espera en la cola, sin gastar intentos" || FALLA "cola de ${PREF}c: $(sql "SELECT count(*) || '|' || coalesce(max(intentos),0) FROM evento_grafo_compra WHERE id_usuario=$ID_c AND procesado_en IS NULL;")"
    # Desde el 2026-10-20 (ADR-22) para ti sale de los pedidos en PostgreSQL
    # cuando Neo4j no responde. Antes daba 503.
    COD_PT=$(curl -s -o /dev/null -w '%{http_code}' -m 60 "$API/productos/para-ti" -H "Cookie: $COOKIE_a")
    [ "$COD_PT" = "200" ] && OK "para ti sin Neo4j sale del respaldo en PostgreSQL, 200" || FALLA "para ti sin Neo4j dio $COD_PT y no 200"
    docker start "$NEO" >/dev/null 2>&1
    for _ in $(seq 1 90); do [ -n "$(cypher "RETURN 1;")" ] && break; sleep 2; done
    esperar_compras "$ID_c" 1 90 && OK "Neo4j volvio y la compra de ${PREF}c se proyecto sola" || FALLA "${PREF}c tiene $(compras_en_grafo "$ID_c") :Compra"
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/productos/para-ti" -H "Cookie: $COOKIE_a")" = "200" ] && OK "y para ti responde otra vez, sin reiniciar el backend" || FALLA "para ti sigue fallando"
fi


titulo "7. Cancelar se lleva las compras del grafo"
r=$(llamar POST "/comprador/pedidos/$PEDIDO_A/cancelar" "$COOKIE_a")
[ "$(echo "$r" | campo ok)" = "True" ] && OK "${PREF}a cancelo el pedido $PEDIDO_A" || FALLA "no se pudo cancelar: $(echo "$r" | campo mensaje)"
esperar_compras "$ID_a" 0 30 && OK "y sus :Compra salieron del grafo" || FALLA "${PREF}a sigue con $(compras_en_grafo "$ID_a") :Compra"
[ "$(curl -s "$API/productos/para-ti" -H "Cookie: $COOKIE_a" | python -c "
import sys,json
print(len(json.load(sys.stdin)['payload']))")" = "0" ] && OK "sin compras, para ti de ${PREF}a queda vacio" || FALLA "para ti de ${PREF}a no quedo vacio"
for _ in $(seq 1 30); do case "$(conciliacion)" in True\|0\|0\|*) break ;; esac; sleep 2; done
IFS='|' read -r cuadra dif pend lineas <<< "$(conciliacion)"
[ "$cuadra|$dif|$pend" = "True|0|0" ] && OK "la conciliacion vuelve a cuadrar ($lineas lineas)" || FALLA "conciliacion: cuadra $cuadra, diferencia $dif, cola $pend"


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
echo "  Las compras llegan al grafo por su cola, con o sin Neo4j, y para ti y tambien compraron salen de ahi."
exit 0
