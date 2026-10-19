#!/usr/bin/env bash
# pruebas/ofertas_y_seguimientos.sh -- el buscador de ofertas (mesh_ofertas) y
# los avisos del comprador (el percolator mesh_seguimientos), a fondo.
#
#   bash pruebas/ofertas_y_seguimientos.sh
#   SIN_CAIDA=1 bash pruebas/ofertas_y_seguimientos.sh   sin parar Elasticsearch
#
# Lo que Jose David dejo como "falta la prueba a fondo" en evento-oferta.md y
# seguimiento-ofertas.md (25f0fe0, 2026-10-17). Toda accion pasa por las rutas
# HTTP del backend; PostgreSQL y Elasticsearch solo se MIRAN. La unica mano
# encima es parar y levantar el contenedor de Elasticsearch (parte 6).
#
# QUE COMPRUEBA
# ============================================================
#   1. El indice esta al dia: una fila de mesh_ofertas por cada oferta y la
#      cola evento_oferta vacia.
#   2. GET /vendedor/ofertas/buscar: un vendedor solo ve lo suyo, el texto
#      tolera errores de tecleo, alcance=todas es solo de la tienda y del
#      admin, y las reglas dan 400.
#   3. La cola sigue a la oferta: una oferta nueva aparece al aprobarla, y un
#      cambio de precio, de stock y de estado llega al documento.
#   4. Y a lo que la rodea: cambiar el nombre del vendedor, suspenderlo y
#      reactivarlo llega a TODAS sus ofertas (trigger de usuarios).
#   5. Los avisos: una busqueda que se cumple cuando llega una oferta nueva,
#      el precio maximo que la frena, una baja de precio de verdad, un solo
#      aviso aunque la oferta se toque dos veces, leido y no leido, y borrar.
#   6. Elasticsearch caido: crear un aviso da 503 sin dejar nada en
#      PostgreSQL, un cambio de oferta espera en la cola, y al volver se
#      indexa solo, sin reiniciar el backend.
#
# Deja un vendedor nuevo con dos ofertas retiradas, y una cuenta compradora
# nueva sin seguimientos. Las cuentas de la semilla quedan como estaban.

set -u

API="${API:-http://localhost:3000}"
ES="${ES:-http://localhost:9200}"
PG="${PG:-mesh-postgres}"
ELASTIC="${ELASTIC:-mesh-elastic}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
CLAVE="${CLAVE_PRUEBA:-Desarrollo123!}"
SIN_CAIDA="${SIN_CAIDA:-0}"

export MSYS_NO_PATHCONV=1
export PYTHONUTF8=1

PREF="ofs$(date +%s | tail -c 7)"

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
# Sin cuerpo no va el Content-Type: Fastify contesta 400 a un JSON vacio.
codigo() {
    if [ -n "${4:-}" ]; then
        curl -s -o /dev/null -w '%{http_code}' -X "$1" "$API$2" -H "Content-Type: application/json" -H "Cookie: $3" -d "$4"
    else
        curl -s -o /dev/null -w '%{http_code}' -X "$1" "$API$2" -H "Cookie: $3"
    fi
}

# El documento de una oferta en mesh_ofertas, un campo. Vacio si no esta.
doc() {
    curl -s "$ES/mesh_ofertas/_doc/$1" | python -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
print(d.get('_source',{}).get(sys.argv[1],'') if d.get('found') else '')" "$2"
}
# Espera hasta $3 s a que el campo $2 de la oferta $1 diga $4.
esperar_doc() {
    local i
    for i in $(seq 1 "$3"); do
        [ "$(doc "$1" "$2")" = "$4" ] && return 0
        sleep 1
    done
    return 1
}
cola() { sql "SELECT count(*) FROM evento_oferta WHERE procesado_en IS NULL;"; }
consultas() { curl -s "$ES/mesh_seguimientos/_count" | campo count; }

titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend responde" || { echo "  El backend no responde en $API."; exit 1; }
[ "$(sql "SELECT to_regclass('public.evento_oferta') IS NOT NULL AND to_regclass('public.seguimiento_oferta') IS NOT NULL;")" = "t" ] \
    && OK "las migraciones 043 y 044 estan" || { echo "  Faltan la 043 o la 044. Corre .\\arrancar.ps1"; exit 1; }
[ "$(curl -s "$ES/mesh_ofertas/_mapping" | campo mesh_ofertas.mappings.dynamic)" = "strict" ] \
    && OK "mesh_ofertas existe con su mapeo estricto" || { echo "  Falta mesh_ofertas. Corre .\\arrancar.ps1"; exit 1; }
tipo=$(curl -s "$ES/mesh_seguimientos/_mapping/field/consulta" | python -c "
import sys,json
try: print(json.load(sys.stdin)['mesh_seguimientos']['mappings']['consulta']['mapping']['consulta']['type'])
except Exception: print('')")
[ "$tipo" = "percolator" ] && OK "mesh_seguimientos es un percolator" || { echo "  Falta mesh_seguimientos. Corre .\\arrancar.ps1"; exit 1; }

ADMIN=$(entrar "admin@mesh.com" "Admin123")
TIENDA=$(entrar "tienda@mesh.com" "Vendedor123")
NORTE=$(entrar "ventas.norte@mesh.com" "Vendedor123")
[ -n "$ADMIN" ] && [ -n "$TIENDA" ] && [ -n "$NORTE" ] && OK "sesiones de admin, tienda y ventas.norte" || { echo "  No se pudo entrar con las cuentas de la semilla."; exit 1; }
ID_NORTE=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='ventas.norte@mesh.com';")


titulo "1. El indice esta al dia"
for _ in $(seq 1 120); do [ "$(cola)" = "0" ] && break; sleep 1; done
[ "$(cola)" = "0" ] && OK "la cola evento_oferta esta vacia" || FALLA "quedan $(cola) ofertas en la cola"
curl -s -X POST "$ES/mesh_ofertas/_refresh" >/dev/null
en_pg=$(sql "SELECT count(*) FROM oferta;")
en_es=$(curl -s "$ES/mesh_ofertas/_count" | campo count)
[ "$en_pg" = "$en_es" ] && OK "$en_es documentos en mesh_ofertas, uno por oferta de PostgreSQL" || FALLA "PostgreSQL $en_pg ofertas, Elasticsearch $en_es"
apartadas=$(sql "SELECT count(*) FROM evento_oferta WHERE procesado_en IS NULL AND intentos >= 5;")
[ "$apartadas" = "0" ] && OK "ninguna apartada por fallar" || FALLA "$apartadas ofertas apartadas"


titulo "2. El buscador por HTTP"
r=$(curl -s "$API/vendedor/ofertas/buscar?q=laptop&limite=100" -H "Cookie: $NORTE")
ajenas=$(echo "$r" | python -c "
import sys,json
d=json.load(sys.stdin)['payload']
print(sum(1 for o in d['ofertas'] if o['vendedor']['id_usuario']!='$ID_NORTE'))")
total=$(echo "$r" | campo payload.total_ofertas)
[ "${total:-0}" -gt 0 ] 2>/dev/null && [ "$ajenas" = "0" ] && OK "ventas.norte busca laptop: $total ofertas, todas suyas" || FALLA "ventas.norte vio $ajenas ajenas de $total"
mal=$(curl -s "$API/vendedor/ofertas/buscar?q=laptp&limite=5" -H "Cookie: $NORTE" | campo payload.total_ofertas)
[ "${mal:-0}" -gt 0 ] 2>/dev/null && OK "laptp, mal escrito, encuentra $mal" || FALLA "laptp no encontro nada"
[ "$(codigo GET "/vendedor/ofertas/buscar?alcance=todas" "$NORTE")" = "400" ] && OK "alcance=todas como vendedor, 400" || FALLA "un vendedor pudo pedir alcance=todas"
r=$(curl -s "$API/vendedor/ofertas/buscar?q=laptop&alcance=todas&limite=1" -H "Cookie: $ADMIN")
vend=$(echo "$r" | python -c "
import sys,json
print(len(json.load(sys.stdin)['payload']['resumen'].get('por_vendedor') or []))")
[ "${vend:-0}" -gt 1 ] 2>/dev/null && OK "el admin con alcance=todas ve $vend vendedores en el resumen" || FALLA "el resumen por vendedor trae $vend"
suma=$(echo "$r" | python -c "
import sys,json
d=json.load(sys.stdin)['payload']
print('si' if sum(d['resumen']['por_estado'].values())==d['total_ofertas'] else 'no')")
[ "$suma" = "si" ] && OK "el resumen cuenta todo lo que cumple, no solo la pagina" || FALLA "por_estado no suma total_ofertas"
[ "$(codigo GET "/vendedor/ofertas/buscar?precio_min=100&precio_max=50" "$TIENDA")" = "400" ] && OK "precio_min mayor que precio_max, 400" || FALLA "precio_min>precio_max no dio 400"
[ "$(codigo GET "/vendedor/ofertas/buscar?orden=raro" "$TIENDA")" = "400" ] && OK "un orden que no existe, 400" || FALLA "orden=raro no dio 400"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$API/vendedor/ofertas/buscar")" = "401" ] && OK "sin sesion, 401" || FALLA "contesto sin sesion"
COMP_SUR=$(entrar "comprador.sur@mesh.com" "Comprador123")
[ "$(codigo GET "/vendedor/ofertas/buscar" "$COMP_SUR")" = "403" ] && OK "un comprador, 403" || FALLA "un comprador pudo buscar ofertas"


titulo "3. Un vendedor nuevo y su oferta, de la cola al documento"
curl -s -o /dev/null -X POST "$API/usuario/registro" -H "Content-Type: application/json" \
    -d "{\"correo_electronico\":\"${PREF}v@mesh.com\",\"usuario\":\"${PREF}v\",\"nombre\":\"Prueba\",\"apellido\":\"Ofertas\",\"contrasena\":\"$CLAVE\"}"
ID_V=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='${PREF}v@mesh.com';")
llamar PATCH "/admin/usuarios/$ID_V" "$ADMIN" '{"id_rol_usuario":2}' >/dev/null
VEND=$(entrar "${PREF}v@mesh.com" "$CLAVE")
[ -n "$VEND" ] && OK "vendedor ${PREF}v (id $ID_V)" || { echo "  No se pudo crear el vendedor de prueba."; exit 1; }

# El producto 83 (Cartas al puerto seco), el mismo de las demos.
PRODUCTO=83; VARIANTE=166
NOMBRE_P=$(sql "SELECT nombre FROM producto_catalogo WHERE id_producto_mongo=$PRODUCTO;")
MINIMO=$(sql "SELECT min(ROUND(o.precio * (1 - COALESCE(o.porcentaje_descuento,0)/100), 2)) FROM oferta o
               JOIN estado_oferta e USING (id_estado_oferta)
              WHERE o.id_producto_mongo=$PRODUCTO AND o.id_producto_variante_mongo=$VARIANTE AND e.estado_oferta_nombre='activa' AND o.stock>0;")
echo "  producto $PRODUCTO, $NOMBRE_P; la oferta activa mas barata de su variante $VARIANTE esta a $MINIMO"

# Los avisos se piden ANTES de que llegue la oferta: un percolator solo avisa
# de lo que cambia.
curl -s -o /dev/null -X POST "$API/usuario/registro" -H "Content-Type: application/json" \
    -d "{\"correo_electronico\":\"${PREF}c@mesh.com\",\"usuario\":\"${PREF}c\",\"nombre\":\"Prueba\",\"apellido\":\"Avisos\",\"contrasena\":\"$CLAVE\"}"
COMP=$(entrar "${PREF}c@mesh.com" "$CLAVE")
c0=$(consultas)
TEXTO=$(echo "$NOMBRE_P" | tr 'A-Z' 'a-z')
r=$(llamar POST "/comprador/seguimientos" "$COMP" "{\"tipo\":\"busqueda\",\"texto\":\"$TEXTO\"}")
SEG_BUSQ=$(echo "$r" | campo payload.id_seguimiento)
[ -n "$SEG_BUSQ" ] && OK "avisame cuando llegue \"$TEXTO\" (seguimiento $SEG_BUSQ)" || FALLA "no se creo el seguimiento: $(echo "$r" | campo mensaje)"
r=$(llamar POST "/comprador/seguimientos" "$COMP" "{\"tipo\":\"busqueda\",\"texto\":\"$TEXTO puerto\",\"precio_maximo\":\"1.00\"}")
SEG_TOPE=$(echo "$r" | campo payload.id_seguimiento)
[ -n "$SEG_TOPE" ] && OK "y otro con precio maximo Q1.00, que no se tiene que cumplir" || FALLA "no se creo el del precio maximo: $(echo "$r" | campo mensaje)"
[ "$(codigo POST "/comprador/seguimientos" "$COMP" "{\"tipo\":\"busqueda\",\"texto\":\"$TEXTO\"}")" = "409" ] \
    && OK "la misma busqueda otra vez, 409" || FALLA "dejo seguir dos veces la misma busqueda"
[ "$(codigo POST "/comprador/seguimientos" "$COMP" '{"tipo":"busqueda","texto":"algo","id_producto":1}')" = "400" ] \
    && OK "un campo del otro tipo, 400" || FALLA "acepto id_producto en una busqueda"
curl -s -X POST "$ES/mesh_seguimientos/_refresh" >/dev/null
[ "$(consultas)" = "$((c0+2))" ] && OK "el percolator guardo las 2 consultas" || FALLA "el percolator paso de $c0 a $(consultas)"

r=$(llamar POST "/vendedor/ofertas" "$VEND" "{\"id_producto\":$PRODUCTO,\"id_producto_variante\":$VARIANTE,\"precio\":\"40.00\",\"stock_inicial\":10}")
OF=$(echo "$r" | campo payload.id_oferta)
[ -n "$OF" ] && OK "publico la oferta $OF, nace pendiente" || { echo "  No se pudo publicar: $(echo "$r" | campo mensaje)"; exit 1; }
esperar_doc "$OF" estado 20 pendiente && OK "en menos de 20 s esta en mesh_ofertas como pendiente" || FALLA "la oferta $OF no llego al indice (estado '$(doc "$OF" estado)')"
llamar PATCH "/vendedor/ofertas/$OF/revision" "$ADMIN" '{"decision":"aprobar"}' >/dev/null
esperar_doc "$OF" estado 20 activa && OK "la tienda la aprueba y el documento pasa a activa" || FALLA "el documento sigue en '$(doc "$OF" estado)'"
[ "$(doc "$OF" vendedor_usuario)" = "${PREF}v" ] && OK "con su vendedor, ${PREF}v" || FALLA "vendedor_usuario = $(doc "$OF" vendedor_usuario)"
[ "$(doc "$OF" nombre_producto)" = "$NOMBRE_P" ] && OK "y el nombre del producto, de producto_catalogo" || FALLA "nombre_producto = $(doc "$OF" nombre_producto)"

llamar PATCH "/vendedor/ofertas/$OF" "$VEND" '{"precio":"38.50"}' >/dev/null
esperar_doc "$OF" precio_final 20 38.5 && OK "precio nuevo, 38.50, en el documento" || FALLA "precio_final = $(doc "$OF" precio_final)"
llamar PATCH "/vendedor/ofertas/$OF" "$VEND" '{"ajuste_stock":-3}' >/dev/null
esperar_doc "$OF" stock 20 7 && OK "stock de 10 a 7 en el documento" || FALLA "stock = $(doc "$OF" stock)"
r=$(curl -s "$API/vendedor/ofertas/buscar?q=$(python -c "import urllib.parse;print(urllib.parse.quote('$TEXTO'))")" -H "Cookie: $VEND")
[ "$(echo "$r" | python -c "
import sys,json
print(','.join(o['id_oferta'] for o in json.load(sys.stdin)['payload']['ofertas']))")" = "$OF" ] \
    && OK "el vendedor la encuentra por el nombre del producto" || FALLA "el buscador del vendedor no la devuelve"


titulo "4. Lo que rodea a la oferta: el vendedor"
llamar PATCH "/admin/usuarios/$ID_V" "$ADMIN" '{"nombre":"Renombrado"}' >/dev/null
esperar_doc "$OF" vendedor_nombre 20 "Renombrado Ofertas" && OK "el nombre nuevo del vendedor llega al documento" || FALLA "vendedor_nombre = $(doc "$OF" vendedor_nombre)"
SUSP=$(sql "SELECT id_estado_usuario FROM estado_usuario WHERE estado_usuario_nombre <> 'activo' ORDER BY id_estado_usuario LIMIT 1;")
NOMBRE_SUSP=$(sql "SELECT estado_usuario_nombre FROM estado_usuario WHERE id_estado_usuario=$SUSP;")
ACT=$(sql "SELECT id_estado_usuario FROM estado_usuario WHERE estado_usuario_nombre = 'activo';")
llamar PATCH "/admin/usuarios/$ID_V" "$ADMIN" "{\"id_estado_usuario\":$SUSP}" >/dev/null
esperar_doc "$OF" estado_vendedor 20 "$NOMBRE_SUSP" && OK "vendedor $NOMBRE_SUSP: el documento lo dice" || FALLA "estado_vendedor = $(doc "$OF" estado_vendedor)"
llamar PATCH "/admin/usuarios/$ID_V" "$ADMIN" "{\"id_estado_usuario\":$ACT}" >/dev/null
esperar_doc "$OF" estado_vendedor 20 activo && OK "y activo otra vez" || FALLA "estado_vendedor = $(doc "$OF" estado_vendedor)"
VEND=$(entrar "${PREF}v@mesh.com" "$CLAVE")


titulo "5. Los avisos"
# Una oferta activa que se movio (precio, stock, aprobacion) ya paso por el
# percolator: la busqueda sin tope se tuvo que cumplir con ella, y la de Q1.00 no.
avisos_de() { curl -s "$API/comprador/seguimientos/avisos" -H "Cookie: $1"; }
for _ in $(seq 1 20); do
    [ -n "$(sql "SELECT fecha_cumplido FROM seguimiento_oferta WHERE id_seguimiento=${SEG_BUSQ:-0};")" ] && break
    sleep 1
done
r=$(avisos_de "$COMP")
[ "$(echo "$r" | python -c "
import sys,json
a=[x for x in json.load(sys.stdin)['payload']['avisos'] if x['seguimiento']['id_seguimiento']=='$SEG_BUSQ']
print(a[0]['oferta']['id_oferta'] if len(a)==1 else len(a))")" = "$OF" ] \
    && OK "la busqueda se cumplio con la oferta nueva, $OF: un solo aviso" || FALLA "los avisos de la busqueda no son el de la oferta $OF"
[ -n "$(sql "SELECT fecha_cumplido FROM seguimiento_oferta WHERE id_seguimiento=${SEG_BUSQ:-0};")" ] \
    && OK "el seguimiento quedo cumplido en PostgreSQL" || FALLA "fecha_cumplido sigue en NULL"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$ES/mesh_seguimientos/_doc/$SEG_BUSQ")" = "404" ] \
    && OK "y salio del percolator" || FALLA "la consulta sigue en el percolator"
[ -z "$(sql "SELECT fecha_cumplido FROM seguimiento_oferta WHERE id_seguimiento=${SEG_TOPE:-0};")" ] \
    && OK "el de precio maximo Q1.00 sigue esperando" || FALLA "el de Q1.00 se cumplio"
llamar PATCH "/vendedor/ofertas/$OF" "$VEND" '{"ajuste_stock":1}' >/dev/null
sleep 8
n=$(sql "SELECT count(*) FROM aviso_seguimiento_oferta WHERE id_seguimiento=${SEG_BUSQ:-0};")
[ "$n" = "1" ] && OK "tocar la oferta otra vez no da un segundo aviso" || FALLA "hay $n avisos del mismo seguimiento"

# Una baja de precio de verdad: se sigue la variante sin decir referencia, el
# backend toma la mas barata de hoy, y el vendedor nuevo baja por debajo.
r=$(llamar POST "/comprador/seguimientos" "$COMP" "{\"tipo\":\"baja_precio\",\"id_producto\":$PRODUCTO,\"id_producto_variante\":$VARIANTE}")
SEG_BAJA=$(echo "$r" | campo payload.id_seguimiento)
REF=$(echo "$r" | campo payload.precio_referencia)
[ -n "$SEG_BAJA" ] && OK "avisame si baja, referencia la mas barata de hoy: $REF" || FALLA "no se creo el de baja de precio: $(echo "$r" | campo mensaje)"
NUEVO=$(python -c "print('%.2f' % max(0.5, float('${REF:-1}') - 0.5))")
llamar PATCH "/vendedor/ofertas/$OF" "$VEND" "{\"precio\":\"$NUEVO\"}" >/dev/null
for _ in $(seq 1 20); do
    [ -n "$(sql "SELECT fecha_cumplido FROM seguimiento_oferta WHERE id_seguimiento=${SEG_BAJA:-0};")" ] && break
    sleep 1
done
aviso=$(sql "SELECT id_oferta || '|' || precio_final FROM aviso_seguimiento_oferta WHERE id_seguimiento=${SEG_BAJA:-0};")
[ "$aviso" = "$OF|$NUEVO" ] && OK "baja a $NUEVO y avisa con la oferta $OF a ese precio" || FALLA "el aviso de la baja es '$aviso'"

r=$(curl -s "$API/comprador/seguimientos/avisos?no_leidos=true" -H "Cookie: $COMP")
[ "$(echo "$r" | campo payload.total_no_leidos)" = "2" ] && OK "2 avisos sin leer" || FALLA "total_no_leidos = $(echo "$r" | campo payload.total_no_leidos)"
ID_AVISO=$(echo "$r" | python -c "
import sys,json
print(json.load(sys.stdin)['payload']['avisos'][0]['id_aviso'])")
llamar PATCH "/comprador/seguimientos/avisos/$ID_AVISO" "$COMP" '{"leido":true}' >/dev/null
[ "$(curl -s "$API/comprador/seguimientos/avisos" -H "Cookie: $COMP" | campo payload.total_no_leidos)" = "1" ] && OK "marcar uno como leido deja 1" || FALLA "no bajo a 1"
llamar PATCH "/comprador/seguimientos/avisos/$ID_AVISO" "$COMP" '{"leido":false}' >/dev/null
[ "$(curl -s "$API/comprador/seguimientos/avisos" -H "Cookie: $COMP" | campo payload.total_no_leidos)" = "2" ] && OK "y como no leido otra vez, 2" || FALLA "no volvio a 2"
[ "$(codigo PATCH "/comprador/seguimientos/avisos/$ID_AVISO" "$COMP_SUR" '{"leido":true}')" = "404" ] && OK "otra cuenta no puede tocar ese aviso, 404" || FALLA "otra cuenta toco el aviso"
[ "$(codigo DELETE "/comprador/seguimientos/$SEG_TOPE" "$COMP_SUR")" = "404" ] && OK "ni borrar su seguimiento, 404" || FALLA "otra cuenta borro el seguimiento"

c1=$(consultas)
c=$(codigo DELETE "/comprador/seguimientos/$SEG_TOPE" "$COMP")
[ "$c" = "200" ] && OK "borrar el que sigue esperando, 200" || FALLA "no se pudo borrar ($c)"
curl -s -X POST "$ES/mesh_seguimientos/_refresh" >/dev/null
[ "$(consultas)" = "$((c1-1))" ] && OK "y sale del percolator" || FALLA "el percolator paso de $c1 a $(consultas)"
for s_ in "$SEG_BUSQ" "$SEG_BAJA"; do codigo DELETE "/comprador/seguimientos/$s_" "$COMP" >/dev/null; done
[ "$(sql "SELECT count(*) FROM seguimiento_oferta s JOIN usuarios u USING (id_usuario) WHERE u.correo_electronico='${PREF}c@mesh.com';")" = "0" ] \
    && OK "borrar los cumplidos se lleva sus avisos" || FALLA "quedaron seguimientos de la cuenta de prueba"


titulo "6. Elasticsearch caido y de vuelta"
if [ "$SIN_CAIDA" = "1" ]; then
    echo "  saltado (SIN_CAIDA=1)"
else
    docker stop "$ELASTIC" >/dev/null 2>&1
    antes=$(sql "SELECT count(*) FROM seguimiento_oferta;")
    c=$(codigo POST "/comprador/seguimientos" "$COMP" '{"tipo":"busqueda","texto":"algo que no llega"}')
    [ "$c" = "503" ] && OK "crear un aviso sin Elasticsearch, 503" || FALLA "crear un aviso sin Elasticsearch dio $c"
    [ "$(sql "SELECT count(*) FROM seguimiento_oferta;")" = "$antes" ] && OK "y no quedo nada en PostgreSQL (ROLLBACK)" || FALLA "quedo un seguimiento sin su consulta"
    llamar PATCH "/vendedor/ofertas/$OF" "$VEND" '{"ajuste_stock":2}' >/dev/null
    sleep 8
    [ "$(sql "SELECT count(*) FROM evento_oferta WHERE id_oferta=$OF AND procesado_en IS NULL;")" = "1" ] \
        && OK "el cambio de stock espera en la cola" || FALLA "la cola no tiene la oferta $OF pendiente"
    docker start "$ELASTIC" >/dev/null 2>&1
    for _ in $(seq 1 120); do curl -s -m 3 "$ES" >/dev/null 2>&1 && break; sleep 1; done
    esperar_doc "$OF" stock 90 10 && OK "Elasticsearch volvio y el documento se puso al dia solo (stock 10)" || FALLA "stock = $(doc "$OF" stock) tras volver"
    [ "$(sql "SELECT count(*) FROM evento_oferta WHERE id_oferta=$OF AND procesado_en IS NULL;")" = "0" ] && OK "y la cola se vacio sin reiniciar el backend" || FALLA "la oferta sigue en la cola"
    c=$(codigo POST "/comprador/seguimientos" "$COMP" '{"tipo":"busqueda","texto":"algo que no llega"}')
    [ "$c" = "201" ] && OK "crear un aviso vuelve a funcionar (201)" || FALLA "crear un aviso sigue fallando ($c)"
    codigo DELETE "/comprador/seguimientos/$(sql "SELECT max(s.id_seguimiento) FROM seguimiento_oferta s JOIN usuarios u USING (id_usuario) WHERE u.correo_electronico='${PREF}c@mesh.com';")" "$COMP" >/dev/null
fi


titulo "LIMPIEZA"
llamar PATCH "/vendedor/ofertas/$OF" "$VEND" '{"estado":"retirada"}' >/dev/null
esperar_doc "$OF" estado 30 retirada && OK "la oferta de prueba quedo retirada, tambien en el indice" || FALLA "estado = $(doc "$OF" estado)"


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
[ "$fallo" -gt 0 ] && exit 1
echo "  El buscador de ofertas sigue a PostgreSQL por su cola y los avisos se disparan una vez, con o sin caidas."
exit 0
