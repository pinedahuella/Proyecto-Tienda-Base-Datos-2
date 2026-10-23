#!/usr/bin/env bash
# prueba_acceso.sh -- la evidencia del control de acceso en todas las bases.
#
# El enunciado de la Entrega final pide autenticacion y autorizacion en al menos
# un componente NoSQL, "con evidencia de que un usuario sin los permisos
# correspondientes no puede ejecutar operaciones fuera de su alcance". Redis lo
# tiene desde la primera version (redis/prueba_acceso.sh, que esto tambien
# corre). Desde el 2026-10-23 lo tienen PostgreSQL, MongoDB, ClickHouse y
# Elasticsearch, y aqui se prueba cada uno. Los usuarios los crea arrancar.ps1
# (paso 9f) con los archivos de esta carpeta. Neo4j no puede, y la parte 5 deja
# la respuesta de Neo4j como evidencia.
#
# Cada negativa tiene su control. Que mesh_lectura no pueda escribir solo
# significa algo si mesh_backend si puede escribir lo mismo, y que mesh_backend
# no pueda borrar una tabla solo significa algo si el dueno si puede. Sin el
# control, una base caida haria pasar todas las negativas.
#
# NO cambia ni borra nada de la tienda. Lo que borraria algo si la configuracion
# estuviera mal se intenta dentro de una transaccion que se deshace
# (PostgreSQL), sobre un objeto que no existe (MongoDB, ClickHouse,
# Elasticsearch), o se le pregunta antes a la base si lo dejaria pasar.
#
# Uso:  bash seguridad/prueba_acceso.sh

set -u
export MSYS_NO_PATHCONV=1

DIR="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "$DIR/.." && pwd)"
leer_env() { grep -E "^$1=" "$RAIZ/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r'; }
for v in DB_USER DB_NAME PG_BACKEND_PASSWORD PG_LECTURA_PASSWORD \
         MONGO_DB MONGO_BACKEND_PASSWORD MONGO_LECTURA_PASSWORD \
         CLICKHOUSE_DB CLICKHOUSE_USER CLICKHOUSE_PASSWORD CLICKHOUSE_BACKEND_PASSWORD CLICKHOUSE_LECTURA_PASSWORD \
         ELASTIC_PASSWORD ELASTIC_BACKEND_PASSWORD ELASTIC_LECTURA_PASSWORD KIBANA_PASSWORD NEO4J_PASSWORD; do
    [ -n "${!v:-}" ] || printf -v "$v" '%s' "$(leer_env "$v")"
    if [ -z "${!v}" ]; then
        echo "Falta $v en el .env. Corre .\\arrancar.ps1, que la agrega y crea los usuarios." >&2
        exit 1
    fi
done
ES="${ES:-http://localhost:9200}"

ok=0; fallo=0
bien() { ok=$((ok+1)); printf '  OK     %s\n' "$1"; }
mal()  { fallo=$((fallo+1)); printf '  FALLA  %s  (salio: %s)\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-220)"; }
# deja QUE SALIDA     la operacion paso
deja() { case "$2" in *rror*|*ERROR*|*denied*|*Denied*|*nauthorized*|*NOT_ENOUGH*|*ACCESS_DENIED*|*REQUIRED_PASSWORD*|*AUTHENTICATION_FAILED*|*"authentication fail"*) mal "$1" "$2";; *) bien "$1";; esac; }
# niega QUE SALIDA PATRON     la base contesto que no, con ese patron
niega() { if printf '%s' "$2" | grep -Eq "$3"; then bien "$1"; else mal "$1" "$2"; fi; }

# ------------------------------------------------------------------
echo "1. PostgreSQL"
# Se entra por la red de Docker (-h postgres) y no por el socket de adentro, que
# tiene confianza sin contrasena y haria pasar cualquier clave.
pg() { local u="$1" p="$2"; shift 2
       docker exec -e PGPASSWORD="$p" mesh-postgres psql -h postgres -U "$u" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tAq "$@" 2>&1 | tr -d '\r'; }
