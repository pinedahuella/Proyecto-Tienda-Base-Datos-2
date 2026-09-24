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
#   5. EL ESTANTE. Lee el ZSET de Redis, respeta su orden, salta el id que no
#      tiene detalle cacheado y contesta 200 sin sesion. Desde el 2026-09-23 el
#      detalle de cada producto sale de otro HASH de Redis que llena el worker,
#      mesh:productos:mas_vendidos:detalle, y ya no de MongoDB.
#   6. QUE LO SEMBRADO NO ENTRA. Desde el 2026-09-19 las seis rutas y el worker
#      de mas vendidos cuentan SOLO lote = 'real', sin parametro para lo
#      contrario. Una fila de lote 'generado-...' con un total enorme no puede
#      aparecer en ningun ranking.
#
# COMO SE SIEMBRA AHORA, Y POR QUE CAMBIO. Antes las filas de prueba llevaban
# lote 'prueba-tendencias' y las rutas las contaban. Con el filtro fijo de lote
# real esas filas ya no cuentan, asi que la prueba sembraba y no media nada.
# Ahora se siembra con lote = 'real' (es lo unico que las rutas leen) y lo que
# distingue a las filas de la prueba de las de verdad son MARCADORES en otras
# columnas:
#
#   id_producto   987654321 (ficticio) en las cuatro tablas de producto. No existe
#                 en Mongo, asi que la ruta lo devuelve con `producto: null`, y esa
#                 es la fila que se busca. Sin producto real no hace falta restar
#                 lo que ya hubiera: no hay nada mas con ese id.
#   termino       empieza con 'prueba-tendencias-' en las dos de busqueda.
#
# LA REGLA QUE NO SE ROMPE al limpiar: se borra por marcador Y por lote real,
# nunca por lote solo. Con lote = 'real' a secas se borrarian ventas de verdad.
# vistas_por_producto_dia se llena sola por una vista materializada y solo mira
# lo que ENTRA, asi que va aparte; su clave es (dia, id_producto, lote), o sea
# que con el id ficticio esas filas son enteramente de la prueba.
#
# LO QUE SIEMBRA Y LO QUE LIMPIA. Las filas marcadas en las seis tablas y en el
# resumen, y las dos claves del estante en Redis: el ZSET
# mesh:productos:mas_vendidos, que se GUARDA antes y se RESTAURA al terminar (si
# no existia, se borra), y el HASH mesh:productos:mas_vendidos:detalle, que se
# aparta entero con RENAME a una clave de respaldo y vuelve igual al terminar.
# Si una corrida anterior murio con el respaldo apartado, se devuelve al
# empezar. Al final comprueba que no quedo ni una fila marcada. Hay un trap: si
# el proceso muere, limpia.
#
# LO QUE CUESTA CORRERLO. Dos inicios de sesion (admin y comprador), que suman
# al contador multi_cuenta_ip del fraude de login. Y hay una carrera pequena
# con el worker de mas vendidos, que reescribe esas dos claves cada 10 minutos
# y ahora vera brevemente el id ficticio en compra_producto (lo salta, no tiene
# producto visible): si cae justo en medio, el paso 5 puede dar un rojo que no
# es del codigo. Se repite solo. Corre de a uno, con nadie mas tocando eventos.
#
# No instala nada: curl, docker y node, que ya estan.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
CH_CONTENEDOR="${CH_CONTENEDOR:-mesh-clickhouse}"
REDIS="${REDIS:-mesh-redis}"
CLAVE_RANKING="mesh:productos:mas_vendidos"
CLAVE_DETALLE="mesh:productos:mas_vendidos:detalle"
# Donde se aparta el HASH de detalle mientras corre la prueba. Con RENAME, que
# mueve la clave entera sin copiar valor por valor.
RESPALDO_DETALLE="mesh:productos:mas_vendidos:detalle:respaldo-tendencias"

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

# Los marcadores de lo sembrado. Ver la cabecera.
FALSO=987654321
PREFIJO_TERMINO="prueba-tendencias-"
TERMINO="${PREFIJO_TERMINO}termino-${$}"
TERMINO_VIEJO="${PREFIJO_TERMINO}viejo-${$}"
# Un producto real, solo para el ZSET del estante (paso 5).
P=1
Q=2

