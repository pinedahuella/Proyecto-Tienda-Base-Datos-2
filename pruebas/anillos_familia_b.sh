#!/usr/bin/env bash
# pruebas/anillos_familia_b.sh -- los patrones B de resenas (migracion 023),
# armados y leidos enteramente por el backend.
#
#   bash pruebas/anillos_familia_b.sh
#   ESPERA=120 bash pruebas/anillos_familia_b.sh
#   ESPERA_B7=960 bash pruebas/anillos_familia_b.sh   espera tambien a B.7
#
# POR QUE EXISTE
# ============================================================
# neo4j/correr_patrones.sh prueba las consultas B1..B7 del repositorio contra
# Neo4j, sembrando a mano. El backend (PatronesFraudeDetectorService, desde el
# 2026-09-24) tiene sus propias copias, con una ventana de 60 dias que las del
# repositorio no llevan, y las guarda en anillo_fraude con los tipos 4 a 10.
# Desde el refactor de fraude (migraciones 031 a 033) las guarda como senales,
# en senal_fraude con la familia patron_resenas, y el id_anillo_fraude de la API
# es senal_fraude.id_senal_fraude.
# Esta prueba pasa por el camino completo, igual que pruebas/anillos.sh para
# A.1: cuentas, ofertas, compras y resenas reales por HTTP, y el caso leido por
# GET /admin/fraude/alertas-resenas.
#
# DESDE EL 2026-10-17 (limpieza de fraude de Jose David, migracion 042) ya no
# existen cadena_abierta (B.1) ni favor_devuelto (B.5). El favor devuelto va
# dentro de `mutuo`: el par guarda en su `detalle` las HORAS entre la ida y la
# vuelta, y el puntaje lo usa como bono. Hasta esa fecha esta prueba esperaba
# un caso favor_devuelto aparte del mutuo, con la misma clave.
#
# QUE HACE
# ============================================================
#   1. Registra 4 cuentas con un prefijo unico. La 1 y la 2 pasan a vendedor.
#   2. La 1 publica tres ofertas (tres productos) y la 2 una. El admin las
#      aprueba.
#   3. Favor devuelto. La 1 le compra a la 2 y la califica con 5, y la 2 le
#      devuelve el 5 a la 1 enseguida. El disparo inmediato tiene que guardar
#      un `mutuo` con las dos cuentas, y en su detalle menos de 1 hora entre la
#      ida y la vuelta (el bono de +20 del puntaje).
#   4. B.6 coordinados. La 3 y la 4 compran los tres productos de la 1 y los
#      califican, las dos, en el mismo rato: tres coincidencias. Tiene que salir
#      un caso `coordinados` con la 3 y la 4, y SIN la 1: en B.6 el vendedor es
#      un tercero y no entra en las cuentas del caso (excepcion del backend en
#      SQL_CUENTAS_DE_ANILLO).
#   5. Los tipos quitados no vuelven: ni una senal cadena_abierta ni
#      favor_devuelto en la base, y el catalogo ya no los tiene.
#   6. Controles. La 3 y la 4 no salen en ningun mutuo, y el par 1-2 no sale en
#      ningun coordinados.
#   7. El filtro ?tipo= acepta los tipos de la familia B y rechaza con 400 el
#      reservado `anillo_en_el_tiempo` (B.4 no se persiste) y los dos quitados.
#   8. Opcional, con ESPERA_B7 > 0: B.7 reputacion expres solo corre en el
#      worker de cada 15 minutos. Las cuatro cuentas tienen minutos de vida, asi
#      que la 1 tiene que salir como vendedor con reputacion en minutos.
#
# Los tiempos son los del backend: el grafo se alimenta por la cola evento_grafo
# y el disparo inmediato corre despues de proyectar la resena.
#
# NO ES REVERSIBLE, igual que pruebas/anillos.sh: compra de verdad y deja
# cuentas, ofertas, pedidos y pagos. Los casos que arma se marcan revisados al
# final para que no se acumulen en el panel ni en la campana del admin.

set -u

API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
CLAVE="${CLAVE_ANILLO:-Desarrollo123!}"
ESPERA="${ESPERA:-90}"
ESPERA_B7="${ESPERA_B7:-0}"

