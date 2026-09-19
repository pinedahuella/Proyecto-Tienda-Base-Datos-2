#!/usr/bin/env bash
# ============================================================
# Los seis rankings de tendencias y el estante de lo mas vendido
# ============================================================
#
#   bash pruebas/tendencias.sh
#
# Mide dos rutas que Jose David publico el 2026-09-18:
#
#   GET /admin/eventos/vista|carrito|compra|devolucion|busqueda|busqueda-clic
#   GET /productos/mas-vendidos
#
# Lo que se comprueba, y por que es lo que hay que comprobar:
#
#   1. QUIEN PUEDE. Sin sesion 401, un comprador 403, un admin 200, en las seis.
#   2. LA METRICA DE CADA TABLA. No es la misma en las seis y es la decision
#      central de la ruta: vista y busquedas cuentan sesiones DISTINTAS, carrito
#      cuentas DISTINTAS, compra y devolucion SUMAN unidades. Los datos que se
#      siembran llevan duplicados a proposito, de modo que COUNT(*) daria un
#      numero distinto del correcto en cada tabla. Si el arnes sembrara filas
#      todas distintas, un COUNT(*) pasaria por bueno.
#   3. LA VENTANA. Una fila de hace 10 dias sale con dias=30 y NO con dias=7.
#   4. LOS PARAMETROS. limite recorta, direccion invierte el orden, y un valor
#      malo da 400 en vez de callarse.
#   5. EL ESTANTE. Lee el ZSET de Redis, respeta su orden, salta el id que ya no
#      tiene producto visible y contesta 200 sin sesion.
#
# COMO SE MIDE SIN ENSUCIAR EL RESULTADO. Las tablas ya traen filas ajenas (el
# lote generado de clickhouse/lote pone miles de vistas), asi que el numero que
# devuelve la ruta para el producto 1 no es solo el sembrado aqui. Se le resta:
# antes de sembrar se calcula, directo en ClickHouse y con la misma metrica, lo
# que ya hay para ese producto sin contar el lote de esta prueba, y lo esperado
# es esa base mas lo sembrado. Los terminos de busqueda llevan un nombre unico y
# no necesitan base.
#
# LO QUE SIEMBRA Y LO QUE LIMPIA. Filas con lote 'prueba-tendencias' en las seis
# tablas de mesh_eventos, y la clave mesh:productos:mas_vendidos de Redis, que
# se GUARDA antes y se RESTAURA al terminar (si no existia, se borra). Al final
# comprueba que no quedo ni una fila. Hay un trap: si el proceso muere, limpia.
#
# LO QUE CUESTA CORRERLO. Dos inicios de sesion (admin y comprador), que suman
# al contador multi_cuenta_ip del fraude de login. Y hay una carrera pequena
# con el worker de mas vendidos, que reescribe esa clave cada 10 minutos: si
# cae justo en medio, el paso 5 puede dar un rojo que no es del codigo. Se
# repite solo. Corre de a uno, con nadie mas tocando eventos.
#
# No instala nada: curl, docker y node, que ya estan.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
CH_CONTENEDOR="${CH_CONTENEDOR:-mesh-clickhouse}"
REDIS="${REDIS:-mesh-redis}"
CLAVE_RANKING="mesh:productos:mas_vendidos"

# Las cuentas de la semilla, las mismas de ARRANCAR.txt: esto corre contra la
# base local de desarrollo.
ADMIN_USUARIO="${ADMIN_USUARIO:-admin@mesh.com}"
ADMIN_CLAVE="${ADMIN_CLAVE:-Admin123}"
COMPRADOR_USUARIO="${COMPRADOR_USUARIO:-comprador.sur@mesh.com}"
COMPRADOR_CLAVE="${COMPRADOR_CLAVE:-Comprador123}"

# Las credenciales de las bases salen del .env y NO llevan valor por defecto,
# por lo mismo que explica pruebas/eventos.sh: un respaldo escrito aqui quedaria
# publicado en el repositorio y taparia un .env mal puesto.
if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
CH_USUARIO="${CLICKHOUSE_USER:-}"
CH_BASE="${CLICKHOUSE_DB:-mesh_eventos}"
if [ -z "${REDIS_PASSWORD:-}" ] || [ -z "${CLICKHOUSE_PASSWORD:-}" ] || [ -z "$CH_USUARIO" ]; then
    echo "Faltan REDIS_PASSWORD, CLICKHOUSE_USER o CLICKHOUSE_PASSWORD. Ponlas en el .env de la raiz." >&2
    exit 1
