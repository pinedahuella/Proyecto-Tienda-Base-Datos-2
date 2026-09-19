#!/usr/bin/env bash
# ============================================================
# El ETL de Mongo no le pasa por encima a lo que edita la aplicacion
# ============================================================
#
#   bash pruebas/etl_mongo.sh
#
# El backend edita el catalogo SOLO en Mongo (PATCH /vendedor/productos/:id) y
# anota cada edicion en productos_eventos. Hasta el 2026-09-18 etl/cargar.js
# hacia replaceOne del documento entero y borraba los eventos que PostgreSQL no
# conocia, asi que la siguiente corrida DESHACIA cada edicion, borraba su
# historial y se llevaba la bandera pendiente_busqueda. Esta prueba mide que eso
# ya no pasa, y que el ETL sigue haciendo lo que si le toca.
#
# NUNCA TOCA EL CATALOGO VIVO. Clona la base de Mongo con mongodump/mongorestore
# a `mesh_etl_prueba`, simula ahi lo que haria el backend, corre el ETL apuntado
# a la copia (MESH_MONGO_BASE, ver etl/correr.sh) y borra la copia al terminar.
# De PostgreSQL solo LEE: es la misma extraccion de siempre.
#
# Lo que se comprueba:
#
#   1. Un producto EDITADO desde la aplicacion conserva su nombre, sus
#      caracteristicas personalizadas y su evento; solo se le refrescan los
#      agregados, y eso lo marca para el buscador.
#   2. Un producto SIN editar sigue derivandose entero de PostgreSQL: el ETL
#      repara lo que alguien le haya manipulado.
#   3. Los 16 eventos de modificacion que ya hay en la base viva sobreviven.
#   4. Correrlo dos veces no marca nada nuevo para el buscador (no reindexa el
#      catalogo entero por nada).
#   5. La etapa de notas marca solo el producto cuya nota cambio.
#   6. EL MUTANTE. Se corre una copia de cargar.js con la regla apagada y se
#      comprueba que la prueba LA ATRAPA. Sin este paso, un arnes que nunca
#      pudiera fallar aprobaria igual.
#
# No instala nada: docker y las credenciales del .env. Corre de a uno: usa la
# base `mesh_etl_prueba` y los archivos /tmp del contenedor de Mongo.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
export MSYS_NO_PATHCONV=1

MONGO="${MONGO:-mesh-mongo}"
COPIA="mesh_etl_prueba"
EDITADO=20      # producto de PostgreSQL al que se le simula una edicion del backend
SIN_EDITAR=21   # producto de PostgreSQL al que solo se le manipula un dato
NOTA_A=3        # dos productos con resenas de verdad
NOTA_B=4
TEXTO_EDITADO="EDITADO DESDE LA APLICACION"
TEXTO_MANIPULADO="MANIPULADO A MANO"

ok=0; fallo=0
OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
igual() { if [ "$3" = "$2" ]; then OK "$1 ($3)"; else FALLA "$1 -- esperado $2, salio $3"; fi; }

# JavaScript a mongosh, contra la base que se diga. El JS entra por una variable
# de entorno para que pueda llevar comillas y $ sin que las shells se lo coman.
mongo() { # base, js
    docker exec -e JS="$2" -e BASE="$1" "$MONGO" sh -c 'mongosh --quiet \
        -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
        --authenticationDatabase admin "$BASE" --eval "$JS"' 2>&1 | tr -d '\r'
}
en_copia() { mongo "$COPIA" "$1"; }

clonar() {
    docker exec -e COPIA="$COPIA" "$MONGO" sh -c '
        mongodump -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
            --authenticationDatabase admin --db "$MONGO_INITDB_DATABASE" --archive --quiet \
        | mongorestore -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
            --authenticationDatabase admin --archive --quiet --drop \
            --nsFrom "$MONGO_INITDB_DATABASE.*" --nsTo "$COPIA.*"' >/dev/null 2>&1
}

borrar_copia() { en_copia 'db.dropDatabase()' >/dev/null 2>&1; }
trap borrar_copia EXIT INT TERM

# La corrida del ETL contra la copia. Devuelve lo que imprimio.
correr_etl() { MESH_MONGO_BASE="$COPIA" bash "$RAIZ/etl/correr.sh" "$@" 2>&1 | tr -d '\r'; }

