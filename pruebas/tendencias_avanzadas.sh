#!/usr/bin/env bash
# ============================================================
# T1, T2 y T3 por HTTP: en ascenso, embudo y busquedas sin respuesta
# ============================================================
#
#   bash pruebas/tendencias_avanzadas.sh
#
# Mide las tres rutas que el backend conecto el 2026-09-25
# (AdminTendenciasAvanzadasController), con las consultas de
# clickhouse/consultas/T1..T3:
#
#   GET /admin/eventos/tendencias               T1, dias_recientes, dias_base, limite
#   GET /admin/eventos/embudo                   T2, dias_ventana, limite
#   GET /admin/eventos/busquedas-sin-respuesta  T3, dias_ventana, limite
#
# clickhouse/correr_consultas.sh ya prueba el SQL del repositorio en una base
# aparte. Esta prueba mide lo que corre en el backend, con sus umbrales fijos,
# contra la base de verdad.
#
# QUE COMPRUEBA
# ============================================================
#   1. Quien puede. Sin sesion 401, comprador 403, admin 200, en las tres.
#   2. Los parametros. dias_ventana 0, dias_base "abc" y limite 0 dan 400.
#   3. T1. Un producto con 25 vistas de 3 sesiones hoy y ninguna antes sale con
#      3.6 al dia, 0 antes, 4.57 veces y 8.3 vistas por persona. Uno con 5
#      vistas (bajo el minimo de 20) no sale.
#   4. T2. 20 sesiones sin ningun pedido sale como mucho_interes_poca_compra.
#      20 sesiones con 1 pedido (5 %, arriba del 2 %) no sale. 2 unidades con 1
#      devuelta sale como devolucion_alta.
#   5. T3. Un termino de 3 sesiones con 0 resultados sale como no_tenemos; uno
#      con resultados y sin clics como no_convence. Con un clic no sale, y con
#      2 sesiones tampoco.
#
# COMO SE SIEMBRA. Igual que pruebas/tendencias.sh: con lote 'real' (lo unico
# que leen las rutas) y MARCADORES en otras columnas. Los productos son ids
# ficticios (987654401 a 987654405), que no existen en Mongo, asi que la ruta
# los devuelve con `producto: null`; los terminos empiezan con
# 'prueba-tavanz-'. Como las filas de producto no traen su id, se reconocen
# por sus numeros, que se eligieron para no repetirse. Antes de sembrar se
# exige que ninguna ruta traiga ya filas con `producto: null`.
#
# LA REGLA QUE NO SE ROMPE al limpiar: marcador Y lote real, nunca lote solo.
# vistas_por_producto_dia se llena sola por la vista materializada, asi que
# las vistas sembradas tambien se borran de ahi (hallazgo del companero en
# cambio_propuestas/2026-09-25_0815: si no, quedan como falsos positivos de T1).
# Hay un trap: si el proceso muere, limpia.
#
# LO QUE CUESTA. Dos inicios de sesion (admin y comprador), que suman al
# contador multi_cuenta_ip del fraude de login. De a uno, sin nadie mas
# sembrando eventos.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
CH_CONTENEDOR="${CH_CONTENEDOR:-mesh-clickhouse}"
ADMIN_USUARIO="${ADMIN_USUARIO:-admin@mesh.com}"
ADMIN_CLAVE="${ADMIN_CLAVE:-Admin123}"
COMPRADOR_USUARIO="${COMPRADOR_USUARIO:-comprador.sur@mesh.com}"
COMPRADOR_CLAVE="${COMPRADOR_CLAVE:-Comprador123}"

if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
CH_USUARIO="${CLICKHOUSE_USER:-}"
CH_BASE="${CLICKHOUSE_DB:-mesh_eventos}"
if [ -z "${CLICKHOUSE_PASSWORD:-}" ] || [ -z "$CH_USUARIO" ]; then
    echo "Faltan CLICKHOUSE_USER o CLICKHOUSE_PASSWORD. Ponlas en el .env de la raiz." >&2
    exit 1