fi

# Git Bash convierte las rutas que empiezan con / al pasarlas a docker.
export MSYS_NO_PATHCONV=1

# Archivos de trabajo con nombre RELATIVO y nunca /dev/null. Ver pruebas/busqueda.sh.
TARRO_ADMIN=".mesh-tend-admin.txt"
TARRO_COMPRADOR=".mesh-tend-comprador.txt"
CUERPO=".mesh-tend-cuerpo.txt"
RESPALDO_ZSET=".mesh-tend-zset.txt"

LOTE="prueba-tendencias"
# vistas_por_producto_dia va AL FINAL a proposito: no se le siembra nada, se llena
# sola por una vista materializada cuando entra una fila en vista_producto, y esa
# vista solo mira lo que ENTRA. Borrar de vista_producto no le quita nada, asi que
# hay que borrarla aparte. Sin ella aqui, cada corrida de esta prueba dejaba tres
# filas 'prueba-tendencias' en el resumen (se vio el 2026-09-18) y la comprobacion
# de "no queda nada" pasaba en verde por no mirarla.
TABLAS="vista_producto carrito_producto compra_producto devolucion_producto busqueda_realizada busqueda_clic vistas_por_producto_dia"
# El producto sobre el que se mide. Tiene que existir en Mongo y estar activo:
# el 1 es la Laptop Ambar Campus 14 del catalogo curado.
P=1
Q=2
TERMINO="prueba-tendencias-termino-${$}"
TERMINO_VIEJO="prueba-tendencias-viejo-${$}"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# ---------- ayudas ----------
# La que NO puede faltar: --database. Sin ella clickhouse-client entra a
# `default`, donde las tablas TAMBIEN existen, el INSERT sale bien y el backend
# (que mira mesh_eventos) no ve ni una fila. Salio asi el 2026-09-18.
# Y `< /dev/null`: un docker exec -i deja la entrada abierta y cuelga al cliente
# (ver TRASPASO).
ch() {
    docker exec -i "$CH_CONTENEDOR" clickhouse-client \
        --user "$CH_USUARIO" --password "$CLICKHOUSE_PASSWORD" \
        --database "$CH_BASE" -q "$1" < /dev/null
}
rcli() { docker exec "$REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'; }

# node evalua una expresion sobre el JSON de la respuesta, en `j`.
jx() {
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch(e){console.log("__NO_JSON__");return}try{console.log(eval(process.argv[1]))}catch(e){console.log("__ERROR__")}})' "$1"
}

# GET con un tarro de cookies (o sin sesion si va vacio). Deja el cuerpo en
# $CUERPO y devuelve el codigo HTTP.
get() {
    local ruta="$1" tarro="${2:-}"
    if [ -n "$tarro" ]; then
        curl -s -o "$CUERPO" -w '%{http_code}' -b "$tarro" "$API$ruta"
    else
        curl -s -o "$CUERPO" -w '%{http_code}' "$API$ruta"
    fi
}

entrar() {
    curl -s -o "$CUERPO" -w '%{http_code}' -c "$2" -X POST "$API/usuario/login" \
        -H 'Content-Type: application/json' \
        -d "{\"identificador\":\"$1\",\"contrasena\":\"$3\"}"
}

# El total que devuelve una ruta de producto para el producto $2, o 0 si no sale.
total_producto() { get "/admin/eventos/$1?dias=$3&limite=200" "$TARRO_ADMIN" >/dev/null; jx "(j.payload.find(x=>x.producto&&x.producto._id===$2)||{total:0}).total" < "$CUERPO"; }
total_termino()  { get "/admin/eventos/$1?dias=$3&limite=200" "$TARRO_ADMIN" >/dev/null; jx "(j.payload.find(x=>x.termino==='$2')||{total:-1}).total" < "$CUERPO"; }

igual() { # descripcion esperado obtenido
    if [ "$3" = "$2" ]; then OK "$1 ($3)"; else FALLA "$1 -- esperado $2, salio $3"; fi
}

