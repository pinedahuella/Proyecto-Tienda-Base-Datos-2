#!/usr/bin/env bash
# pruebas/acl_ofertas.sh -- el ACL de la aplicacion, por oferta (migracion 049).
#
#   bash pruebas/acl_ofertas.sh
#
# Todo pasa por el backend (cuentas, permisos, ver, editar, descuento);
# PostgreSQL solo se MIRA. La duena es ventas.norte, la que recibe los
# permisos es ventas.sur y ventas.oriente es una tercera sin nada.
#
# QUE COMPRUEBA
# ============================================================
#   1. Negar por defecto: sin entrada, ver, editar y descuento dan 404, la
#      oferta no sale en la lista y el intento queda en el registro.
#   2. Repartir: correo que no existe, a si misma, permiso desconocido, lista
#      vacia, vencimiento pasado, a un comprador, oferta ajena, quien no es
#      dueno, sin sesion y un comprador en la ruta: todos rechazados.
#   3. Con ver: se ve, pero editar y descuento siguen en 404 (cada permiso se
#      revisa por separado) y el motivo queda anotado.
#   4. Con editar: el precio y la existencia cambian de verdad, el estado no se
#      puede tocar por aqui, y el registro dice quien lo hizo y a nombre de quien.
#   5. Con descuento: se pone y se quita.
#   6. La tercera cuenta sigue sin ver nada.
#   7. Quitar un permiso lo quita al instante.
#   8. Un permiso con vencimiento deja de valer solo.
#   9. Un admin sin entrada tampoco pasa; reparte por la tienda y no por otros.
#  10. Las rutas de lo propio no cambian: un permiso compartido no abre
#      /vendedor/ofertas.
#  11. La duena ve las entradas y el registro.
#  12. Limpieza: sin permisos de la prueba, la oferta con su precio, su
#      descuento y su existencia de antes.
#
# Deja: una cuenta compradora aclcomprador@mesh.com (se reusa) y las filas del
# registro (auditoria_permiso_oferta), que son historia a proposito.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
PG="${PG:-mesh-postgres}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"

if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi

export MSYS_NO_PATHCONV=1
export PYTHONUTF8=1

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