pg_dueno() { docker exec mesh-postgres psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -tAq "$@" 2>&1 | tr -d '\r'; }

[ "$(pg mesh_backend "$PG_BACKEND_PASSWORD" -c 'SELECT current_user')" = "mesh_backend" ] \
    && bien "mesh_backend entra con su contrasena" || mal "mesh_backend entra con su contrasena" "$(pg mesh_backend "$PG_BACKEND_PASSWORD" -c 'SELECT current_user')"
niega "mesh_backend no entra con otra contrasena" "$(pg mesh_backend "x$PG_BACKEND_PASSWORD" -c 'SELECT 1')" 'password authentication failed|autentificaci'
niega "mesh_backend no es superusuario ni crea bases ni usuarios" \
    "$(pg mesh_backend "$PG_BACKEND_PASSWORD" -c "SELECT rolsuper::text || rolcreatedb::text || rolcreaterole::text FROM pg_roles WHERE rolname = current_user")" '^falsefalsefalse$'
deja "mesh_backend lee pedidos" "$(pg mesh_backend "$PG_BACKEND_PASSWORD" -c 'SELECT count(*) FROM pedido')"
# UPDATE ... WHERE false: PostgreSQL revisa el permiso al planear, sin tocar filas
deja "mesh_backend puede cambiar pedidos (sin tocar ninguno)" \
    "$(pg mesh_backend "$PG_BACKEND_PASSWORD" -c 'UPDATE pedido SET id_pedido = id_pedido WHERE false')"
deja "control: el dueno crea una tabla (y se deshace)" \
    "$(pg_dueno -c 'BEGIN' -c 'CREATE TABLE prueba_acceso_tmp (x int)' -c 'ROLLBACK')"
niega "mesh_backend NO crea tablas" \
    "$(pg mesh_backend "$PG_BACKEND_PASSWORD" -c 'BEGIN' -c 'CREATE TABLE prueba_acceso_tmp (x int)' -c 'ROLLBACK')" 'permission denied|permiso denegado'
niega "mesh_backend NO borra tablas (en una transaccion que se deshace)" \
    "$(pg mesh_backend "$PG_BACKEND_PASSWORD" -c 'BEGIN' -c 'DROP TABLE pedido_producto' -c 'ROLLBACK')" 'must be owner|debe ser dueño|debe ser due'
niega "mesh_backend NO vacia tablas con TRUNCATE (idem)" \
    "$(pg mesh_backend "$PG_BACKEND_PASSWORD" -c 'BEGIN' -c 'TRUNCATE pedido_producto' -c 'ROLLBACK')" 'permission denied|permiso denegado'
niega "mesh_backend NO crea usuarios" \
    "$(pg mesh_backend "$PG_BACKEND_PASSWORD" -c 'CREATE ROLE prueba_acceso_tmp')" 'permission denied|permiso denegado'
deja "mesh_lectura lee pedidos" "$(pg mesh_lectura "$PG_LECTURA_PASSWORD" -c 'SELECT count(*) FROM pedido')"
niega "mesh_lectura NO cambia pedidos" \
    "$(pg mesh_lectura "$PG_LECTURA_PASSWORD" -c 'UPDATE pedido SET id_pedido = id_pedido WHERE false')" 'permission denied|permiso denegado|read-only|solo lectura'

# ------------------------------------------------------------------
echo "2. MongoDB"
mg() { local u="$1" p="$2" js="$3"
       docker exec mesh-mongo mongosh --quiet -u "$u" -p "$p" --authenticationDatabase admin "$MONGO_DB" --eval "$js" 2>&1 | tr -d '\r'; }
mg_root() { docker exec mesh-mongo sh -c 'mongosh --quiet -u $MONGO_INITDB_ROOT_USERNAME -p $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin $MONGO_INITDB_DATABASE --eval "$0"' "$1" 2>&1 | tr -d '\r'; }
# Para lo que pide una respuesta de error, sin que mongosh corte el script
intento() { printf 'try { const r = %s; print("PASO " + JSON.stringify(r)) } catch (e) { print("NEGADO " + e.codeName + " " + e.message) }' "$1"; }