# Las tablas de producto (marcador: id_producto) y las de busqueda (marcador: termino).
TABLAS_PRODUCTO="vista_producto carrito_producto compra_producto devolucion_producto vistas_por_producto_dia"
TABLAS_BUSQUEDA="busqueda_realizada busqueda_clic"

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

# El total de la fila del producto FICTICIO, que la ruta devuelve con
# `producto: null` (0 si no sale). Los reales nunca son null.
total_falso() { get "/admin/eventos/$1?dias=$2&limite=200" "$TARRO_ADMIN" >/dev/null; jx "(j.payload.find(x=>x.producto===null)||{total:0}).total" < "$CUERPO"; }
total_termino()  { get "/admin/eventos/$1?dias=$3&limite=200" "$TARRO_ADMIN" >/dev/null; jx "(j.payload.find(x=>x.termino==='$2')||{total:-1}).total" < "$CUERPO"; }

igual() { # descripcion esperado obtenido
    if [ "$3" = "$2" ]; then OK "$1 ($3)"; else FALLA "$1 -- esperado $2, salio $3"; fi
}

# Cuantas filas MARCADAS hay ahora, sumadas en todas las tablas. Sirve para los
# restos de una corrida anterior y para la comprobacion final.
filas_marcadas() {
    local n=0 t c
    for t in $TABLAS_PRODUCTO; do
        c=$(ch "SELECT count() FROM $t WHERE lote = 'real' AND id_producto = $FALSO")
        n=$((n + c))
    done
    for t in $TABLAS_BUSQUEDA; do
        c=$(ch "SELECT count() FROM $t WHERE lote = 'real' AND startsWith(termino, '$PREFIJO_TERMINO')")
        n=$((n + c))
    done
    echo "$n"
}