sql() { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" 2>/dev/null | tr -d '\r'; }
campo() { python -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
for k in sys.argv[1].split('.'):
    if d is None: break
    if isinstance(d,list):
        try: d=d[int(k)]
        except Exception: d=None
    else: d = d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" "$1"; }
entrar() {
    curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
        -d "{\"identificador\":\"$1\",\"contrasena\":\"$2\"}" \
      | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1
}
# codigo METODO RUTA COOKIE [CUERPO] -> solo el codigo HTTP
codigo() { curl -s -o /dev/null -w '%{http_code}' -X "$1" "$API$2" -H "Content-Type: application/json" -H "Cookie: $3" -d "${4:-{\}}"; }
# llamar METODO RUTA COOKIE [CUERPO] -> el cuerpo
llamar() { curl -s -X "$1" "$API$2" -H "Content-Type: application/json" -H "Cookie: $3" -d "${4:-{\}}"; }
esperar() { [ "$1" = "$2" ] && OK "$3 ($1)" || FALLA "$3: dio $1, se esperaba $2"; }

# Cuantas filas del registro de esta oferta, accion y actor desde el inicio.
registro() { sql "SELECT count(*) FROM auditoria_permiso_oferta WHERE id_oferta=$OF AND accion='$1' AND id_usuario_actor=$2 AND id_auditoria_permiso_oferta > $INICIO_REG;"; }
# Los permisos de la oferta para una cuenta, como texto ordenado.
entradas() { sql "SELECT coalesce(string_agg(t.tipo_permiso_oferta_nombre, ',' ORDER BY t.id_tipo_permiso_oferta), '') FROM permiso_oferta p JOIN tipo_permiso_oferta t USING (id_tipo_permiso_oferta) WHERE p.id_oferta=$OF AND p.id_usuario=$1;"; }
# El id de una entrada (oferta, cuenta, permiso) para quitarla.
id_entrada() { sql "SELECT p.id_permiso_oferta FROM permiso_oferta p JOIN tipo_permiso_oferta t USING (id_tipo_permiso_oferta) WHERE p.id_oferta=$OF AND p.id_usuario=$1 AND t.tipo_permiso_oferta_nombre='$2';"; }
otorgar() { llamar POST "/vendedor/ofertas/$OF/permisos" "$NORTE" "$1"; }
en_lista() { llamar GET "/compartidas/ofertas" "$1" | python -c "
import sys,json
d=json.load(sys.stdin).get('payload') or []
print('si' if any(x['id_oferta']=='$OF' for x in d) else 'no')"; }


titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend responde" || { echo "  El backend no responde en $API."; exit 1; }
[ "$(sql "SELECT to_regclass('public.permiso_oferta') IS NOT NULL AND to_regclass('public.auditoria_permiso_oferta') IS NOT NULL;")" = "t" ] \
    && OK "la migracion 049 esta (permiso_oferta y auditoria_permiso_oferta)" || { echo "  Falta la 049. Corre .\\arrancar.ps1"; exit 1; }
[ "$(sql "SELECT string_agg(tipo_permiso_oferta_nombre, ',' ORDER BY id_tipo_permiso_oferta) FROM tipo_permiso_oferta;")" = "ver,editar,descuento" ] \
    && OK "el catalogo tiene ver, editar y descuento" || FALLA "el catalogo de permisos no es el esperado"

NORTE=$(entrar "ventas.norte@mesh.com" "Vendedor123")
SUR=$(entrar "ventas.sur@mesh.com" "Vendedor123")
ORIENTE=$(entrar "ventas.oriente@mesh.com" "Vendedor123")
ADMIN=$(entrar "admin@mesh.com" "Admin123")
curl -s -o /dev/null -X POST "$API/usuario/registro" -H "Content-Type: application/json" \
    -d '{"correo_electronico":"aclcomprador@mesh.com","usuario":"aclcomprador","nombre":"Acl","apellido":"Comprador","contrasena":"Comprador123!"}'
COMPRADOR=$(entrar "aclcomprador@mesh.com" "Comprador123!")
[ -n "$NORTE" ] && [ -n "$SUR" ] && [ -n "$ORIENTE" ] && [ -n "$ADMIN" ] && [ -n "$COMPRADOR" ] \
    && OK "sesiones de ventas.norte, ventas.sur, ventas.oriente, admin y un comprador" || { echo "  No se pudo entrar con las cuentas de prueba."; exit 1; }

ID_NORTE=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='ventas.norte@mesh.com';")
ID_SUR=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='ventas.sur@mesh.com';")
ID_ORIENTE=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='ventas.oriente@mesh.com';")
ID_ADMIN=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='admin@mesh.com';")

# Una oferta activa de ventas.norte, sin descuento, sin venta relampago y con
# existencia, de un producto que este en la copia del catalogo.
OF=$(sql "SELECT o.id_oferta FROM oferta o JOIN estado_oferta e USING (id_estado_oferta)
           JOIN producto_catalogo pc ON pc.id_producto_mongo = o.id_producto_mongo
          WHERE o.id_usuario=$ID_NORTE AND e.estado_oferta_nombre='activa'
            AND o.porcentaje_descuento IS NULL AND NOT o.es_inventario_limitado AND o.stock >= 5
            AND NOT EXISTS (SELECT 1 FROM permiso_oferta p WHERE p.id_oferta=o.id_oferta)
          ORDER BY o.id_oferta LIMIT 1;")
OF_AJENA=$(sql "SELECT o.id_oferta FROM oferta o WHERE o.id_usuario=$ID_SUR ORDER BY o.id_oferta LIMIT 1;")
OF_TIENDA=$(sql "SELECT o.id_oferta FROM oferta o JOIN usuarios u USING (id_usuario) WHERE u.correo_electronico='tienda@mesh.com' ORDER BY o.id_oferta LIMIT 1;")
[ -n "$OF" ] && [ -n "$OF_AJENA" ] && [ -n "$OF_TIENDA" ] \
    && OK "oferta $OF de ventas.norte, $OF_AJENA de ventas.sur y $OF_TIENDA de la tienda" || { echo "  No hay ofertas para probar."; exit 1; }
PRECIO0=$(sql "SELECT precio FROM oferta WHERE id_oferta=$OF;")
STOCK0=$(sql "SELECT stock FROM oferta WHERE id_oferta=$OF;")
INICIO_REG=$(sql "SELECT coalesce(max(id_auditoria_permiso_oferta), 0) FROM auditoria_permiso_oferta;")
echo "  precio de antes Q$PRECIO0, existencia $STOCK0"


titulo "1. Negar por defecto"
esperar "$(codigo GET "/compartidas/ofertas/$OF" "$SUR")" 404 "ventas.sur sin entrada no ve la oferta"
esperar "$(codigo PATCH "/compartidas/ofertas/$OF" "$SUR" '{"precio":"1.00"}')" 404 "ni la edita"
esperar "$(codigo POST "/compartidas/ofertas/$OF/descuento" "$SUR" '{"porcentaje_descuento":50}')" 404 "ni le pone descuento"
esperar "$(codigo DELETE "/compartidas/ofertas/$OF/descuento" "$SUR")" 404 "ni se lo quita"
esperar "$(en_lista "$SUR")" no "la oferta no sale en su lista de compartidas"
esperar "$(sql "SELECT precio FROM oferta WHERE id_oferta=$OF;")" "$PRECIO0" "el precio sigue igual"
esperar "$(registro negado "$ID_SUR")" 4 "los cuatro intentos quedaron en el registro como negado"
esperar "$(codigo GET "/compartidas/ofertas/999999999" "$SUR")" 404 "una oferta que no existe da el mismo 404"
esperar "$(codigo GET "/compartidas/ofertas/abc" "$SUR")" 400 "un id que no es numero, 400"
esperar "$(codigo GET "/compartidas/ofertas" "")" 401 "sin sesion, 401"
esperar "$(codigo GET "/compartidas/ofertas" "$COMPRADOR")" 403 "un comprador no entra a la ruta (rol), 403"


titulo "2. Repartir, lo que se rechaza"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" '{"correo":"nadie.existe.acl@mesh.com","permisos":["ver"]}')" 400 "un correo que no existe"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" '{"correo":"ventas.norte@mesh.com","permisos":["ver"]}')" 400 "a si misma"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" '{"correo":"ventas.sur@mesh.com","permisos":["borrar"]}')" 400 "un permiso desconocido"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" '{"correo":"ventas.sur@mesh.com","permisos":[]}')" 400 "sin permisos"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" '{"correo":"ventas.sur@mesh.com","permisos":["ver"],"fecha_vencimiento":"2020-01-01T00:00:00Z"}')" 400 "con un vencimiento que ya paso"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" '{"correo":"aclcomprador@mesh.com","permisos":["ver"]}')" 400 "a una cuenta compradora"
esperar "$(codigo POST "/vendedor/ofertas/$OF_AJENA/permisos" "$NORTE" '{"correo":"ventas.oriente@mesh.com","permisos":["ver"]}')" 404 "sobre una oferta ajena, el 404 de siempre"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$SUR" '{"correo":"ventas.oriente@mesh.com","permisos":["ver"]}')" 404 "quien no es la duena no reparte"
esperar "$(codigo GET "/vendedor/ofertas/$OF/permisos" "$SUR")" 404 "ni ve las entradas"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "" '{"correo":"ventas.sur@mesh.com","permisos":["ver"]}')" 401 "sin sesion, 401"
esperar "$(codigo GET "/vendedor/ofertas/$OF/permisos" "$COMPRADOR")" 403 "un comprador no entra (rol), 403"
esperar "$(entradas "$ID_SUR")" "" "y no quedo ninguna entrada"


titulo "3. Con ver"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" '{"correo":"ventas.sur@mesh.com","permisos":["ver"]}')" 201 "ventas.norte le da ver a ventas.sur"
esperar "$(entradas "$ID_SUR")" ver "queda una entrada, ver"
r=$(llamar GET "/compartidas/ofertas/$OF" "$SUR")
esperar "$(echo "$r" | campo payload.id_oferta)" "$OF" "ventas.sur ve la oferta"
esperar "$(echo "$r" | campo payload.dueno.correo)" "ventas.norte@mesh.com" "y sabe de quien es"
esperar "$(echo "$r" | campo payload.permisos.0.permiso)" ver "y que solo puede ver"
esperar "$(en_lista "$SUR")" si "sale en su lista de compartidas"
esperar "$(codigo PATCH "/compartidas/ofertas/$OF" "$SUR" '{"precio":"1.00"}')" 404 "ver no deja editar"
esperar "$(codigo POST "/compartidas/ofertas/$OF/descuento" "$SUR" '{"porcentaje_descuento":50}')" 404 "ni poner descuento"
esperar "$(sql "SELECT detalle->>'motivo' FROM auditoria_permiso_oferta WHERE id_oferta=$OF AND accion='negado' AND id_usuario_actor=$ID_SUR ORDER BY id_auditoria_permiso_oferta DESC LIMIT 1;")" "tiene ver, no descuento" "el registro dice por que se nego"


titulo "4. Con editar"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" '{"correo":"ventas.sur@mesh.com","permisos":["editar"]}')" 201 "ventas.norte le suma editar"
esperar "$(entradas "$ID_SUR")" "ver,editar" "quedan ver y editar"
NUEVO=$(python -c "print(f'{float(\"$PRECIO0\") + 7:.2f}')")
r=$(llamar PATCH "/compartidas/ofertas/$OF" "$SUR" "{\"precio\":\"$NUEVO\"}")
esperar "$(echo "$r" | campo ok)" True "ventas.sur cambia el precio a Q$NUEVO"
esperar "$(sql "SELECT precio FROM oferta WHERE id_oferta=$OF;")" "$NUEVO" "el precio cambio en PostgreSQL"
esperar "$(sql "SELECT precio FROM precio_historial WHERE id_oferta=$OF ORDER BY id_precio_historial DESC LIMIT 1;")" "$NUEVO" "y el historial de precios lo anoto (el trigger de siempre)"
esperar "$(llamar PATCH "/compartidas/ofertas/$OF" "$SUR" '{"ajuste_stock":2}' | campo payload.stock)" "$((STOCK0 + 2))" "ajusta la existencia, +2"
esperar "$(llamar PATCH "/compartidas/ofertas/$OF" "$SUR" '{"ajuste_stock":-2}' | campo payload.stock)" "$STOCK0" "y la devuelve, -2"
esperar "$(codigo PATCH "/compartidas/ofertas/$OF" "$SUR" '{"estado":"inactiva"}')" 400 "el estado no se toca por aqui"
esperar "$(codigo PATCH "/compartidas/ofertas/$OF" "$SUR" '{"precio":"-5"}')" 400 "un precio invalido lo rechaza la misma validacion de siempre"
esperar "$(registro editar "$ID_SUR")" 3 "tres ediciones en el registro, con ventas.sur como quien lo hizo"
esperar "$(sql "SELECT id_usuario_dueno FROM auditoria_permiso_oferta WHERE id_oferta=$OF AND accion='editar' ORDER BY id_auditoria_permiso_oferta DESC LIMIT 1;")" "$ID_NORTE" "y a nombre de ventas.norte"
esperar "$(sql "SELECT detalle->>'precio' FROM auditoria_permiso_oferta WHERE id_oferta=$OF AND accion='editar' AND detalle ? 'precio' ORDER BY id_auditoria_permiso_oferta DESC LIMIT 1;")" "$NUEVO" "con el precio que puso"
esperar "$(codigo POST "/compartidas/ofertas/$OF/descuento" "$SUR" '{"porcentaje_descuento":10}')" 404 "editar no deja poner descuento"


titulo "5. Con descuento"
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" '{"correo":"ventas.sur@mesh.com","permisos":["descuento"]}')" 201 "ventas.norte le suma descuento"
esperar "$(llamar POST "/compartidas/ofertas/$OF/descuento" "$SUR" '{"porcentaje_descuento":10}' | campo payload.porcentaje_descuento)" 10.00 "ventas.sur pone 10 por ciento"
esperar "$(sql "SELECT porcentaje_descuento FROM oferta WHERE id_oferta=$OF;")" 10.00 "y queda en PostgreSQL"
esperar "$(codigo POST "/compartidas/ofertas/$OF/descuento" "$SUR" '{"porcentaje_descuento":95}')" 400 "un porcentaje fuera de rango lo rechaza la validacion de siempre"
esperar "$(codigo DELETE "/compartidas/ofertas/$OF/descuento" "$SUR")" 200 "lo quita"
esperar "$(sql "SELECT coalesce(porcentaje_descuento::text, 'sin') FROM oferta WHERE id_oferta=$OF;")" sin "y la oferta queda sin descuento"
esperar "$(registro poner_descuento "$ID_SUR"):$(registro quitar_descuento "$ID_SUR")" "1:1" "poner y quitar quedaron en el registro"


titulo "6. La tercera cuenta"
esperar "$(codigo GET "/compartidas/ofertas/$OF" "$ORIENTE")" 404 "ventas.oriente no ve la oferta"
esperar "$(codigo PATCH "/compartidas/ofertas/$OF" "$ORIENTE" '{"precio":"1.00"}')" 404 "ni la edita"
esperar "$(en_lista "$ORIENTE")" no "ni le sale en la lista"


titulo "7. Quitar un permiso"
ID_EDITAR=$(id_entrada "$ID_SUR" editar)
r=$(llamar DELETE "/vendedor/ofertas/$OF/permisos/$ID_EDITAR" "$NORTE")
esperar "$(echo "$r" | campo ok)" True "ventas.norte le quita editar"
esperar "$(entradas "$ID_SUR")" "ver,descuento" "quedan ver y descuento"
esperar "$(codigo PATCH "/compartidas/ofertas/$OF" "$SUR" '{"precio":"1.00"}')" 404 "editar ya no pasa, al instante"
esperar "$(codigo GET "/compartidas/ofertas/$OF" "$SUR")" 200 "ver sigue"
esperar "$(codigo DELETE "/vendedor/ofertas/$OF/permisos/$ID_EDITAR" "$NORTE")" 404 "quitar otra vez la misma, 404"
esperar "$(codigo DELETE "/vendedor/ofertas/$OF/permisos/$(id_entrada "$ID_SUR" ver)" "$SUR")" 404 "ventas.sur no puede quitarse ni quitar nada"


titulo "8. Vencimiento"
VENCE=$(python -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=6)).isoformat())")
esperar "$(codigo POST "/vendedor/ofertas/$OF/permisos" "$NORTE" "{\"correo\":\"ventas.sur@mesh.com\",\"permisos\":[\"editar\"],\"fecha_vencimiento\":\"$VENCE\"}")" 201 "editar por 6 segundos"
esperar "$(codigo PATCH "/compartidas/ofertas/$OF" "$SUR" "{\"precio\":\"$PRECIO0\"}")" 200 "mientras vale, edita (devuelve el precio de antes)"
sleep 7
esperar "$(codigo PATCH "/compartidas/ofertas/$OF" "$SUR" '{"precio":"1.00"}')" 404 "vencido, ya no edita, sin que nadie lo borre"
esperar "$(llamar GET "/vendedor/ofertas/$OF/permisos" "$NORTE" | python -c "
import sys,json
d=json.load(sys.stdin)['payload']['permisos']
e=[x for x in d if x['permiso']=='editar' and x['receptor']['correo']=='ventas.sur@mesh.com']
print('vencida' if e and e[0]['vigente'] is False else 'mal')")" vencida "la duena la ve como no vigente"
esperar "$(sql "SELECT precio FROM oferta WHERE id_oferta=$OF;")" "$PRECIO0" "el precio quedo el de antes"


titulo "9. Un admin"
esperar "$(codigo GET "/compartidas/ofertas/$OF" "$ADMIN")" 404 "sin entrada, un admin tampoco ve por la via compartida"
esperar "$(codigo GET "/vendedor/ofertas/$OF_TIENDA/permisos" "$ADMIN")" 200 "reparte los de la tienda"
esperar "$(codigo GET "/vendedor/ofertas/$OF/permisos" "$ADMIN")" 404 "no los de ventas.norte"
esperar "$(registro negado "$ID_ADMIN")" 1 "su intento tambien quedo en el registro"


titulo "10. Lo propio no cambia"
esperar "$(codigo PATCH "/vendedor/ofertas/$OF" "$SUR" '{"precio":"1.00"}')" 404 "con descuento compartido, /vendedor/ofertas/$OF sigue en 404 para ventas.sur"
esperar "$(codigo POST "/vendedor/ofertas/$OF/descuento" "$SUR" '{"porcentaje_descuento":10}')" 404 "su descuento por la ruta propia tambien"
esperar "$(sql "SELECT precio FROM oferta WHERE id_oferta=$OF;")" "$PRECIO0" "el precio no se movio"
r=$(llamar GET "/vendedor/ofertas/producto/$(sql "SELECT id_producto_mongo FROM oferta WHERE id_oferta=$OF;")" "$NORTE")
esperar "$(echo "$r" | campo ok)" True "ventas.norte sigue usando su ruta de siempre"


titulo "11. Lo que ve la duena"
r=$(llamar GET "/vendedor/ofertas/$OF/permisos" "$NORTE")
esperar "$(echo "$r" | python -c "
import sys,json
d=json.load(sys.stdin)['payload']
v=sorted(x['permiso'] for x in d['permisos'] if x['vigente'])
print(','.join(v))")" "descuento,ver" "las entradas vigentes de ventas.sur, ver y descuento"
esperar "$(echo "$r" | python -c "
import sys,json
d=json.load(sys.stdin)['payload']['registro']
acc=set(x['accion'] for x in d)
print('si' if {'otorgar','revocar','editar','poner_descuento','quitar_descuento','negado'} <= acc and any(x['actor']=='ventas_sur' for x in d) else 'no')")" si "el registro trae otorgar, revocar, editar, descuento y negado, con ventas.sur como actor"


titulo "12. Limpieza"
# Si algo de arriba fallo a medias, la duena devuelve la oferta por su ruta.
[ "$(sql "SELECT porcentaje_descuento IS NOT NULL FROM oferta WHERE id_oferta=$OF;")" = "t" ]     && llamar DELETE "/vendedor/ofertas/$OF/descuento" "$NORTE" >/dev/null
[ "$(sql "SELECT precio FROM oferta WHERE id_oferta=$OF;")" != "$PRECIO0" ]     && llamar PATCH "/vendedor/ofertas/$OF" "$NORTE" "{\"precio\":\"$PRECIO0\"}" >/dev/null
dif=$(( STOCK0 - $(sql "SELECT stock FROM oferta WHERE id_oferta=$OF;") ))
[ "$dif" -ne 0 ] && llamar PATCH "/vendedor/ofertas/$OF" "$NORTE" "{\"ajuste_stock\":$dif}" >/dev/null
for id in $(sql "SELECT id_permiso_oferta FROM permiso_oferta WHERE id_oferta=$OF;"); do
    llamar DELETE "/vendedor/ofertas/$OF/permisos/$id" "$NORTE" >/dev/null
done
esperar "$(sql "SELECT count(*) FROM permiso_oferta WHERE id_oferta=$OF;")" 0 "sin permisos sobre la oferta $OF"
esperar "$(codigo GET "/compartidas/ofertas/$OF" "$SUR")" 404 "ventas.sur ya no la ve"
esperar "$(sql "SELECT precio || ' ' || coalesce(porcentaje_descuento::text, 'sin') || ' ' || stock FROM oferta WHERE id_oferta=$OF;")" "$PRECIO0 sin $STOCK0" "la oferta como estaba: precio, descuento y existencia"


echo
echo "=============================================================="
echo "  $ok OK, $fallo FALLA"
echo "=============================================================="
[ "$fallo" -eq 0 ]
