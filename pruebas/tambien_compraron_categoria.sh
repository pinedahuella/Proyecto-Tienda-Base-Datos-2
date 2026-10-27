#!/usr/bin/env bash
# pruebas/tambien_compraron_categoria.sh -- "quienes lo compraron tambien
# llevaron" ordena por grupos: primero SIEMPRE los de la misma categoria que el
# producto de la ficha, despues el resto, y dentro de cada grupo por cuantas
# cuentas los compraron. La categoria vive en el :Producto del grafo.
#
#   bash pruebas/tambien_compraron_categoria.sh
#   SIN_CAIDA=1 bash pruebas/tambien_compraron_categoria.sh   sin parar Neo4j ni MongoDB
#
# Compras REALES por el backend (cuentas, carrito, checkout y cancelacion por
# HTTP); PostgreSQL y Neo4j se MIRAN. Dos manos encima, las dos a proposito y
# dichas aqui: la parte 4 le cambia la categoria a un :Producto directo en
# Neo4j para ver que el worker GrafoCategoriasSyncService la arregla solo, y la
# parte 6 para y levanta los contenedores de Neo4j y de MongoDB.
#
# QUE COMPRUEBA
# ============================================================
#   1. Cada :Producto del grafo tiene la categoria que dice la copia del
#      catalogo en PostgreSQL (producto_catalogo).
#   2. En todos los productos comprados, la respuesta va por grupos: ningun
#      producto de otra categoria antes de uno de la misma, y dentro de cada
#      grupo de mas a menos compradores.
#   3. El caso que define la regla, con cuentas nuevas sobre un producto X que
#      nadie habia comprado: A y B llevan X e Y (otra categoria), C lleva X y
#      Z (la misma categoria que X). Sale Z con 1 comprador ANTES que Y con 2.
#   4. El worker: con la categoria de Z cambiada a mano en el grafo, Z baja de
#      grupo; en menos de 75 s el worker la devuelve y Z vuelve arriba. Igual
#      si se le borra la categoria.
#   5. Punta a punta por la API: el admin mueve el producto 2 (Laptop Vireo Air
#      12, cuyas caracteristicas tambien caben en Telefonos) a Telefonos; la
#      copia del catalogo, el grafo y el orden lo siguen, y al devolverlo
#      vuelven.
#   6. Con Neo4j caido sale lo mismo, desde los pedidos en PostgreSQL. Con
#      MongoDB caido tambien, con las tarjetas de la copia del catalogo.
#   7. Limpieza: se cancelan los tres pedidos y vuelve la existencia.
#
# Deja tres cuentas (prefijo tc) con sus pedidos cancelados, igual que
# grafo_compras.sh.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
NEO="${NEO:-mesh-neo4j}"
MONGO="${MONGO:-mesh-mongo}"
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

PREF="tc$(date +%s | tail -c 7)"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
esperar() { [ "$1" = "$2" ] && OK "$3" || FALLA "$3: dio '$1', se esperaba '$2'"; }

