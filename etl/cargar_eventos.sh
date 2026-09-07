#!/usr/bin/env bash
# cargar_eventos.sh
# Copia los eventos de PostgreSQL a ClickHouse: `log_login` a `evento_login` y
# `log_registro` a `evento_registro`.
#
# En Windows se corre desde Git Bash, no desde PowerShell. Es la misma razon
# que dicen correr.sh y cargar_grafo.sh: PowerShell se come las comillas al
# llamar a docker y la consulta llega partida.
#
# Uso:
#   bash etl/cargar_eventos.sh                   copia lo nuevo de las dos tablas
#   bash etl/cargar_eventos.sh --solo-logueos    solo log_login
#   bash etl/cargar_eventos.sh --solo-registros  solo log_registro
#   bash etl/cargar_eventos.sh --ayuda           esto mismo
#
# Las dos banderas de "solo" existen para poder mirar una tabla a la vez cuando
# algo no cuadra. En la corrida normal no se usan: las dos copias son baratas y
# separarlas por costumbre es como se llega a una de las dos vieja.
#
#
# ES UNA COPIA, NO UNA MUDANZA
# ============================================================
# Las dos tablas se quedan enteras en PostgreSQL. Alla es donde `id_usuario`
# tiene una llave foranea contra `usuarios` con ON DELETE RESTRICT, y eso es lo
# que impide que quede un evento apuntando a una cuenta que ya no existe.
# ClickHouse no tiene llaves foraneas y no puede sostener esa integridad.
# Lo que gana a cambio es la pregunta por IP, que es la senal de fraude que ni
# el indice de PostgreSQL ni el grafo contestan: el grafo sabe que dos cuentas
# se califican entre si, pero no sabe que las dos entran desde la misma casa.
#
#
# LO QUE ESTE SCRIPT TIENE MIEDO DE VERDAD
# ============================================================
# No es fallar. Es TERMINAR EN CERO HABIENDO COPIADO NADA.
#
# Una base de eventos vacia no se nota nunca. No hay pantalla que se rompa, no
# hay error, no hay un hueco visible en ninguna parte: las consultas de fraude
# corren perfectamente contra cero filas y contestan "no hay cuentas anomalas",
# que es una respuesta creible, tranquilizadora y falsa. El dia de la entrega
# nadie va a poder distinguir eso de un sistema limpio.
#
# Por eso aqui hay tres guardas y no una sola, copiadas de cargar_busqueda.sh:
#   1. ClickHouse tiene que contestar ANTES de escribir nada.
#   2. Si PostgreSQL tiene filas nuevas y el destino no crecio, es mortal.
#   3. Al final se cuentan las dos puntas y se dice si cuadran. Si no, exit 1.
# La numero 3 es la que importa: es la unica que mide el RESULTADO en vez de
# mirar si los pasos parecieron ir bien.
#
#
# LA MARCA DE AGUA VIVE EN EL DESTINO, Y AQUI SI SE PUEDE
# ============================================================
# El ETL del grafo lleva su marca de agua en una tabla de cola de PostgreSQL
# (`evento_grafo`, la del outbox de la migracion 015) porque alla la fuente
# CAMBIA: una resena se edita y se borra. Un id mayor no dice nada sobre si la
# resena numero 3 se toco esta manana, asi que hace falta que alguien apunte
# expresamente que fila quedo sucia, y eso lo hace un trigger.
#
# Aqui la fuente es un LOG. `log_login` y `log_registro` son inmutables y solo
# crecen: nadie edita un logueo que ya paso y nadie lo borra, porque el evento
# ya ocurrio y cambiarlo seria mentir sobre el pasado. Con esa propiedad, "el
# mayor id que ya copie" es una marca de agua COMPLETA -- todo lo que falta
# esta por encima, y nada de lo que esta por debajo pudo cambiar.
#
# Y por eso puede vivir en el destino en vez de en una tabla aparte, que es lo
# que la vuelve a prueba de descuidos: si alguien tira el volumen de ClickHouse,
# la marca se va CON los datos y la siguiente corrida vuelve a copiar todo sola.
# Una marca guardada en PostgreSQL habria sobrevivido al borrado, y el ETL
# habria seguido copiando desde el id 317 sobre una tabla vacia, dejandola vacia
# para siempre sin dar un solo error. Ese es exactamente el fallo del parrafo de
# arriba, y guardar la marca donde estan los datos lo hace imposible.
#
# LO QUE ESTA MARCA NO PUEDE HACER, dicho antes de que muerda: solo mira hacia
# adelante. Si alguien BORRA una fila de `log_login` que ya se copio, la copia
# de ClickHouse se queda con ella para siempre, porque nada por debajo de la
# marca se vuelve a mirar. No es teorico -- el 2026-09-06, corriendo esto, una
# prueba de otra pieza dejo y quito la fila 322 en mitad de la tarde.
#
# Se asume a proposito, y el precio esta bien elegido: lo peor que produce es
# un evento de MAS en el destino, nunca uno de menos. Un evento de mas se ve
# solo, porque el conteo del final deja de cuadrar y lo dice; uno de menos es
# el que no se nota. Cuando pase, se vacia lo que tenga lote='real' en la tabla
# de destino y la siguiente corrida lo trae todo otra vez desde cero.
#
#
# CORRERLO DOS VECES NO PUEDE DUPLICAR NADA, Y NO ES POR EL MOTOR
# ============================================================
# Es tentador decir que da igual repetir porque las dos tablas de destino son
# ReplacingMergeTree. No da igual. ReplacingMergeTree colapsa las filas que
# comparten la clave de orden, pero SOLO cuando le toca fusionar partes, que es
# cuando ClickHouse quiere y no cuando termina el INSERT. Entre medias, un
# `count()` cuenta las repetidas y una rafaga que nunca existio aparece en el
# panel de fraude. El motor es la red de seguridad, no el mecanismo.
#
# El mecanismo es la marca de agua: lo que ya se copio no se vuelve a pedir. La
# segunda corrida seguida encuentra cero pendientes y no manda ni una fila.