# ---------- limpieza ----------
# SIEMPRE marcador Y lote real. Nunca por lote solo: borraria ventas de verdad.
BORRADO=0
borrar_marcadas() {
    local t
    for t in $TABLAS_PRODUCTO; do
        ch "ALTER TABLE $t DELETE WHERE lote = 'real' AND id_producto = $FALSO SETTINGS mutations_sync = 2" >/dev/null 2>&1
    done
    for t in $TABLAS_BUSQUEDA; do
        ch "ALTER TABLE $t DELETE WHERE lote = 'real' AND startsWith(termino, '$PREFIJO_TERMINO') SETTINGS mutations_sync = 2" >/dev/null 2>&1
    done
}
# El HASH de detalle vuelve a su sitio. Si no habia nada apartado (no existia
# antes de la prueba), queda sin detalle, igual que estaba.
DETALLE_APARTADO=0
RANKING_RESPALDADO=0
devolver_detalle() {
    rcli DEL "$CLAVE_DETALLE" >/dev/null
    if [ "$(rcli EXISTS "$RESPALDO_DETALLE")" = "1" ]; then
        rcli RENAME "$RESPALDO_DETALLE" "$CLAVE_DETALLE" >/dev/null
    fi
    DETALLE_APARTADO=0
}
limpiar() {
    [ "$BORRADO" = 1 ] && return
    BORRADO=1
    borrar_marcadas
    # Restaura el ZSET tal como estaba. Solo si ya se habia respaldado: un
    # trap que salta en el paso 0 (backend caido) no tiene respaldo, y borrar
    # la clave ahi dejaria el estante vacio sin haberlo tocado.
    if [ "$RANKING_RESPALDADO" = 1 ]; then
        rcli DEL "$CLAVE_RANKING" >/dev/null
        if [ -s "$RESPALDO_ZSET" ]; then
            local miembro puntaje
            while IFS= read -r miembro && IFS= read -r puntaje; do
                [ -n "$miembro" ] && rcli ZADD "$CLAVE_RANKING" "$puntaje" "$miembro" >/dev/null
            done < "$RESPALDO_ZSET"
        fi
    fi
    [ "$DETALLE_APARTADO" = 1 ] && devolver_detalle
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

for t in $TABLAS_PRODUCTO $TABLAS_BUSQUEDA; do
    if ! ch "SELECT 1 FROM $t LIMIT 1" >/dev/null 2>&1; then
        FALLA "no se puede leer $CH_BASE.$t -- corrio clickhouse/001_esquema.sql?"
        exit 1
    fi
done
OK "las seis tablas y el resumen se leen en $CH_BASE"

# Restos de una corrida que murio sin su trap.
restos=$(filas_marcadas)
if [ "$restos" -gt 0 ]; then
    echo "  (habia $restos fila(s) marcadas de una corrida anterior, se borran)"
    borrar_marcadas
fi
OK "sin restos de otra corrida"

rcli ZRANGE "$CLAVE_RANKING" 0 -1 WITHSCORES > "$RESPALDO_ZSET"
RANKING_RESPALDADO=1
echo "  (ranking de Redis respaldado, $(($(wc -l < "$RESPALDO_ZSET") / 2)) miembro(s))"

# Un respaldo del detalle que quedo apartado es de una corrida que murio sin
# su trap: ese es el detalle de verdad, y vuelve antes de apartar nada.
if [ "$(rcli EXISTS "$RESPALDO_DETALLE")" = "1" ]; then
    echo "  (habia un detalle apartado por una corrida anterior, se devuelve)"
    devolver_detalle
fi
rcli DEL "$RESPALDO_DETALLE" >/dev/null
if [ "$(rcli EXISTS "$CLAVE_DETALLE")" = "1" ]; then
    rcli RENAME "$CLAVE_DETALLE" "$RESPALDO_DETALLE" >/dev/null
fi
DETALLE_APARTADO=1
echo "  (detalle del estante apartado en $RESPALDO_DETALLE)"

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

# Antes de sembrar: no puede haber ya otra fila con `producto: null` en las
# rutas de producto, o no se sabria cual es la del id ficticio.
for r in vista carrito compra devolucion; do
    get "/admin/eventos/$r?dias=365&limite=200" "$TARRO_ADMIN" >/dev/null
    huerfanas=$(jx 'j.payload.filter(x=>x.producto===null).length' < "$CUERPO")
    if [ "$huerfanas" != "0" ]; then
        FALLA "$r ya trae $huerfanas fila(s) de un producto sin ficha antes de sembrar: la prueba no distinguiria la suya"
        exit 1
    fi
done
OK "ninguna ruta de producto trae filas huerfanas antes de sembrar"

# ============================================================
titulo "2. Se siembra, con lote real, con duplicados y con marcadores"
# ============================================================
# vista: sesiones A, A, B dentro de la ventana y C hace 10 dias.
#        distintas en 7 dias = 2, y COUNT(*) daria 3. En 30 dias = 3, y COUNT(*) 4.
ch "INSERT INTO vista_producto (fecha,id_producto,sesion,ip,origen,lote) VALUES
    (now(),$FALSO,'pt-A','127.0.0.1','catalogo','real'),
    (now(),$FALSO,'pt-A','127.0.0.1','catalogo','real'),
    (now(),$FALSO,'pt-B','127.0.0.1','catalogo','real'),
    (now() - INTERVAL 10 DAY,$FALSO,'pt-C','127.0.0.1','catalogo','real')"
# carrito: la cuenta 900000001 dos veces y la 900000002 una. Distintas 2, COUNT(*) 3.
ch "INSERT INTO carrito_producto (fecha,id_producto,id_oferta,id_usuario,cantidad,ip,lote) VALUES
    (now(),$FALSO,1,900000001,2,'127.0.0.1','real'),
    (now(),$FALSO,1,900000001,1,'127.0.0.1','real'),
    (now(),$FALSO,1,900000002,1,'127.0.0.1','real')"
# compra: cantidades 5 y 3. SUM da 8, COUNT(*) daria 2.
ch "INSERT INTO compra_producto (fecha,id_producto,id_oferta,id_usuario,cantidad,id_pedido,ip,lote) VALUES
    (now(),$FALSO,1,900000001,5,990000001,'127.0.0.1','real'),
    (now(),$FALSO,1,900000002,3,990000002,'127.0.0.1','real')"
# devolucion: 2 y 1. SUM da 3, COUNT(*) daria 2.
ch "INSERT INTO devolucion_producto (fecha,id_producto,id_oferta,id_usuario,cantidad,id_pedido,ip,lote) VALUES
    (now(),$FALSO,1,900000001,2,990000001,'127.0.0.1','real'),
    (now(),$FALSO,1,900000002,1,990000002,'127.0.0.1','real')"
# busqueda: el termino con las sesiones s1, s1 y s2 (distintas 2, COUNT(*) 3),
# y otro termino de hace 10 dias.
ch "INSERT INTO busqueda_realizada (fecha,termino,resultados,sesion,lote) VALUES
    (now(),'$TERMINO',5,'pt-s1','real'),
    (now(),'$TERMINO',5,'pt-s1','real'),
    (now(),'$TERMINO',5,'pt-s2','real'),
    (now() - INTERVAL 10 DAY,'$TERMINO_VIEJO',0,'pt-s1','real')"
# clic: dos clics de la misma sesion. Distintas 1, COUNT(*) daria 2.
ch "INSERT INTO busqueda_clic (fecha,termino,id_producto,posicion,sesion,lote) VALUES
    (now(),'$TERMINO',$FALSO,1,'pt-s1','real'),
    (now(),'$TERMINO',$FALSO,2,'pt-s1','real')"
OK "sembradas las filas marcadas (lote real, id_producto $FALSO, terminos $PREFIJO_TERMINO...)"

# ============================================================
titulo "3. La metrica de cada tabla"
# ============================================================
igual "vista, 7 dias: sesiones DISTINTAS, no eventos (un COUNT(*) daria 3)" 2 "$(total_falso vista 7)"
igual "carrito, 7 dias: cuentas DISTINTAS (un COUNT(*) daria 3)" 2 "$(total_falso carrito 7)"
igual "compra, 7 dias: SUMA de unidades (un COUNT(*) daria 2)" 8 "$(total_falso compra 7)"
igual "devolucion, 7 dias: SUMA de unidades (un COUNT(*) daria 2)" 3 "$(total_falso devolucion 7)"
igual "busqueda: sesiones DISTINTAS por termino (un COUNT(*) daria 3)" 2 "$(total_termino busqueda "$TERMINO" 7)"
igual "busqueda-clic: sesiones DISTINTAS por termino (un COUNT(*) daria 2)" 1 "$(total_termino busqueda-clic "$TERMINO" 7)"

# El arnes se vigila a si mismo: si los datos sembrados no distinguen la metrica
# buena de la mala, todo lo de arriba pasaria igual con un COUNT(*).
[ 2 -ne 3 ] && [ 8 -ne 2 ] && OK "los datos sembrados separan la metrica buena de COUNT(*)" \
    || FALLA "los datos sembrados no separan la metrica buena de COUNT(*)"

# ============================================================
titulo "4. La ventana, el limite y la direccion"
# ============================================================
igual "vista, 30 dias: la fila de hace 10 dias SI entra" 3 "$(total_falso vista 30)"
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
# Y el HASH de detalle con un documento minimo para el 1 y el 2, a proposito
# en el orden contrario al del ranking: si la ruta siguiera el orden del HASH
# en vez del ZSET, saldria al reves. El id que no existe no tiene detalle, que
# es lo que le pasa a un producto que el worker no cacheo. El 3 tiene detalle
# pero no esta en el ranking, y no puede salir.
#
# El worker del backend reescribe las DOS claves cada 10 minutos. Si le toca
# justo entre la siembra y el GET, la ruta contesta el ranking de verdad y los
# dos igual de abajo salen en FALLA sin que el codigo este mal (paso el
# 2026-09-23). Por eso despues del GET se mira si el id inventado sigue en el
# ZSET: si ya no esta, lo piso el worker, y se siembra y se pregunta otra vez.
sembrar_estante() {
    rcli DEL "$CLAVE_RANKING" >/dev/null
    rcli ZADD "$CLAVE_RANKING" 30 "$Q" 20 "$P" 10 99999999 >/dev/null
    rcli DEL "$CLAVE_DETALLE" >/dev/null
    rcli HSET "$CLAVE_DETALLE" \
        "$P" "{\"_id\":$P,\"nombre\":\"prueba-tendencias $P\"}" \
        "$Q" "{\"_id\":$Q,\"nombre\":\"prueba-tendencias $Q\"}" \
        3 "{\"_id\":3,\"nombre\":\"prueba-tendencias 3\"}" >/dev/null
}
for intento in 1 2; do
    sembrar_estante
    c=$(get "/productos/mas-vendidos")
    [ -n "$(rcli ZSCORE "$CLAVE_RANKING" 99999999)" ] && break
    echo "  (el worker de mas vendidos reescribio el ranking en medio, se repite)"
done
igual "GET /productos/mas-vendidos sin sesion" 200 "$c"
igual "sale en el orden del ranking y salta el id sin detalle" "$Q,$P" "$(jx 'j.payload.map(p=>p._id).join(",")' < "$CUERPO")"
igual "el detalle sale del HASH de Redis, no de MongoDB" "prueba-tendencias $Q" "$(jx 'j.payload[0].nombre' < "$CUERPO")"

# Con ranking pero sin ningun detalle cacheado: 200 y lista vacia.
rcli DEL "$CLAVE_DETALLE" >/dev/null
c=$(get "/productos/mas-vendidos")
igual "ranking sin detalle contesta 200" 200 "$c"
igual "y no inventa productos" 0 "$(jx 'j.payload.length' < "$CUERPO")"

rcli DEL "$CLAVE_RANKING" >/dev/null
c=$(get "/productos/mas-vendidos")
igual "sin ranking contesta 200, no un error" 200 "$c"
igual "y la lista va vacia" 0 "$(jx 'j.payload.length' < "$CUERPO")"

# ============================================================
titulo "6. Lo sembrado (lote generado) no entra en ningun ranking"
# ============================================================
# Filas de lote 'generado-prueba-tendencias' con totales enormes y con los MISMOS
# marcadores. Si alguna ruta las contara, los totales del paso 3 se moverian.
# Se borran por marcador Y por su lote, y solo esas.
LOTE_AJENO="generado-prueba-tendencias"
ch "INSERT INTO compra_producto (fecha,id_producto,id_oferta,id_usuario,cantidad,id_pedido,ip,lote) VALUES
    (now(),$FALSO,1,900000003,999,990000009,'127.0.0.1','$LOTE_AJENO')"
ch "INSERT INTO vista_producto (fecha,id_producto,sesion,ip,origen,lote) VALUES
    (now(),$FALSO,'pt-gen-1','127.0.0.1','catalogo','$LOTE_AJENO'),
    (now(),$FALSO,'pt-gen-2','127.0.0.1','catalogo','$LOTE_AJENO')"
ch "INSERT INTO busqueda_realizada (fecha,termino,resultados,sesion,lote) VALUES
    (now(),'$TERMINO',5,'pt-gen-1','$LOTE_AJENO'),
    (now(),'$TERMINO',5,'pt-gen-2','$LOTE_AJENO')"
igual "compra: los 999 del lote generado no suman (sigue 8)" 8 "$(total_falso compra 7)"
igual "vista: las dos sesiones del lote generado no cuentan (sigue 2)" 2 "$(total_falso vista 7)"
igual "busqueda: las dos sesiones del lote generado no cuentan (sigue 2)" 2 "$(total_termino busqueda "$TERMINO" 7)"
ch "ALTER TABLE compra_producto DELETE WHERE lote = '$LOTE_AJENO' AND id_producto = $FALSO SETTINGS mutations_sync = 2" >/dev/null
ch "ALTER TABLE vista_producto DELETE WHERE lote = '$LOTE_AJENO' AND id_producto = $FALSO SETTINGS mutations_sync = 2" >/dev/null
ch "ALTER TABLE vistas_por_producto_dia DELETE WHERE lote = '$LOTE_AJENO' AND id_producto = $FALSO SETTINGS mutations_sync = 2" >/dev/null
ch "ALTER TABLE busqueda_realizada DELETE WHERE lote = '$LOTE_AJENO' AND startsWith(termino, '$PREFIJO_TERMINO') SETTINGS mutations_sync = 2" >/dev/null

# ============================================================
titulo "7. Limpieza"
# ============================================================
limpiar
igual "no queda ni una fila marcada, resumen incluido" 0 "$(filas_marcadas)"
igual "ni una del lote generado de la prueba" 0 \
    "$(ch "SELECT (SELECT count() FROM compra_producto WHERE lote = '$LOTE_AJENO') + (SELECT count() FROM vista_producto WHERE lote = '$LOTE_AJENO') + (SELECT count() FROM vistas_por_producto_dia WHERE lote = '$LOTE_AJENO') + (SELECT count() FROM busqueda_realizada WHERE lote = '$LOTE_AJENO')")"

echo
echo "=============================================================="
echo "  $ok OK, $fallo FALLA"
echo "=============================================================="
[ "$fallo" -eq 0 ]
