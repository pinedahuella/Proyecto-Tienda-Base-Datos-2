#!/usr/bin/env bash
# pruebas/permisos_rol.sh -- el ACL de funcionalidades, por rol (migracion 050).
#
#   bash pruebas/permisos_rol.sh
#
# Todo por el backend, llamando a las rutas DIRECTO, como lo haria alguien con
# curl o Postman sin pasar por la pagina. PostgreSQL se mira, y en la parte 4 se
# cambia una fila a mano para ensenar que la tabla manda sin reiniciar nada.
#
# QUE COMPRUEBA
# ============================================================
#   1. Sin sesion, o con un token armado a mano, 401 en las rutas privadas.
#   2. La matriz entera: los 38 permisos para los tres roles (114 llamadas). Cada
#      permiso con una ruta que lo pide; si el rol lo tiene en rol_permiso el
#      guard deja pasar (lo que conteste despues no es 403), si no, 403. Las
#      llamadas que pasan no cambian nada: ids que no existen, cuerpos vacios o
#      un carrito vacio.
#   3. Quitar y devolver por la API del admin: el vendedor pierde
#      ofertas.publicar, publicar da 403 con el codigo que falta, el intento
#      queda en auditoria_permiso con su ruta, y al devolverlo vuelve a pasar.
#   4. Con SQL a mano, como en la demo: borrar la fila de carrito.usar del
#      comprador lo deja sin carrito en la peticion siguiente, y volverla a
#      poner se lo devuelve. Sin reiniciar el backend.
#   5. Tambien el admin: sin tendencias.ver, 403.
#   6. La API del admin: protegidos (409), lo que no tiene (404), lo que ya
#      tiene (no cambia), ids malos (400) y que no existen (404).
#   7. La API se protege con su propio ACL: un comprador y un vendedor no la
#      ven ni la cambian.
#   8. GET /usuario/yo trae los permisos del rol, los mismos de la tabla.
#   9. Un cambio de rol vale en la peticion siguiente: el admin le baja el rol
#      al vendedor por la API y su MISMA sesion, con el token de antes, ya da
#      403 en lo de vendedor y /usuario/yo trae los permisos del comprador. Al
#      devolverle el rol, vuelve a pasar. El rol que cuenta es el de la base.
#  10. Limpieza: la matriz queda exactamente como estaba al empezar. Si la
#      prueba se corta a la mitad, la trampa de salida la devuelve igual, y el
#      vendedor de la prueba vuelve a ser vendedor.
#
# Deja: las cuentas permcomprador@mesh.com y permvendedor@mesh.com (se reusan)
# y las filas de auditoria_permiso, que son historia a proposito.

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

# </dev/null: con -i, docker exec se come la entrada estandar, y dentro del
# while read de la parte 2 se tragaba el resto de la lista. En local solo se
# probaba el primer permiso de 38; en modo remoto no pasaba (2026-11-02).
sql() { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" </dev/null 2>/dev/null | tr -d '\r'; }
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
# El guard dejo pasar: lo que contesto el servicio despues no es 401, 403 ni 5xx.
paso() { [ "$1" != "401" ] && [ "$1" != "403" ] && [ "$1" -lt 500 ]; }

# La matriz como texto (rol:id_permiso,...), para dejarla igual al final.
matriz() { sql "SELECT coalesce(string_agg(id_rol_usuario || ':' || id_permiso, ',' ORDER BY id_rol_usuario, id_permiso), '') FROM rol_permiso;"; }
id_permiso() { sql "SELECT p.id_permiso FROM permiso p JOIN modulo_permiso m USING (id_modulo_permiso) WHERE m.modulo_permiso_nombre || '.' || p.permiso_nombre = '$1';"; }
tiene() { sql "SELECT EXISTS (SELECT 1 FROM rol_permiso WHERE id_rol_usuario = $1 AND id_permiso = $(id_permiso "$2"));"; }
negados() { sql "SELECT count(*) FROM auditoria_permiso WHERE accion = 'negado' AND id_auditoria_permiso > $INICIO_REG AND id_permiso = $(id_permiso "$1") AND id_usuario_actor = $2 ${3:+AND ruta = '$3'};"; }


titulo "0. Todo arriba"
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$API/carrito")" = "401" ] \
    && OK "el backend responde" || { echo "  El backend no responde en $API."; exit 1; }