set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"

# Las credenciales salen del .env de la raiz, el mismo que lee docker compose.
# CLICKHOUSE_PASSWORD sale de ahi tambien: no se escribe en este archivo, que
# si se sube al repositorio.
set -a
. "$RAIZ/.env"
set +a

# La trampa de Git Bash.
#
# Git Bash sobre Windows convierte las rutas que empiezan con `/` al pasarselas
# a un programa. El `-f /dev/stdin` de mas abajo es de DENTRO del contenedor de
# PostgreSQL, pero Git lo reescribe antes de que docker lo vea y psql termina
# buscando `C:/Program Files/Git/dev/stdin`. El error que sale no menciona ni a
# Git ni a docker, dice que no encuentra el archivo, y se pierde media tarde.
#
# Es la misma esquiva de cargar_busqueda.sh, y aqui es segura por el mismo
# motivo que alla: con el parche puesto no viaja NINGUNA ruta de Windows como
# argumento. Lo local entra por la entrada estandar (`< `), que la maneja bash.
export MSYS_NO_PATHCONV=1

HACER_LOGIN=1
HACER_REGISTRO=1

for ARG in "$@"; do
    case "$ARG" in
        --solo-logueos)   HACER_REGISTRO=0 ;;
        --solo-registros) HACER_LOGIN=0 ;;
        --ayuda|-h)
            # La ayuda se lee de la cabecera de este mismo archivo en vez de
            # repetirse en un echo. Dos textos que dicen lo mismo se separan a
            # la primera bandera nueva, y el que miente es siempre el de abajo.
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        # Cualquier otra cosa se para en seco en vez de ignorarse. Una bandera
        # mal escrita que el script se traga corre la copia COMPLETA callado, y
        # quien la tecleo se queda creyendo que hizo lo que pidio.
        *) echo "Opcion desconocida: $ARG" >&2; exit 2 ;;
    esac
done


# ------------------------------------------------------------------
# Los dos clientes, que ya viven dentro de sus contenedores
# ------------------------------------------------------------------
# La regla de etl/README.md es "No hay nada que instalar", y aqui se cumple
# igual que en los otros ETL: no hace falta un psql ni un cliente de ClickHouse
# en la maquina, se usan los que trae cada imagen.
#
# Ninguno de los dos ayudantes lleva `docker exec -i`, y es a proposito: `-i`
# engancha la entrada estandar del script, y un ayudante que se la come dentro
# de un bucle o de una tuberia se lleva por delante lo que venia detras. Los
# unicos `-i` de este archivo estan en la tuberia de carga, donde hacen falta.

