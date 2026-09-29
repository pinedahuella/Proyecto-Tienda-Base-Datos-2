#!/usr/bin/env bash
# pruebas/anillos.sh -- el detector de anillos de resenas encuentra un anillo
# REAL, armado y consultado enteramente por el backend (Entrega 2, grafo, 3 pts).
#
#   bash pruebas/anillos.sh
#
# POR QUE EXISTE
# ============================================================
# neo4j/correr_fraude.sh corre los archivos neo4j/consultas/A*.cypher directo
# contra Neo4j. El detector del backend (AnillosDetectorService) tiene sus
# propias copias de esas consultas dentro del codigo, asi que aquella prueba
# demuestra las consultas del repositorio y no las que corren. Esta prueba pasa
# por el camino completo del backend, sin tocar Neo4j ni PostgreSQL a mano.
#
# QUE HACE
# ============================================================
#   1. Registra 4 cuentas nuevas con un prefijo unico por corrida. Tres formaran
#      el anillo y la cuarta es el CONTROL, una cuenta que compra y resena pero
#      nadie le compra a ella, o sea que no cierra ningun ciclo.
#   2. Las tres del anillo pasan a vendedor (PATCH /admin/usuarios/:id) y cada
#      una publica una oferta que el admin aprueba.
#   3. Compras REALES con el checkout de siempre (POST /carrito/comprar) y
#      resenas REALES (POST /resenas). La cuenta de control le compra y le
#      resena a la primera. Despues A le compra a B, B a C y C a A.
#   4. Espera a que el detector lo encuentre y lo lee por
#      GET /admin/fraude/alertas-resenas. Tiene que salir un ciclo con las tres
#      cuentas, y la de control NO tiene que salir en ningun anillo.
#   5. Pide su detalle, GET .../detalle-grafo, que se lee de Neo4j, y lo marca
#      revisado con PATCH. Marcarlo otra vez tiene que dar 409.
#
# Lo unico que se lee directo es PostgreSQL, para CONFIRMAR que el anillo quedo
# guardado. No se escribe nada a mano.
#
# NO ES REVERSIBLE. Igual que pruebas/falla_checkout.sh, esto compra de verdad:
# deja cuentas, ofertas, pedidos, pagos y movimientos de stock. El anillo queda
# marcado como revisado para que no se acumulen pendientes en el panel ni en la
# campana del admin.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
CLAVE="${CLAVE_ANILLO:-Desarrollo123!}"
ESPERA="${ESPERA:-60}"

export MSYS_NO_PATHCONV=1

PREF="anit$(date +%s | tail -c 7)"

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


titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend sirve /carrito" || { echo "  El backend no responde en $API."; exit 1; }
ADMIN=$(entrar "admin@mesh.com" "Admin123")
[ -n "$ADMIN" ] && OK "sesion de admin" || { echo "  No se pudo entrar como admin."; exit 1; }
pend_antes=$(curl -s "$API/admin/fraude/alertas-resenas?estado=pendiente&pagina=1&limite=1" -H "Cookie: $ADMIN" | campo payload.total_anillos)
echo "  anillos pendientes antes de empezar, $pend_antes"


titulo "1. Cuatro cuentas nuevas, prefijo $PREF"

CUENTAS=(1 2 3 4)
declare -A COOKIE IDU DIRE OFERTA
for n in "${CUENTAS[@]}"; do
    correo="$PREF$n@mesh.com"
    curl -s -o /dev/null -X POST "$API/usuario/registro" -H "Content-Type: application/json" \
        -d "{\"correo_electronico\":\"$correo\",\"usuario\":\"$PREF$n\",\"nombre\":\"Anillo $n\",\"apellido\":\"Prueba\",\"contrasena\":\"$CLAVE\"}"
    IDU[$n]=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='$correo';")
    [ -n "${IDU[$n]}" ] && OK "registrada $correo (id ${IDU[$n]})" || { echo "  No se registro $correo"; exit 1; }
done


titulo "2. Las tres del anillo pasan a vendedor y publican su oferta"

PRODUCTO=(0 83 76 81)
VARIANTE=(0 166 158 170)
for n in 1 2 3; do
    llamar PATCH "/admin/usuarios/${IDU[$n]}" "$ADMIN" '{"id_rol_usuario":2}' >/dev/null
