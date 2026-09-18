#!/usr/bin/env bash
# pruebas/eventos.sh -- comprueba que la copia de eventos a ClickHouse trae lo
# que tiene que traer, y sobre todo que correrla dos veces no cuenta nada dos
# veces.
#
#   bash pruebas/eventos.sh
#
# AVISO, DESDE EL 2026-09-10: EL ORIGEN YA NO RECIBE LOGUEOS. El backend dejo de
# escribir log_login y log_registro; los logueos van ahora a la coleccion
# eventos_autenticacion de MongoDB (backend/src/services/log.service.ts). La
# copia que mide este arnes sigue leyendo esas dos tablas, asi que hoy solo le
# llegan las filas que el propio arnes siembra. Un verde aqui dice que la COPIA
# funciona, no que ClickHouse este al dia con los logueos de verdad. Al empezar
# se imprime la fecha del ultimo log_login real y la del ultimo login guardado
# en MongoDB, y cuantos hay en MongoDB despues de esa fecha, para que el hueco
# se vea con numeros. Lo que aprueba o reprueba no cambio.
#
# QUE PRUEBA, y por que hace falta un arnes propio
#
# El ETL de eventos (etl/cargar_eventos.sh) copia log_login y log_registro de
# PostgreSQL a evento_login y evento_registro de ClickHouse. Es la primera pieza
# del proyecto que COPIA en vez de proyectar, y eso cambia la clase de fallo que
# puede tener. El indice de busqueda se tira entero y se vuelve a hacer, asi que
# no puede acumular basura; aqui no, aqui se agrega, y una copia que se agrega
# tiene dos formas de mentir que no dan ningun error:
#
#   1. Correrla dos veces mete el mismo logueo dos veces. Nadie lo nota mirando
#      la pantalla, porque el numero que sale sigue siendo creible. Lo que se
#      rompe es el analisis de fraude, que es justo para lo que se trajo esta
#      base: una entrada normal repetida se vuelve una rafaga desde una IP que
#      nunca ocurrio, y el panel acusa a una cuenta de la semilla.
#   2. Quedarse corta y no alcanzar lo nuevo. El panel entonces ensena una foto
#      vieja con toda la confianza del mundo.
#
# Las dos se miden aqui, y la 1 es la razon de existir de este archivo.
#
# LA PARTE 1 ROMPE EL PROBLEMA ANTES DE MEDIRLO. Siembra la fila y comprueba que
# ESA fila NO esta todavia en ClickHouse. Sin ese paso, la parte 2 aprobaria
# igual con un ETL que no hace absolutamente nada, porque estaria mirando un
# destino que ya venia lleno de la corrida anterior. Es la misma idea que la
# parte 1 de pruebas/notas.sh.
#
# LA MARCA ES UNA IP, y sirve en las dos bases a la vez. Se siembra todo con
# ip_origen = 203.0.113.77, que es del rango que la RFC 5737 reserva para
# documentacion y por lo tanto no puede llegar de trafico de verdad. Ademas hoy
# los 317 logueos reales comparten UNA sola IP, 127.0.0.1, porque todo esto
# corre en local; asi que la marca no se confunde ni con lo real ni con lo que
# siembra el generador. Lo mismo del lado de ClickHouse, donde la fila copiada
# llega con esa misma IP y se reconoce sin guardar ningun id.
#
# TOCA LAS DOS BASES Y LAS DEJA COMO ESTABAN. Lo que siembra en PostgreSQL lo
# borra, y borra tambien su copia en ClickHouse. Lo que NO borra es la copia de
# los eventos de verdad que haya hecho el ETL, que es precisamente para lo que
# se corre y no es suciedad de la prueba.
#
# DE UNO EN UNO. Dos copias de esto a la vez no se pueden distinguir, porque la
# marca es la misma para las dos: cada una siembra con la misma IP, cada una
# corre el ETL, y las dos corridas del ETL se pisan y dejan la fila repetida.
# El 2026-09-06 paso de verdad y el arnes salio en rojo con el ETL bueno. Lo
# mismo vale para correr esto mientras alguien usa el portal, que escribe
# logueos de verdad en medio de la medicion. Si sale rojo, lo primero es mirar
# si habia algo mas corriendo, y despues volver a correrlo solo.
#
# No instala nada: docker y bash, que ya estan.

set -u

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PG="${PG:-mesh-postgres}"
PG_USUARIO="${PG_USUARIO:-meme}"
PG_BASE="${PG_BASE:-mesh}"
CH="${CH:-mesh-clickhouse}"

# Las credenciales de ClickHouse salen del .env de la raiz, el mismo que lee
# docker compose y el mismo del que las saca etl/cargar_grafo.sh.
#
# NINGUNA LLEVA VALOR POR DEFECTO, y eso es a proposito. La primera version de
# este archivo escribia la contrasena de VERDAD como respaldo de
# CLICKHOUSE_PASSWORD, y este archivo SI se sube al repositorio. Se descubrio
# buscando la clave del .env dentro de todo lo que iba a entrar en el commit,
# justo antes de subirlo.
#
# Y de paso, el arreglo tampoco puede citarla en el comentario. La primera
# version de ESTA nota la escribia entera para explicar el fallo, y la deja
# publicada igual que antes.
#
# Un valor por defecto en una credencial es peor que no tenerlo por dos motivos.
# El obvio es que la contrasena queda publicada. El otro es que tapa el error:
# en la maquina donde ese respaldo coincide con la clave real, el arnes funciona
# aunque el .env este mal, y el fallo solo aparece en la maquina del companero.
#
# Sin respaldo, si falta la variable el arnes se para y dice cual falta, que es
# lo mismo que hace redis/prueba_carrito.sh con REDIS_PASSWORD.
if [ -f "$RAIZ/.env" ]; then
    set -a
    . "$RAIZ/.env"
    set +a