pg() {
    docker exec mesh-postgres \
        psql -U "$DB_USER" -d "$DB_NAME" -qtAX -v ON_ERROR_STOP=1 -c "$1" \
        | tr -d '[:space:]'
}

ch() {
    docker exec mesh-clickhouse clickhouse-client \
        --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
        --database "$CLICKHOUSE_DB" --query "$1" \
        | tr -d '[:space:]'
}


# ------------------------------------------------------------------
# 0. Que ClickHouse este de verdad ahi
# ------------------------------------------------------------------
# Se pregunta ANTES de leer la marca de agua, y ese orden es el que importa.
# Un cliente que no conecta devuelve texto vacio por la salida estandar, el
# `tr` lo deja en nada, y "nada" en la marca de agua se lee como "no he copiado
# nunca". La copia arrancaria desde cero contra una base que no contesta.
if ! ch "SELECT 1" > /dev/null 2>&1; then
    echo "ClickHouse no contesta en el contenedor mesh-clickhouse" >&2
    echo "Levantalo con:  docker compose up -d clickhouse" >&2
    exit 1
fi

# Y que el esquema este aplicado. Si las tablas no existen, todo lo de abajo
# falla igual, pero con un error de ClickHouse sobre una tabla desconocida que
# no le dice a nadie que lo que falta es correr clickhouse/001_esquema.sql.
if [ "$(ch "EXISTS TABLE evento_login")" != "1" ] \
   || [ "$(ch "EXISTS TABLE evento_registro")" != "1" ]; then
    echo "Faltan las tablas de eventos en ClickHouse." >&2
    echo "Aplica primero clickhouse/001_esquema.sql (lo hace arrancar.ps1)." >&2
    exit 1
fi