deja "mesh_backend entra y cuenta productos" "$(mg mesh_backend "$MONGO_BACKEND_PASSWORD" 'print(db.productos.countDocuments())')"
niega "mesh_backend no entra con otra contrasena" "$(mg mesh_backend "x$MONGO_BACKEND_PASSWORD" 'print(1)')" 'Authentication failed'
niega "mesh_backend puede cambiar productos (sobre un id que no existe)" \
    "$(mg mesh_backend "$MONGO_BACKEND_PASSWORD" "$(intento "db.productos.updateOne({_id: -424242}, {\$set: {prueba: 1}})")")" '^PASO'
niega "control: root si puede crear un indice (en una coleccion que no existe)" \
    "$(mg_root "$(intento "db.prueba_acceso_tmp.createIndex({x: 1})")")" '^PASO'
mg_root 'db.prueba_acceso_tmp.drop()' >/dev/null
niega "mesh_backend NO crea indices" \
    "$(mg mesh_backend "$MONGO_BACKEND_PASSWORD" "$(intento "db.prueba_acceso_tmp.createIndex({x: 1})")")" 'NEGADO Unauthorized'
niega "mesh_backend NO borra colecciones (una que no existe)" \
    "$(mg mesh_backend "$MONGO_BACKEND_PASSWORD" "$(intento "db.prueba_acceso_tmp.drop()")")" 'NEGADO Unauthorized'
niega "mesh_backend NO lee los usuarios de la base admin" \
    "$(mg mesh_backend "$MONGO_BACKEND_PASSWORD" "$(intento "db.getSiblingDB('admin').system.users.findOne()")")" 'NEGADO Unauthorized'
niega "mesh_backend NO crea usuarios" \
    "$(mg mesh_backend "$MONGO_BACKEND_PASSWORD" "$(intento "db.getSiblingDB('admin').createUser({user: 'prueba_acceso_tmp', pwd: 'x', roles: []})")")" 'NEGADO Unauthorized'
mg_root "$(intento "db.prueba_acceso_tmp.drop()")" >/dev/null
deja "mesh_lectura (DbGate) lee productos" "$(mg mesh_lectura "$MONGO_LECTURA_PASSWORD" 'print(db.productos.countDocuments())')"
niega "mesh_lectura NO cambia productos" \
    "$(mg mesh_lectura "$MONGO_LECTURA_PASSWORD" "$(intento "db.productos.updateOne({_id: -424242}, {\$set: {prueba: 1}})")")" 'NEGADO Unauthorized'

# ------------------------------------------------------------------
echo "3. ClickHouse"
ch() { local u="$1" p="$2" q="$3"
       docker exec mesh-clickhouse clickhouse-client --user "$u" --password "$p" --database "$CLICKHOUSE_DB" --query "$q" 2>&1 | tr -d '\r'; }

deja "mesh_backend entra y cuenta las vistas de producto" "$(ch mesh_backend "$CLICKHOUSE_BACKEND_PASSWORD" 'SELECT count() FROM vista_producto')"
niega "mesh_backend no entra con otra contrasena" "$(ch mesh_backend "x$CLICKHOUSE_BACKEND_PASSWORD" 'SELECT 1')" 'AUTHENTICATION_FAILED|Authentication failed|password is incorrect'
deja "mesh_backend puede agregar eventos (agrega cero filas)" \
    "$(ch mesh_backend "$CLICKHOUSE_BACKEND_PASSWORD" 'INSERT INTO vista_producto SELECT * FROM vista_producto WHERE 0')"