export MSYS_NO_PATHCONV=1
export PYTHONUTF8=1

PREF="famb$(date +%s | tail -c 7)"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

sql()   { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" 2>/dev/null | tr -d '\r'; }
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

# buscar_caso TIPO USUARIOS_SEPARADOS_POR_COMA -> "id" del caso con esas
# cuentas exactas, o vacio. Lee la API, nunca PostgreSQL.
buscar_caso() {
    curl -s "$API/admin/fraude/alertas-resenas?tipo=$1&pagina=1&limite=200" -H "Cookie: $ADMIN" | python -c "
import sys,json
quiero=set(sys.argv[1].split(','))
try: d=json.load(sys.stdin)['payload']['anillos']
except Exception: d=[]
for a in d:
    if {c['usuario'] for c in a['cuentas']} == quiero:
        print(a['id_anillo_fraude']); break" "$2"
}

# esperar_caso TIPO USUARIOS SEGUNDOS -> deja el id en CASO
esperar_caso() {
    CASO=""
    for _ in $(seq 1 "$3"); do
        CASO=$(buscar_caso "$1" "$2")
        [ -n "$CASO" ] && return
        sleep 1
    done
}

# Cuantos casos de ese tipo incluyen a ese usuario, de cualquier estado.
casos_con() {
    curl -s "$API/admin/fraude/alertas-resenas?tipo=$1&pagina=1&limite=200" -H "Cookie: $ADMIN" | python -c "
import sys,json
try: d=json.load(sys.stdin)['payload']['anillos']
except Exception: d=[]
print(sum(1 for a in d if any(c['usuario']==sys.argv[1] for c in a['cuentas'])))" "$2"
}


titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend sirve /carrito" || { echo "  El backend no responde en $API."; exit 1; }
ADMIN=$(entrar "admin@mesh.com" "Admin123")
[ -n "$ADMIN" ] && OK "sesion de admin" || { echo "  No se pudo entrar como admin."; exit 1; }
# Por nombre y no contando la familia: desde la 035 a la 039 patron_resenas
# tambien lleva las senales de texto (resenas repetidas, notas incoherentes...).
# De la familia B quedan 5 desde la 042: sin cadena_abierta ni favor_devuelto.
tipos=$(sql "SELECT count(*) FROM tipo_senal_fraude t JOIN familia_senal_fraude f USING (id_familia_senal_fraude)
             WHERE f.familia_senal_fraude_nombre = 'patron_resenas'
               AND t.tipo_senal_fraude_nombre IN ('satelites', 'persistente', 'anillo_en_el_tiempo',
                                                  'coordinados', 'reputacion_expres');")
[ "$tipos" = "5" ] && OK "la 031 esta aplicada, los 5 tipos que quedan de la familia B" || { echo "  Faltan tipos de patron_resenas en tipo_senal_fraude ($tipos de 5). Corre .\\arrancar.ps1."; exit 1; }
quitados=$(sql "SELECT count(*) FROM tipo_senal_fraude WHERE tipo_senal_fraude_nombre IN ('cadena_abierta', 'favor_devuelto', 'carrito_acaparador');")
[ "$quitados" = "0" ] && OK "la 042 esta aplicada: cadena_abierta, favor_devuelto y carrito_acaparador ya no estan" || { echo "  Siguen $quitados tipos que la 042 quita. Corre .\\arrancar.ps1."; exit 1; }


titulo "1. Cuatro cuentas nuevas, prefijo $PREF"
declare -A COOKIE IDU DIRE
for n in 1 2 3 4; do
    correo="$PREF$n@mesh.com"
    curl -s -o /dev/null -X POST "$API/usuario/registro" -H "Content-Type: application/json" \
        -d "{\"correo_electronico\":\"$correo\",\"usuario\":\"$PREF$n\",\"nombre\":\"Familia $n\",\"apellido\":\"Prueba\",\"contrasena\":\"$CLAVE\"}"
    IDU[$n]=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='$correo';")
    [ -n "${IDU[$n]}" ] && OK "registrada $correo (id ${IDU[$n]})" || { echo "  No se registro $correo"; exit 1; }
done
for n in 1 2; do
    llamar PATCH "/admin/usuarios/${IDU[$n]}" "$ADMIN" '{"id_rol_usuario":2}' >/dev/null
done
# El rol viaja en el JWT: se entra DESPUES del cambio.
for n in 1 2 3 4; do
    COOKIE[$n]=$(entrar "$PREF$n@mesh.com" "$CLAVE")
    [ -n "${COOKIE[$n]}" ] || { echo "  No se pudo entrar como $PREF$n"; exit 1; }
    llamar POST "/direccion-usuario" "${COOKIE[$n]}" \
        '{"pais":"Guatemala","departamento":"Guatemala","ciudad":"Guatemala","direccion_exacta":"Direccion de prueba de la familia B","codigo_postal":"01001"}' >/dev/null
    DIRE[$n]=$(curl -s "$API/direccion-usuario" -H "Cookie: ${COOKIE[$n]}" | python -c "
import sys,json
d=json.load(sys.stdin).get('payload') or []
print(d[0]['id_direccion'] if d else '')")
done


titulo "2. Las ofertas"
# Los mismos productos y variantes que pruebas/anillos.sh.
PRODUCTOS=(83 76 81)
VARIANTES=(166 158 170)
declare -A OFERTA   # OFERTA[vendedor,producto]
publicar() {   # VENDEDOR PRODUCTO VARIANTE
    local r id
    r=$(llamar POST "/vendedor/ofertas" "${COOKIE[$1]}" \
        "{\"id_producto\":$2,\"id_producto_variante\":$3,\"precio\":\"15.00\",\"stock_inicial\":20}")
    id=$(echo "$r" | campo payload.id_oferta)
    if [ -n "$id" ]; then
        llamar PATCH "/vendedor/ofertas/$id/revision" "$ADMIN" '{"decision":"aprobar"}' >/dev/null
        OFERTA[$1,$2]=$id
        OK "$PREF$1 publico la oferta $id (producto $2) y el admin la aprobo"
    else
        FALLA "$PREF$1 no pudo publicar el producto $2, $(echo "$r" | campo mensaje)"
    fi
}
for i in 0 1 2; do publicar 1 "${PRODUCTOS[$i]}" "${VARIANTES[$i]}"; done
# La 2 vende OTRO producto: si el intercambio fuera sobre el mismo, A.2 lo
# llamaria `reiterado` y no `mutuo`. Se busca cualquiera de los dos abajo.
publicar 2 "${PRODUCTOS[1]}" "${VARIANTES[1]}"


# comprar_y_resenar COMPRADOR VENDEDOR PRODUCTO
comprar_y_resenar() {
    local b=$1 v=$2 p=$3
    local of="${OFERTA[$v,$p]:-}"
    [ -n "$of" ] || { FALLA "no hay oferta de $PREF$v para el producto $p"; return; }
    llamar PUT "/carrito/lineas/$of" "${COOKIE[$b]}" '{"cantidad":1}' >/dev/null
    local c; c=$(llamar POST "/carrito/comprar" "${COOKIE[$b]}" "{\"id_direccion\":${DIRE[$b]},\"metodo_pago\":\"efectivo contra entrega\"}")
    if [ "$(echo "$c" | campo payload.comprado)" != "True" ]; then
        FALLA "$PREF$b no pudo comprarle a $PREF$v el producto $p, $(echo "$c" | campo mensaje)"; return
    fi
    local r; r=$(llamar POST "/resenas" "${COOKIE[$b]}" \
        "{\"id_producto\":$p,\"correo_vendedor\":\"$PREF$v@mesh.com\",\"calificacion\":5,\"comentario\":\"Todo llego perfecto y a tiempo. Muy recomendado.\"}")
    [ "$(echo "$r" | campo ok)" = "True" ] && OK "$PREF$b le compro a $PREF$v el producto $p y le puso 5" \
        || FALLA "la resena de $PREF$b a $PREF$v, $(echo "$r" | campo mensaje)"
}


titulo "3. Favor devuelto, que desde la 042 es un mutuo con sus horas"
comprar_y_resenar 1 2 "${PRODUCTOS[1]}"
comprar_y_resenar 2 1 "${PRODUCTOS[0]}"
echo "  esperando hasta $ESPERA s el caso mutuo..."
esperar_caso mutuo "${PREF}1,${PREF}2" "$ESPERA"
ID_MUTUO="$CASO"
# Si los dos productos fueran el mismo, A.2 lo llamaria reiterado (ver arriba).
[ -z "$ID_MUTUO" ] && ID_MUTUO=$(buscar_caso reiterado "${PREF}1,${PREF}2")
[ -n "$ID_MUTUO" ] && OK "caso mutuo $ID_MUTUO con ${PREF}1 y ${PREF}2" || FALLA "no aparecio el mutuo de ${PREF}1 y ${PREF}2 en $ESPERA s"
if [ -n "$ID_MUTUO" ]; then
    n=$(sql "SELECT count(*) FROM senal_fraude_resena WHERE id_senal_fraude=$ID_MUTUO;")
    [ "$n" = "2" ] && OK "la evidencia son las 2 resenas del intercambio" || FALLA "la evidencia guardada es de $n resenas"
    horas=$(sql "SELECT detalle->>'horas' FROM senal_fraude WHERE id_senal_fraude=$ID_MUTUO;")
    python -c "import sys; sys.exit(0 if '$horas' and float('$horas') < 1 else 1)" 2>/dev/null \
        && OK "su detalle guarda las horas entre la ida y la vuelta ($horas): menos de 1 h, el bono de +20" \
        || FALLA "el detalle del mutuo no trae horas de menos de 1 ('$horas')"
fi


titulo "4. B.6 coordinados"
for i in 0 1 2; do
    comprar_y_resenar 3 1 "${PRODUCTOS[$i]}"
    comprar_y_resenar 4 1 "${PRODUCTOS[$i]}"
done
echo "  esperando hasta $ESPERA s el caso coordinados..."
esperar_caso coordinados "${PREF}3,${PREF}4" "$ESPERA"
ID_COORD="$CASO"
[ -n "$ID_COORD" ] && OK "caso coordinados $ID_COORD con ${PREF}3 y ${PREF}4, sin el vendedor" \
    || FALLA "no aparecio un coordinados con exactamente ${PREF}3 y ${PREF}4 en $ESPERA s"
if [ -n "$ID_COORD" ]; then
    n=$(sql "SELECT count(*) FROM senal_fraude_resena WHERE id_senal_fraude=$ID_COORD;")
    [ "$n" = "6" ] && OK "la evidencia son las 6 resenas, tres de cada una" || FALLA "la evidencia guardada es de $n resenas"
fi


titulo "5. Los tipos quitados no vuelven"
# El detector ya no los busca y la 042 los borra en cada arranque: con este
# mismo intercambio, antes del 10-17 salian un favor_devuelto y una cadena.
n=$(sql "SELECT count(*) FROM senal_fraude s JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude)
          WHERE t.tipo_senal_fraude_nombre IN ('cadena_abierta', 'favor_devuelto');")
[ "$n" = "0" ] && OK "ni una senal cadena_abierta ni favor_devuelto en la base" || FALLA "hay $n senales de tipos quitados"
otras=$(sql "SELECT count(*) FROM senal_fraude WHERE clave = (SELECT clave FROM senal_fraude WHERE id_senal_fraude=${ID_MUTUO:-0})
              AND id_senal_fraude <> ${ID_MUTUO:-0}
              AND id_tipo_senal_fraude IN (SELECT id_tipo_senal_fraude FROM tipo_senal_fraude t JOIN familia_senal_fraude f USING (id_familia_senal_fraude)
                                            WHERE f.familia_senal_fraude_nombre IN ('anillo_resenas', 'patron_resenas'));")
[ "$otras" = "0" ] && OK "el par 1-2 sale una sola vez, como mutuo" || FALLA "el par 1-2 sale en $otras senales mas de resenas"



titulo "6. Controles"
[ "$(casos_con mutuo "${PREF}3")" = "0" ] && OK "${PREF}3 no sale en ningun mutuo" || FALLA "${PREF}3 salio en un mutuo"
[ "$(casos_con mutuo "${PREF}4")" = "0" ] && OK "${PREF}4 no sale en ningun mutuo" || FALLA "${PREF}4 salio en un mutuo"
[ "$(casos_con coordinados "${PREF}1")" = "0" ] && OK "${PREF}1, el vendedor, no sale en ningun coordinados" || FALLA "${PREF}1 salio en un coordinados"
[ "$(casos_con coordinados "${PREF}2")" = "0" ] && OK "${PREF}2 no sale en ningun coordinados" || FALLA "${PREF}2 salio en un coordinados"


titulo "7. El filtro por tipo"
for t in mutuo satelites persistente coordinados reputacion_expres; do
    c=$(curl -s -o /dev/null -w '%{http_code}' "$API/admin/fraude/alertas-resenas?tipo=$t&pagina=1&limite=1" -H "Cookie: $ADMIN")
    [ "$c" = "200" ] && OK "?tipo=$t, 200" || FALLA "?tipo=$t contesto $c"
done
for t in cadena_abierta favor_devuelto; do
    c=$(curl -s -o /dev/null -w '%{http_code}' "$API/admin/fraude/alertas-resenas?tipo=$t&pagina=1&limite=1" -H "Cookie: $ADMIN")
    [ "$c" = "400" ] && OK "?tipo=$t, 400 (quitado el 2026-10-17)" || FALLA "?tipo=$t contesto $c"
done
c=$(curl -s -o /dev/null -w '%{http_code}' "$API/admin/fraude/alertas-resenas?tipo=anillo_en_el_tiempo" -H "Cookie: $ADMIN")
[ "$c" = "400" ] && OK "?tipo=anillo_en_el_tiempo, 400 (B.4 no se guarda)" || FALLA "?tipo=anillo_en_el_tiempo contesto $c"
if [ -n "$ID_COORD" ]; then
    det=$(curl -s "$API/admin/fraude/alertas-resenas/$ID_COORD/detalle-grafo" -H "Cookie: $ADMIN" | python -c "
import sys,json
try: print(len(json.load(sys.stdin)['payload'].get('resenas') or []))
except Exception: print(0)")
    [ "$det" = "6" ] && OK "el detalle-grafo del coordinados trae sus 6 resenas" || FALLA "el detalle-grafo trae $det resenas"
fi


titulo "8. B.7 reputacion expres"
if [ "$ESPERA_B7" -gt 0 ] 2>/dev/null; then
    echo "  esperando hasta $ESPERA_B7 s al worker de cada 15 minutos..."
    ID_B7=""
    for _ in $(seq 1 $((ESPERA_B7 / 10))); do
        ID_B7=$(curl -s "$API/admin/fraude/alertas-resenas?tipo=reputacion_expres&pagina=1&limite=200" -H "Cookie: $ADMIN" | python -c "
import sys,json
try: d=json.load(sys.stdin)['payload']['anillos']
except Exception: d=[]
for a in d:
    if any(c['usuario']==sys.argv[1] for c in a['cuentas']):
        print(a['id_anillo_fraude']); break" "${PREF}1")
        [ -n "$ID_B7" ] && break
        sleep 10
    done
    [ -n "$ID_B7" ] && OK "caso reputacion_expres $ID_B7 con ${PREF}1 de vendedor" || FALLA "no aparecio el reputacion_expres de ${PREF}1 en $ESPERA_B7 s"
else
    echo "  saltado. Corre con ESPERA_B7=960 para esperar al worker."
fi


titulo "LIMPIEZA, los casos de la prueba quedan revisados"
pendientes=$(curl -s "$API/admin/fraude/alertas-resenas?estado=pendiente&pagina=1&limite=200" -H "Cookie: $ADMIN" | python -c "
import sys,json
p=sys.argv[1]
try: d=json.load(sys.stdin)['payload']['anillos']
except Exception: d=[]
print(' '.join(a['id_anillo_fraude'] for a in d if a['cuentas'] and all(c['usuario'].startswith(p) for c in a['cuentas'])))" "$PREF")
n=0
for id in $pendientes; do
    r=$(llamar PATCH "/admin/fraude/alertas-resenas/$id" "$ADMIN" '{"estado":"revisada"}')
    [ "$(echo "$r" | campo ok)" = "True" ] && n=$((n+1))
done
echo "  $n casos marcados revisados"


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
echo "  Los patrones B se armaron por la API, el backend los guardo con su tipo y los controles quedaron fuera."
exit 0