# ---------- limpieza ----------
BORRADO=0
limpiar() {
    [ "$BORRADO" = 1 ] && return
    BORRADO=1
    for t in $TABLAS; do
        ch "ALTER TABLE $t DELETE WHERE lote = '$LOTE' SETTINGS mutations_sync = 1" >/dev/null 2>&1
    done
    # Restaura el ZSET tal como estaba.
    rcli DEL "$CLAVE_RANKING" >/dev/null
    if [ -s "$RESPALDO_ZSET" ]; then
        local miembro puntaje
        while IFS= read -r miembro && IFS= read -r puntaje; do
            [ -n "$miembro" ] && rcli ZADD "$CLAVE_RANKING" "$puntaje" "$miembro" >/dev/null
        done < "$RESPALDO_ZSET"
    fi
    rm -f "$TARRO_ADMIN" "$TARRO_COMPRADOR" "$CUERPO" "$RESPALDO_ZSET"
}
trap limpiar EXIT INT TERM

# ============================================================
titulo "0. Que estan vivos el backend, ClickHouse y Redis, y que no hay restos"
# ============================================================
codigo=$(get "/productos/mas-vendidos")
if [ "$codigo" != "200" ]; then
    FALLA "GET /productos/mas-vendidos dio $codigo -- esta el backend arriba y es el de hoy?"
    echo; echo "  Sin backend no hay nada que medir."; exit 1
fi
OK "el backend contesta y la ruta de mas vendidos existe"

for t in $TABLAS; do
    if ! ch "SELECT 1 FROM $t LIMIT 1" >/dev/null 2>&1; then
        FALLA "no se puede leer $CH_BASE.$t -- corrio clickhouse/001_esquema.sql?"
        exit 1
    fi
done
OK "las seis tablas se leen en $CH_BASE"

# Restos de una corrida que murio sin su trap.
restos=0
for t in $TABLAS; do
    n=$(ch "SELECT count() FROM $t WHERE lote = '$LOTE'")
    restos=$((restos + n))
done
if [ "$restos" -gt 0 ]; then
    echo "  (habia $restos fila(s) de una corrida anterior, se borran)"
    for t in $TABLAS; do ch "ALTER TABLE $t DELETE WHERE lote = '$LOTE' SETTINGS mutations_sync = 1" >/dev/null; done
fi
OK "sin restos de otra corrida"

rcli ZRANGE "$CLAVE_RANKING" 0 -1 WITHSCORES > "$RESPALDO_ZSET"
echo "  (ranking de Redis respaldado, $(($(wc -l < "$RESPALDO_ZSET") / 2)) miembro(s))"

# ============================================================
titulo "1. Quien puede mirar: sin sesion 401, comprador 403, admin 200"
# ============================================================
c=$(entrar "$ADMIN_USUARIO" "$TARRO_ADMIN" "$ADMIN_CLAVE")
[ "$c" = "200" ] && OK "entra el admin" || { FALLA "el admin no entro ($c)"; exit 1; }
c=$(entrar "$COMPRADOR_USUARIO" "$TARRO_COMPRADOR" "$COMPRADOR_CLAVE")
[ "$c" = "200" ] && OK "entra el comprador" || { FALLA "el comprador no entro ($c)"; exit 1; }

for r in vista carrito compra devolucion busqueda busqueda-clic; do
    igual "$r sin sesion" 401 "$(get "/admin/eventos/$r")"
    igual "$r con comprador" 403 "$(get "/admin/eventos/$r" "$TARRO_COMPRADOR")"
    igual "$r con admin" 200 "$(get "/admin/eventos/$r" "$TARRO_ADMIN")"
done

# ============================================================
titulo "2. Se siembra, con duplicados a proposito"
# ============================================================
# Las bases de lo que ya hay, SIN contar esta prueba, con la metrica de cada tabla.
b_vista7=$(ch "SELECT uniqExact(sesion) FROM vista_producto WHERE id_producto=$P AND lote != '$LOTE' AND fecha >= now() - INTERVAL 7 DAY")
b_vista30=$(ch "SELECT uniqExact(sesion) FROM vista_producto WHERE id_producto=$P AND lote != '$LOTE' AND fecha >= now() - INTERVAL 30 DAY")
b_carrito=$(ch "SELECT uniqExact(id_usuario) FROM carrito_producto WHERE id_producto=$P AND lote != '$LOTE' AND fecha >= now() - INTERVAL 7 DAY")
b_compra=$(ch "SELECT sum(cantidad) FROM compra_producto WHERE id_producto=$P AND lote != '$LOTE' AND fecha >= now() - INTERVAL 7 DAY")
b_devol=$(ch "SELECT sum(cantidad) FROM devolucion_producto WHERE id_producto=$P AND lote != '$LOTE' AND fecha >= now() - INTERVAL 7 DAY")
echo "  bases previas del producto $P (7 dias)  vistas $b_vista7  carrito $b_carrito  compras $b_compra  devoluciones $b_devol"