fi
CH_USUARIO="${CLICKHOUSE_USER:-}"
CH_CLAVE="${CLICKHOUSE_PASSWORD:-}"
CH_BASE="${CLICKHOUSE_DB:-}"

if [ -z "$CH_USUARIO" ] || [ -z "$CH_CLAVE" ] || [ -z "$CH_BASE" ]; then
    echo "Faltan las credenciales de ClickHouse." >&2
    echo "Ponlas en el .env de la raiz o exportalas antes de correr esto:" >&2
    echo "   CLICKHOUSE_USER, CLICKHOUSE_PASSWORD, CLICKHOUSE_DB" >&2
    echo "Si acabas de actualizar el repositorio son variables NUEVAS, y tu .env" >&2
    echo "no viene en el pull. Copia esas tres lineas de .env.example." >&2
    exit 1
fi

# Git Bash convierte las rutas que empiezan con / al pasarlas a docker. Sin
# esto, cualquier "docker exec ... /tmp/algo" llega como ruta de Windows.
export MSYS_NO_PATHCONV=1

# La salida del ETL se guarda para poder ensenarla cuando falle, y va con
# nombre RELATIVO en vez de /tmp, que es la regla de pruebas/busqueda.sh. Se
# borra al terminar.
SALIDA="${SALIDA:-.mesh-eventos-salida.txt}"

ok=0; fallo=0