fi

export MSYS_NO_PATHCONV=1

TARRO_ADMIN=".mesh-tavanz-admin.txt"
TARRO_COMPRADOR=".mesh-tavanz-comprador.txt"
CUERPO=".mesh-tavanz-cuerpo.txt"

# Los marcadores.
T1_SUBE=987654401
T1_POCO=987654402
T2_INTERES=987654403
T2_BIEN=987654404
T2_DEVUELVE=987654405
FALSOS="$T1_SUBE,$T1_POCO,$T2_INTERES,$T2_BIEN,$T2_DEVUELVE"
PREFIJO="prueba-tavanz-"
TABLAS_PRODUCTO="vista_producto carrito_producto compra_producto devolucion_producto vistas_por_producto_dia"
TABLAS_BUSQUEDA="busqueda_realizada busqueda_clic"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
igual() { if [ "$3" = "$2" ]; then OK "$1 ($3)"; else FALLA "$1 -- esperado $2, salio $3"; fi; }

ch() {
    docker exec -i "$CH_CONTENEDOR" clickhouse-client \
        --user "$CH_USUARIO" --password "$CLICKHOUSE_PASSWORD" \
        --database "$CH_BASE" -q "$1" < /dev/null
}
jx() {
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch(e){console.log("__NO_JSON__");return}try{console.log(eval(process.argv[1]))}catch(e){console.log("__ERROR__")}})' "$1"
}
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

filas_marcadas() {
    local n=0 t c
    for t in $TABLAS_PRODUCTO; do
        c=$(ch "SELECT count() FROM $t WHERE lote = 'real' AND id_producto IN ($FALSOS)")
        n=$((n + c))
    done
    for t in $TABLAS_BUSQUEDA; do
        c=$(ch "SELECT count() FROM $t WHERE lote = 'real' AND startsWith(termino, '$PREFIJO')")
        n=$((n + c))
    done
    echo "$n"
}
borrar_marcadas() {
    local t
    for t in $TABLAS_PRODUCTO; do
        ch "ALTER TABLE $t DELETE WHERE lote = 'real' AND id_producto IN ($FALSOS) SETTINGS mutations_sync = 2" >/dev/null 2>&1
    done
    for t in $TABLAS_BUSQUEDA; do
        ch "ALTER TABLE $t DELETE WHERE lote = 'real' AND startsWith(termino, '$PREFIJO') SETTINGS mutations_sync = 2" >/dev/null 2>&1
    done
}
BORRADO=0
limpiar() {
    [ "$BORRADO" = 1 ] && return
    BORRADO=1
    borrar_marcadas
    rm -f "$TARRO_ADMIN" "$TARRO_COMPRADOR" "$CUERPO"
}
trap limpiar EXIT INT TERM

# ============================================================
titulo "0. Backend y ClickHouse vivos, y sin restos"
# ============================================================
for t in $TABLAS_PRODUCTO $TABLAS_BUSQUEDA; do
    ch "SELECT 1 FROM $t LIMIT 1" >/dev/null 2>&1 || { FALLA "no se puede leer $CH_BASE.$t"; exit 1; }
done
OK "las tablas de eventos se leen en $CH_BASE"
restos=$(filas_marcadas)
if [ "$restos" -gt 0 ]; then
    echo "  (habia $restos fila(s) marcadas de una corrida anterior, se borran)"
    borrar_marcadas
fi
OK "sin restos de otra corrida"