deja "control: el usuario del ETL ve los usuarios" "$(ch "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" 'SELECT count() FROM system.users')"
niega "mesh_backend NO ve los usuarios" "$(ch mesh_backend "$CLICKHOUSE_BACKEND_PASSWORD" 'SELECT count() FROM system.users')" 'ACCESS_DENIED|Not enough privileges'
niega "mesh_backend NO borra eventos" \
    "$(ch mesh_backend "$CLICKHOUSE_BACKEND_PASSWORD" 'ALTER TABLE vista_producto DELETE WHERE 0')" 'ACCESS_DENIED|Not enough privileges'
niega "mesh_backend NO crea tablas" \
    "$(ch mesh_backend "$CLICKHOUSE_BACKEND_PASSWORD" 'CREATE TABLE prueba_acceso_tmp (x UInt8) ENGINE = Memory')" 'ACCESS_DENIED|Not enough privileges'
# ClickHouse dice "no existe" antes de mirar el permiso, asi que la tabla se crea
# de verdad (vacia y en memoria) para que el intento llegue al permiso.
ch "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" 'CREATE TABLE IF NOT EXISTS prueba_acceso_tmp (x UInt8) ENGINE = Memory' >/dev/null
niega "mesh_backend NO borra tablas (una vacia, hecha para esto)" \
    "$(ch mesh_backend "$CLICKHOUSE_BACKEND_PASSWORD" 'DROP TABLE prueba_acceso_tmp')" 'ACCESS_DENIED|Not enough privileges'
ch "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" 'DROP TABLE IF EXISTS prueba_acceso_tmp' >/dev/null
niega "mesh_backend NO crea usuarios" \
    "$(ch mesh_backend "$CLICKHOUSE_BACKEND_PASSWORD" "CREATE USER prueba_acceso_tmp IDENTIFIED BY 'x1234567'")" 'ACCESS_DENIED|Not enough privileges'
deja "mesh_lectura lee las vistas de producto" "$(ch mesh_lectura "$CLICKHOUSE_LECTURA_PASSWORD" 'SELECT count() FROM vista_producto')"
niega "mesh_lectura NO agrega eventos" \
    "$(ch mesh_lectura "$CLICKHOUSE_LECTURA_PASSWORD" 'INSERT INTO vista_producto SELECT * FROM vista_producto WHERE 0')" 'ACCESS_DENIED|Not enough privileges'
niega "el usuario default de fabrica no entra sin contrasena" \
    "$(docker exec mesh-clickhouse clickhouse-client --user default --query 'SELECT 1' 2>&1)" 'AUTHENTICATION_FAILED|Authentication failed|password is incorrect|REQUIRED_PASSWORD|no user with such name'

# ------------------------------------------------------------------
echo "4. Elasticsearch"
# es USUARIO:CLAVE METODO RUTA [CUERPO]   el codigo HTTP
es() { local a="$1" m="$2" r="$3" c="${4:-}"
       if [ -n "$a" ]; then
           curl -s -o /dev/null -w '%{http_code}' -u "$a" -X "$m" "$ES$r" -H 'Content-Type: application/json' ${c:+-d "$c"}
       else
           curl -s -o /dev/null -w '%{http_code}' -X "$m" "$ES$r" -H 'Content-Type: application/json' ${c:+-d "$c"}
       fi; }
codigo() { case "$2" in "$3") bien "$1";; *) mal "$1" "HTTP $2, se esperaba $3";; esac; }
B="mesh_backend:$ELASTIC_BACKEND_PASSWORD"; L="mesh_lectura:$ELASTIC_LECTURA_PASSWORD"; S="elastic:$ELASTIC_PASSWORD"

codigo "sin usuario no se entra" "$(es '' GET /_cluster/health)" 401
codigo "con otra contrasena no se entra" "$(es "mesh_backend:x$ELASTIC_BACKEND_PASSWORD" GET /_cluster/health)" 401
codigo "kibana_system entra con la suya" "$(es "kibana_system:$KIBANA_PASSWORD" GET /_security/_authenticate)" 200
codigo "mesh_backend busca en mesh_productos" "$(es "$B" POST /mesh_productos/_search '{"size":0}')" 200
# _update sobre un id que no existe: 404 quiere decir que tenia permiso y no lo encontro
codigo "mesh_backend puede escribir en mesh_productos (id que no existe, 404)" \
    "$(es "$B" POST /mesh_productos/_update/prueba-acceso-no-existe '{"doc":{"x":1}}')" 404