# ------------------------------------------------------------------
# La copia de una tabla
# ------------------------------------------------------------------
# Las dos copias son la misma operacion contra tablas casi gemelas, asi que va
# una sola vez aqui. Los argumentos son, en orden:
#
#   1  1 si es log_login, 0 si es log_registro (lo entiende el \if del .sql)
#   2  como se llama esto cuando se le habla a una persona
#   3  la tabla de ClickHouse
#   4  la tabla de PostgreSQL
#   5  la columna del id de origen, que se llama igual en las dos puntas
#   6  la lista de columnas del INSERT
#
# EL ARGUMENTO 6 ES UN CONTRATO CON extraer_eventos.sql. TabSeparated es
# posicional y no lleva nombres de columna: si el orden de aqui deja de coincidir
# con el del SELECT de alla, ClickHouse no protesta, mete el id en la fecha y
# guarda basura con cara de dato. Las dos listas estan escritas en el mismo
# orden para que se puedan comparar de un vistazo.
copiar() {
    local ES_LOGIN="$1" NOMBRE="$2" TABLA_CH="$3" TABLA_PG="$4" COL_ID="$5" COLUMNAS="$6"
    local DESDE ANTES DESPUES PENDIENTES ENTRARON

    echo "==> $NOMBRE"

    # La marca de agua, preguntada al propio destino.
    #
    # El filtro por lote='real' no es cosmetico. La otra mitad de esta tabla la
    # siembra el generador de clickhouse/lote con lote='generado', y esas filas
    # llevan ids que no significan nada en PostgreSQL. Sin el filtro, un id
    # inventado mas alto empujaria la marca hacia adelante y esta copia se
    # saltaria logueos REALES para siempre, sin dar un error.
    #
    # max() sobre un conjunto vacio devuelve 0 en ClickHouse, que es justo lo
    # que hace falta: una tabla recien creada arranca la copia desde el
    # principio sin ningun caso especial.
    DESDE="$(ch "SELECT max($COL_ID) FROM $TABLA_CH WHERE lote = 'real'")"

    # uniqExact y no count() para medir lo que ya hay.
    #
    # ReplacingMergeTree colapsa las filas repetidas cuando fusiona partes, no
    # cuando termina el INSERT, asi que un count() puede estar contando filas
    # que ya son la misma y que van a desaparecer solas mas tarde. Contar ids
    # DISTINTOS da el mismo numero antes y despues de la fusion, que es la
    # unica forma de que la comparacion del final signifique algo.
    ANTES="$(ch "SELECT uniqExact($COL_ID) FROM $TABLA_CH WHERE lote = 'real'")"

    # Cuanto tendria que entrar Y HASTA DONDE, preguntados a la FUENTE en UNA
    # SOLA consulta y antes de tocar nada.
    #
    # Los dos numeros salen juntos a proposito, y no en dos consultas seguidas.
    # Esta tabla crece por debajo mientras esto corre: el portal esta vivo y cada
    # persona que entra escribe una fila. Si la cuenta y el tope vinieran de dos
    # vistazos distintos, entre uno y otro cabria una fila nueva y volveriamos a
    # tener justo el descuadre que el tope existe para cerrar.
    #
    # PENDIENTES es lo que convierte "no entro nada" en una respuesta con dos
    # sentidos: si aqui hay cero, no entrar nada es lo correcto; si aqui hay
    # filas, no entrar nada es el fallo mortal.
    #
    # HASTA es el tope del tramo, y va al SQL como `:hasta`. Lo que llegue por
    # encima de ese id mientras esto copia NO se pierde: se queda para la
    # siguiente corrida, que lo vera porque la marca de agua queda justo aqui.
    # Van en DOS consultas y no en una que devuelva los dos numeros pegados con
    # un separador. El primer intento hacia eso -- count() || ' ' || max() -- y
    # el separador se perdia por el camino, asi que las dos variables se llevaban
    # la cadena entera: PENDIENTES salio 1340 cuando eran 1 fila hasta el id 340.
    # El script se mato solo con un MORTAL que no significaba nada.
    #
    # Con dos consultas no hace falta ningun truco de texto, y siguen siendo
    # coherentes porque la SEGUNDA va acotada por la primera. Da igual cuantas
    # filas entren entre una y otra: las de arriba del tope no las cuenta ni las
    # copia, y quedan para la corrida siguiente.
    HASTA="$(pg "SELECT coalesce(max($COL_ID), $DESDE) FROM $TABLA_PG")"
    PENDIENTES="$(pg "SELECT count(*) FROM $TABLA_PG WHERE $COL_ID > $DESDE AND $COL_ID <= $HASTA")"

    echo "    copiado hasta el id $DESDE, pendientes en PostgreSQL: $PENDIENTES"

    if [ "$PENDIENTES" = "0" ]; then
        echo "    nada nuevo que copiar"
        return 0
    fi

    # La tuberia. psql saca TabSeparated y entra directo al cliente de
    # ClickHouse, sin archivo intermedio, igual que el .cypher que cargar_grafo.sh
    # se niega a escribir: un archivo tirado en el disco es una foto que
    # envejece, y el primero que la encuentre no va a saber de que corrida es.
    #
    # -q NO ES OPCIONAL, y esto se midio el 2026-09-06 contra las bases vivas.
    # Sin el, psql imprime los tags de estado de las sentencias que no son
    # SELECT, y el `SET TIME ZONE` de extraer_eventos.sql manda la palabra "SET"
    # por la tuberia como si fuera una fila. ClickHouse la intenta parsear como
    # una fecha y revienta la carga entera. Con -q solo salen las filas.
    #
    # ON_ERROR_STOP=1 tampoco es opcional. Sin el, psql se salta la sentencia
    # que fallo, sigue con las demas y termina en CERO. Lo que llega al otro
    # lado de la tuberia es una extraccion incompleta, ClickHouse la acepta
    # contento, y el destino queda cargado a medias pareciendo que funciono.
    # Es el peor final posible.
    #
    # set -o pipefail (arriba) es lo que hace que un fallo de psql mate la
    # corrida. Sin el, bash mira solo el codigo del ULTIMO programa de la
    # tuberia, que seria el de ClickHouse, y ese termina feliz porque lo que
    # recibio (nada) es TabSeparated perfectamente valido.
    docker exec -i mesh-postgres \
        psql -U "$DB_USER" -d "$DB_NAME" -qtAX -F$'\t' \
             -v ON_ERROR_STOP=1 -v es_login="$ES_LOGIN" -v desde="$DESDE" -v hasta="$HASTA" \
             -f /dev/stdin \
        < "$RAIZ/etl/extraer_eventos.sql" \
      | docker exec -i mesh-clickhouse clickhouse-client \
            --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
            --database "$CLICKHOUSE_DB" \
            --query "INSERT INTO $TABLA_CH ($COLUMNAS) FORMAT TabSeparated"

    # GUARDA MORTAL. Se mide el destino otra vez y se resta.
    #
    # No se pregunta si los comandos "fueron bien": ya se sabe que fueron bien,
    # porque si no set -e habria matado esto. Se pregunta si el destino CRECIO
    # lo que tenia que crecer. Son dos preguntas distintas y solo la segunda
    # sirve, porque el modo de fallo que da miedo es justo el que no da error.
    DESPUES="$(ch "SELECT uniqExact($COL_ID) FROM $TABLA_CH WHERE lote = 'real'")"
    ENTRARON=$(( DESPUES - ANTES ))

    # La comparacion es exacta, y AHORA SI puede serlo, porque el tramo esta
    # cerrado por los dos lados: se conto y se copio el mismo `> DESDE` y
    # `<= HASTA`. Antes de poner el tope esta linea era una bomba de relojeria --
    # bastaba con que alguien entrara al portal mientras el ETL corria para que
    # ENTRARAN una fila mas de las contadas y esto matara una copia perfecta.
    #
    # Se deja en != y no en "menor que" a proposito. Con el tramo cerrado, que
    # entren DE MAS es tan raro como que entren de menos, y las dos direcciones
    # significan que algo que nadie entiende esta escribiendo en la tabla de
    # destino. Aflojar la guarda a "solo me asusto si faltan" habria tapado el
    # sintoma en vez de cerrar la ventana.
    if [ "$ENTRARON" != "$PENDIENTES" ]; then
        echo "MORTAL: PostgreSQL tenia $PENDIENTES fila(s) en $TABLA_PG" >&2
        echo "entre el id $DESDE y el $HASTA, y en $TABLA_CH entraron $ENTRARON." >&2
        echo "No se sigue." >&2
        exit 1
    fi

    echo "    copiadas $ENTRARON fila(s), ahora hay $DESPUES"
}


