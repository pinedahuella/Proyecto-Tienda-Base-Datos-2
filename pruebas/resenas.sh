#!/usr/bin/env bash
# pruebas/resenas.sh -- comprueba las 5 rutas de resenas y te dice que clicar.
#
#   bash pruebas/resenas.sh
#
# Hace DOS cosas, y la segunda es la que resuelve "no veo nada":
#
#   PARTE 1  prueba las 5 rutas contra el backend vivo y dice OK o FALLA.
#            Escribe una resena de prueba y LA BORRA al terminar.
#   PARTE 2  busca en la base que puedes resenar AHORA MISMO y con que cuenta,
#            y te imprime la direccion exacta que hay que abrir.
#
# La parte 2 existe porque la regla del backend es que solo puede resenar quien
# COMPRO y PAGO ese producto a ese vendedor. Con la semilla actual eso pasa en
# muy pocos casos, asi que el boton de "Escribir una resena" no aparece casi
# nunca -- y desde afuera se ve igual que si estuviera roto. Este script te dice
# en cual SI aparece.
#
# No instala nada: curl, docker y python, que ya estan.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-http://localhost:3000}"
WEB="${WEB:-http://localhost:5173}"
PG="${PG:-mesh-postgres}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"

# Git Bash convierte las rutas que empiezan con / al pasarlas a docker. Sin
# esto, cualquier "docker exec ... -f /algo" falla con una ruta de Windows.
export MSYS_NO_PATHCONV=1

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

sql() { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAc "$1" 2>/dev/null | tr -d '\r'; }

entrar() {
    curl -s -i -X POST "$API/usuario/login" -H "Content-Type: application/json" \
         -d "{\"identificador\":\"$1\",\"contrasena\":\"$2\"}" \
    | grep -i "^set-cookie" | sed 's/set-cookie: //i' | cut -d';' -f1
}

# El campo de un JSON, sin depender de jq.
campo() { python -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
for k in sys.argv[1].split('.'):
    if d is None: break
    d = d.get(k) if isinstance(d,dict) else None
print('' if d is None else d)" "$1"; }


titulo "0. Esta todo arriba?"

if ! docker ps --format '{{.Names}}' | grep -q "^$PG$"; then
    echo "  El contenedor $PG no esta corriendo. Corre .\\arrancar.ps1 primero."
    exit 1
fi
OK "PostgreSQL responde"

codigo=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "$API/productos?limite=1")
if [ "$codigo" != "200" ]; then
    echo "  FALLA el backend no contesta en $API (HTTP $codigo)"
    echo "        Levantalo con:  cd backend  &&  npm run start:dev"
    exit 1
fi
OK "el backend contesta en $API"

# Se mira el CODIGO HTTP y no el codigo de salida de curl, y eso no es un
# detalle: este aviso salia SIEMPRE, con el frontend sirviendo un 200 limpio.
#
# La causa es el `export MSYS_NO_PATHCONV=1` de mas arriba, que hace falta para
# los `docker exec` pero tambien deja de traducir `/dev/null` a `NUL`. curl no
# puede escribir el destino, sale con 23 (CURLE_WRITE_ERROR) y el `if !` lo lee
# como "no contesta" aunque la peticion haya ido perfecta. Comprobado:
#
#   curl -s -o /dev/null -m 8 "$WEB"                  -> 0
#   MSYS_NO_PATHCONV=1 curl -s -o /dev/null -m 8 ...  -> 23
#
# Los otros tres chequeos de este archivo ya leian `%{http_code}` y por eso
# nunca fallaron. Un aviso que sale en verde y en rojo no informa de nada.
codigo_web=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "$WEB")
if [ "$codigo_web" = "000" ]; then
    echo "  (aviso) el frontend no contesta en $WEB. La parte 1 igual corre."
    echo "          Para la parte 2:  cd frontend  &&  npm run dev"
fi


titulo "1. Las 5 rutas"