sql()    { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" 2>/dev/null | tr -d '\r'; }
cypher() { docker exec -i "$NEO" cypher-shell -u neo4j -p "$NEO4J_PASSWORD" --format plain "$1" 2>/dev/null | tail -n +2 | tr -d '\r"'; }
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

# La respuesta de tambien-compraron como "id:compradores:M|O" separados por
# espacio (M = misma categoria, O = otra).
tc() { curl -s -m 60 "$API/productos/$1/tambien-compraron" | python -c "
import sys,json
try: d=json.load(sys.stdin)['payload']
except Exception: print('sin-respuesta'); sys.exit()
print(' '.join('%s:%s:%s' % (x['id_producto'], x['compradores'], 'M' if x['misma_categoria'] else 'O') for x in d))"; }

nueva_cuenta() {
    local n=$1 correo="${PREF}$1@mesh.com"
    curl -s -o /dev/null -X POST "$API/usuario/registro" -H "Content-Type: application/json" \
        -d "{\"correo_electronico\":\"$correo\",\"usuario\":\"${PREF}$n\",\"nombre\":\"Tambien\",\"apellido\":\"Compraron\",\"contrasena\":\"$CLAVE\"}"
    eval "COOKIE_$n=\$(entrar \"$correo\" \"$CLAVE\")"
    eval "ID_$n=\$(sql \"SELECT id_usuario FROM usuarios WHERE correo_electronico='$correo';\")"
    local c; eval "c=\$COOKIE_$n"
    llamar POST "/direccion-usuario" "$c" \
        '{"pais":"Guatemala","departamento":"Guatemala","ciudad":"Guatemala","direccion_exacta":"Direccion de la prueba de categorias","codigo_postal":"01001"}' >/dev/null
    eval "DIR_$n=\$(curl -s \"$API/direccion-usuario\" -H \"Cookie: \$c\" | python -c \"
import sys,json
d=json.load(sys.stdin).get('payload') or []
print(d[0]['id_direccion'] if d else '')\")"
}
comprar() {   # COOKIE DIRECCION OFERTA... -> deja PEDIDO
    local c=$1 d=$2; shift 2
    curl -s -X DELETE "$API/carrito" -H "Cookie: $c" >/dev/null
    for of in "$@"; do llamar PUT "/carrito/lineas/$of" "$c" '{"cantidad":1}' >/dev/null; done
    local r; r=$(llamar POST "/carrito/comprar" "$c" "{\"id_direccion\":$d,\"metodo_pago\":\"efectivo contra entrega\"}")
    PEDIDO=$(echo "$r" | campo payload.id_pedido)
    [ "$(echo "$r" | campo payload.comprado)" = "True" ]
}
compras_en_grafo() { cypher "MATCH (:Usuario {id: $1})-[:HIZO]->(k:Compra) RETURN count(k);"; }
esperar_compras() { local i; for i in $(seq 1 "$3"); do [ "$(compras_en_grafo "$1")" = "$2" ] && return 0; sleep 1; done; return 1; }
# Espera hasta S segundos a que tambien-compraron de P de exactamente E.
esperar_orden() { local i; for i in $(seq 1 "$3"); do [ "$(tc "$1")" = "$2" ] && return 0; sleep 1; done; return 1; }

# Una oferta con existencia, fuera de venta relampago, de un producto activo.
# CONDICION es SQL extra sobre o (oferta) y pc (producto); SOLO_TIENDA en 1 la
# pide de la tienda, en 0 de cualquier vendedor.
oferta_tienda() {
    sql "SELECT o.id_oferta || ' ' || o.id_producto_mongo
           FROM oferta o JOIN estado_oferta e USING (id_estado_oferta)
           JOIN producto_catalogo pc ON pc.id_producto_mongo = o.id_producto_mongo
           JOIN variante_catalogo v ON v.id_producto_mongo=o.id_producto_mongo AND v.id_producto_variante_mongo=o.id_producto_variante_mongo
          WHERE e.estado_oferta_nombre='activa' AND o.stock >= 5 AND NOT o.es_inventario_limitado
            AND ($2 = 0 OR o.id_usuario=$TIENDA_ID) AND v.estado='activa' AND pc.estado='activo' AND $1
          ORDER BY o.id_producto_mongo, o.id_oferta LIMIT 1;"
}


titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend responde" || { echo "  El backend no responde en $API."; exit 1; }
ADMIN=$(entrar "admin@mesh.com" "Admin123")
[ -n "$ADMIN" ] && OK "sesion de admin" || { echo "  No se pudo entrar como admin."; exit 1; }
TIENDA_ID=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='tienda@mesh.com';")


titulo "1. La categoria de cada :Producto es la del catalogo"
# Por si el backend acaba de arrancar: el worker corre al arrancar y cada 60 s.
for _ in $(seq 1 75); do
    [ "$(cypher "MATCH (p:Producto) WHERE p.id_categoria IS NULL RETURN count(p);")" = "0" ] && break
    sleep 1
done
total=$(cypher "MATCH (p:Producto) RETURN count(p);")
esperar "$(cypher "MATCH (p:Producto) WHERE p.id_categoria IS NULL RETURN count(p);")" 0 "los $total :Producto tienen id_categoria"
grafo=$(cypher "MATCH (p:Producto) RETURN p.id + ':' + p.id_categoria + ':' + p.categoria ORDER BY p.id;" | tr '\n' ' ')
ids=$(cypher "MATCH (p:Producto) RETURN p.id ORDER BY p.id;" | tr '\n' ',' | sed 's/,$//')
copia=$(sql "SELECT string_agg(pc.id_producto_mongo || ':' || pc.id_categoria || ':' || c.nombre, ' ' ORDER BY pc.id_producto_mongo) || ' '
               FROM producto_catalogo pc JOIN categorias c USING (id_categoria) WHERE pc.id_producto_mongo IN ($ids);")
esperar "$grafo" "$copia" "y es la misma, id y nombre, que en producto_catalogo"


titulo "2. En todos los productos comprados, primero la misma categoria"
mapfile -t COMPRADOS < <(cypher "MATCH (p:Producto)<-[:DE]-(:Compra) RETURN DISTINCT p.id ORDER BY p.id;")
mal=0; con_ambos=0
for p in "${COMPRADOS[@]}"; do
    r=$(tc "$p")
    v=$(python -c "
import sys
xs=[x.split(':') for x in sys.argv[1].split()]
g=[x[2] for x in xs]
ok = g == sorted(g, key=lambda s: 0 if s=='M' else 1)
for grupo in 'MO':
    c=[int(x[1]) for x in xs if x[2]==grupo]
    ok = ok and c == sorted(c, reverse=True)
print(('bien' if ok else 'mal') + (' ambos' if 'M' in g and 'O' in g else ''))" "$r")
    case "$v" in mal*) mal=$((mal+1)); [ "$mal" -le 3 ] && echo "        producto $p: $r" ;; esac
    case "$v" in *ambos) con_ambos=$((con_ambos+1)) ;; esac
done
esperar "$mal" 0 "${#COMPRADOS[@]} productos comprados, ninguno con el orden mal"
[ "$con_ambos" -gt 0 ] && OK "y $con_ambos de ellos traen los dos grupos a la vez" || FALLA "ninguno trae los dos grupos: la prueba no mide nada"


titulo "3. Uno de la misma categoria con 1 comprador va antes que otro con 2"
# K = Laptops (la del producto 2, que se usa en la parte 5), L = Telefonos.
CAT_K=$(sql "SELECT id_categoria FROM producto_catalogo WHERE id_producto_mongo=2;")
CAT_L=$(sql "SELECT id_categoria FROM categorias WHERE nombre='Telefonos';")
read -r OF_X PX <<< "$(oferta_tienda "pc.id_categoria=$CAT_K AND o.id_producto_mongo <> 2 AND NOT EXISTS (SELECT 1 FROM pedido_producto pp WHERE pp.id_producto_mongo=o.id_producto_mongo)" 1)"
# Z puede ser de cualquier vendedor: en la PC de Jose David la oferta de la
# tienda del producto 2 tiene abierta la venta relampago del inicio.
read -r OF_Z PZ <<< "$(oferta_tienda "o.id_producto_mongo = 2" 0)"
read -r OF_Y PY <<< "$(oferta_tienda "pc.id_categoria=$CAT_L" 1)"
[ -n "${PX:-}" ] && [ -n "${PZ:-}" ] && [ -n "${PY:-}" ] \
    && OK "X=$PX y Z=$PZ en la categoria $CAT_K, Y=$PY en la $CAT_L; X sin compras de nadie" \
    || { echo "  No hay productos para armar el caso (X='${PX:-}', Z='${PZ:-}', Y='${PY:-}')."; exit 1; }

for n in a b c; do nueva_cuenta "$n"; done
[ -n "$ID_a" ] && [ -n "$ID_b" ] && [ -n "$ID_c" ] && OK "cuentas ${PREF}a, ${PREF}b y ${PREF}c" || { echo "  No se crearon las cuentas."; exit 1; }
comprar "$COOKIE_a" "$DIR_a" "$OF_X" "$OF_Y" && PEDIDO_A=$PEDIDO && OK "${PREF}a compro X e Y" || FALLA "${PREF}a no pudo comprar"
comprar "$COOKIE_b" "$DIR_b" "$OF_X" "$OF_Y" && PEDIDO_B=$PEDIDO && OK "${PREF}b compro X e Y" || FALLA "${PREF}b no pudo comprar"
comprar "$COOKIE_c" "$DIR_c" "$OF_X" "$OF_Z" && PEDIDO_C=$PEDIDO && OK "${PREF}c compro X y Z" || FALLA "${PREF}c no pudo comprar"
esperar_compras "$ID_a" 2 30 && esperar_compras "$ID_b" 2 30 && esperar_compras "$ID_c" 2 30 \
    && OK "las seis :Compra estan en el grafo" || FALLA "faltan :Compra en el grafo"

ESPERADO="$PZ:1:M $PY:2:O"
esperar "$(tc "$PX")" "$ESPERADO" "tambien-compraron de X es Z (1 comprador, misma categoria) y despues Y (2, otra)"
esperar "$(cypher "MATCH (x:Producto {id: $PX}), (z:Producto {id: $PZ}) RETURN x.id_categoria = z.id_categoria;")" TRUE "en el grafo X y Z tienen la misma id_categoria"


titulo "4. El worker devuelve la categoria que se le cambia al grafo"
cypher "MATCH (z:Producto {id: $PZ}) SET z.id_categoria = $CAT_L, z.categoria = 'cambiada a mano';" >/dev/null
esperar "$(tc "$PX")" "$PY:2:O $PZ:1:O" "con Z en otra categoria a mano, Z baja de grupo y va despues de Y"
inicio=$(date +%s)
esperar_orden "$PX" "$ESPERADO" 75 && OK "el worker la devolvio en $(( $(date +%s) - inicio )) s y Z volvio arriba" || FALLA "a los 75 s el orden es $(tc "$PX")"
esperar "$(cypher "MATCH (z:Producto {id: $PZ}) RETURN z.categoria;")" "$(sql "SELECT nombre FROM categorias WHERE id_categoria=$CAT_K;")" "con su nombre de categoria"
cypher "MATCH (z:Producto {id: $PZ}) REMOVE z.id_categoria, z.categoria;" >/dev/null
esperar "$(tc "$PX")" "$PY:2:O $PZ:1:O" "sin categoria, Z tampoco es de la misma"
esperar_orden "$PX" "$ESPERADO" 75 && OK "y el worker se la vuelve a poner" || FALLA "a los 75 s el orden es $(tc "$PX")"


titulo "5. Punta a punta: el admin cambia la categoria de Z por la API"
r=$(llamar PATCH "/vendedor/productos/$PZ" "$ADMIN" "{\"id_categoria\":$CAT_L}")
esperar "$(echo "$r" | campo ok)" True "Z pasa a la categoria $CAT_L"
esperar "$(sql "SELECT id_categoria FROM producto_catalogo WHERE id_producto_mongo=$PZ;")" "$CAT_L" "la copia del catalogo lo tiene al instante"
inicio=$(date +%s)
esperar_orden "$PX" "$PY:2:O $PZ:1:O" 75 && OK "en $(( $(date +%s) - inicio )) s el grafo lo sigue y Z queda despues de Y" || FALLA "a los 75 s el orden es $(tc "$PX")"
r=$(llamar PATCH "/vendedor/productos/$PZ" "$ADMIN" "{\"id_categoria\":$CAT_K}")
esperar "$(echo "$r" | campo ok)" True "Z vuelve a la categoria $CAT_K"
esperar_orden "$PX" "$ESPERADO" 75 && OK "y Z vuelve arriba" || FALLA "a los 75 s el orden es $(tc "$PX")"
esperar "$(sql "SELECT id_categoria FROM producto_catalogo WHERE id_producto_mongo=$PZ;")" "$CAT_K" "la copia quedo como estaba"


titulo "6. Con Neo4j y con MongoDB caidos"
if [ "$SIN_CAIDA" = "1" ]; then
    echo "  saltado (SIN_CAIDA=1)"
else
    docker stop "$NEO" >/dev/null 2>&1
    esperar "$(tc "$PX")" "$ESPERADO" "sin Neo4j, el respaldo de PostgreSQL da lo mismo y en el mismo orden"
    docker start "$NEO" >/dev/null 2>&1
    for _ in $(seq 1 60); do [ "$(cypher "RETURN 1;")" = "1" ] && break; sleep 2; done
    docker stop "$MONGO" >/dev/null 2>&1
    esperar "$(tc "$PX")" "$ESPERADO" "sin MongoDB, igual, con las tarjetas de la copia del catalogo"
    docker start "$MONGO" >/dev/null 2>&1
    for _ in $(seq 1 60); do docker exec "$MONGO" mongosh --quiet --eval "1" >/dev/null 2>&1 && break; sleep 2; done
    esperar_orden "$PX" "$ESPERADO" 60 && OK "con las dos de vuelta, lo mismo" || FALLA "con las dos de vuelta da $(tc "$PX")"
fi


titulo "7. Limpieza"
for n in a b c; do
    eval "c=\$COOKIE_$n; p=\$PEDIDO_$(echo $n | tr a-c A-C)"
    [ -n "${p:-}" ] && llamar POST "/comprador/pedidos/$p/cancelar" "$c" | grep -q '"ok":true' \
        && OK "${PREF}$n cancelo su pedido $p" || FALLA "${PREF}$n no pudo cancelar"
done
esperar_orden "$PX" "" 30 && OK "sin compras vivas, X ya no recomienda nada" || FALLA "X sigue con $(tc "$PX")"


echo
echo "=============================================================="
echo "  $ok OK, $fallo FALLA"
echo "=============================================================="
[ "$fallo" -eq 0 ]