# ------------------------------------------------------------------
# 1. Copiar
# ------------------------------------------------------------------
if [ "$HACER_LOGIN" = "1" ]; then
    copiar 1 "log_login -> evento_login" evento_login log_login id_log_login \
        "fecha, id_usuario, ip, tipo, lote, id_log_login"
fi

if [ "$HACER_REGISTRO" = "1" ]; then
    copiar 0 "log_registro -> evento_registro" evento_registro log_registro id_log_registro \
        "fecha, id_usuario, ip, lote, id_log_registro"
fi


# ------------------------------------------------------------------
# 2. Contar las dos puntas y decirlo
# ------------------------------------------------------------------
# Esto se imprime SIEMPRE, incluso cuando no se copio ni una fila, y ese es el
# punto: es la unica linea de toda la corrida que demuestra que la tabla de
# destino tiene datos. Un ETL que dice "listo" y no dice cuanto hay puede
# llevar meses cargando cero.
#
# Las cuentas se comparan contra lote='real' porque lo generado no tiene pareja
# en PostgreSQL: son las IP de mentira que hacen falta para poder probar el
# analisis, ya que los 317 logueos de verdad comparten UNA sola IP (127.0.0.1,
# todo desarrollo local). Sumarlas aqui haria que el destino siempre pareciera
# tener de mas, y una comparacion que nunca cuadra se ignora a la semana.
#
# Es ademas la prueba de que repetir la corrida no duplica: correr el script dos
# veces seguidas tiene que imprimir exactamente los mismos numeros.
echo "==> conteo de las dos puntas"

TODO_CUADRA=1