OK()    { echo "  OK    $1"; ok=$((ok+1)); }
FALLA() { echo "  FALLA $1"; fallo=$((fallo+1)); }
titulo(){ echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# La -q no es decorativa. Sin ella, un INSERT ... RETURNING devuelve DOS lineas
# -- el valor y el tag "INSERT 0 1" -- y la variable que lo recoge se lleva las
# dos. El siguiente INSERT recibe entonces un id partido y falla sin decir por
# que. Costo una corrida entera averiguarlo.
sql() { docker exec -i "$PG" psql -U "$PG_USUARIO" -d "$PG_BASE" -qtAc "$1" 2>/dev/null | tr -d '\r'; }

# Todo lo que sale de docker exec arrastra el retorno de carro de Windows. Con
# el pegado, un "317" no es igual a "317" y la comparacion falla ensenando dos
# numeros que en pantalla se ven identicos.
# LA ENTRADA ESTANDAR SE CIERRA A MANO, Y ESA LINEA NO ES UN ADORNO.
#
# `docker exec -i` deja la entrada estandar ABIERTA hacia el contenedor, y
# clickhouse-client con un `--query` que sea un INSERT ... VALUES no se conforma
# con los valores que van en la consulta: se queda esperando MAS filas por ahi.
# Si quien llamo al arnes no cierra su entrada -- una tarea en segundo plano, un
# `bash prueba.sh` sin redirigir, una tuberia que sigue viva -- el cliente espera
# para siempre.
#
# Medido el 2026-09-06: una corrida se quedo clavada y ClickHouse la ensenaba en
# system.processes con 459 segundos de `elapsed` sobre un
# `INSERT INTO vista_producto ... VALUES`. Sin error, sin mensaje, sin nada.
#
# Lo peor es que NO falla siempre: corriendo el arnes a mano en una terminal, la
# entrada da EOF enseguida y todo va bien. Solo se cuelga cuando se corre de una
# forma en la que esa entrada se queda abierta, que es justo como lo va a correr
# un guion de arranque o quien lo lance en segundo plano.
#
# Con `< /dev/null` el cliente recibe el fin de entrada de inmediato, se queda
# con los valores de la consulta y termina. Se pone en LOS DOS ayudantes, porque
# el problema es de la forma de llamar y no de lo que se consulta.
ch() {
    docker exec -i "$CH" clickhouse-client \
        --user "$CH_USUARIO" --password "$CH_CLAVE" --database "$CH_BASE" \
        --query "$1" < /dev/null 2>/dev/null | tr -d '\r'
}

# Para numeros se quitan ademas los espacios y el salto, que es lo que hace
# mongo_cuenta en pruebas/busqueda.sh y por el mismo motivo.
ch_num() { ch "$1" | tr -d ' \n'; }

# El borrado de ClickHouse es una MUTACION, y por defecto vuelve enseguida
# dejando el trabajo para despues. Sin --mutations_sync la comprobacion de la
# limpieza leeria la tabla antes de que el borrado se aplicara y diria que
# quedaron filas de prueba que en realidad estaban a medio irse.
ch_borrar() {
    docker exec -i "$CH" clickhouse-client \
        --user "$CH_USUARIO" --password "$CH_CLAVE" --database "$CH_BASE" \
        --mutations_sync 2 --query "$1" < /dev/null > /dev/null 2>&1
}

# ============================================================
# Limpieza, registrada ANTES de sembrar nada
# ============================================================
#
# Va en un trap para que se corra tambien si el script muere a la mitad. Una
# fila de prueba olvidada en log_login es peor aqui que en cualquier otro
# arnes: el ETL la copiaria a ClickHouse en la siguiente corrida de verdad y
# ahi quedaria, marcada como 'real', dibujando una IP que nunca existio dentro
# del analisis de fraude.
#
# Se borra por la MARCA y no por los ids que devolvieron los INSERT. Si el
# arnes muere justo entre el INSERT y la linea que recoge su id, esa variable
# esta vacia y una limpieza por id no borraria nada -- que es exactamente el
# caso en que mas falta hace. La marca los encuentra a todos, incluidos los que
# haya dejado una corrida anterior que murio.
#
# PostgreSQL va PRIMERO y ClickHouse despues. Al reves hay una ventana en la
# que la fila sigue en el origen y ya no esta en el destino, y un ETL corriendo
# en ese momento la volveria a copiar dejando lo que acabamos de borrar. Ni
# log_login ni log_registro tienen nada colgando de ellas, asi que entre esas
# dos el orden da igual; las dos son hojas y solo apuntan a usuarios, que no se
# toca.
MARCA_IP='203.0.113.77'
MARCA_PRODUCTO='999999999'

limpiar() {
    sql "DELETE FROM log_login    WHERE ip_origen = '$MARCA_IP';" > /dev/null
    sql "DELETE FROM log_registro WHERE ip_origen = '$MARCA_IP';" > /dev/null
    ch_borrar "ALTER TABLE evento_login    DELETE WHERE ip = '$MARCA_IP'"
    ch_borrar "ALTER TABLE evento_registro DELETE WHERE ip = '$MARCA_IP'"
    ch_borrar "ALTER TABLE vista_producto           DELETE WHERE id_producto = $MARCA_PRODUCTO"
    ch_borrar "ALTER TABLE vistas_por_producto_dia  DELETE WHERE id_producto = $MARCA_PRODUCTO"
    rm -f "$SALIDA"
}
trap limpiar EXIT

# ============================================================
# AVISO: el hueco entre log_login y los logueos de verdad
# ============================================================
#
# Solo informa. No suma OK ni FALLA y no para nada: lo que mide este arnes es
# la copia, y la copia sigue haciendo lo suyo con lo que le den. Pero quien lea
# un verde tiene que saber que desde el 2026-09-10 lo que le dan es solo lo que
# siembra el arnes. El JavaScript entra por una variable de entorno, como en
# pruebas/alertas_login.sh, para que las comillas lleguen enteras.
MONGO="${MONGO:-mesh-mongo}"
mongo_aviso() {
    docker exec -e JS="$1" "$MONGO" sh -c 'mongosh --quiet \
        -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
        --authenticationDatabase admin "$MONGO_INITDB_DATABASE" --eval "$JS"' 2>/dev/null | tr -d '\r\n'
}

ULTIMO_LOG=$(sql "SELECT to_char(max(fecha_login) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')
                    FROM log_login WHERE ip_origen IS DISTINCT FROM '$MARCA_IP'")
FILAS_LOG=$(sql "SELECT count(*) FROM log_login WHERE ip_origen IS DISTINCT FROM '$MARCA_IP'")
ULTIMO_EV=$(mongo_aviso 'const e = db.eventos_autenticacion.find({tipo: "login"}).sort({fecha: -1}).limit(1).toArray()[0];
    print(e ? e.fecha.toISOString().slice(0, 19).replace("T", " ") : "ninguno")')
if [ -n "$ULTIMO_LOG" ]; then
    DESPUES=$(mongo_aviso 'print(db.eventos_autenticacion.countDocuments({tipo: "login", fecha: {$gt: new Date("'"${ULTIMO_LOG/ /T}"'Z")}}))')
else
    DESPUES=$(mongo_aviso 'print(db.eventos_autenticacion.countDocuments({tipo: "login"}))')
fi

titulo "AVISO: log_login ya no recibe logueos desde el 2026-09-10"
echo "  El backend los guarda en eventos_autenticacion de MongoDB. Lo que este"
echo "  arnes copia a ClickHouse es solo lo que el mismo siembra."
echo
echo "    ultimo log_login real            ${ULTIMO_LOG:-ninguno} UTC  ($FILAS_LOG filas)"
echo "    ultimo login en MongoDB          ${ULTIMO_EV:-no se pudo leer} UTC"
echo "    logins en MongoDB despues de esa fecha: ${DESPUES:-no se pudo leer}  <- ClickHouse no los ve"
echo
echo "  Un verde aqui dice que la copia funciona, no que ClickHouse este al dia."
echo "  Lo arregla repuntar etl/cargar_eventos.sh a MongoDB, que esta pendiente."

# ============================================================
# 0. Que haya con que trabajar
# ============================================================
titulo "0. LAS TABLAS ESTAN Y SON LAS DEL ESQUEMA"

if [ "$(ch_num 'SELECT 1')" != "1" ]; then
    echo "  ClickHouse no contesta en el contenedor $CH"
    echo "  Levantalo con  docker compose up -d clickhouse"
    exit 1
fi

if [ ! -f "$RAIZ/etl/cargar_eventos.sh" ]; then
    echo "  No existe etl/cargar_eventos.sh, que es lo que este arnes prueba."
    echo "  Sin el no hay nada que medir, y aprobar igual seria mentir, asi que"
    echo "  se para aqui."
    exit 1
fi

# Las columnas se comparan una por una contra lo que dice clickhouse/001_esquema.sql.
#
# No es una comprobacion de adorno. El ETL escribe columna por columna, y un
# esquema que cambio de tipo por debajo -- una IPv6 que alguien paso a String,
# un lote que dejo de ser LowCardinality -- hace que la carga falle o, peor,
# que entre mal callada. Que el arnes traiga escrito el contrato hace que el
# fallo salga aqui, con el nombre de la columna, en vez de tres partes mas
# abajo con una cuenta que no cuadra.
esperado_vista_producto=$(cat <<'TXT'
fecha DateTime64(3)
id_producto UInt64
id_usuario Nullable(UInt64)
sesion String
ip IPv6
origen LowCardinality(String)
lote LowCardinality(String)
TXT
)

esperado_evento_login=$(cat <<'TXT'
fecha DateTime64(3)
id_usuario UInt64
ip IPv6
tipo LowCardinality(String)
lote LowCardinality(String)
id_log_login UInt64
TXT
)

esperado_evento_registro=$(cat <<'TXT'
fecha DateTime64(3)
id_usuario UInt64
ip IPv6
id_log_registro UInt64
lote LowCardinality(String)
TXT
)

esperado_resumen=$(cat <<'TXT'
dia Date
id_producto UInt64
lote LowCardinality(String)
vistas AggregateFunction(count, UInt64)
sesiones AggregateFunction(uniq, String)
TXT
)

columnas() { ch "DESCRIBE TABLE $1 FORMAT TSV" | cut -f1,2 | tr '\t' ' '; }

comprobar_tabla() {
    _tabla="$1"
    _esperado="$2"
    _real=$(columnas "$_tabla")
    if [ -z "$_real" ]; then
        FALLA "la tabla $_tabla no existe en $CH_BASE"
        echo "        Corre  .\\arrancar.ps1  que aplica clickhouse/001_esquema.sql"
        return
    fi
    if [ "$_real" = "$_esperado" ]; then
        OK "$_tabla tiene las columnas del esquema"
    else
        FALLA "$_tabla no tiene las columnas del esquema"
        echo "        tiene"
        echo "$_real" | sed 's/^/          /'
        echo "        se esperaba"
        echo "$_esperado" | sed 's/^/          /'
    fi
}

comprobar_tabla vista_producto          "$esperado_vista_producto"
comprobar_tabla evento_login            "$esperado_evento_login"
comprobar_tabla evento_registro         "$esperado_evento_registro"
comprobar_tabla vistas_por_producto_dia "$esperado_resumen"

# El motor no es un detalle de implementacion, es la mitad de la parte 3. Si
# alguien cambiara evento_login a MergeTree, la tabla seguiria teniendo las
# mismas columnas y el mismo aspecto, y perderia en silencio lo unico que la
# protege de contar un evento dos veces.
MOTOR=$(ch "SELECT engine FROM system.tables WHERE database = '$CH_BASE' AND name = 'evento_login' FORMAT TSV")
if [ "$MOTOR" = "ReplacingMergeTree" ]; then
    OK "evento_login usa ReplacingMergeTree, que es lo que colapsa la fila repetida"
else
    FALLA "evento_login usa $MOTOR y no ReplacingMergeTree"
fi

HAY_MV=$(ch_num "SELECT count() FROM system.tables WHERE database = '$CH_BASE' AND name = 'vistas_por_producto_dia_mv'")
if [ "$HAY_MV" = "1" ]; then
    OK "la vista materializada vistas_por_producto_dia_mv existe"
else
    FALLA "no existe la vista materializada vistas_por_producto_dia_mv"
fi

if [ "$fallo" -gt 0 ]; then
    echo
    echo "  El terreno no esta como dice clickhouse/001_esquema.sql."
    echo "  Lo de abajo mediria sobre una base distinta a la del contrato, asi"
    echo "  que se para aqui."
    exit 1
fi

# ============================================================
# 1. LO QUE VAMOS A MEDIR NO ESTA TODAVIA EN EL DESTINO
# ============================================================
titulo "1. Se siembra un logueo y ClickHouse todavia no lo tiene"

# Esta es la parte que hace que las demas signifiquen algo.
#
# Sin ella, la parte 2 diria OK con un ETL que no copia nada, siempre que
# alguien hubiera corrido el de verdad ayer: las cuentas cuadrarian por la
# corrida vieja y el arnes estaria aprobando algo que ya funcionaba antes de
# tocar nada. Aqui se comprueba primero que la fila sembrada NO esta al otro
# lado, y solo entonces se corre el ETL.

USUARIO=$(sql "SELECT min(id_usuario) FROM usuarios")
if [ -z "$USUARIO" ]; then
    echo "  No hay ni una cuenta en la tabla usuarios."
    echo "  Corre  .\\arrancar.ps1 -Reiniciar  y vuelve a probar."
    exit 1
fi

# Antes de sembrar, que la marca este limpia de las dos bases. Si una corrida
# anterior murio y dejo algo, todas las cuentas de abajo saldrian corridas y el
# motivo no se veria por ningun lado.
SOBRAS_PG=$(sql "SELECT count(*) FROM log_login WHERE ip_origen = '$MARCA_IP'")
SOBRAS_CH=$(ch_num "SELECT count() FROM evento_login WHERE ip = '$MARCA_IP'")
if [ "$SOBRAS_PG" = "0" ] && [ "$SOBRAS_CH" = "0" ]; then
    OK "la marca $MARCA_IP no aparece en ninguna de las dos bases (= $SOBRAS_PG y $SOBRAS_CH)"
else
    FALLA "la marca $MARCA_IP ya estaba puesta, $SOBRAS_PG en PostgreSQL y $SOBRAS_CH en ClickHouse"
    echo "        Lo dejo una corrida que murio a la mitad. Borralas con"
    echo "        DELETE FROM log_login WHERE ip_origen = '$MARCA_IP';"
    echo "        ALTER TABLE evento_login DELETE WHERE ip = '$MARCA_IP';"
    exit 1
fi

ID_LOGIN_A=$(sql "INSERT INTO log_login (id_usuario, id_tipo_login, ip_origen)
                  VALUES ($USUARIO, 1, '$MARCA_IP')
                  RETURNING id_log_login")

if [ -n "$ID_LOGIN_A" ]; then
    OK "logueo sembrado en PostgreSQL (id_log_login $ID_LOGIN_A, cuenta $USUARIO)"
else
    FALLA "no se pudo sembrar el logueo en log_login"
    exit 1
fi

EN_DESTINO=$(ch_num "SELECT count() FROM evento_login WHERE id_log_login = $ID_LOGIN_A")
if [ "$EN_DESTINO" = "0" ]; then
    OK "ese id_log_login todavia no existe en evento_login (= $EN_DESTINO)"
else
    FALLA "el id_log_login $ID_LOGIN_A ya estaba en ClickHouse antes de correr el ETL"
    echo "        Entonces lo de abajo no mediria la copia, mediria una copia vieja."
    exit 1
fi

# ============================================================
# 2. LA COPIA CUADRA CON EL ORIGEN
# ============================================================
titulo "2. Se corre el ETL y las dos bases dicen el mismo numero"

if bash "$RAIZ/etl/cargar_eventos.sh" > "$SALIDA" 2>&1; then
    OK "etl/cargar_eventos.sh termino bien"
else
    FALLA "etl/cargar_eventos.sh salio con codigo $?"
    tail -15 "$SALIDA" | sed 's/^/        /'
fi

# El FINAL importa. ReplacingMergeTree colapsa las filas repetidas cuando le
# toca hacer una fusion, no en el momento de insertarlas, asi que un count() a
# secas puede ver dos copias del mismo evento durante un rato largo. FINAL
# obliga a leerlo ya colapsado, que es lo que de verdad va a contestar una
# consulta del panel escrita con cuidado.
#
# Y se cuenta solo lo que lleva lote = 'real', porque lo generado por
# clickhouse/lote no sale de PostgreSQL y no tiene por que cuadrar con nada.
cuenta_login()    { ch_num "SELECT count() FROM evento_login    FINAL WHERE lote = 'real'"; }
cuenta_registro() { ch_num "SELECT count() FROM evento_registro FINAL WHERE lote = 'real'"; }

PG_LOGIN=$(sql "SELECT count(*) FROM log_login")
CH_LOGIN=$(cuenta_login)
if [ "$PG_LOGIN" = "$CH_LOGIN" ]; then
    OK "log_login y evento_login dicen lo mismo (= $CH_LOGIN)"
else
    FALLA "log_login tiene $PG_LOGIN filas y evento_login tiene $CH_LOGIN reales"
fi

PG_REGISTRO=$(sql "SELECT count(*) FROM log_registro")
CH_REGISTRO=$(cuenta_registro)
if [ "$PG_REGISTRO" = "$CH_REGISTRO" ]; then
    OK "log_registro y evento_registro dicen lo mismo (= $CH_REGISTRO)"
else
    FALLA "log_registro tiene $PG_REGISTRO filas y evento_registro tiene $CH_REGISTRO reales"
fi

# Y que la fila concreta que sembramos sea una de esas. Las cuentas pueden
# cuadrar por casualidad si el ETL copiara otras tantas filas equivocadas.
#
# Se cuenta aparte de leerla, y el LIMIT 1 no sobra. Si la fila entro dos veces
# -- pasa de verdad, medido el 2026-09-06 con dos copias del ETL corriendo a la
# vez -- la lectura devuelve DOS lineas, se meten enteras en el mensaje y lo que
# sale por pantalla es un FALLA partido en dos que no se entiende. El numero de
# copias se dice con su propio numero.
COPIAS_A=$(ch_num "SELECT count() FROM evento_login WHERE id_log_login = $ID_LOGIN_A")
LLEGO=$(ch "SELECT tipo, lote FROM evento_login WHERE id_log_login = $ID_LOGIN_A LIMIT 1 FORMAT TSV" | tr '\t' ' ')
if [ "$COPIAS_A" = "1" ] && [ "$LLEGO" = "login real" ]; then
    OK "la fila sembrada llego una vez, con su tipo y con lote real (= $LLEGO)"
else
    FALLA "la fila sembrada aparece $COPIAS_A vez/veces y dice '$LLEGO', se esperaba una sola 'login real'"
fi

# ============================================================
# 3. CORRERLO DOS VECES NO DUPLICA
# ============================================================
titulo "3. Se corre otra vez sin sembrar nada y no se repite ni una fila"

# Esta es la comprobacion por la que existe este archivo.
#
# Se miran DOS numeros y no uno, porque cuentan cosas distintas:
#
#   CRUDAS      count() a secas. Son las filas que hay escritas.
#   DISTINTAS   uniqExact(id_log_login). Son los eventos de origen que hay.
#
# Lo que importa es la RESTA de las dos, que es cuantas filas sobran. Y se mira
# la resta y no el crecimiento de CRUDAS, porque el crecimiento se mueve solo
# por dos motivos que no son una duplicacion, y los dos se midieron el
# 2026-09-06 sobre las bases vivas:
#
#   Sube      porque entro un logueo nuevo en PostgreSQL mientras esto corria
#             -- alguien usando el portal, otra prueba sembrando, el backend --
#             y el ETL lo copio, que es lo que tiene que hacer.
#   Baja      porque ReplacingMergeTree fusiono durante la corrida y colapso
#             filas repetidas que ya venian de antes.
#
# La resta no se mueve con ninguno de los dos. Un logueo nuevo suma uno a las
# dos cuentas y una fusion solo baja lo que ya sobraba. Sube unicamente cuando
# esta corrida escribio una fila que ya estaba, que es exactamente el fallo.
#
# Y que sobre una fila importa aunque el motor la vaya a colapsar despues.
# Entre el INSERT y la fusion, que puede tardar, cualquier consulta escrita sin
# FINAL cuenta ese evento dos veces, y ahi es donde nace la rafaga de fraude
# desde una IP que nunca ocurrio.
CRUDAS_ANTES=$(ch_num    "SELECT count() FROM evento_login WHERE lote = 'real'")
DISTINTAS_ANTES=$(ch_num "SELECT uniqExact(id_log_login) FROM evento_login WHERE lote = 'real'")
ORIGEN_ANTES=$(sql "SELECT count(*) FROM log_login")

bash "$RAIZ/etl/cargar_eventos.sh" > "$SALIDA" 2>&1

CRUDAS_DESPUES=$(ch_num    "SELECT count() FROM evento_login WHERE lote = 'real'")
DISTINTAS_DESPUES=$(ch_num "SELECT uniqExact(id_log_login) FROM evento_login WHERE lote = 'real'")
ORIGEN_DESPUES=$(sql "SELECT count(*) FROM log_login")

# Los :-0 no sobran. Si un contenedor se cae justo aqui, la variable llega
# VACIA y una resta sobre nada no es cero, es un error de sintaxis de bash que
# mata el arnes entero en la parte mas importante. Con el 0 la comparacion
# falla, que es lo que tiene que pasar, y el mensaje sale.
SOBRAN_ANTES=$((   ${CRUDAS_ANTES:-0}   - ${DISTINTAS_ANTES:-0} ))
SOBRAN_DESPUES=$(( ${CRUDAS_DESPUES:-0} - ${DISTINTAS_DESPUES:-0} ))
CRECIO_ORIGEN=$((  ${ORIGEN_DESPUES:-0} - ${ORIGEN_ANTES:-0} ))
CRECIO_DISTINTAS=$(( ${DISTINTAS_DESPUES:-0} - ${DISTINTAS_ANTES:-0} ))

if [ "$SOBRAN_DESPUES" = "0" ]; then
    OK "no sobra ni una fila en evento_login, $CRUDAS_DESPUES escritas para $DISTINTAS_DESPUES eventos"
elif [ "$SOBRAN_DESPUES" -gt "$SOBRAN_ANTES" ]; then
    FALLA "esta corrida dejo $SOBRAN_DESPUES fila(s) de sobra donde antes habia $SOBRAN_ANTES"
    echo "        El ETL esta volviendo a copiar lo que ya estaba. Aunque"
    echo "        ReplacingMergeTree lo colapse mas tarde, hasta que fusione"
    echo "        cualquier consulta sin FINAL cuenta esos eventos dos veces."
    echo "        Mira por donde reanuda etl/cargar_eventos.sh."
else
    FALLA "en evento_login sobran $SOBRAN_DESPUES fila(s), y ya sobraban antes de esta corrida"
    echo "        No las metio la corrida que se acaba de hacer, asi que esta"
    echo "        comprobacion no midio lo suyo. Pasa si dos copias del ETL"
    echo "        corrieron a la vez. Espera a que el motor fusione, o fuerzalo"
    echo "        con  OPTIMIZE TABLE evento_login FINAL;  y vuelve a correr esto."
fi

# El otro lado del mismo tiro. Que no sobre nada dice que no hay filas de mas,
# y esto dice que tampoco DESAPARECIO ninguna. Las dos hacen falta: una copia
# que borra lo que ya tenia tampoco duplica, y no por eso esta bien.
if [ "$DISTINTAS_ANTES" = "$DISTINTAS_DESPUES" ]; then
    OK "siguen siendo los mismos eventos de origen (= $DISTINTAS_DESPUES)"
elif [ "$CRECIO_ORIGEN" -gt 0 ] && [ "$CRECIO_DISTINTAS" = "$CRECIO_ORIGEN" ]; then
    echo "  (entraron $CRECIO_ORIGEN logueo(s) nuevos en PostgreSQL mientras esto"
    echo "   corria y el ETL los copio, que es lo que tiene que hacer.)"
else
    FALLA "los eventos distintos pasaron de $DISTINTAS_ANTES a $DISTINTAS_DESPUES"
fi

# El mismo tiro sobre la fila que sembramos nosotros, que es la que sabemos que
# entro en la corrida anterior y por lo tanto la candidata numero uno a entrar
# otra vez.
REPETIDA=$(ch_num "SELECT count() FROM evento_login WHERE id_log_login = $ID_LOGIN_A")
if [ "$REPETIDA" = "1" ]; then
    OK "el logueo sembrado sigue estando una sola vez (= $REPETIDA)"
else
    FALLA "el logueo sembrado aparece $REPETIDA veces en evento_login"
fi

# Y que el registro tampoco se haya movido.
CH_REGISTRO_2=$(cuenta_registro)
if [ "$CH_REGISTRO_2" = "$CH_REGISTRO" ]; then
    OK "evento_registro tampoco cambio con la segunda corrida (= $CH_REGISTRO_2)"
else
    FALLA "evento_registro paso de $CH_REGISTRO a $CH_REGISTRO_2 sin que naciera ningun registro"
fi

# ============================================================
# 4. LO NUEVO SI LLEGA, Y --solo-logueos SE QUEDA EN LOS LOGUEOS
# ============================================================
titulo "4. Una fila nueva alcanza la siguiente corrida"

# Que no duplique es la mitad del trabajo. La otra mitad es que siga trayendo,
# y las dos se rompen desde el mismo sitio: un ETL que se pasa de listo con el
# punto por donde reanuda se queda corto, y uno que no reanuda duplica. Por eso
# van pegadas.
ID_LOGIN_B=$(sql "INSERT INTO log_login (id_usuario, id_tipo_login, ip_origen)
                  VALUES ($USUARIO, 2, '$MARCA_IP')
                  RETURNING id_log_login")

ID_REGISTRO_B=$(sql "INSERT INTO log_registro (id_usuario, ip_origen)
                     VALUES ($USUARIO, '$MARCA_IP')
                     RETURNING id_log_registro")

if [ -n "$ID_LOGIN_B" ] && [ -n "$ID_REGISTRO_B" ]; then
    OK "sembrados un logueo mas y un registro (ids $ID_LOGIN_B y $ID_REGISTRO_B)"
else
    FALLA "no se pudieron sembrar las filas nuevas"
    exit 1
fi

if bash "$RAIZ/etl/cargar_eventos.sh" --solo-logueos > "$SALIDA" 2>&1; then
    OK "etl/cargar_eventos.sh --solo-logueos termino bien"
else
    FALLA "etl/cargar_eventos.sh --solo-logueos salio con codigo $?"
    tail -15 "$SALIDA" | sed 's/^/        /'
fi

# El cero y el dos son fallos distintos y se cuentan distinto. Decirle "no
# llego" a una fila que llego dos veces manda a quien lea esto a buscar al lado
# contrario del problema.
NUEVO_LOGIN=$(ch_num "SELECT count() FROM evento_login WHERE id_log_login = $ID_LOGIN_B")
if [ "$NUEVO_LOGIN" = "1" ]; then
    OK "el logueo nuevo llego en la corrida siguiente (= $NUEVO_LOGIN)"
elif [ "$NUEVO_LOGIN" = "0" ]; then
    FALLA "el logueo $ID_LOGIN_B no llego a evento_login (= $NUEVO_LOGIN)"
    echo "        El incremental no alcanza lo que se escribio despues de la"
    echo "        ultima corrida, que es la otra forma de mentir de una copia."
    echo "        La salida de esa corrida decia"
    tail -8 "$SALIDA" | sed 's/^/          /'
    echo "        Si ahi pone que no habia nada pendiente, la marca de agua del"
    echo "        destino se fue por delante de PostgreSQL. Pasa si alguien"
    echo "        estuvo escribiendo en log_login o borrando de evento_login"
    echo "        mientras esto corria, y tambien si el generador de"
    echo "        clickhouse/lote sembro filas con lote real."
else
    FALLA "el logueo $ID_LOGIN_B llego $NUEVO_LOGIN veces, se esperaba una sola"
    echo "        Llego, pero repetido. Es el mismo fallo de la parte 3 visto"
    echo "        sobre una fila concreta. Si esto sale con la parte 3 en verde,"
    echo "        mira si habia dos copias del ETL corriendo a la vez."
fi

# El otro lado del filtro. Sin esto, el OK de arriba pasaria igual con un
# --solo-logueos que en realidad copia las dos cosas, y la opcion no estaria
# haciendo nada.
NUEVO_REGISTRO=$(ch_num "SELECT count() FROM evento_registro WHERE id_log_registro = $ID_REGISTRO_B")
if [ "$NUEVO_REGISTRO" = "0" ]; then
    OK "y --solo-logueos dejo el registro donde estaba (= $NUEVO_REGISTRO)"
else
    FALLA "--solo-logueos copio tambien el registro $ID_REGISTRO_B ($NUEVO_REGISTRO fila(s))"
fi

# Ahora la corrida entera, que si tiene que traerlo.
bash "$RAIZ/etl/cargar_eventos.sh" > "$SALIDA" 2>&1

TRAS_COMPLETA=$(ch_num "SELECT count() FROM evento_registro WHERE id_log_registro = $ID_REGISTRO_B")
if [ "$TRAS_COMPLETA" = "1" ]; then
    OK "la corrida completa si trajo el registro (= $TRAS_COMPLETA)"
else
    FALLA "el registro $ID_REGISTRO_B aparece $TRAS_COMPLETA veces tras la corrida completa"
    tail -8 "$SALIDA" | sed 's/^/          /'
fi

PG_LOGIN_3=$(sql "SELECT count(*) FROM log_login")
CH_LOGIN_3=$(cuenta_login)
PG_REGISTRO_3=$(sql "SELECT count(*) FROM log_registro")
CH_REGISTRO_3=$(cuenta_registro)
if [ "$PG_LOGIN_3" = "$CH_LOGIN_3" ] && [ "$PG_REGISTRO_3" = "$CH_REGISTRO_3" ]; then
    OK "y las dos bases vuelven a cuadrar (= $CH_LOGIN_3 logueos y $CH_REGISTRO_3 registros)"
else
    FALLA "tras las siembras quedo $PG_LOGIN_3 contra $CH_LOGIN_3 y $PG_REGISTRO_3 contra $CH_REGISTRO_3"
fi

# ============================================================
# 5. LA VISTA MATERIALIZADA SE LLENA SOLA
# ============================================================
titulo "5. El resumen por dia sube sin que nadie corra nada"

# Lo que se mide aqui es que el resumen NO necesita ETL. En Cassandra esto
# seria un proceso aparte que hay que acordarse de correr, y la senal de que se
# quedo parado es un panel que ensena numeros viejos sin quejarse. Aqui lo hace
# la base en el mismo INSERT, y esta parte lo comprueba sin llamar a nada entre
# el insert y la lectura.
#
# El producto de la prueba es el 999999999, que no existe en el catalogo. Asi
# el resumen que se lea solo puede venir de estas dos filas.
RESUMEN_ANTES=$(ch_num "SELECT count() FROM vistas_por_producto_dia WHERE id_producto = $MARCA_PRODUCTO")
if [ "$RESUMEN_ANTES" = "0" ]; then
    OK "el resumen no tiene todavia nada del producto $MARCA_PRODUCTO (= $RESUMEN_ANTES)"
else
    FALLA "el resumen ya tenia $RESUMEN_ANTES fila(s) del producto de prueba"
    echo "        Lo dejo una corrida anterior. Borralas con"
    echo "        ALTER TABLE vistas_por_producto_dia DELETE WHERE id_producto = $MARCA_PRODUCTO;"
fi

# Dos vistas del mismo producto y el mismo dia, de dos sesiones distintas, una
# de cada lote. Con esto se miden las dos cosas de un tiro: que el resumen se
# llena solo, y que el lote lo parte en dos.
ch "INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen, lote) VALUES
    (now64(3), $MARCA_PRODUCTO, NULL, 'prueba-eventos-a', '$MARCA_IP', 'prueba', 'real'),
    (now64(3), $MARCA_PRODUCTO, NULL, 'prueba-eventos-b', '$MARCA_IP', 'prueba', 'generado')" > /dev/null

VISTAS_REAL=$(ch_num "SELECT countMerge(vistas) FROM vistas_por_producto_dia WHERE id_producto = $MARCA_PRODUCTO AND lote = 'real'")
if [ "$VISTAS_REAL" = "1" ]; then
    OK "sin correr nada, el resumen ya cuenta la vista real (= $VISTAS_REAL)"
else
    FALLA "el resumen cuenta $VISTAS_REAL vistas reales, se esperaba 1"
    echo "        La vista materializada no se esta disparando en el INSERT."
    echo "        Mira si vistas_por_producto_dia_mv sigue apuntando a la tabla."
fi

# countMerge y uniqMerge no son la misma pregunta, y confundirlas es el error
# clasico con AggregatingMergeTree. Una sesion que mira cien veces son cien
# vistas y UNA sesion, y el panel de tendencia se cae del lado que se elija.
SESIONES=$(ch_num "SELECT uniqMerge(sesiones) FROM vistas_por_producto_dia WHERE id_producto = $MARCA_PRODUCTO AND lote = 'real'")
if [ "$SESIONES" = "1" ]; then
    OK "y cuenta una sola sesion distinta para ese lote (= $SESIONES)"
else
    FALLA "el resumen dice $SESIONES sesiones distintas, se esperaba 1"
fi

# ============================================================
# 6. LA COLUMNA LOTE SEPARA LO REAL DE LO GENERADO
# ============================================================
titulo "6. Lo generado no se suma con lo medido"

# Si el lote no estuviera en la clave del resumen, las dos filas de arriba
# caerian en la misma celda y quedaria un 2 del que ya no se puede sacar que
# mitad se invento un script. Es la unica pregunta que de verdad hay que poder
# contestar cuando alguien mire el panel.
PARTIDO=$(ch "SELECT lote, countMerge(vistas) FROM vistas_por_producto_dia
              WHERE id_producto = $MARCA_PRODUCTO GROUP BY lote ORDER BY lote FORMAT TSV" | tr '\t' ' ' | tr '\n' '|')
if [ "$PARTIDO" = "generado 1|real 1|" ]; then
    OK "el resumen guarda las dos vistas en celdas distintas por lote (= $PARTIDO)"
else
    FALLA "el resumen quedo como '$PARTIDO', se esperaba 'generado 1|real 1|'"
fi

# Y del lado de la copia: todo lo que trajo el ETL tiene que decir 'real'. Lo
# comprueba comparando contra PostgreSQL, que es el unico que sabe cuantos
# eventos de verdad hay. Si el ETL marcara alguno como generado, la cuenta de
# arriba se quedaria corta; si marcara como real algo que se invento, se
# pasaria. Las dos salen del mismo numero.
GENERADOS=$(ch_num "SELECT count() FROM evento_login FINAL WHERE lote != 'real'")
REALES=$(cuenta_login)
PG_AHORA=$(sql "SELECT count(*) FROM log_login")
if [ "$REALES" = "$PG_AHORA" ]; then
    OK "lo marcado como real es exactamente lo que hay en log_login (= $REALES, y $GENERADOS generado(s) aparte)"
else
    FALLA "hay $REALES filas reales en ClickHouse y $PG_AHORA en log_login"
fi

# ============================================================
# LIMPIEZA
# ============================================================
titulo "LIMPIEZA"

limpiar

QUEDAN_PG=$(sql "SELECT (SELECT count(*) FROM log_login    WHERE ip_origen = '$MARCA_IP')
                      + (SELECT count(*) FROM log_registro WHERE ip_origen = '$MARCA_IP')")
if [ "$QUEDAN_PG" = "0" ]; then
    OK "no quedo ninguna fila de prueba en PostgreSQL (= $QUEDAN_PG)"
else
    FALLA "quedaron $QUEDAN_PG fila(s) con la marca $MARCA_IP en PostgreSQL"
fi

QUEDAN_CH=$(ch_num "SELECT (SELECT count() FROM evento_login    WHERE ip = '$MARCA_IP')
                         + (SELECT count() FROM evento_registro WHERE ip = '$MARCA_IP')
                         + (SELECT count() FROM vista_producto  WHERE id_producto = $MARCA_PRODUCTO)
                         + (SELECT count() FROM vistas_por_producto_dia WHERE id_producto = $MARCA_PRODUCTO)")
if [ "$QUEDAN_CH" = "0" ]; then
    OK "no quedo ninguna fila de prueba en ClickHouse (= $QUEDAN_CH)"
else
    FALLA "quedaron $QUEDAN_CH fila(s) de prueba en ClickHouse"
fi

# Y que las dos bases queden cuadradas, ya sin nada sembrado. Es la foto con la
# que se va el arnes, y la que va a encontrar el siguiente que corra esto.
PG_FINAL=$(sql "SELECT count(*) FROM log_login")
CH_FINAL=$(cuenta_login)
if [ "$PG_FINAL" = "$CH_FINAL" ]; then
    OK "las dos bases quedan cuadradas (= $CH_FINAL logueos)"
else
    FALLA "quedaron $PG_FINAL logueos en PostgreSQL y $CH_FINAL en ClickHouse"
    echo "        Corre  bash etl/cargar_eventos.sh  y vuelve a mirar."
fi

titulo "RESULTADO"
echo "  $ok OK, $fallo FALLA"
if [ "$fallo" -gt 0 ]; then
    echo "  La copia de eventos no esta haciendo lo que se dijo."
    exit 1
fi
echo "  La copia trae lo mismo que hay en PostgreSQL, correrla dos veces no"
echo "  repite ni una fila, lo nuevo alcanza la corrida siguiente y el resumen"
echo "  por dia se mantiene solo."
exit 0
