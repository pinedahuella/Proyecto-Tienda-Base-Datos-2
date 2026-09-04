#!/usr/bin/env bash
# correr.sh
# Corre el ETL entero: extrae de PostgreSQL y carga en Mongo.
#
# En Windows se corre desde Git Bash, no desde PowerShell. PowerShell se come
# las comillas al llamar a docker y la consulta llega partida.
#
# No hay archivo intermedio en el disco: la salida de psql entra directo al
# contenedor de Mongo. La carpeta etl/ no esta montada en ningun contenedor,
# asi que los archivos se meten por la entrada estandar.

set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"

# Las credenciales salen del .env de la raiz, el mismo que lee docker compose.
set -a
. "$RAIZ/.env"
set +a

# Por defecto se extrae de la base del .env. Se puede pasar otra como
# argumento suelto, para correr el ETL contra una copia sin tocar la de
# trabajo.
#
#   ./etl/correr.sh              las tres etapas
#   ./etl/correr.sh --notas      SOLO la nota del catalogo
#   ./etl/correr.sh otra_base    las tres etapas contra otra base
#
# --notas es lo barato de correr a menudo, igual que --cola en el del grafo:
# toca dos campos de db.productos y no reconstruye ningun documento. Tarda un
# segundo en vez de trece. Sirve cuando lo unico que se movio son resenas.
#
# Lo que --notas NO hace es traer productos nuevos ni cambios de catalogo: para
# eso hay que correr las tres.

BASE="$DB_NAME"
SOLO_NOTAS=0

for ARG in "$@"; do
    case "$ARG" in
        --notas) SOLO_NOTAS=1 ;;
        -*)      echo "opcion desconocida: $ARG" >&2; exit 2 ;;
        *)       BASE="$ARG" ;;
    esac
done

# Son TRES consultas. Las dos primeras arman una coleccion cada una; la
# tercera no arma nada, refresca dos campos de db.productos que las otras dos
# no pueden alcanzar solas (etl/cargar_notas.js dice por que).
#
# Las OFERTAS no se migran: se quedan en PostgreSQL. Precio, stock y estado
# cambian en cada venta, y copiarlos aqui obligaria a sostenerlos al dia en dos
# bases a la vez. Lo que si viaja son cinco numeros agregados por producto
# (precio_tienda, stock_tienda, stock_total, total_ofertas), que los calcula
# extraer.sql y son los que la LISTA del catalogo necesita en cada tarjeta.
#
# Cada consulta devuelve una linea por documento; mezclarlas obligaria a marcar
# cada linea con su tipo y a separarlas otra vez del otro lado.
#
# -q sin mensajes, -t sin encabezado ni conteo de filas, -A sin relleno de
# columnas, -X ignorando el .psqlrc de quien lo corra. Lo que sale es JSON.

if [ "$SOLO_NOTAS" = "0" ]; then

    docker exec -i mesh-postgres \
        psql -U "$DB_USER" -d "$BASE" -qtAX -f - < "$RAIZ/etl/extraer.sql" \
        | docker exec -i mesh-mongo sh -c 'cat > /tmp/mesh-productos.json'

    docker exec -i mesh-postgres \
        psql -U "$DB_USER" -d "$BASE" -qtAX -f - < "$RAIZ/etl/extraer_categorias.sql" \
        | docker exec -i mesh-mongo sh -c 'cat > /tmp/mesh-categorias.json'

    docker exec -i mesh-mongo sh -c 'cat > /tmp/cargar.js' < "$RAIZ/etl/cargar.js"

    docker exec mesh-mongo sh -c 'mongosh --quiet \
        -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
        --authenticationDatabase admin "$MONGO_INITDB_DATABASE" \
        --file /tmp/cargar.js'

fi

# La TERCERA etapa, y va despues de cargar.js a proposito.
#
# cargar.js reemplaza cada documento entero, asi que si esto corriera antes se
# lo llevaria por delante. Y tiene que existir aparte porque cargar.js solo
# alcanza a los productos que tienen fila en PostgreSQL: la nota tambien es de
# los que solo viven en Mongo, y de los que se quedaron con una nota vieja
# despues de que les borraran la ultima resena. Ver etl/cargar_notas.js.

docker exec -i mesh-postgres \
    psql -U "$DB_USER" -d "$BASE" -qtAX -f - < "$RAIZ/etl/extraer_notas.sql" \
    | docker exec -i mesh-mongo sh -c 'cat > /tmp/mesh-notas.json'

docker exec -i mesh-mongo sh -c 'cat > /tmp/cargar_notas.js' < "$RAIZ/etl/cargar_notas.js"

docker exec mesh-mongo sh -c 'mongosh --quiet \
    -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin "$MONGO_INITDB_DATABASE" \
    --file /tmp/cargar_notas.js'