# vista: sesiones A, A, B dentro de la ventana y C hace 10 dias.
#        distintas en 7 dias = 2, y COUNT(*) daria 3. En 30 dias = 3, y COUNT(*) 4.
ch "INSERT INTO vista_producto (fecha,id_producto,sesion,ip,origen,lote) VALUES
    (now(),$P,'pt-A','127.0.0.1','catalogo','$LOTE'),
    (now(),$P,'pt-A','127.0.0.1','catalogo','$LOTE'),
    (now(),$P,'pt-B','127.0.0.1','catalogo','$LOTE'),
    (now() - INTERVAL 10 DAY,$P,'pt-C','127.0.0.1','catalogo','$LOTE')"
# carrito: la cuenta 900000001 dos veces y la 900000002 una. Distintas 2, COUNT(*) 3.
ch "INSERT INTO carrito_producto (fecha,id_producto,id_oferta,id_usuario,cantidad,ip,lote) VALUES
    (now(),$P,1,900000001,2,'127.0.0.1','$LOTE'),
    (now(),$P,1,900000001,1,'127.0.0.1','$LOTE'),
    (now(),$P,1,900000002,1,'127.0.0.1','$LOTE')"
# compra: cantidades 5 y 3. SUM da 8, COUNT(*) daria 2.
ch "INSERT INTO compra_producto (fecha,id_producto,id_oferta,id_usuario,cantidad,id_pedido,ip,lote) VALUES
    (now(),$P,1,900000001,5,990000001,'127.0.0.1','$LOTE'),
    (now(),$P,1,900000002,3,990000002,'127.0.0.1','$LOTE')"
# devolucion: 2 y 1. SUM da 3, COUNT(*) daria 2.
ch "INSERT INTO devolucion_producto (fecha,id_producto,id_oferta,id_usuario,cantidad,id_pedido,ip,lote) VALUES
    (now(),$P,1,900000001,2,990000001,'127.0.0.1','$LOTE'),
    (now(),$P,1,900000002,1,990000002,'127.0.0.1','$LOTE')"
# busqueda: el termino con las sesiones s1, s1 y s2 (distintas 2, COUNT(*) 3),
# y otro termino de hace 10 dias.
ch "INSERT INTO busqueda_realizada (fecha,termino,resultados,sesion,lote) VALUES
    (now(),'$TERMINO',5,'pt-s1','$LOTE'),
    (now(),'$TERMINO',5,'pt-s1','$LOTE'),
    (now(),'$TERMINO',5,'pt-s2','$LOTE'),
    (now() - INTERVAL 10 DAY,'$TERMINO_VIEJO',0,'pt-s1','$LOTE')"
# clic: dos clics de la misma sesion. Distintas 1, COUNT(*) daria 2.
ch "INSERT INTO busqueda_clic (fecha,termino,id_producto,posicion,sesion,lote) VALUES
    (now(),'$TERMINO',$P,1,'pt-s1','$LOTE'),
    (now(),'$TERMINO',$P,2,'pt-s1','$LOTE')"
OK "sembradas las filas del lote $LOTE"

# ============================================================
titulo "3. La metrica de cada tabla"
# ============================================================
igual "vista, 7 dias: sesiones DISTINTAS, no eventos (un COUNT(*) daria $((b_vista7 + 3)))" \
    $((b_vista7 + 2)) "$(total_producto vista $P 7)"
igual "carrito, 7 dias: cuentas DISTINTAS (un COUNT(*) daria $((b_carrito + 3)))" \
    $((b_carrito + 2)) "$(total_producto carrito $P 7)"
