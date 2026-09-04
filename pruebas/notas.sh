#!/usr/bin/env bash
# pruebas/notas.sh -- comprueba que la nota del catalogo alcanza a los productos
# que el ETL viejo no podia tocar.
#
#   bash pruebas/notas.sh
#
# QUE PRUEBA, y por que hace falta un arnes propio
#
# La nota (resenas_promedio y resenas_total) se calculaba solo dentro de
# extraer.sql, que recorre `FROM productos p` en PostgreSQL. Eso dejaba dos
# agujeros que NO se ven mirando la pantalla, porque en los dos el catalogo
# ensena un numero perfectamente creible que resulta ser falso:
#
#   1. Un producto que solo vive en Mongo nunca recibia su nota.
#   2. Un producto al que le borraron la ultima resena se quedaba con la nota
#      vieja para siempre.
#
# Las cuatro partes de aqui abajo prueban las dos, y la PARTE 1 prueba primero
# que el problema existe: si extraer.sql alcanzara a esos productos, la etapa
# nueva no haria falta y este arnes estaria aprobando algo que ya funcionaba.
#
# TOCA LA BASE Y LA DEJA COMO ESTABA. Siembra una resena sobre un producto real
# y la borra al terminar, incluso si algo falla a la mitad. Lo que escribe lleva
# la marca 'PRUEBA notas.sh' para que se reconozca si alguna vez queda algo.
#
# OJO CON EL GRAFO: `resena` tiene el trigger trg_resena_al_grafo, asi que
# sembrar y borrar aqui encola dos eventos en evento_grafo. El worker del
# backend los aplica en unos 10 segundos y el saldo final es cero, igual que
# con pruebas/resenas.sh. No hace falta hacer nada.
#
# No instala nada: docker y bash, que ya estan.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PG="${PG:-mesh-postgres}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
MONGO="${MONGO:-mesh-mongo}"

# Git Bash convierte las rutas que empiezan con / al pasarlas a docker. Sin
# esto, cualquier "docker exec ... /tmp/algo" llega como ruta de Windows.
export MSYS_NO_PATHCONV=1

ok=0; fallo=0

OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# La -q no es decorativa. Sin ella, un INSERT ... RETURNING devuelve DOS lineas
# -- el valor y el tag "INSERT 0 1" -- y la variable que lo recoge se lleva las
# dos. El siguiente INSERT recibe entonces un id partido y falla sin decir por
# que. Costo una corrida entera averiguarlo.
sql()   { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -qtAc "$1" 2>/dev/null | tr -d '\r'; }

# mongosh lee las credenciales de las variables del propio contenedor, que es
# como lo hacen arrancar.ps1 y etl/correr.sh. Asi no viaja ninguna contrasena
# por la linea de comandos ni queda en el historial.
mongo() {
    docker exec -i "$MONGO" sh -c 'cat > /tmp/prueba_notas.js' \
        && docker exec "$MONGO" sh -c 'mongosh --quiet \
            -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
            --authenticationDatabase admin "$MONGO_INITDB_DATABASE" \
            /tmp/prueba_notas.js' 2>/dev/null | tr -d '\r'
}

# ============================================================
# Limpieza, registrada ANTES de sembrar nada
# ============================================================
#
# Va en un trap para que se corra tambien si el script muere a la mitad: una
# resena de prueba olvidada en la base movería la nota de un producto real y el
# siguiente que corriera esto no entenderia nada.
ID_RESENA=""
ID_COMENTARIO=""
MARCA='PRUEBA notas.sh'

# Se borra por la MARCA y no por el id que guardamos. Si el arnes muere justo
# entre el INSERT y la linea que recoge su id, esa variable esta vacia y una
# limpieza por id no borraria nada -- que es exactamente el caso en que mas
# falta hace. La marca la encuentra igual.
#
# Y la resena va primero: comentario tiene ON DELETE RESTRICT desde resena, asi
# que al reves el borrado del comentario fallaria y dejaria las dos filas.
limpiar() {
    sql "DELETE FROM resena
         WHERE id_comentario IN (SELECT id_comentario FROM comentario WHERE comentario = '$MARCA');" > /dev/null
    sql "DELETE FROM comentario WHERE comentario = '$MARCA';" > /dev/null
}
trap limpiar EXIT

# ============================================================
# Elegir el producto de la prueba
# ============================================================
titulo "EL PRODUCTO DE LA PRUEBA"

# La lista de ids de PostgreSQL entra al contenedor de Mongo por un archivo,
# porque son mas de mil numeros y no caben comodos en una linea de comando.
sql "SELECT string_agg(id_producto::text, ',') FROM productos" \
    | docker exec -i "$MONGO" sh -c 'cat > /tmp/pgids_prueba.txt'