# ============================================================
titulo "1. Quien puede"
# ============================================================
c=$(entrar "$ADMIN_USUARIO" "$TARRO_ADMIN" "$ADMIN_CLAVE")
[ "$c" = "200" ] && OK "entra el admin" || { FALLA "el admin no entro ($c). Esta el backend en $API?"; exit 1; }
c=$(entrar "$COMPRADOR_USUARIO" "$TARRO_COMPRADOR" "$COMPRADOR_CLAVE")
[ "$c" = "200" ] && OK "entra el comprador" || { FALLA "el comprador no entro ($c)"; exit 1; }
for r in tendencias embudo busquedas-sin-respuesta; do
    igual "$r sin sesion" 401 "$(get "/admin/eventos/$r")"
    igual "$r con comprador" 403 "$(get "/admin/eventos/$r" "$TARRO_COMPRADOR")"
    igual "$r con admin" 200 "$(get "/admin/eventos/$r" "$TARRO_ADMIN")"
done

# ============================================================
titulo "2. Los parametros malos dan 400"
# ============================================================
igual "embudo con dias_ventana 0" 400 "$(get "/admin/eventos/embudo?dias_ventana=0" "$TARRO_ADMIN")"
igual "tendencias con dias_base abc" 400 "$(get "/admin/eventos/tendencias?dias_base=abc" "$TARRO_ADMIN")"
igual "busquedas con limite 0" 400 "$(get "/admin/eventos/busquedas-sin-respuesta?limite=0" "$TARRO_ADMIN")"

# Sin filas de producto sin ficha antes de sembrar: si las hubiera, no se
# sabria cuales son las de la prueba.
for r in tendencias embudo; do
    get "/admin/eventos/$r?limite=200" "$TARRO_ADMIN" >/dev/null
    huerfanas=$(jx 'j.payload.filter(x=>x.producto===null).length' < "$CUERPO")
    if [ "$huerfanas" != "0" ]; then
        FALLA "$r ya trae $huerfanas fila(s) de un producto sin ficha antes de sembrar"
        exit 1
    fi
done
OK "tendencias y embudo no traen filas huerfanas antes de sembrar"

# ============================================================
titulo "3. Se siembra"
# ============================================================
# T1_SUBE: 25 vistas hoy de 3 sesiones (9, 8 y 8). T1_POCO: 5 vistas.
ch "INSERT INTO vista_producto (fecha,id_producto,sesion,ip,origen,lote)
    SELECT now(), $T1_SUBE, concat('ta-s', toString(number % 3)), '127.0.0.1', 'catalogo', 'real' FROM numbers(25)"
ch "INSERT INTO vista_producto (fecha,id_producto,sesion,ip,origen,lote)
    SELECT now(), $T1_POCO, 'ta-poco', '127.0.0.1', 'catalogo', 'real' FROM numbers(5)"
# T2: 20 sesiones distintas en cada uno. T2_BIEN ademas vende 1 pedido.
for p in $T2_INTERES $T2_BIEN; do
    ch "INSERT INTO vista_producto (fecha,id_producto,sesion,ip,origen,lote)
        SELECT now(), $p, concat('ta-e$p-', toString(number)), '127.0.0.1', 'catalogo', 'real' FROM numbers(20)"
done
ch "INSERT INTO compra_producto (fecha,id_producto,id_oferta,id_usuario,cantidad,id_pedido,ip,lote) VALUES
    (now(),$T2_BIEN,1,900000001,1,990000401,'127.0.0.1','real'),
    (now(),$T2_DEVUELVE,1,900000001,2,990000402,'127.0.0.1','real')"
ch "INSERT INTO devolucion_producto (fecha,id_producto,id_oferta,id_usuario,cantidad,id_pedido,ip,lote) VALUES
    (now(),$T2_DEVUELVE,1,900000001,1,990000402,'127.0.0.1','real')"