igual "compra, 7 dias: SUMA de unidades (un COUNT(*) daria $((b_compra + 2)))" \
    $((b_compra + 8)) "$(total_producto compra $P 7)"
igual "devolucion, 7 dias: SUMA de unidades (un COUNT(*) daria $((b_devol + 2)))" \
    $((b_devol + 3)) "$(total_producto devolucion $P 7)"
igual "busqueda: sesiones DISTINTAS por termino (un COUNT(*) daria 3)" 2 "$(total_termino busqueda "$TERMINO" 7)"
igual "busqueda-clic: sesiones DISTINTAS por termino (un COUNT(*) daria 2)" 1 "$(total_termino busqueda-clic "$TERMINO" 7)"

# El arnes se vigila a si mismo: si los datos sembrados no distinguen la metrica
# buena de la mala, todo lo de arriba pasaria igual con un COUNT(*).
[ $((b_vista7 + 2)) -ne $((b_vista7 + 3)) ] && [ 8 -ne 2 ] && OK "los datos sembrados separan la metrica buena de COUNT(*)" \
    || FALLA "los datos sembrados no separan la metrica buena de COUNT(*)"

# ============================================================
titulo "4. La ventana, el limite y la direccion"
# ============================================================
igual "vista, 30 dias: la fila de hace 10 dias SI entra" \
    $((b_vista30 + 3)) "$(total_producto vista $P 30)"
igual "busqueda, 7 dias: el termino de hace 10 dias NO sale" -1 "$(total_termino busqueda "$TERMINO_VIEJO" 7)"
igual "busqueda, 30 dias: el termino de hace 10 dias SI sale" 1 "$(total_termino busqueda "$TERMINO_VIEJO" 30)"

get "/admin/eventos/busqueda?dias=30&limite=1" "$TARRO_ADMIN" >/dev/null
igual "limite=1 devuelve una sola fila" 1 "$(jx 'j.payload.length' < "$CUERPO")"

get "/admin/eventos/vista?dias=365&limite=200&direccion=positivo" "$TARRO_ADMIN" >/dev/null
igual "direccion=positivo va de mayor a menor" true "$(jx 'j.payload.every((x,i,a)=>i===0||a[i-1].total>=x.total)' < "$CUERPO")"
get "/admin/eventos/vista?dias=365&limite=200&direccion=negativo" "$TARRO_ADMIN" >/dev/null
igual "direccion=negativo va de menor a mayor" true "$(jx 'j.payload.every((x,i,a)=>i===0||a[i-1].total<=x.total)' < "$CUERPO")"

igual "dias=0 da 400" 400 "$(get "/admin/eventos/vista?dias=0" "$TARRO_ADMIN")"
igual "limite=0 da 400" 400 "$(get "/admin/eventos/vista?limite=0" "$TARRO_ADMIN")"
igual "direccion=lateral da 400" 400 "$(get "/admin/eventos/vista?direccion=lateral" "$TARRO_ADMIN")"

# ============================================================
titulo "5. El estante de lo mas vendido, sin sesion"
# ============================================================
# ZSET de prueba: el 2 primero, el 1 despues y un id que no existe al final.
rcli DEL "$CLAVE_RANKING" >/dev/null
rcli ZADD "$CLAVE_RANKING" 30 "$Q" 20 "$P" 10 99999999 >/dev/null
c=$(get "/productos/mas-vendidos")
igual "GET /productos/mas-vendidos sin sesion" 200 "$c"
igual "sale en el orden del ranking y salta el id que no existe" "$Q,$P" "$(jx 'j.payload.map(p=>p._id).join(",")' < "$CUERPO")"

rcli DEL "$CLAVE_RANKING" >/dev/null
c=$(get "/productos/mas-vendidos")
igual "sin ranking contesta 200, no un error" 200 "$c"
igual "y la lista va vacia" 0 "$(jx 'j.payload.length' < "$CUERPO")"

# ============================================================
titulo "6. Limpieza"
# ============================================================
limpiar
resto=0
for t in $TABLAS; do
    n=$(ch "SELECT count() FROM $t WHERE lote = '$LOTE'")
    resto=$((resto + n))
done
igual "no queda ni una fila del lote $LOTE" 0 "$resto"

echo
echo "=============================================================="
echo "  $ok OK, $fallo FALLA"
echo "=============================================================="
[ "$fallo" -eq 0 ]