PRODUCTO=$(mongo <<'JS'
const enPg = new Set(
  require('fs').readFileSync('/tmp/pgids_prueba.txt', 'utf8').trim().split(',').map(Number)
);
// Se busca uno que ademas no tenga resenas hoy: asi la nota que aparezca
// durante la prueba solo puede venir de la resena que siembra este arnes.
const libre = db.productos
  .find({ resenas_total: 0 }, { _id: 1 })
  .sort({ _id: 1 })
  .toArray()
  .filter(d => !enPg.has(d._id));
print(libre.length > 0 ? libre[0]._id : '');
JS
)

if [ -z "$PRODUCTO" ]; then
    echo "  No hay ningun producto que viva SOLO en Mongo y este sin resenas."
    echo "  Publica uno desde el panel del vendedor y vuelve a correr esto."
    echo "  (Sin ese producto esta prueba no puede medir nada, y aprobar"
    echo "   igual seria mentir, asi que se para aqui.)"
    exit 1
fi

echo "  producto $PRODUCTO  vive solo en MongoDB, sin resenas"

# ============================================================
# PARTE 1 -- el ETL viejo NO puede alcanzarlo
# ============================================================
titulo "1. extraer.sql no ve a ese producto, y por eso hace falta la etapa"

EN_PG=$(sql "SELECT count(*) FROM productos WHERE id_producto = $PRODUCTO")
if [ "$EN_PG" = "0" ]; then
    OK "no tiene fila en la tabla productos de PostgreSQL (= $EN_PG)"
else
    FALLA "tiene fila en PostgreSQL: entonces no sirve para esta prueba"
fi

# extraer.sql recorre `FROM productos p`, asi que un id sin fila no puede salir
# en su resultado. Se comprueba de verdad, corriendolo, en vez de razonarlo.
SALE_EN_EXTRAER=$(docker exec -i "$PG" \
    psql -U "$PG_USUARIO" -d "$PG_BASE" -qtAX -f - < "$RAIZ/etl/extraer.sql" 2>/dev/null \
    | grep -c "\"id_producto\": $PRODUCTO," || true)

if [ "$SALE_EN_EXTRAER" = "0" ]; then
    OK "extraer.sql no lo devuelve en ninguna linea (= $SALE_EN_EXTRAER)"
else
    FALLA "extraer.sql si lo devuelve ($SALE_EN_EXTRAER lineas): la premisa de la etapa es falsa"
fi

# ============================================================
# PARTE 2 -- con una resena, la nota LLEGA
# ============================================================
titulo "2. Se le siembra una resena y la nota llega al catalogo"

# Dos cuentas distintas, que la tabla lo exige (CHECK id_usuario <> vendedor).
COMPRADOR=$(sql "SELECT id_usuario FROM usuarios WHERE correo_electronico = 'compradora.norte@mesh.com'")
VENDEDOR=$(sql  "SELECT id_usuario FROM usuarios WHERE correo_electronico = 'ventas.norte@mesh.com'")

if [ -z "$COMPRADOR" ] || [ -z "$VENDEDOR" ]; then
    echo "  Faltan las cuentas de la semilla. Corre .\\arrancar.ps1 -Reiniciar"
    exit 1
fi

