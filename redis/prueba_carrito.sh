#!/usr/bin/env bash
#
# prueba_carrito.sh -- la evidencia de que el carrito vence por INACTIVIDAD.
#
# No comprueba que el codigo "corre": comprueba las tres afirmaciones que el
# README hace y que la rubrica pide justificar.
#
#   1. El vencimiento esta puesto A PROPOSITO y con un numero (no es el
#      comportamiento por omision de Redis, que es no vencer nunca).
#   2. Cada toque lo devuelve entero. Eso es inactividad, no un plazo fijo:
#      el carrito sobrevive mas de un TTL entero si la persona sigue ahi.
#   3. Cuando vence no hay NADA que liberar en PostgreSQL. Se mide antes y
#      despues.
#
# Y de paso comprueba la parte que se puede romper en silencio: que el carrito
# guardado en Redis realmente sirve para llamar a comprar_carrito(), incluido
# el `id_precio_historial` que arregla el problema del precio congelado. Esa
# compra se hace y se DESHACE con ROLLBACK -- la prueba no vende nada ni deja
# un pedido tirado.
#
# TRAMPA DEL INSTRUMENTO, que es la razon de que el TTL se lea con el comando
# TTL suelto y nunca con la operacion `ver`: `ver` RENUEVA. Medir el TTL
# llamando a `ver` daria siempre el valor completo y la prueba pasaria aunque
# la renovacion estuviera rota. Un arnes que mira lo que el mismo acaba de
# tocar no mide nada.
#
# Uso:  bash redis/prueba_carrito.sh
# Tarda alrededor de 45 segundos: hay que esperar de verdad a que venza.

set -u
export MSYS_NO_PATHCONV=1   # Git Bash convierte las rutas con / al pasarlas a
                            # docker exec y las vuelve C:/Program Files/...

DIR="$(cd "$(dirname "$0")" && pwd)"

CONTENEDOR_REDIS="${CONTENEDOR_REDIS:-mesh-redis}"
CONTENEDOR_PG="${CONTENEDOR_PG:-mesh-postgres}"
# La contrasena sale del .env de la raiz, NUNCA escrita aqui: este archivo
# se sube al repositorio y el .env no. Si falta, el script para y lo dice,
# en vez de intentar con un valor por defecto y fallar con "WRONGPASS".
if [ -z "${REDIS_PASSWORD:-}" ] && [ -f "$DIR/../.env" ]; then
    REDIS_PASSWORD=$(grep -E "^REDIS_PASSWORD=" "$DIR/../.env" | head -1 | cut -d= -f2-)
fi
if [ -z "${REDIS_PASSWORD:-}" ]; then
    echo "Falta REDIS_PASSWORD. Ponla en el .env de la raiz o exportala." >&2
    exit 1
fi
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"

# TTL chico a proposito: la prueba tiene que ESPERAR a que venza de verdad, y
# con las 24 horas de produccion no habria forma de comprobarlo. Lo que se
# comprueba es el mecanismo, y el mecanismo es el mismo con 10 segundos que con
# 86400.
#
# 15 y no 10, y el motivo es medicion, no gusto: cada `docker exec` cuesta
# entre uno y tres segundos, y esos segundos corren contra el TTL igual que
# los del `sleep`. Con TTL 10 y una espera de 6, la lectura llego a dar TTL=1
# -- a un parpadeo de que la clave ya no existiera y de que la prueba fallara
# por la lentitud de la herramienta en vez de por un bug.
TTL_PRUEBA=15
ESPERA=6          # menos que TTL_PRUEBA: cada toque llega antes de vencer
TOQUES=3          # 3 x 6 = 18 segundos vivo con un TTL de 15

# Ningun id se escribe a mano: todo entra por correo o por nombre.
CORREO_COMPRADOR="${CORREO_COMPRADOR:-compradora.norte@mesh.com}"
CORREO_VENDEDOR="${CORREO_VENDEDOR:-ventas.norte@mesh.com}"

# Prefijo propio para no pisar ninguna clave de verdad. Todo lo que esta
# prueba escribe empieza con esto y se borra al final.
PREFIJO="prueba:carrito"