# T3: cuatro terminos.
ch "INSERT INTO busqueda_realizada (fecha,termino,resultados,sesion,lote) VALUES
    (now(),'${PREFIJO}nada',0,'ta-b1','real'),
    (now(),'${PREFIJO}nada',0,'ta-b2','real'),
    (now(),'${PREFIJO}nada',0,'ta-b3','real'),
    (now(),'${PREFIJO}sin-clic',7,'ta-b1','real'),
    (now(),'${PREFIJO}sin-clic',7,'ta-b2','real'),
    (now(),'${PREFIJO}sin-clic',7,'ta-b3','real'),
    (now(),'${PREFIJO}con-clic',7,'ta-b1','real'),
    (now(),'${PREFIJO}con-clic',7,'ta-b2','real'),
    (now(),'${PREFIJO}con-clic',7,'ta-b3','real'),
    (now(),'${PREFIJO}pocas',0,'ta-b1','real'),
    (now(),'${PREFIJO}pocas',0,'ta-b2','real')"
ch "INSERT INTO busqueda_clic (fecha,termino,id_producto,posicion,sesion,lote) VALUES
    (now(),'${PREFIJO}con-clic',1,1,'ta-b1','real')"
sembradas=$(filas_marcadas)
[ "$sembradas" -gt 0 ] && OK "sembradas $sembradas filas marcadas" || { FALLA "no se sembro nada"; exit 1; }

# ============================================================
titulo "4. T1, en ascenso"
# ============================================================
get "/admin/eventos/tendencias?dias_recientes=7&dias_base=21&limite=200" "$TARRO_ADMIN" >/dev/null
fila=$(jx 'const f=j.payload.find(x=>x.producto===null && Number(x.vistas_por_persona)===8.3); f ? [f.por_dia_ahora,f.por_dia_antes,f.veces].map(Number).join("|") : "no-sale"' < "$CUERPO")
igual "el que sube sale con 3.6 al dia, 0 antes y 4.57 veces" "3.6|0|4.57" "$fila"
poco=$(jx 'j.payload.filter(x=>x.producto===null && Number(x.por_dia_ahora)===0.7).length' < "$CUERPO")
igual "el de 5 vistas no llega al minimo" 0 "$poco"

# ============================================================
titulo "5. T2, donde se cae la venta"
# ============================================================
get "/admin/eventos/embudo?dias_ventana=30&limite=200" "$TARRO_ADMIN" >/dev/null
interes=$(jx 'j.payload.filter(x=>x.producto===null && x.diagnostico==="mucho_interes_poca_compra" && Number(x.sesiones)===20 && Number(x.pedidos)===0).length' < "$CUERPO")
igual "20 sesiones y ningun pedido, mucho_interes_poca_compra" 1 "$interes"
bien=$(jx 'j.payload.filter(x=>x.producto===null && Number(x.sesiones)===20 && Number(x.pedidos)===1).length' < "$CUERPO")
igual "20 sesiones y 1 pedido (5 %) no sale" 0 "$bien"
devuelve=$(jx 'const f=j.payload.find(x=>x.producto===null && x.diagnostico==="devolucion_alta" && Number(x.unidades)===2); f ? [f.devueltas,f.tasa_devolucion].map(Number).join("|") : "no-sale"' < "$CUERPO")
igual "2 vendidas y 1 devuelta, devolucion_alta al 50 %" "1|0.5" "$devuelve"

# ============================================================
titulo "6. T3, busquedas sin respuesta"
# ============================================================
get "/admin/eventos/busquedas-sin-respuesta?dias_ventana=30&limite=200" "$TARRO_ADMIN" >/dev/null
diag() { jx "(j.payload.find(x=>x.termino==='${PREFIJO}$1')||{diagnostico:'no-sale'}).diagnostico" < "$CUERPO"; }
igual "0 resultados en 3 sesiones" "no_tenemos" "$(diag nada)"
igual "resultados y ningun clic" "no_convence" "$(diag sin-clic)"
igual "con un clic no sale" "no-sale" "$(diag con-clic)"
igual "con 2 sesiones no sale" "no-sale" "$(diag pocas)"

# ============================================================
titulo "7. Limpieza"
# ============================================================
limpiar
igual "no quedo ninguna fila marcada" 0 "$(filas_marcadas)"

titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
exit 0