PRIV=$(curl -s -u "$B" "$ES/_security/user/_has_privileges" -H 'Content-Type: application/json' \
    -d '{"index":[{"names":["mesh_productos"],"privileges":["delete_index","create_index","manage"]}]}')
case "$PRIV" in *'"has_all_requested":false'*) bien "Elasticsearch dice que mesh_backend no puede crear ni borrar indices";;
               *) mal "Elasticsearch dice que mesh_backend no puede crear ni borrar indices" "$PRIV";; esac
codigo "control: elastic ve un indice que no existe (404)" "$(es "$S" GET /mesh_prueba_acceso_no_existe)" 404
codigo "mesh_backend NO borra indices (uno que no existe)" "$(es "$B" DELETE /mesh_prueba_acceso_no_existe)" 403
codigo "mesh_backend NO crea indices" "$(es "$B" PUT /mesh_prueba_acceso_no_existe)" 403
es "$S" DELETE /mesh_prueba_acceso_no_existe >/dev/null
codigo "mesh_backend NO lee indices que no son de la tienda (.kibana)" "$(es "$B" POST /.kibana/_search '{"size":0}')" 403
codigo "mesh_backend NO administra usuarios" "$(es "$B" GET /_security/user)" 403
codigo "mesh_lectura busca en mesh_productos" "$(es "$L" POST /mesh_productos/_search '{"size":0}')" 200
codigo "mesh_lectura NO escribe en mesh_productos" "$(es "$L" POST /mesh_productos/_update/prueba-acceso-no-existe '{"doc":{"x":1}}')" 403

# ------------------------------------------------------------------
echo "5. Neo4j (edicion community, sin roles)"
cy() { docker exec mesh-neo4j cypher-shell -u neo4j -p "$1" -d "${2:-neo4j}" "$3" 2>&1 | tr -d '\r'; }
deja "neo4j entra con su contrasena" "$(cy "$NEO4J_PASSWORD" neo4j 'RETURN 1')"
niega "neo4j no entra con otra contrasena" "$(cy "x$NEO4J_PASSWORD" neo4j 'RETURN 1')" 'unauthorized|Unauthorized|credentials'
EDICION=$(cy "$NEO4J_PASSWORD" system 'CALL dbms.components() YIELD edition RETURN edition')
ROL=$(cy "$NEO4J_PASSWORD" system 'CREATE ROLE mesh_backend_rol')
case "$ROL" in
    *nsupported*|*nterprise*|*not\ available*|*"no longer supported"*)
        bien "Neo4j se niega a crear un rol: es la edicion $(printf '%s' "$EDICION" | tail -1)"
        echo "         Neo4j contesto: $(printf '%s' "$ROL" | head -2 | tr '\n' ' ')"
        echo "         Por eso Neo4j es la unica base con un solo usuario. Ver docs/SEGURIDAD.md.";;
    *) mal "Neo4j se niega a crear un rol" "$ROL"
       cy "$NEO4J_PASSWORD" system 'DROP ROLE mesh_backend_rol IF EXISTS' >/dev/null;;
esac

# ------------------------------------------------------------------
echo "6. Redis (redis/prueba_acceso.sh)"
SALIDA_REDIS=$(bash "$RAIZ/redis/prueba_acceso.sh" 2>&1)
printf '%s\n' "$SALIDA_REDIS" | sed 's/^/  /'
ok=$((ok + $(printf '%s\n' "$SALIDA_REDIS" | grep -c '^  OK')))
fallo=$((fallo + $(printf '%s\n' "$SALIDA_REDIS" | grep -c '^  FALLA')))

echo
echo "RESULTADO: $ok OK, $fallo FALLA"
[ "$fallo" -eq 0 ]