# Un par resenable de verdad, elegido por la MISMA regla que aplica el backend.
# Si se eligiera a mano, el dia que la semilla cambie esta prueba fallaria por
# el dato y no por el codigo.
PAR=$(sql "
SELECT pe.id_usuario||' '||pp.id_producto_mongo||' '||uv.correo_electronico
FROM pedido pe
JOIN pago pg ON pg.id_pedido=pe.id_pedido
JOIN estado_pago epa USING(id_estado_pago)
JOIN estado_pedido epe ON epe.id_estado_pedido=pe.id_estado_pedido
JOIN pedido_producto pp ON pp.id_pedido=pe.id_pedido
JOIN precio_historial ph ON ph.id_precio_historial=pp.id_precio_historial
JOIN oferta o ON o.id_oferta=ph.id_oferta
JOIN usuarios uv ON uv.id_usuario=o.id_usuario
JOIN usuarios u  ON u.id_usuario=pe.id_usuario
WHERE epa.estado_pago_nombre='pagado' AND epe.estado_pedido_nombre<>'cancelado'
  AND o.id_usuario<>pe.id_usuario
  AND u.correo_electronico='compradora.norte@mesh.com'
  AND NOT EXISTS (SELECT 1 FROM resena r WHERE r.id_usuario=pe.id_usuario
                    AND r.id_usuario_vendedor=o.id_usuario
                    AND r.id_producto_mongo=pp.id_producto_mongo)
LIMIT 1;")

if [ -z "$PAR" ]; then
    echo "  No queda ningun par resenable para compradora.norte: ya los uso todos."
    echo "  Borra una resena suya o corre .\\arrancar.ps1 -Reiniciar."
    exit 1
fi
PRODUCTO=$(echo "$PAR" | cut -d' ' -f2)
VENDEDOR=$(echo "$PAR" | cut -d' ' -f3)
echo "  probando con producto $PRODUCTO, vendedor $VENDEDOR"
echo

C=$(entrar "compradora.norte@mesh.com" "Comprador123")
[ -n "$C" ] && OK "sesion iniciada" || { FALLA "no se pudo iniciar sesion"; exit 1; }

# --- GET
cuerpo=$(curl -s "$API/productos/$PRODUCTO/resenas" -H "Cookie: $C")
[ "$(echo "$cuerpo" | campo ok)" = "True" ] && OK "GET /productos/:id/resenas" || FALLA "GET /productos/:id/resenas"

# Las cinco llaves del reparto tienen que venir SIEMPRE, aunque valgan 0: si
# falta una, la barra de esa nota desaparece en vez de salir vacia.
llaves=$(echo "$cuerpo" | python -c "
import sys,json; print(','.join(sorted(json.load(sys.stdin)['payload']['resumen']['reparto'].keys())))")
[ "$llaves" = "1,2,3,4,5" ] && OK "el reparto trae las 5 notas" || FALLA "reparto incompleto: $llaves"

quedan=$(echo "$cuerpo" | python -c "
import sys,json; print(len(json.load(sys.stdin)['payload']['puede_calificar']))")
[ "$quedan" -gt 0 ] && OK "puede_calificar trae $quedan vendedor(es)" || FALLA "puede_calificar vino vacio"

# --- POST resena
r=$(curl -s -X POST "$API/resenas" -H "Content-Type: application/json" -H "Cookie: $C" \
     -d "{\"id_producto\":$PRODUCTO,\"correo_vendedor\":\"$VENDEDOR\",\"calificacion\":4,\"comentario\":\"PRUEBA AUTOMATICA -- se borra sola al terminar la prueba de resenas.\"}")
ID_RESENA=$(echo "$r" | campo payload.id_resena)
ID_COM=$(echo "$r" | campo payload.id_comentario)
[ -n "$ID_RESENA" ] && OK "POST /resenas (resena $ID_RESENA)" || { FALLA "POST /resenas: $(echo "$r" | campo mensaje)"; }

# --- POST respuesta
if [ -n "$ID_RESENA" ]; then
    r=$(curl -s -X POST "$API/resenas/$ID_RESENA/respuestas" -H "Content-Type: application/json" -H "Cookie: $C" \
         -d '{"comentario":"PRUEBA AUTOMATICA -- respuesta."}')
    ID_RESP=$(echo "$r" | campo payload.id_comentario)
    [ -n "$ID_RESP" ] && OK "POST /resenas/:id/respuestas" || FALLA "POST respuestas: $(echo "$r" | campo mensaje)"
fi

# --- PUT voto, cambiarlo, y DELETE
if [ -n "$ID_COM" ]; then
    a=$(curl -s -X PUT "$API/comentarios/$ID_COM/voto" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"valor":1}')
    [ "$(echo "$a" | campo payload.a_favor)" = "1" ] && OK "PUT voto a favor" || FALLA "PUT voto a favor"

    b=$(curl -s -X PUT "$API/comentarios/$ID_COM/voto" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"valor":-1}')
    [ "$(echo "$b" | campo payload.en_contra)" = "1" ] && OK "cambiar el voto" || FALLA "cambiar el voto"

    # Cambiar de opinion es un UPDATE, no una fila nueva: la llave de `likes`
    # es (id_usuario, id_comentario). Dos filas aqui serian dos votos de la
    # misma cuenta, y "40 likes en tres minutos" dejaria de ser una senal.
    filas=$(sql "SELECT count(*) FROM likes WHERE id_comentario=$ID_COM;")
    [ "$filas" = "1" ] && OK "el cambio de voto fue UPDATE (1 fila, no 2)" || FALLA "quedaron $filas filas en likes"

    c=$(curl -s -X DELETE "$API/comentarios/$ID_COM/voto" -H "Cookie: $C")
    [ "$(echo "$c" | campo payload.a_favor)" = "0" ] && OK "DELETE voto" || FALLA "DELETE voto"

    d=$(curl -s -X PUT "$API/comentarios/$ID_COM/voto" -H "Content-Type: application/json" -H "Cookie: $C" -d '{"valor":7}')
    [ "$(echo "$d" | campo ok)" = "False" ] && OK "un voto de 7 se rechaza" || FALLA "acepto un voto de 7"
fi

# --- el trigger de los contadores
desfase=$(sql "
SELECT count(*) FROM comentario c
WHERE c.cantidad_likes    <> (SELECT count(*) FROM likes l WHERE l.id_comentario=c.id_comentario AND l.valor= 1)
   OR c.cantidad_dislikes <> (SELECT count(*) FROM likes l WHERE l.id_comentario=c.id_comentario AND l.valor=-1);")
[ "$desfase" = "0" ] && OK "los contadores cuadran con likes" || FALLA "$desfase comentario(s) descuadrados"

# --- limpieza: no dejar la resena de prueba en la base
if [ -n "${ID_RESENA:-}" ]; then
    sql "DELETE FROM likes  WHERE id_comentario IN (${ID_COM:-0}, ${ID_RESP:-0});" >/dev/null
    sql "DELETE FROM resena WHERE id_resena = $ID_RESENA;" >/dev/null
    sql "DELETE FROM comentario WHERE id_comentario IN (${ID_RESP:-0}, ${ID_COM:-0});" >/dev/null
    quedo=$(sql "SELECT count(*) FROM resena WHERE id_resena=$ID_RESENA;")
    [ "$quedo" = "0" ] && OK "la resena de prueba se borro" || FALLA "quedo la resena $ID_RESENA en la base"
fi


titulo "2. Que abrir para VERLO en el navegador"

echo "  La regla del backend: solo puede resenar quien COMPRO y PAGO ese"
echo "  producto a ese vendedor. Por eso el boton casi nunca aparece."
echo
echo "  Estos son los casos donde SI aparece, ahora mismo:"
echo

sql "
SELECT '   entra como '||u.correo_electronico||'  ->  $WEB/producto/'||pp.id_producto_mongo
       ||'   (podras calificar a '||count(DISTINCT uv.correo_electronico)||' vendedor(es))'
FROM pedido pe
JOIN pago pg ON pg.id_pedido=pe.id_pedido
JOIN estado_pago epa USING(id_estado_pago)
JOIN estado_pedido epe ON epe.id_estado_pedido=pe.id_estado_pedido
JOIN pedido_producto pp ON pp.id_pedido=pe.id_pedido
JOIN precio_historial ph ON ph.id_precio_historial=pp.id_precio_historial
JOIN oferta o ON o.id_oferta=ph.id_oferta
JOIN usuarios uv ON uv.id_usuario=o.id_usuario
JOIN usuarios u  ON u.id_usuario=pe.id_usuario
WHERE epa.estado_pago_nombre='pagado' AND epe.estado_pedido_nombre<>'cancelado'
  AND o.id_usuario<>pe.id_usuario
  AND NOT EXISTS (SELECT 1 FROM resena r WHERE r.id_usuario=pe.id_usuario
                    AND r.id_usuario_vendedor=o.id_usuario
                    AND r.id_producto_mongo=pp.id_producto_mongo)
GROUP BY u.correo_electronico, pp.id_producto_mongo
ORDER BY count(DISTINCT uv.correo_electronico) DESC, 1
LIMIT 8;"

echo
echo "  Contrasenas: los compradores usan Comprador123."
echo
echo "  Lo que tienes que ver en esa pagina, al final de la ficha:"
echo "    - la seccion 'Resenas' con su promedio y las barras por estrella"
echo "    - el boton 'Escribir una resena' arriba a la derecha de esa seccion"
echo "    - al escribirla: aparece en la lista y el boton DESAPARECE"
echo "      (ya calificaste a ese vendedor: no se puede dos veces)"
echo "    - 'Util' / 'No util' en cada resena, y 'Responder'"
echo "    - una pastilla 'tu resena' en las que escribiste vos"
echo
echo "  Y para ver una que YA tiene resenas sembradas, sin escribir nada:"
sql "SELECT '    $WEB/producto/'||id_producto_mongo||'   ('||count(*)||' resenas)'
     FROM resena GROUP BY id_producto_mongo ORDER BY count(*) DESC LIMIT 3;"


titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
if [ "$fallo" -gt 0 ]; then
    echo "  Algo no funciona. La base quedo limpia igual."
    exit 1
fi
echo "  Las 5 rutas funcionan y la base quedo como estaba."
exit 0