done
# El rol viaja dentro del JWT, se firma al entrar. Hay que entrar DESPUES del cambio.
for n in "${CUENTAS[@]}"; do
    COOKIE[$n]=$(entrar "$PREF$n@mesh.com" "$CLAVE")
    [ -n "${COOKIE[$n]}" ] || { echo "  No se pudo entrar como $PREF$n"; exit 1; }
    llamar POST "/direccion-usuario" "${COOKIE[$n]}" \
        '{"pais":"Guatemala","departamento":"Guatemala","ciudad":"Guatemala","direccion_exacta":"Direccion de prueba de anillos","codigo_postal":"01001"}' >/dev/null
    DIRE[$n]=$(curl -s "$API/direccion-usuario" -H "Cookie: ${COOKIE[$n]}" | python -c "
import sys,json
d=json.load(sys.stdin).get('payload') or []
print(d[0]['id_direccion'] if d else '')")
done
for n in 1 2 3; do
    r=$(llamar POST "/vendedor/ofertas" "${COOKIE[$n]}" \
        "{\"id_producto\":${PRODUCTO[$n]},\"id_producto_variante\":${VARIANTE[$n]},\"precio\":\"15.00\",\"stock_inicial\":20}")
    OFERTA[$n]=$(echo "$r" | campo payload.id_oferta)
    if [ -n "${OFERTA[$n]}" ]; then
        llamar PATCH "/vendedor/ofertas/${OFERTA[$n]}/revision" "$ADMIN" '{"decision":"aprobar"}' >/dev/null
        OK "$PREF$n publico y el admin aprobo la oferta ${OFERTA[$n]}"
    else
        FALLA "$PREF$n no pudo publicar, $(echo "$r" | campo mensaje)"
    fi
done


# comprar_y_resenar COMPRADOR VENDEDOR
comprar_y_resenar() {
    local b=$1 v=$2
    llamar PUT "/carrito/lineas/${OFERTA[$v]}" "${COOKIE[$b]}" '{"cantidad":1}' >/dev/null
    local c; c=$(llamar POST "/carrito/comprar" "${COOKIE[$b]}" "{\"id_direccion\":${DIRE[$b]},\"metodo_pago\":\"efectivo contra entrega\"}")
    # `ok` sale true tambien cuando no compro porque el precio cambio desde la
    # foto del carrito (comprado false, con avisos). Lo que cuenta es comprado.
    if [ "$(echo "$c" | campo payload.comprado)" = "True" ]; then
        OK "$PREF$b le compro a $PREF$v con el checkout real"
    else
        FALLA "$PREF$b no pudo comprarle a $PREF$v, $(echo "$c" | campo mensaje)"; return
    fi
    local r; r=$(llamar POST "/resenas" "${COOKIE[$b]}" \
        "{\"id_producto\":${PRODUCTO[$v]},\"correo_vendedor\":\"$PREF$v@mesh.com\",\"calificacion\":5,\"comentario\":\"Excelente vendedor, todo llego perfecto y en tiempo. Lo recomiendo.\"}")
    [ "$(echo "$r" | campo ok)" = "True" ] && OK "$PREF$b le resena 5 estrellas a $PREF$v" || FALLA "la resena de $PREF$b a $PREF$v, $(echo "$r" | campo mensaje)"
}

titulo "3. El control primero, y despues el ciclo"

# La cuenta 4 le compra y le resena a la 1. Nadie le compra a la 4, no hay ciclo.
comprar_y_resenar 4 1
# El anillo, 1 -> 2 -> 3 -> 1. La ultima resena lo cierra.
comprar_y_resenar 1 2
comprar_y_resenar 2 3
comprar_y_resenar 3 1


titulo "4. El detector lo encuentra, y se lee por la API"

echo "  esperando hasta $ESPERA s a que el detector guarde el anillo..."
ID_ANILLO=""; TIPO=""
for s in $(seq 1 "$ESPERA"); do
    lista=$(curl -s "$API/admin/fraude/alertas-resenas?estado=pendiente&pagina=1&limite=50" -H "Cookie: $ADMIN")
    salida=$(echo "$lista" | python -c "
import sys,json
p='$PREF'
try: d=json.load(sys.stdin)['payload']['anillos']
except Exception: d=[]
quiero={p+'1',p+'2',p+'3'}
for a in d:
    usuarios={c['usuario'] for c in a['cuentas']}
    if usuarios==quiero:
        print(a['id_anillo_fraude'],a['tipo']); break")
    if [ -n "$salida" ]; then ID_ANILLO=${salida%% *}; TIPO=${salida##* }; break; fi
    sleep 1
done
[ -n "$ID_ANILLO" ] && OK "el detector guardo el anillo $ID_ANILLO a los $s s" || { FALLA "no aparecio ningun anillo con las tres cuentas en $ESPERA s"; }
[ "$TIPO" = "ciclo" ] && OK "lo clasifico como ciclo" || FALLA "tipo inesperado, '$TIPO'"

# El control no puede estar en ningun anillo de la familia A (mutuo, ciclo, reiterado).
# Desde la familia B (023) si sale en una cadena abierta (B.1): califico a una cuenta del
# ciclo, asi que es un eslabon de una cadena que no vuelve a el. Es lo que el diseno llama
# periferia (docs/fraude-entrega3/02-reglas-backend.md): se lista y nada automatico la toca.
en_control=$(curl -s "$API/admin/fraude/alertas-resenas?pagina=1&limite=200" -H "Cookie: $ADMIN" | python -c "
import sys,json
p='$PREF'
d=json.load(sys.stdin)['payload']['anillos']
a_=sum(1 for a in d if a['tipo'] in ('mutuo','ciclo','reiterado') for c in a['cuentas'] if c['usuario']==p+'4')
b_=sum(1 for a in d if a['tipo'] not in ('mutuo','ciclo','reiterado') for c in a['cuentas'] if c['usuario']==p+'4')
print(a_, b_)")
en_a=${en_control%% *}; en_b=${en_control##* }
[ "$en_a" = "0" ] && OK "la cuenta de control ($PREF""4) no sale en ningun anillo de la familia A" || FALLA "la cuenta de control salio en $en_a anillos de la familia A"
[ "$en_b" != "0" ] && echo "  (la cuenta de control sale en $en_b cadena(s) abierta(s) de la familia B, como periferia, esperado)"

if [ -n "$ID_ANILLO" ]; then
    # Confirmacion, solo lectura. Las resenas del anillo quedaron en la tabla pivote.
    resenas_pg=$(sql "SELECT count(*) FROM anillo_fraude_resena WHERE id_anillo_fraude=$ID_ANILLO;")
    [ "$resenas_pg" = "3" ] && OK "PostgreSQL guardo las 3 resenas de evidencia" || FALLA "la evidencia guardada es de $resenas_pg resenas"

    titulo "5. El detalle sale de Neo4j, y el caso se trabaja como una cola"

    det=$(curl -s -o "$TEMP/anillo_detalle.json" -w '%{http_code}' "$API/admin/fraude/alertas-resenas/$ID_ANILLO/detalle-grafo" -H "Cookie: $ADMIN")
    [ "$det" = "200" ] && OK "GET .../detalle-grafo contesta 200" || FALLA "detalle-grafo contesto $det"
    n_res=$(python -c "
import json,os
try: d=json.load(open(os.environ['TEMP']+'/anillo_detalle.json'))['payload']
except Exception: print(0); raise SystemExit
print(len(d.get('resenas') or []))")
    [ "$n_res" = "3" ] && OK "el detalle trae las 3 resenas del ciclo, leidas del grafo" || FALLA "el detalle trae $n_res resenas"
    rm -f "$TEMP/anillo_detalle.json"

    r=$(llamar PATCH "/admin/fraude/alertas-resenas/$ID_ANILLO" "$ADMIN" '{"estado":"revisada"}')
    [ "$(echo "$r" | campo ok)" = "True" ] && OK "PATCH lo marco revisado" || FALLA "PATCH, $(echo "$r" | campo mensaje)"
    codigo=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$API/admin/fraude/alertas-resenas/$ID_ANILLO" \
        -H "Content-Type: application/json" -H "Cookie: $ADMIN" -d '{"estado":"descartada"}')
    [ "$codigo" = "409" ] && OK "moverlo otra vez desde revisado da 409" || FALLA "moverlo otra vez dio $codigo y no 409"
    estado_pg=$(sql "SELECT e.estado_alerta_fraude_nombre FROM anillo_fraude a JOIN estado_alerta_fraude e USING(id_estado_alerta_fraude) WHERE a.id_anillo_fraude=$ID_ANILLO;")
    [ "$estado_pg" = "revisada" ] && OK "PostgreSQL confirma el estado, revisada" || FALLA "el estado guardado es '$estado_pg'"
fi

pend_desp=$(curl -s "$API/admin/fraude/alertas-resenas?estado=pendiente&pagina=1&limite=1" -H "Cookie: $ADMIN" | campo payload.total_anillos)
# Las cadenas abiertas de la familia B que toca el control nacen pendientes y son de esta
# prueba. Se descuentan para comparar solo lo que no es de ella.
pend_b=$(sql "SELECT count(*) FROM anillo_fraude a JOIN estado_alerta_fraude e USING (id_estado_alerta_fraude)
               JOIN tipo_anillo_fraude t USING (id_tipo_anillo_fraude)
              WHERE e.estado_alerta_fraude_nombre = 'pendiente' AND t.tipo_anillo_fraude_nombre NOT IN ('mutuo','ciclo','reiterado')
                AND EXISTS (SELECT 1 FROM usuarios u WHERE u.usuario LIKE '$PREF%'
                             AND u.id_usuario::text = ANY (string_to_array(a.clave, '-')));")
[ -n "$pend_b" ] && pend_desp=$((pend_desp - pend_b))
[ "$pend_desp" = "$pend_antes" ] && OK "los anillos pendientes quedaron como estaban ($pend_antes), el de la prueba ya esta revisado" \
    || FALLA "pendientes, $pend_antes antes y $pend_desp despues"


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
echo "  El anillo se armo y se detecto por el backend, y la cuenta de control quedo fuera."
exit 0