# Lo que hace el backend al editar: un $set sobre el documento y un evento
# nuevo con el siguiente numero (productos.service.ts, crearEventoModificacion).
simular_edicion() { # id
    en_copia "
      const id = $1;
      const ult = db.productos_eventos.find({id_producto: id}).sort({numero: -1}).limit(1).toArray()[0].numero;
      db.productos.updateOne({_id: id}, {\$set: {
          nombre: '$TEXTO_EDITADO',
          caracteristicas_personalizadas: [{nombre: 'Extra', valor: 'Rojo', unidad: null}],
          stock_total: -7
      }});
      db.productos_eventos.insertOne({_id: id + '-' + (ult + 1), id_producto: id, numero: ult + 1,
          fecha: new Date(), operacion: 'modificacion', cambios: {nombre: '$TEXTO_EDITADO'}});
    " >/dev/null
}

# ============================================================
titulo "0. Que hay lo necesario"
# ============================================================
if ! docker exec "$MONGO" true 2>/dev/null; then
    FALLA "no esta el contenedor $MONGO"; exit 1
fi
OK "el contenedor de Mongo esta arriba"

clonar
n_copia=$(en_copia 'print(db.productos.countDocuments())')
n_vivo=$(mongo "$MONGO_DB" 'print(db.productos.countDocuments())')
igual "la copia tiene los mismos productos que la base viva" "$n_vivo" "$n_copia"

mod_antes=$(en_copia 'print(db.productos_eventos.countDocuments({operacion: "modificacion"}))')
echo "  (eventos de modificacion en la copia: $mod_antes)"

nombre_orig_sin=$(en_copia "print(db.productos.findOne({_id: $SIN_EDITAR}).nombre)")
stock_orig_ed=$(en_copia "print(db.productos.findOne({_id: $EDITADO}).stock_total)")
stock_orig_sin=$(en_copia "print(db.productos.findOne({_id: $SIN_EDITAR}).stock_total)")

# ============================================================
titulo "1. Una edicion de la aplicacion sobrevive al ETL"
# ============================================================
en_copia 'db.productos.updateMany({}, {$unset: {pendiente_busqueda: ""}})' >/dev/null
simular_edicion "$EDITADO"
en_copia "db.productos.updateOne({_id: $SIN_EDITAR}, {\$set: {nombre: '$TEXTO_MANIPULADO', stock_total: -9}})" >/dev/null

salida=$(correr_etl)
echo "$salida" | grep -E "^(productos|eventos|CONSERVADOS|buscador|notas|apagados)" | sed 's/^/  | /'

igual "el nombre editado se conserva" "$TEXTO_EDITADO" "$(en_copia "print(db.productos.findOne({_id: $EDITADO}).nombre)")"
igual "las caracteristicas personalizadas se conservan" 1 "$(en_copia "print((db.productos.findOne({_id: $EDITADO}).caracteristicas_personalizadas||[]).length)")"
igual "su evento de modificacion sigue ahi" 1 "$(en_copia "print(db.productos_eventos.countDocuments({id_producto: $EDITADO, cambios: {nombre: '$TEXTO_EDITADO'}}))")"
igual "el agregado que si viene de las ofertas se refresca (stock_total)" "$stock_orig_ed" "$(en_copia "print(db.productos.findOne({_id: $EDITADO}).stock_total)")"
igual "el producto editado queda marcado para el buscador" true "$(en_copia "print(db.productos.findOne({_id: $EDITADO}).pendiente_busqueda === true)")"
echo "$salida" | grep -q "^CONSERVADOS" && OK "el ETL dice cuantos conservo" || FALLA "el ETL no dijo que conservo productos editados"

# ============================================================
titulo "2. Un producto sin editar se sigue derivando de PostgreSQL"
# ============================================================
igual "el nombre manipulado a mano se repara" "$nombre_orig_sin" "$(en_copia "print(db.productos.findOne({_id: $SIN_EDITAR}).nombre)")"
igual "el stock manipulado se repara" "$stock_orig_sin" "$(en_copia "print(db.productos.findOne({_id: $SIN_EDITAR}).stock_total)")"
igual "y por haber cambiado, queda marcado para el buscador" true "$(en_copia "print(db.productos.findOne({_id: $SIN_EDITAR}).pendiente_busqueda === true)")"