ID_COMENTARIO=$(sql "INSERT INTO comentario (id_usuario, comentario)
                     VALUES ($COMPRADOR, '$MARCA')
                     RETURNING id_comentario")

ID_RESENA=$(sql "INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo, calificacion, id_comentario)
                 VALUES ($COMPRADOR, $VENDEDOR, $PRODUCTO, 5, $ID_COMENTARIO)
                 RETURNING id_resena")

if [ -n "$ID_RESENA" ]; then
    OK "resena sembrada en PostgreSQL (id $ID_RESENA, 5 estrellas)"
else
    FALLA "no se pudo sembrar la resena"
    exit 1
fi

# Antes de correr nada, el documento tiene que seguir en cero. Si ya dijera 5,
# lo que mide la siguiente comprobacion no seria la etapa nueva.
ANTES=$(mongo <<JS
const d = db.productos.findOne({ _id: $PRODUCTO }, { resenas_total: 1, resenas_promedio: 1 });
print(d.resenas_total + '|' + d.resenas_promedio);
JS
)
if [ "$ANTES" = "0|0" ]; then
    OK "el documento sigue en 0 antes de correr el ETL (= $ANTES)"
else
    FALLA "el documento ya decia $ANTES antes de correr nada"
fi

bash "$RAIZ/etl/correr.sh" --notas > /dev/null 2>&1

DESPUES=$(mongo <<JS
const d = db.productos.findOne({ _id: $PRODUCTO }, { resenas_total: 1, resenas_promedio: 1 });
print(d.resenas_total + '|' + d.resenas_promedio);
JS
)
if [ "$DESPUES" = "1|5" ]; then
    OK "tras correr --notas el documento dice 1 resena y promedio 5 (= $DESPUES)"
else
    FALLA "tras correr --notas el documento dice $DESPUES, se esperaba 1|5"
fi

# ============================================================
# PARTE 3 -- al borrar la resena, la nota se APAGA
# ============================================================
titulo "3. Se borra la resena y la nota vuelve a cero"

sql "DELETE FROM resena WHERE id_resena = $ID_RESENA;" > /dev/null
sql "DELETE FROM comentario WHERE id_comentario = $ID_COMENTARIO;" > /dev/null
ID_RESENA=""
ID_COMENTARIO=""

# El producto ya no sale en extraer_notas.sql, porque no tiene resenas. Que la
# nota se apague depende del $nin de cargar_notas.js, no de la consulta.
bash "$RAIZ/etl/correr.sh" --notas > /dev/null 2>&1

APAGADO=$(mongo <<JS
const d = db.productos.findOne({ _id: $PRODUCTO }, { resenas_total: 1, resenas_promedio: 1 });
print(d.resenas_total + '|' + d.resenas_promedio);
JS
)
if [ "$APAGADO" = "0|0" ]; then
    OK "el documento volvio a 0 resenas y promedio 0 (= $APAGADO)"
else
    FALLA "el documento quedo en $APAGADO, se esperaba 0|0"
fi

# ============================================================
# PARTE 4 -- las dos etapas no se contradicen
# ============================================================
titulo "4. extraer.sql y extraer_notas.sql dicen lo mismo"

# Los dos escriben sobre el mismo campo del mismo documento. Si un dia dejaran
# de coincidir, el valor del catalogo dependeria de cual corrio de ultima, que
# es la clase de fallo que no da ningun error.
DISCREPAN=$(sql "
WITH del_extractor AS (
    SELECT p.id_producto,
           (SELECT coalesce(round(avg(r.calificacion), 2), 0)
            FROM resena r WHERE r.id_producto_mongo = p.id_producto) AS promedio,
           (SELECT count(*)
            FROM resena r WHERE r.id_producto_mongo = p.id_producto) AS total
    FROM productos p
),
de_las_notas AS (
    SELECT r.id_producto_mongo AS id_producto,
           round(avg(r.calificacion), 2) AS promedio,
           count(*) AS total
    FROM resena r
    GROUP BY r.id_producto_mongo
)
SELECT count(*)
FROM del_extractor e
JOIN de_las_notas n ON n.id_producto = e.id_producto
WHERE e.promedio IS DISTINCT FROM n.promedio
   OR e.total    IS DISTINCT FROM n.total")

if [ "$DISCREPAN" = "0" ]; then
    OK "ningun producto compartido tiene dos notas distintas (= $DISCREPAN)"
else
    FALLA "$DISCREPAN producto(s) reciben una nota distinta segun la etapa"
fi

# Y que lo que quedo en Mongo sea lo que dice PostgreSQL, para los que si
# tienen fila en las dos. Esto mide el resultado, no las consultas.
sql "SELECT string_agg(r.id_producto_mongo || ':' || count(*) || ':' || round(avg(r.calificacion), 2), ',')
     FROM resena r GROUP BY r.id_producto_mongo" > /dev/null

ESPERADO=$(sql "SELECT count(DISTINCT id_producto_mongo) FROM resena")
EN_MONGO=$(mongo <<'JS'
print(db.productos.countDocuments({ resenas_total: { $gt: 0 } }));
JS
)
if [ "$ESPERADO" = "$EN_MONGO" ]; then
    OK "los productos con nota en Mongo son los mismos que en PostgreSQL (= $EN_MONGO)"
else
    FALLA "PostgreSQL dice $ESPERADO productos con resenas y Mongo tiene $EN_MONGO"
fi

# ============================================================
# LIMPIEZA
# ============================================================
titulo "LIMPIEZA"

QUEDAN=$(sql "SELECT count(*) FROM comentario WHERE comentario = '$MARCA'")
if [ "$QUEDAN" = "0" ]; then
    OK "no quedo ningun comentario de prueba en la base (= $QUEDAN)"
else
    FALLA "quedaron $QUEDAN comentario(s) de prueba"
fi

FINAL=$(mongo <<JS
const d = db.productos.findOne({ _id: $PRODUCTO }, { resenas_total: 1, resenas_promedio: 1 });
print(d.resenas_total + '|' + d.resenas_promedio);
JS
)
if [ "$FINAL" = "0|0" ]; then
    OK "el producto $PRODUCTO quedo como estaba (= $FINAL)"
else
    FALLA "el producto $PRODUCTO quedo en $FINAL"
fi

titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
if [ "$fallo" -gt 0 ]; then
    echo "  La nota del catalogo no esta llegando donde deberia."
    exit 1
fi
echo "  La nota alcanza a los productos que solo viven en Mongo, y se apaga"
echo "  cuando les borran la ultima resena."
exit 0