[ "$(sql "SELECT to_regclass('public.rol_permiso') IS NOT NULL AND to_regclass('public.auditoria_permiso') IS NOT NULL;")" = "t" ] \
    && OK "la migracion 050 esta (rol_permiso y auditoria_permiso)" || { echo "  Falta la 050. Corre .\\arrancar.ps1"; exit 1; }

ADMIN=$(entrar "admin@mesh.com" "Admin123")
[ -n "$ADMIN" ] || { echo "  No se pudo entrar como admin."; exit 1; }
for c in permcomprador permvendedor; do
    curl -s -o /dev/null -X POST "$API/usuario/registro" -H "Content-Type: application/json" \
        -d "{\"correo_electronico\":\"$c@mesh.com\",\"usuario\":\"$c\",\"nombre\":\"Permisos\",\"apellido\":\"Prueba\",\"contrasena\":\"Comprador123!\"}"
done
ID_ADMIN=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='admin@mesh.com';")
ID_COMPRADOR=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='permcomprador@mesh.com';")
ID_VENDEDOR=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico='permvendedor@mesh.com';")
[ -n "$ID_COMPRADOR" ] && [ -n "$ID_VENDEDOR" ] || { echo "  No se pudieron crear las cuentas de prueba."; exit 1; }
# El vendedor de la prueba nace comprador; el admin le cambia el rol por la API.
if [ "$(sql "SELECT id_rol_usuario FROM usuarios WHERE id_usuario=$ID_VENDEDOR;")" != "2" ]; then
    codigo PATCH "/admin/usuarios/$ID_VENDEDOR" "$ADMIN" '{"id_rol_usuario":2}' >/dev/null
fi
COMPRADOR=$(entrar "permcomprador@mesh.com" "Comprador123!")
VENDEDOR=$(entrar "permvendedor@mesh.com" "Comprador123!")
[ -n "$COMPRADOR" ] && [ -n "$VENDEDOR" ] \
    && [ "$(sql "SELECT string_agg(id_rol_usuario::text, ',' ORDER BY id_usuario) FROM usuarios WHERE id_usuario IN ($ID_COMPRADOR, $ID_VENDEDOR);")" = "1,2" ] \
    && OK "sesiones de un comprador, un vendedor y el admin, con su rol" || { echo "  Las cuentas de prueba no tienen el rol esperado."; exit 1; }

MATRIZ0=$(matriz)
INICIO_REG=$(sql "SELECT coalesce(max(id_auditoria_permiso), 0) FROM auditoria_permiso;")
echo "  matriz al empezar: $(echo "$MATRIZ0" | tr ',' '\n' | grep -c .) entradas"
# Pase lo que pase, la matriz vuelve a como estaba.
devolver_matriz() {
    # Si se corta en la parte 9, el vendedor de la prueba vuelve a ser vendedor.
    sql "UPDATE usuarios SET id_rol_usuario = 2 WHERE id_usuario = $ID_VENDEDOR AND id_rol_usuario <> 2;" >/dev/null
    sql "DELETE FROM rol_permiso WHERE (id_rol_usuario || ':' || id_permiso) <> ALL (string_to_array('$MATRIZ0', ','));" >/dev/null
    sql "INSERT INTO rol_permiso (id_rol_usuario, id_permiso)
         SELECT split_part(x, ':', 1)::smallint, split_part(x, ':', 2)::smallint
           FROM unnest(string_to_array('$MATRIZ0', ',')) x
         ON CONFLICT DO NOTHING;" >/dev/null
}
trap devolver_matriz EXIT