# ============================================================
titulo "3. Los eventos que ya existian no se pierden"
# ============================================================
# La copia ya traia $mod_antes de modificacion, y la simulada suma una.
igual "eventos de modificacion, antes mas la simulada" $((mod_antes + 1)) \
    "$(en_copia 'print(db.productos_eventos.countDocuments({operacion: "modificacion"}))')"

# ============================================================
titulo "4. Correrlo otra vez no marca nada nuevo"
# ============================================================
pend1=$(en_copia 'print(db.productos.countDocuments({pendiente_busqueda: true}))')
salida2=$(correr_etl)
echo "$salida2" | grep -E "^buscador" | sed 's/^/  | /'
pend2=$(en_copia 'print(db.productos.countDocuments({pendiente_busqueda: true}))')
igual "los pendientes no crecen en la segunda corrida" "$pend1" "$pend2"
igual "las dos etapas dicen 0 marcados" 2 "$(echo "$salida2" | grep -c '^buscador    0 productos')"

# ============================================================
titulo "5. La nota marca solo el producto cuya nota cambio"
# ============================================================
en_copia 'db.productos.updateMany({}, {$unset: {pendiente_busqueda: ""}})' >/dev/null
prom_a=$(en_copia "print(db.productos.findOne({_id: $NOTA_A}).resenas_total)")
en_copia "db.productos.updateOne({_id: $NOTA_A}, {\$set: {resenas_total: 99}})" >/dev/null
salida3=$(correr_etl --notas)
echo "$salida3" | grep -E "^(notas|apagados|buscador)" | sed 's/^/  | /'
igual "la nota manipulada se repara" "$prom_a" "$(en_copia "print(db.productos.findOne({_id: $NOTA_A}).resenas_total)")"
igual "ese producto queda marcado" true "$(en_copia "print(db.productos.findOne({_id: $NOTA_A}).pendiente_busqueda === true)")"
igual "el otro producto con resenas NO se marca" false "$(en_copia "print(db.productos.findOne({_id: $NOTA_B}).pendiente_busqueda === true)")"

# ============================================================
titulo "6. El mutante: con la regla apagada, la prueba tiene que ponerse en rojo"
# ============================================================
clonar
en_copia 'db.productos.updateMany({}, {$unset: {pendiente_busqueda: ""}})' >/dev/null
simular_edicion "$EDITADO"
# La misma cargar.js, con "esta editado en Mongo" siempre en falso: vuelve al
# replaceOne de antes.
sed 's/const editadoEnMongo = previo !== undefined \&\&/const editadoEnMongo = false \&\&/' \
    "$RAIZ/etl/cargar.js" | docker exec -i "$MONGO" sh -c 'cat > /tmp/cargar_mutante.js'
docker exec -e BASE="$COPIA" "$MONGO" sh -c 'mongosh --quiet \
    -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin "$BASE" --file /tmp/cargar_mutante.js' >/dev/null 2>&1
docker exec "$MONGO" rm -f /tmp/cargar_mutante.js

nombre_mut=$(en_copia "print(db.productos.findOne({_id: $EDITADO}).nombre)")
if [ "$nombre_mut" != "$TEXTO_EDITADO" ]; then
    OK "con la regla apagada el nombre editado SE PIERDE, y la prueba lo ve ($nombre_mut)"
else
    FALLA "con la regla apagada el nombre editado sobrevivio: esta prueba no distingue nada"
fi
igual "y con la regla apagada tambien se borra el evento" 0 \
    "$(en_copia "print(db.productos_eventos.countDocuments({id_producto: $EDITADO, cambios: {nombre: '$TEXTO_EDITADO'}}))")"

# ============================================================
titulo "7. Limpieza"
# ============================================================
borrar_copia
trap - EXIT INT TERM
existe=$(mongo admin "print(db.getMongo().getDBNames().includes('$COPIA'))")
igual "la copia de prueba ya no existe" false "$existe"
igual "y el catalogo vivo no se movio" "$n_vivo" "$(mongo "$MONGO_DB" 'print(db.productos.countDocuments())')"

echo
echo "=============================================================="
echo "  $ok OK, $fallo FALLA"
echo "=============================================================="
[ "$fallo" -eq 0 ]