comparar() {
    local NOMBRE="$1" TABLA_CH="$2" TABLA_PG="$3" COL_ID="$4" CUENTA="$5"
    local EN_PG EN_CH

    # SE COMPARA HASTA LA MARCA, NO HASTA EL FINAL DE LA TABLA.
    #
    # `count(*)` a secas sobre PostgreSQL era otra ventana abierta, la misma que
    # el tope `:hasta` cerro en la copia: entre que termina de copiar y llega
    # esta linea, alguien entra al portal, PostgreSQL queda con una fila mas, y
    # esto gritaba FALTAN EVENTOS y salia con 1 sobre una copia impecable.
    #
    # La pregunta correcta no es "tienen las dos el mismo total", porque la
    # fuente crece sola y la respuesta seria que no cada pocos segundos. Es
    # "de todo lo que DIGO haber copiado, esta todo". Lo que haya por encima de
    # la marca no es un hueco, es trabajo de la proxima corrida, y se dice
    # aparte para que no se confunda con un fallo.
    local MARCA PENDIENTES_AHORA
    MARCA="$(ch "SELECT max($COL_ID) FROM $TABLA_CH WHERE lote = 'real'")"
    [ -z "$MARCA" ] && MARCA=0

    EN_PG="$(pg "SELECT count(*) FROM $TABLA_PG WHERE $COL_ID <= $MARCA")"
    EN_CH="$(ch "SELECT uniqExact($COL_ID) FROM $TABLA_CH WHERE lote = 'real'")"

    PENDIENTES_AHORA="$(pg "SELECT count(*) FROM $TABLA_PG WHERE $COL_ID > $MARCA")"

    if [ "$EN_PG" = "$EN_CH" ]; then
        if [ "$PENDIENTES_AHORA" = "0" ]; then
            echo "    $NOMBRE   PostgreSQL $EN_PG   ClickHouse $EN_CH   cuadran"
        else
            # No es un fallo y por eso no toca TODO_CUADRA. Son filas que
            # entraron DESPUES de que esta corrida cerrara su tramo.
            echo "    $NOMBRE   PostgreSQL $EN_PG   ClickHouse $EN_CH   cuadran, y $PENDIENTES_AHORA llegaron despues"
        fi
        return 0
    fi

    # Una tabla que esta corrida NO tocaba puede estar legitimamente atrasada,
    # asi que se dice y no se falla por ella. Fallar aqui haria que
    # --solo-logueos terminara en 1 sobre una base recien creada, y una bandera
    # que siempre falla se deja de usar. Se cuenta igual, porque el numero es el
    # que avisa de que la otra mitad lleva tiempo sin copiarse.
    if [ "$CUENTA" != "1" ]; then
        echo "    $NOMBRE   PostgreSQL $EN_PG   ClickHouse $EN_CH   sin copiar en esta corrida"
        return 0
    fi

    # Las dos direcciones se dicen por separado porque no significan ni
    # parecido, y quien lea esto a las once de la noche necesita saber cual de
    # las dos tiene delante.
    #
    # Con MENOS en ClickHouse faltan eventos, que es el fallo que da miedo: el
    # analisis de fraude corre igual y contesta de menos.
    #
    # Con MAS, el destino guarda eventos que en PostgreSQL ya no estan, y eso
    # solo puede venir de que alguien BORRO filas de la fuente. Ver la nota de
    # la marca de agua, arriba: la copia no puede deshacer ese borrado sola,
    # porque solo mira hacia adelante. Se arregla vaciando lo real del destino
    # y dejando que la siguiente corrida lo vuelva a traer entero.
    if [ "$EN_CH" -lt "$EN_PG" ]; then
        echo "    $NOMBRE   PostgreSQL $EN_PG   ClickHouse $EN_CH   FALTAN EVENTOS" >&2
    else
        echo "    $NOMBRE   PostgreSQL $EN_PG   ClickHouse $EN_CH   SOBRAN EVENTOS (se borro algo en PostgreSQL)" >&2
    fi
    TODO_CUADRA=0
}

comparar "logueos  " evento_login    log_login    id_log_login    "$HACER_LOGIN"
comparar "registros" evento_registro log_registro id_log_registro "$HACER_REGISTRO"

if [ "$TODO_CUADRA" != "1" ]; then
    echo "Las cuentas no cuadran. Los eventos de ClickHouse estan incompletos" >&2
    echo "y cualquier analisis de fraude que se haga sobre ellos va a mentir." >&2
    exit 1
fi

echo "==> listo, los eventos de PostgreSQL estan copiados enteros"
