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

# Por defecto se extrae de la base del .env. Se puede pasar otra como primer
# argumento, para correr el ETL contra una copia sin tocar la de trabajo.
BASE="${1:-$DB_NAME}"

# Son DOS consultas y dos archivos, uno por coleccion.
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