# Los carritos de las cuentas de prueba, vacios: pagar uno vacio da 409 y no cobra.
codigo DELETE "/carrito" "$COMPRADOR" >/dev/null
codigo DELETE "/carrito" "$VENDEDOR" >/dev/null
ADMIN_CARRITO=$(llamar GET "/carrito" "$ADMIN" | python -c "
import sys,json
d=json.load(sys.stdin).get('payload') or {}
print(len(d.get('lineas') or []))" 2>/dev/null)


titulo "1. Sin sesion o con un token armado a mano"
FALSO="mesh_token=eyJhbGciOiJIUzI1NiJ9.eyJpZF91c3VhcmlvIjoiMSIsImlkX3JvbF91c3VhcmlvIjozfQ.firmafalsa"
for r in "GET /carrito" "GET /admin/permisos" "POST /vendedor/ofertas" "GET /admin/usuarios"; do
    set -- $r
    esperar "$(codigo "$1" "$2" "")" 401 "sin sesion, $1 $2"
    esperar "$(codigo "$1" "$2" "$FALSO")" 401 "token que dice ser admin, $1 $2"
done


titulo "2. La matriz entera, permiso por permiso, para los tres roles"
# codigo|metodo|ruta|cuerpo -- una ruta que pide ese permiso y que, si pasa, no cambia nada.
PRUEBAS="
cuenta.ver|GET|/usuario/yo|
cuenta.editar|PATCH|/perfil/alertas-fraude/x|
direcciones.administrar|GET|/direccion-usuario|
carrito.usar|GET|/carrito|
carrito.comprar|POST|/carrito/comprar|
pedidos.ver|GET|/comprador/pedidos|
pedidos.cancelar|POST|/comprador/pedidos/x/cancelar|
avisos.usar|GET|/comprador/seguimientos|
resenas.escribir|GET|/productos/1/resenado|
resenas.votar|PUT|/comentarios/x/voto|
productos.historial|GET|/productos/ofertas/x/historial|
productos.para_ti|GET|/productos/para-ti|
ofertas.ver|GET|/vendedor/ofertas/x/rechazos|
ofertas.publicar|POST|/vendedor/ofertas|
ofertas.editar|PATCH|/vendedor/ofertas/x|
ofertas.descuento|POST|/vendedor/ofertas/x/descuento|
ofertas.venta_relampago|POST|/vendedor/ofertas/x/venta-limitada|
ofertas.revisar|PATCH|/vendedor/ofertas/x/revision|
ofertas.compartir|GET|/vendedor/ofertas/x/permisos|
ofertas.usar_compartidas|GET|/compartidas/ofertas|
catalogo.ver|GET|/vendedor/categorias|
catalogo.proponer|GET|/vendedor/productos/propuestas/x/rechazos|
catalogo.editar|PATCH|/vendedor/productos/x|
catalogo.revisar|PATCH|/vendedor/productos/x/revision|
catalogo.buscar_todo|GET|/buscador/productos/admin?nombre=zzzzqqq|
reglas.ver|GET|/vendedor/reglas-descuento|
reglas.administrar|DELETE|/vendedor/reglas-descuento/x|
dashboard.ver|GET|/admin/dashboard/resumen|
dashboard.exportar|POST|/admin/dashboard/exportar/correo|{\"correos\":[\"no-es-un-correo\"]}
tendencias.ver|GET|/admin/eventos/vista|
fraude.ver|GET|/admin/fraude/casos/x|
fraude.resolver|PATCH|/admin/fraude/casos/x|
usuarios.ver|GET|/admin/roles|
usuarios.editar|PATCH|/admin/usuarios/x|
reportes.ver|GET|/admin/reportes/ventas|
sistema.ver|GET|/db/cortacircuitos|
permisos.ver|GET|/admin/permisos|
permisos.administrar|POST|/admin/permisos/x/1|
"
probados=""
while IFS='|' read -r cod met ruta cuerpo; do
    [ -z "$cod" ] && continue
    probados="$probados $cod"
    for par in "1:$COMPRADOR:comprador" "2:$VENDEDOR:vendedor" "3:$ADMIN:admin"; do
        rol=${par%%:*}; resto=${par#*:}; cookie=${resto%:*}; nombre=${resto##*:}
        if [ "$cod" = "carrito.comprar" ] && [ "$rol" = "3" ] && [ "${ADMIN_CARRITO:-0}" != "0" ]; then
            echo "  SIN MEDIR $cod para admin: su carrito tiene lineas y pagar las compraria"
            continue
        fi
        c=$(codigo "$met" "$ruta" "$cookie" "${cuerpo:-{\}}")
        if [ "$(tiene "$rol" "$cod")" = "t" ]; then
            paso "$c" && OK "$nombre con $cod pasa ($met $ruta da $c)" || FALLA "$nombre con $cod deberia pasar: $met $ruta dio $c"
        else
            esperar "$c" 403 "$nombre sin $cod, $met $ruta"
        fi
    done
done <<< "$PRUEBAS"
faltan=$(sql "SELECT string_agg(m.modulo_permiso_nombre || '.' || p.permiso_nombre, ' ') FROM permiso p JOIN modulo_permiso m USING (id_modulo_permiso);" | tr ' ' '\n' | while read -r x; do echo "$probados" | grep -qw -- "$x" || echo "$x"; done)
[ -z "$faltan" ] && OK "se probaron los 38 permisos de la base" || FALLA "permisos sin probar: $faltan"


titulo "3. Quitar y devolver por la API: el vendedor y ofertas.publicar"
ROL_V=2; P_PUB=$(id_permiso ofertas.publicar)
r=$(llamar DELETE "/admin/permisos/$ROL_V/$P_PUB" "$ADMIN")
esperar "$(echo "$r" | campo ok)" "True" "el admin le quita ofertas.publicar al vendedor"
esperar "$(tiene $ROL_V ofertas.publicar)" "f" "la fila ya no esta en rol_permiso"
N0=$(negados ofertas.publicar "$ID_VENDEDOR" /vendedor/ofertas)
r=$(curl -s -w '\n%{http_code}' -X POST "$API/vendedor/ofertas" -H "Content-Type: application/json" -H "Cookie: $VENDEDOR" -d '{}')
esperar "$(echo "$r" | tail -1)" 403 "el vendedor llama directo a POST /vendedor/ofertas"
echo "$r" | head -1 | campo mensaje | grep -q "ofertas.publicar" \
    && OK "el mensaje dice que falta: $(echo "$r" | head -1 | campo mensaje)" || FALLA "el mensaje no nombra el permiso: $(echo "$r" | head -1)"
esperar "$(( $(negados ofertas.publicar "$ID_VENDEDOR" /vendedor/ofertas) - N0 ))" 1 "el intento quedo en auditoria_permiso con su ruta"
paso "$(codigo GET /vendedor/ofertas "$VENDEDOR")" && OK "ver sus ofertas le sigue (otro permiso)" || FALLA "ver sus ofertas tambien se cerro"
reg=$(llamar GET "/admin/permisos/registro?limite=5" "$ADMIN")
echo "$reg" | python -c "
import sys,json
d=json.load(sys.stdin)['payload']
print('si' if any(x['accion']=='negado' and x['codigo']=='ofertas.publicar' and x['ruta']=='/vendedor/ofertas' for x in d) else 'no')" | grep -q si \
    && OK "el registro del admin lo ensena" || FALLA "el registro del admin no lo ensena"
esperar "$(codigo POST "/admin/permisos/$ROL_V/$P_PUB" "$ADMIN")" 201 "el admin se lo devuelve"
paso "$(codigo POST /vendedor/ofertas "$VENDEDOR")" && OK "el vendedor vuelve a pasar el guard" || FALLA "el vendedor sigue sin pasar"
esperar "$(sql "SELECT string_agg(accion, ',' ORDER BY id_auditoria_permiso) FROM auditoria_permiso WHERE id_auditoria_permiso > $INICIO_REG AND id_permiso = $P_PUB AND accion <> 'negado';")" "revocar,otorgar" "el registro tiene revocar y otorgar, en ese orden"
esperar "$(sql "SELECT id_usuario_actor FROM auditoria_permiso WHERE id_auditoria_permiso > $INICIO_REG AND id_permiso = $P_PUB AND accion = 'otorgar';")" "$ID_ADMIN" "y quien lo hizo es el admin"


titulo "4. Con SQL a mano: el comprador y carrito.usar, sin reiniciar nada"
P_CAR=$(id_permiso carrito.usar)
esperar "$(codigo GET /carrito "$COMPRADOR")" 200 "antes, el comprador ve su carrito"
sql "DELETE FROM rol_permiso WHERE id_rol_usuario = 1 AND id_permiso = $P_CAR;" >/dev/null
esperar "$(codigo GET /carrito "$COMPRADOR")" 403 "borrada la fila, la peticion siguiente ya da"
esperar "$(codigo GET /comprador/pedidos "$COMPRADOR")" 200 "sus pedidos le siguen (otro permiso)"
sql "INSERT INTO rol_permiso (id_rol_usuario, id_permiso) VALUES (1, $P_CAR);" >/dev/null
esperar "$(codigo GET /carrito "$COMPRADOR")" 200 "puesta otra vez, vuelve a ver su carrito"


titulo "5. Tambien el admin"
P_TEN=$(id_permiso tendencias.ver)
sql "DELETE FROM rol_permiso WHERE id_rol_usuario = 3 AND id_permiso = $P_TEN;" >/dev/null
esperar "$(codigo GET /admin/eventos/vista "$ADMIN")" 403 "el admin sin tendencias.ver no ve Tendencias"
sql "INSERT INTO rol_permiso (id_rol_usuario, id_permiso) VALUES (3, $P_TEN);" >/dev/null
esperar "$(codigo GET /admin/eventos/vista "$ADMIN")" 200 "con el permiso de vuelta, si"


titulo "6. La API del admin: protegidos, repetidos y errores"
P_ADM=$(id_permiso permisos.administrar); P_PVER=$(id_permiso permisos.ver); P_CTA=$(id_permiso cuenta.ver)
esperar "$(codigo DELETE "/admin/permisos/3/$P_ADM" "$ADMIN")" 409 "permisos.administrar no se le quita al admin"
esperar "$(codigo DELETE "/admin/permisos/3/$P_PVER" "$ADMIN")" 409 "permisos.ver tampoco"
esperar "$(codigo DELETE "/admin/permisos/1/$P_CTA" "$ADMIN")" 409 "cuenta.ver no se le quita a nadie"
esperar "$(codigo DELETE "/admin/permisos/1/$(id_permiso fraude.ver)" "$ADMIN")" 404 "quitar lo que no tiene da 404"
r=$(llamar POST "/admin/permisos/2/$P_PUB" "$ADMIN")
esperar "$(echo "$r" | campo payload.cambio)" "False" "dar lo que ya tiene no cambia nada"
esperar "$(codigo POST "/admin/permisos/x/$P_PUB" "$ADMIN")" 400 "un id de rol que no es numero"
esperar "$(codigo POST "/admin/permisos/99/$P_PUB" "$ADMIN")" 404 "un rol que no existe"
esperar "$(codigo POST "/admin/permisos/2/9999" "$ADMIN")" 404 "un permiso que no existe"
esperar "$(codigo GET "/admin/permisos/registro?limite=abc" "$ADMIN")" 400 "un limite que no es numero"
m=$(llamar GET /admin/permisos "$ADMIN")
esperar "$(echo "$m" | python -c "
import sys,json
d=json.load(sys.stdin)['payload']
print(len(d['roles']), sum(len(x['permisos']) for x in d['modulos']), len(d['modulos']))")" "3 38 17" "la matriz trae 3 roles, 38 permisos y 17 modulos"


titulo "7. La API se protege con su propio ACL"
esperar "$(codigo GET /admin/permisos "$COMPRADOR")" 403 "un comprador no ve la matriz"
esperar "$(codigo GET /admin/permisos "$VENDEDOR")" 403 "un vendedor tampoco"
N0=$(negados permisos.administrar "$ID_VENDEDOR")
esperar "$(codigo POST "/admin/permisos/2/$(id_permiso usuarios.editar)" "$VENDEDOR")" 403 "un vendedor no se puede dar permisos"
esperar "$(tiene 2 usuarios.editar)" "f" "y la tabla no cambio"
esperar "$(( $(negados permisos.administrar "$ID_VENDEDOR") - N0 ))" 1 "el intento quedo anotado"


titulo "8. GET /usuario/yo trae los permisos del rol"
for par in "1:$COMPRADOR:comprador" "2:$VENDEDOR:vendedor" "3:$ADMIN:admin"; do
    rol=${par%%:*}; resto=${par#*:}; cookie=${resto%:*}; nombre=${resto##*:}
    api=$(llamar GET /usuario/yo "$cookie" | python -c "import sys,json; print(','.join(sorted(json.load(sys.stdin)['payload']['permisos'])))")
    base=$(sql "SELECT string_agg(m.modulo_permiso_nombre || '.' || p.permiso_nombre, ',' ORDER BY 1) FROM rol_permiso rp JOIN permiso p USING (id_permiso) JOIN modulo_permiso m USING (id_modulo_permiso) WHERE rp.id_rol_usuario = $rol;" | python -c "import sys; print(','.join(sorted(sys.stdin.read().strip().split(','))))")
    esperar "$([ "$api" = "$base" ] && echo igual || echo distinto)" "igual" "$nombre: $(echo "$api" | tr ',' '\n' | grep -c .) permisos, los mismos de rol_permiso"
done


titulo "9. Un cambio de rol vale en la peticion siguiente, con la misma sesion"
# La sesion del vendedor se abrio con el rol 2 dentro del token. El admin le
# baja el rol a comprador por la API y la MISMA cookie ya pasa como comprador:
# el rol que cuenta es el de la base, no el del token (2026-11-02).
esperar "$(codigo PATCH "/admin/usuarios/$ID_VENDEDOR" "$ADMIN" '{"id_rol_usuario":1}')" 200 "el admin le baja el rol a comprador"
N0=$(negados ofertas.ver "$ID_VENDEDOR" /vendedor/ofertas)
esperar "$(codigo GET /vendedor/ofertas "$VENDEDOR")" 403 "con el token de antes ya no ve ofertas"
esperar "$(( $(negados ofertas.ver "$ID_VENDEDOR" /vendedor/ofertas) - N0 ))" 1 "el intento quedo anotado"
esperar "$(sql "SELECT id_rol_usuario FROM auditoria_permiso WHERE accion = 'negado' AND id_usuario_actor = $ID_VENDEDOR ORDER BY id_auditoria_permiso DESC LIMIT 1;")" 1 "y anotado con el rol de hoy, comprador"
yo=$(llamar GET /usuario/yo "$VENDEDOR")
esperar "$(echo "$yo" | campo payload.id_rol_usuario)" 1 "GET /usuario/yo dice rol comprador"
esperar "$(echo "$yo" | python -c "import sys,json; print(len(json.load(sys.stdin)['payload']['permisos']))")" "$(sql "SELECT count(*) FROM rol_permiso WHERE id_rol_usuario = 1;")" "y trae los permisos del comprador, no los del vendedor"
esperar "$(codigo GET /carrito "$VENDEDOR")" 200 "lo de comprador le sigue funcionando"
esperar "$(codigo PATCH "/admin/usuarios/$ID_VENDEDOR" "$ADMIN" '{"id_rol_usuario":2}')" 200 "el admin le devuelve el rol de vendedor"
paso "$(codigo GET /vendedor/ofertas "$VENDEDOR")" && OK "con la misma sesion vuelve a ver sus ofertas" || FALLA "sigue sin ver sus ofertas"


titulo "10. Limpieza"
trap - EXIT
devolver_matriz
esperar "$([ "$(matriz)" = "$MATRIZ0" ] && echo igual || echo distinta)" "igual" "la matriz queda exactamente como al empezar"

echo
echo "=============================================================="
echo "  $ok OK, $fallo FALLA"
echo "=============================================================="
[ "$fallo" -eq 0 ]