fallos=0

R() { docker exec -i "$CONTENEDOR_REDIS" redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@"; }
PSQL() { docker exec -i "$CONTENEDOR_PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -tAF'|' "$@"; }

titulo() { echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
ok()  { echo "  OK    $1"; }
mal() { echo "  FALLA $1"; fallos=$((fallos + 1)); }

# Compara con tolerancia. El TTL se lee con un docker exec, y cada docker exec
# cuesta entre medio segundo y un segundo: exigir el numero exacto haria que la
# prueba fallara por la latencia de la herramienta y no por un bug. Esa
# distincion importa -- un arnes que falla solo ya no sirve como evidencia.
entre() {
    local etiqueta="$1" valor="$2" min="$3" max="$4"
    if [ "$valor" -ge "$min" ] && [ "$valor" -le "$max" ]; then
        ok "$etiqueta = $valor (esperado entre $min y $max)"
    else
        mal "$etiqueta = $valor (esperado entre $min y $max)"
    fi
}

igual() {
    local etiqueta="$1" valor="$2" esperado="$3"
    if [ "$valor" = "$esperado" ]; then
        ok "$etiqueta = $valor"
    else
        mal "$etiqueta = $valor (se esperaba $esperado)"
    fi
}


titulo "0. Preparativos"

SHA=$(R -x SCRIPT LOAD < "$DIR/carrito.lua")
if [ -z "$SHA" ]; then
    echo "No se pudo cargar carrito.lua en Redis. Esta levantado $CONTENEDOR_REDIS?"
    exit 1
fi
echo "  carrito.lua cargado, sha $SHA"

ID_USUARIO=$(PSQL -c "SELECT id_usuario FROM usuarios WHERE correo_electronico = '$CORREO_COMPRADOR';")
if [ -z "$ID_USUARIO" ]; then
    echo "No existe el usuario $CORREO_COMPRADOR en la base $PG_BASE."
    exit 1
fi
CARRITO="$PREFIJO:$ID_USUARIO"
echo "  comprador $CORREO_COMPRADOR -> id $ID_USUARIO, clave $CARRITO"

# Dos ofertas activas y con stock del mismo vendedor, con su precio VIGENTE.
#
# El id_precio_historial es la pieza que este diseno agrega y que el carrito de
# PostgreSQL no necesitaba: es el precio que la persona esta viendo ahora, y
# guardarlo aqui es lo que permite cobrarle ese y no el que haya cuando pague.
# Ver el apartado del precio congelado en README.md.
OFERTAS=$(PSQL -c "
SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
       ph.id_precio_historial, ph.precio, p.nombre
FROM oferta o
JOIN usuarios u   ON u.id_usuario = o.id_usuario
JOIN productos p  ON p.id_producto = o.id_producto_mongo
JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
JOIN LATERAL (
    SELECT id_precio_historial, precio
    FROM precio_historial
    WHERE id_oferta = o.id_oferta
    ORDER BY fecha_creacion DESC, id_precio_historial DESC
    LIMIT 1
) ph ON true
WHERE u.correo_electronico = '$CORREO_VENDEDOR'
  AND eo.estado_oferta_nombre = 'activa'
  AND o.stock >= 2
ORDER BY o.id_oferta
LIMIT 2;")

if [ "$(echo "$OFERTAS" | grep -c .)" -lt 2 ]; then
    echo "No hay dos ofertas activas con stock de $CORREO_VENDEDOR."
    exit 1
fi
echo "  ofertas de prueba:"
echo "$OFERTAS" | sed 's/^/    /'

# Foto de PostgreSQL ANTES de que exista el carrito. Se vuelve a tomar al final
# para comprobar que un carrito que vencio no dejo nada que limpiar.
#
# LA FOTO ES DE LO QUE ESTA PRUEBA TOCA, NO DE LA BASE ENTERA, y esa es la
# correccion: antes se comparaba sum(stock) de TODAS las ofertas y count(*) de
# TODA la tabla `pedido`, con casi un minuto de diferencia entre las dos
# lecturas. Cualquier compra de otro actor en ese rato hacia FALLAR la prueba y
# le echaba la culpa al carrito.
#
# No es hipotetico: corriendo el script tres veces seguidas, dos fallaron. La
# primera dijo "FALLA stock total en oferta = 8292 (se esperaba 8302)" y la
# causa quedo en la base -- stock_movimiento 579, pedido 34, id_usuario 9, una
# compra ajena commiteada mientras el script dormia sus sleeps. El carrito de la
# prueba vive en Redis con prefijo prueba:carrito: y NUNCA escribe en `oferta`
# ni en `pedido`, asi que esas dos lineas no median nada de lo que la prueba
# construye.
#
# Acotado a las dos ofertas que usa y a los pedidos del comprador de prueba, la
# afirmacion que importa ("al vencer no hay nada que liberar") se sigue
# comprobando y deja de depender de que nadie mas use la base.
#
# Se toma DESPUES de elegir las ofertas, porque necesita sus ids.
OFERTAS_USADAS=$(echo "$OFERTAS" | cut -d'|' -f1 | paste -sd, -)
STOCK_ANTES=$(PSQL -c "SELECT coalesce(sum(stock), 0) FROM oferta WHERE id_oferta IN ($OFERTAS_USADAS);")
PEDIDOS_ANTES=$(PSQL -c "SELECT count(*) FROM pedido WHERE id_usuario = $ID_USUARIO;")
echo "  PostgreSQL antes: stock de las ofertas $OFERTAS_USADAS = $STOCK_ANTES, pedidos de $CORREO_COMPRADOR = $PEDIDOS_ANTES"

R DEL "$CARRITO" > /dev/null


titulo "1. El carrito nace con un vencimiento PUESTO, no heredado"
# Una clave de Redis sin EXPIRE vive para siempre y TTL devuelve -1. Que aqui
# diga 10 es la diferencia entre "configurado explicitamente" y "por omision".

LINEA_1=""
LINEA_2=""
OFERTA_1=""
OFERTA_2=""
I=0
# El bucle lee por el descriptor 3 y NO por la entrada normal.
#
# Ya mordio: adentro del bucle se llama a `docker exec -i`, y ese `-i` se come
# TODO lo que quede en la entrada estandar. Con un `while read` normal, la
# primera vuelta agregaba su oferta y docker se tragaba el resto del listado:
# el bucle daba UNA sola vuelta, el carrito quedaba con una linea en vez de
# dos, y el error que se veia era "OFERTA_2: unbound variable" treinta lineas
# mas abajo, que no se parece en nada a la causa.
while IFS='|' read -r ID_OFERTA ID_PROD ID_VAR ID_PRECIO PRECIO NOMBRE <&3; do
    [ -z "$ID_OFERTA" ] && continue
    I=$((I + 1))
    # El JSON se guarda TAL CUAL y no se abre nunca dentro de Lua. La cantidad
    # va aparte, en su propio campo, para poder sumarla con HINCRBY.
    LINEA="{\"id_oferta\":$ID_OFERTA,\"id_producto\":$ID_PROD,\"id_producto_variante\":$ID_VAR,\"id_precio_historial\":$ID_PRECIO,\"precio_visto\":$PRECIO,\"nombre_producto\":\"$NOMBRE\",\"nombre_variante\":\"variante $ID_VAR\"}"
    if [ "$I" = "1" ]; then
        OFERTA_1="$ID_OFERTA"; LINEA_1="$LINEA"
        echo "  agregar 2 unidades de la oferta $ID_OFERTA:"
        R EVALSHA "$SHA" 1 "$CARRITO" agregar "$TTL_PRUEBA" "$ID_OFERTA" 2 "$LINEA" | sed 's/^/    /'
    else
        OFERTA_2="$ID_OFERTA"; LINEA_2="$LINEA"
        echo "  agregar 1 unidad de la oferta $ID_OFERTA:"
        R EVALSHA "$SHA" 1 "$CARRITO" agregar "$TTL_PRUEBA" "$ID_OFERTA" 1 "$LINEA" | sed 's/^/    /'
    fi
done 3<<< "$OFERTAS"

if [ -z "$OFERTA_2" ]; then
    mal "solo entro una oferta al carrito: el listado se leyo a medias"
fi

TTL_INICIAL=$(R TTL "$CARRITO")
entre "TTL recien creado" "$TTL_INICIAL" $((TTL_PRUEBA - 2)) "$TTL_PRUEBA"
igual "lineas en el carrito" "$(R HLEN "$CARRITO")" "4"   # 2 lineas x 2 campos

echo "  contenido:"
R HGETALL "$CARRITO" | sed 's/^/    /'


titulo "2. Sin tocarlo, el TTL baja"

echo "  esperando $ESPERA segundos sin tocar el carrito..."
sleep "$ESPERA"
TTL_BAJO=$(R TTL "$CARRITO")
entre "TTL despues de $ESPERA s quieto" "$TTL_BAJO" 1 $((TTL_PRUEBA - ESPERA + 1))


titulo "3. Un toque lo devuelve ENTERO -- esto es la expiracion por inactividad"
# Aqui esta la diferencia con el JWT. El JWT dura 2 horas desde que se firma y
# usarlo no lo alarga. El carrito se alarga cada vez que se usa.

echo "  operacion 'ver' (mirar el carrito TAMBIEN es actividad):"
R EVALSHA "$SHA" 1 "$CARRITO" ver "$TTL_PRUEBA" | head -3 | sed 's/^/    /'
TTL_RENOVADO=$(R TTL "$CARRITO")
entre "TTL despues del toque" "$TTL_RENOVADO" $((TTL_PRUEBA - 2)) "$TTL_PRUEBA"

if [ "$TTL_RENOVADO" -gt "$TTL_BAJO" ]; then
    ok "el TTL subio de $TTL_BAJO a $TTL_RENOVADO: se renovo"
else
    mal "el TTL no se renovo ($TTL_BAJO -> $TTL_RENOVADO)"
fi


titulo "4. Con actividad sostenida sobrevive mas de un TTL entero"
# $TOQUES toques cada $ESPERA segundos = mas tiempo vivo que el TTL completo.
# Si el vencimiento fuera un plazo fijo desde la creacion, aqui el carrito ya
# no estaria. Esta es la comprobacion que separa las dos politicas.

VIVIDO=0
for i in $(seq 1 "$TOQUES"); do
    sleep "$ESPERA"
    VIVIDO=$((VIVIDO + ESPERA))
    R EVALSHA "$SHA" 1 "$CARRITO" renovar "$TTL_PRUEBA" > /dev/null
    echo "  toque $i, vivo hace ${VIVIDO}s, TTL ahora $(R TTL "$CARRITO")"
done

if [ "$VIVIDO" -le "$TTL_PRUEBA" ]; then
    mal "la prueba no espero mas que el TTL ($VIVIDO s contra $TTL_PRUEBA s): no demuestra nada"
else
    igual "el carrito sigue vivo tras ${VIVIDO}s con TTL de ${TTL_PRUEBA}s" \
          "$(R EXISTS "$CARRITO")" "1"
fi


titulo "5. Ese carrito alimenta a comprar_carrito() -- y se deshace con ROLLBACK"
# Lo que se lee de Redis es lo que se le manda a PostgreSQL. Se arma el arreglo
# de lineas juntando el JSON guardado (campo l:) con la cantidad (campo c:),
# que es exactamente el trabajo que le queda al backend.

LINEAS="["
for OF in "$OFERTA_1" "$OFERTA_2"; do
    L=$(R HGET "$CARRITO" "l:$OF")
    C=$(R HGET "$CARRITO" "c:$OF")
    [ -z "$L" ] && continue
    # Se le injerta la cantidad al JSON guardado. La cantidad vive aparte
    # porque HINCRBY la suma sola; al salir se vuelven a juntar.
    L_CON_CANTIDAD=$(echo "$L" | sed "s/}$/,\"cantidad\":$C}/")
    [ "$LINEAS" != "[" ] && LINEAS="$LINEAS,"
    LINEAS="$LINEAS$L_CON_CANTIDAD"
done
LINEAS="$LINEAS]"
echo "  lineas reconstruidas desde Redis:"
echo "    $LINEAS"

echo "  comprar_carrito() dentro de BEGIN ... ROLLBACK:"
RESULTADO=$(PSQL -c "
BEGIN;
SELECT comprar_carrito(
    (SELECT id_usuario FROM usuarios WHERE correo_electronico = '$CORREO_COMPRADOR'),
    (SELECT dh.id_direccion_historial
     FROM direccion_historial dh
     JOIN direcciones d ON d.id_direccion = dh.id_direccion
     JOIN usuarios u ON u.id_usuario = d.id_usuario
     WHERE u.correo_electronico = '$CORREO_COMPRADOR'
     ORDER BY dh.id_direccion_historial DESC LIMIT 1),
    '$LINEAS'::jsonb,
    'tarjeta');
ROLLBACK;" 2>&1)
echo "$RESULTADO" | sed 's/^/    /'

if echo "$RESULTADO" | grep -q '"id_pedido"'; then
    ok "el carrito de Redis es aceptado por comprar_carrito()"
else
    mal "comprar_carrito() no acepto el carrito de Redis"
fi

if echo "$LINEAS" | grep -q 'id_precio_historial'; then
    ok "cada linea GUARDADA EN REDIS lleva su id_precio_historial"
else
    mal "las lineas guardadas en Redis no llevan id_precio_historial"
fi


titulo "5b. Y PostgreSQL ya RESPETA ese id_precio_historial -- medido, no supuesto"
# Esta seccion existe porque la de arriba, sola, no prueba lo que prometia.
#
# Antes esa segunda linea decia "cada linea lleva su id_precio_historial (la
# salida al precio congelado)", y lo unico que hacia era un grep sobre la cadena
# que el propio script acababa de construir tres lineas mas arriba. Miraba su
# entrada, no el sistema. Un arnes que mira lo que el mismo acaba de escribir no
# mide nada -- es la misma trampa del instrumento que la cabecera de este
# archivo nombra para el TTL.
#
# ESTE BLOQUE YA SE PUSO ROJO UNA VEZ, Y ESA ERA SU RAZON DE EXISTIR.
#
# Hasta la migracion 013, agregar_linea() hacia su PROPIO "SELECT
# id_precio_historial ... ORDER BY fecha_creacion DESC LIMIT 1" e insertaba ese,
# nunca el del JSON: el campo VIAJABA y no SERVIA. Este bloque comprobaba
# justamente eso, mandando un id que no existe en toda la base y verificando que
# la compra saliera bien igual y guardara el vigente.
#
# Y decia, textual, que el dia que alguien hiciera que agregar_linea() respetara
# el parametro se pondria rojo y obligaria a actualizar el arnes en vez de
# dejarlo mintiendo. Ese dia llego con la 013 y el mecanismo funciono: fallo,
# senalando su propio texto. Esto es lo que quedo despues de hacerle caso.
#
# Ahora se comprueban las DOS mitades de la 013, que son las que importan:
#
#   1. Un id INEXISTENTE se RECHAZA. Antes se descartaba en silencio y se
#      cobraba el precio de hoy; ahora levanta excepcion y no compra nada. Es
#      lo correcto: un id que no existe no es "usa el vigente", es una peticion
#      mal formada, y tragarsela es como se cuelan los cobros equivocados.
#
#   2. Un id VALIDO y de ESA oferta se USA. Esta es la mitad que de verdad
#      arregla el problema, y sin ella la primera sola no prueba nada: un
#      agregar_linea() que rechazara TODO tambien pasaria la comprobacion 1.
#      Se congela un precio viejo a proposito y se comprueba que pedido_producto
#      guarde ESE y no el de hoy.

ID_IMPOSIBLE=999999999
LINEAS_FALSAS=$(echo "$LINEAS" | sed "s/\"id_precio_historial\":[0-9]*/\"id_precio_historial\":$ID_IMPOSIBLE/g")
echo "  las mismas lineas, con id_precio_historial=$ID_IMPOSIBLE (no existe ninguna fila con ese id):"
echo "    $LINEAS_FALSAS"

# Todo dentro de UNA transaccion: la compra, la lectura de lo que quedo, y el
# ROLLBACK. Leer despues del ROLLBACK no encontraria nada.
COMPARACION=$(PSQL -c "
BEGIN;
SELECT comprar_carrito(
    (SELECT id_usuario FROM usuarios WHERE correo_electronico = '$CORREO_COMPRADOR'),
    (SELECT dh.id_direccion_historial
     FROM direccion_historial dh
     JOIN direcciones d ON d.id_direccion = dh.id_direccion
     JOIN usuarios u ON u.id_usuario = d.id_usuario
     WHERE u.correo_electronico = '$CORREO_COMPRADOR'
     ORDER BY dh.id_direccion_historial DESC LIMIT 1),
    '$LINEAS_FALSAS'::jsonb,
    'tarjeta') AS compra;
-- El id que quedo guardado contra el que rige hoy para esa oferta. Si son
-- iguales, agregar_linea() puso el vigente y tiro el del JSON.
SELECT 'guardado=' || pp.id_precio_historial ||
       ' vigente=' || (SELECT ph2.id_precio_historial
                       FROM precio_historial ph2
                       WHERE ph2.id_oferta = ph.id_oferta
                       ORDER BY ph2.fecha_creacion DESC, ph2.id_precio_historial DESC
                       LIMIT 1) ||
       ' enviado=$ID_IMPOSIBLE'
FROM pedido_producto pp
JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
WHERE pp.id_pedido = (SELECT max(id_pedido) FROM pedido)
ORDER BY pp.id_pedido_producto;
ROLLBACK;" 2>&1)
echo "$COMPARACION" | sed 's/^/    /'

if echo "$COMPARACION" | grep -q '"id_pedido"'; then
    mal "comprar_carrito() acepto un id_precio_historial inexistente. La 013 tenia que rechazarlo"
else
    ok "comprar_carrito() RECHAZA un id_precio_historial que no existe"
fi

# La otra mitad, y es la que prueba que el arreglo sirve. Un agregar_linea()
# que rechazara cualquier id tambien pasaria la comprobacion de arriba, asi que
# sola no demuestra nada.
#
# Se congela un precio VIEJO a proposito: se busca la fila mas antigua del
# historial de esa oferta, se manda ESA, y se comprueba que pedido_producto
# guarde esa y no la vigente. Si la 013 no estuviera, agregar_linea() volveria a
# poner la vigente y esta comprobacion se pondria roja.
echo
echo "  y ahora al reves: un id VALIDO y viejo de esa misma oferta"

RESPETADO=$(PSQL -c "
BEGIN;
-- El id mas VIEJO del historial de la primera oferta del carrito, que casi
-- nunca es el vigente: es el que se manda para ver si se respeta.
CREATE TEMP TABLE elegida ON COMMIT DROP AS
SELECT o.id_oferta,
       (SELECT ph.id_precio_historial FROM precio_historial ph
         WHERE ph.id_oferta = o.id_oferta
         ORDER BY ph.fecha_creacion ASC, ph.id_precio_historial ASC LIMIT 1) AS viejo,
       (SELECT ph.id_precio_historial FROM precio_historial ph
         WHERE ph.id_oferta = o.id_oferta
         ORDER BY ph.fecha_creacion DESC, ph.id_precio_historial DESC LIMIT 1) AS vigente
FROM oferta o
JOIN estado_oferta e ON e.id_estado_oferta = o.id_estado_oferta
WHERE e.estado_oferta_nombre = 'activa' AND o.stock > 2
ORDER BY o.id_oferta LIMIT 1;

SELECT comprar_carrito(
    (SELECT id_usuario FROM usuarios WHERE correo_electronico = '$CORREO_COMPRADOR'),
    (SELECT dh.id_direccion_historial
     FROM direccion_historial dh
     JOIN direcciones d ON d.id_direccion = dh.id_direccion
     JOIN usuarios u ON u.id_usuario = d.id_usuario
     WHERE u.correo_electronico = '$CORREO_COMPRADOR'
     ORDER BY dh.id_direccion_historial DESC LIMIT 1),
    (SELECT jsonb_build_array(jsonb_build_object(
        'id_oferta', el.id_oferta,
        'cantidad', 1,
        'id_precio_historial', el.viejo,
        'id_producto', pv.id_producto,
        'id_producto_variante', pv.id_producto_variante,
        'nombre_producto', p.nombre,
        'nombre_variante', pv.nombre_variante))
     FROM elegida el
     JOIN oferta o ON o.id_oferta = el.id_oferta
     JOIN productos_variantes pv ON pv.id_producto_variante = o.id_producto_variante_mongo
     JOIN productos p ON p.id_producto = pv.id_producto),
    'tarjeta') AS compra;

SELECT CASE WHEN pp.id_precio_historial = el.viejo THEN 'RESPETADO'
            WHEN pp.id_precio_historial = el.vigente THEN 'PUSO_EL_VIGENTE'
            ELSE 'OTRO' END
FROM pedido_producto pp, elegida el
WHERE pp.id_pedido = (SELECT max(id_pedido) FROM pedido);
ROLLBACK;" 2>&1)

echo "$RESPETADO" | sed 's/^/    /'

if echo "$RESPETADO" | grep -q "RESPETADO"; then
    ok "pedido_producto guardo el id_precio_historial que mando el carrito, no el vigente"
elif echo "$RESPETADO" | grep -q "PUSO_EL_VIGENTE"; then
    mal "agregar_linea() volvio a poner el vigente: la 013 no esta aplicada en esta base"
else
    mal "no se pudo comprobar que se respete el id valido"
fi

echo
echo "  La 013 esta aplicada y hace su mitad. Lo que sigue PENDIENTE, y esta"
echo "  escrito asi en redis/README.md, es la mitad del backend: que el carrito"
echo "  de Redis guarde el id y que POST /carrito/comprar lo mande."


titulo "6. Sin actividad, vence solo"

ESPERA_FINAL=$((TTL_PRUEBA + 3))
echo "  dejando de tocarlo $ESPERA_FINAL segundos..."
sleep "$ESPERA_FINAL"

igual "EXISTS del carrito" "$(R EXISTS "$CARRITO")" "0"
igual "TTL del carrito"    "$(R TTL "$CARRITO")"    "-2"   # -2 = ya no existe


titulo "7. Al vencer NO hay nada que liberar en PostgreSQL"
# docs/base-de-datos.md lo dice textual: "Mientras el pedido esta pendiente, el
# stock NO esta reservado". Agregar al carrito nunca reservo nada, asi que un
# carrito que se evapora no deja stock retenido, ni un pedido pendiente, ni
# ninguna fila que alguien tenga que ir a limpiar. Se mide, no se afirma.

STOCK_DESPUES=$(PSQL -c "SELECT coalesce(sum(stock), 0) FROM oferta WHERE id_oferta IN ($OFERTAS_USADAS);")
PEDIDOS_DESPUES=$(PSQL -c "SELECT count(*) FROM pedido WHERE id_usuario = $ID_USUARIO;")

igual "stock de las ofertas que uso el carrito" "$STOCK_DESPUES"   "$STOCK_ANTES"
igual "pedidos del comprador de prueba"         "$PEDIDOS_DESPUES" "$PEDIDOS_ANTES"


titulo "8. Limpieza"

BORRADAS=$(R DEL "$CARRITO")
echo "  claves de prueba borradas: $BORRADAS"
SOBRANTES=$(R --scan --pattern "$PREFIJO*" | grep -c . || true)
igual "claves con prefijo $PREFIJO que quedaron" "$SOBRANTES" "0"


titulo "RESULTADO"
if [ "$fallos" = "0" ]; then
    echo "  Todo bien. El carrito vence por inactividad y su vencimiento no"
    echo "  deja nada colgando en PostgreSQL."
    exit 0
else
    echo "  $fallos comprobacion(es) FALLARON."
    exit 1
fi
