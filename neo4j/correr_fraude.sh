#!/usr/bin/env bash
#
# AVISO, ESTE ARNES NO PASA POR EL BACKEND. Corre los archivos neo4j/consultas/A*.cypher
# contra Neo4j. El detector del backend (anillos-detector.service.ts) tiene sus
# propias copias de esas consultas dentro del codigo, asi que esto prueba las del
# repositorio y no las que corren. El camino completo, con compras y resenas
# reales y el detector del backend, es pruebas/anillos.sh.
#
# correr_fraude.sh -- las consultas que senalan conjuntos de cuentas con un
# patron de interaccion anomalo. Son los 3 puntos mas grandes de la Entrega 2.
#
# Uso:  bash neo4j/correr_fraude.sh
#
# En Windows se corre desde Git Bash, no desde PowerShell, por lo mismo que
# cargar_grafo.sh: PowerShell se come las comillas al llamar a docker, y su
# operador "<" ni siquiera existe -- pegar en PowerShell el
# "cypher-shell ... < archivo.cypher" que este script reemplaza contesta
# "The '<' operator is reserved for future use" y no corre una sola consulta.
#
#
# QUE HACE, EN DOS PARTES
# ============================================================
#   PARTE A  corre las cinco consultas de neo4j/consultas/A*.cypher contra el
#            grafo de verdad. Hoy devuelven vacio o casi, y esa es la respuesta
#            correcta: los datos sembrados no tienen anillo. Una consulta de
#            fraude que siempre encuentra algo no esta detectando, esta
#            adivinando.
#
#   PARTE B  la prueba de que sirven. Siembra un anillo de mentira, vuelve a
#            correr LOS MISMOS CINCO ARCHIVOS -- no copias -- comprueba con
#            aserciones que cada uno lo encontro, y borra lo sembrado.
#
#
# POR QUE ESTO ES UN .SH Y NO UN .CYPHER, que es como estaba antes
# ============================================================
# Antes las dos partes vivian en un solo neo4j/002_fraude.cypher, y la parte B
# era una COPIA PEGADA de la parte A. Eso no demostraba nada, y se midio:
# cambiando "*4..8" por "*40..80" UNICAMENTE en la copia de arriba -- o sea
# rompiendo a proposito la consulta de varios saltos que vale los 3 puntos --
# la salida del archivo entero quedaba identica y la "demostracion" seguia
# imprimiendo los anillos sembrados con exito, porque corria la copia de abajo,
# intacta. Mientras haya dos textos, el de abajo no prueba nada sobre el de
# arriba.
#
# Cypher no tiene forma de incluir un archivo dentro de otro, asi que el unico
# lugar donde se puede correr el MISMO texto dos veces contra dos estados del
# grafo es afuera. De ahi el script.
#
# El otro fallo que arregla es la ausencia de aserciones. Antes se podia dejar
# la siembra sin la relacion que la hace anillo, las cuatro comprobaciones
# devolvian CERO filas -- la demostracion fracasaba entera -- y el archivo
# terminaba con codigo 0 y sin un solo mensaje. cypher-shell devuelve 1 si el
# Cypher NO COMPILA, nunca si no encuentra nada. Aqui cada bloque de la parte B
# tiene su asercion y el script sale con 1 si alguna falla.
#
#
# LAS ASERCIONES MIRAN LA SALIDA DE VERDAD
# ============================================================
# Cada comprobacion hace grep sobre el texto que imprimio la consulta de la
# entrega, guardado en un archivo temporal. No vuelve a preguntarle al grafo con
# otra consulta parecida: eso seria volver a tener dos textos y el segundo
# taparia al primero, que es el fallo que este archivo existe para no repetir.

set -u
export MSYS_NO_PATHCONV=1   # Git Bash convierte las rutas con / al pasarlas a
                            # docker exec y las vuelve C:/Program Files/...

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
CONSULTAS="$RAIZ/neo4j/consultas"

# Las credenciales salen del .env de la raiz, el mismo que lee docker compose.
# No se escriben aqui, que si se sube al repositorio.
set -a
. "$RAIZ/.env"
set +a

CONTENEDOR="${CONTENEDOR_NEO4J:-mesh-neo4j}"

fallos=0

cypher() {
    docker exec -i "$CONTENEDOR" cypher-shell \
        -u neo4j -p "$NEO4J_PASSWORD" --format plain
}

titulo() { echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
ok()  { echo "  OK    $1"; }
mal() { echo "  FALLA $1"; fallos=$((fallos + 1)); }

# La lista, en el orden en que se leen. Se escribe una vez y la usan las DOS
# partes: si alguien agrega una consulta A6 y se olvida de agregarla aqui, no
# se corre en ninguna de las dos, que es un fallo visible. Antes el olvido era
# invisible al reves -- la parte B tenia cuatro de las cinco consultas y nadie
# lo noto.
ARCHIVOS="A1_anillo A2_par_mutuo A3_rafaga A4_misma_casa A5_puntaje"

# Un directorio temporal para guardar lo que imprimio cada consulta. Se borra al
# salir pase lo que pase, incluido un Ctrl+C: un trap y no un rm al final,
# porque el rm al final es justo el que no corre cuando algo se corta.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# El conteo del grafo, en una sola cadena comparable. Se toma antes de sembrar y
# despues de limpiar, y las dos tienen que ser IGUALES. Antes esto se imprimia
# en dos tablas para que una persona las comparara de memoria; una cadena y un
# "=" no se olvidan de mirar.
conteo_del_grafo() {
    {
        echo 'MATCH (n) UNWIND labels(n) AS e RETURN e, count(*) AS c ORDER BY e;'
        echo 'MATCH ()-[r]->() RETURN type(r) AS t, count(*) AS c ORDER BY t;'
    } | cypher | tr -d '\r' | tr '\n' ' '
}

# Corre las cinco consultas y deja la salida de cada una en $TMP/<nombre>.out,
# ademas de imprimirla. $1 es el sufijo del archivo, para que la corrida contra
# el grafo real y la corrida contra el grafo sembrado no se pisen.
correr_las_cinco() {
    local sufijo="$1" archivo salida
    for archivo in $ARCHIVOS; do
        salida=$(cypher < "$CONSULTAS/$archivo.cypher" 2>&1)
        if [ $? -ne 0 ]; then
            mal "$archivo.cypher no compilo o no se pudo correr:"
            echo "$salida" | sed 's/^/        /'
        fi
        printf '%s\n' "$salida" > "$TMP/$archivo.$sufijo"
        echo
        printf '%s\n' "$salida" | sed 's/^/  /'
    done
}

# grep sobre la salida guardada de UNA consulta. Los patrones se piden todos a
# la vez y tienen que caer en la MISMA linea: "que aparezcan las tres cuentas"
# no es lo mismo que "que aparezcan las tres cuentas en la misma fila", y lo
# segundo es lo que hay que comprobar.
#
#   $1 etiqueta legible   $2 archivo de salida   $3.. patrones (todos en 1 linea)
tiene_fila() {
    local etiqueta="$1" archivo="$2"; shift 2
    local filtro="cat '$archivo'" p
    for p in "$@"; do filtro="$filtro | grep -F -- '$p'"; done
    if eval "$filtro" > /dev/null 2>&1; then
        ok "$etiqueta"
    else
        mal "$etiqueta"
        echo "        lo que imprimio la consulta:"
        sed 's/^/          /' "$archivo"
    fi
}

# Lo contrario: ninguna linea puede cumplir todos los patrones a la vez.
no_tiene_fila() {
    local etiqueta="$1" archivo="$2"; shift 2
    local filtro="cat '$archivo'" p
    for p in "$@"; do filtro="$filtro | grep -F -- '$p'"; done
    if eval "$filtro" > /dev/null 2>&1; then
        mal "$etiqueta"
        echo "        la fila que no deberia estar:"
        eval "$filtro" | sed 's/^/          /'
    else
        ok "$etiqueta"
    fi
}


titulo "PARTE A -- las cinco consultas contra el grafo REAL"
echo "  Lo que salga vacio salio vacio de verdad: cada consulta imprime su"
echo "  rotulo aunque no encuentre nada, justamente para que 'no encontro' y"
echo "  'no se corrio' no se vean igual."

ANTES=$(conteo_del_grafo)
correr_las_cinco real


titulo "PARTE B -- las MISMAS consultas, con un anillo sembrado"

echo "  sembrando..."
# La salida se captura ANTES de pasarla por sed. Con "cypher < x | sed", el $?
# que se lee despues es el de sed -- que siempre sale bien -- y una siembra que
# fallo entera pasaria por buena. Ya mordio en otros scripts de este repo.
SIEMBRA=$(cypher < "$CONSULTAS/siembra.cypher" 2>&1)
SALIO=$?
printf '%s\n' "$SIEMBRA" | sed 's/^/    /'
if [ "$SALIO" -ne 0 ]; then
    echo "  No se pudo sembrar. Se aborta antes de comprobar nada."
    exit 1
fi

correr_las_cinco sembrado


titulo "COMPROBACIONES -- sobre la salida que acaban de imprimir"

# A.1 tiene que encontrar el triangulo de tres cuentas.
tiene_fila "A.1 encontro el triangulo anillo.a -> anillo.b -> anillo.c" \
    "$TMP/A1_anillo.sembrado" \
    'anillo.a@prueba.local' 'anillo.b@prueba.local' 'anillo.c@prueba.local'

# A.1 tiene que encontrar el par mutuo doble.a / doble.b UNA vez, con DOS
# cuentas. Es la regresion del anillo inventado: antes el mismo par salia
# tambien como un anillo de cuatro cuentas con los dos correos repetidos.
tiene_fila "A.1 encontro el par doble.a / doble.b" \
    "$TMP/A1_anillo.sembrado" 'doble.a@prueba.local' 'doble.b@prueba.local'

# Y la comprobacion de verdad, que no depende de que se me ocurra el par
# concreto: NINGUNA fila puede nombrar dos veces la misma cuenta. Un anillo de
# cuatro cuentas donde solo hay dos se ve exactamente asi, un correo repetido
# dentro de la misma lista.
#
# awk parte la linea por comillas: los campos pares son las cadenas entre
# comillas, o sea los correos. Si alguno se repite en la misma linea, la fila es
# inventada.
REPETIDAS=$(awk -F'"' '{ delete vistas; malo=0;
                         for (i = 2; i <= NF; i += 2) if (vistas[$i]++) malo = 1;
                         if (malo) print }' "$TMP/A1_anillo.sembrado")
if [ -z "$REPETIDAS" ]; then
    ok "A.1 no devolvio ni un anillo que repita una cuenta"
else
    mal "A.1 devolvio anillos con una cuenta repetida (anillos inventados)"
    printf '%s\n' "$REPETIDAS" | sed 's/^/          /'
fi

# A.2 tiene que encontrar el par mutuo sobre el MISMO producto.
tiene_fila "A.2 encontro el par mutuo sobre el mismo producto" \
    "$TMP/A2_par_mutuo.sembrado" \
    'anillo.a@prueba.local' 'anillo.b@prueba.local' 'Producto de prueba del anillo'

# A.3 tiene que encontrar la rafaga de anillo.d PESE a la cuarta resena de
# diciembre. Es la regresion de la ventana: la version vieja comparaba el lapso
# entre la primera y la ultima resena del par entero y esa cuarta linea, sola,
# apagaba la alerta.
tiene_fila "A.3 encontro la rafaga de anillo.d pese a la resena vieja" \
    "$TMP/A3_rafaga.sembrado" 'anillo.d@prueba.local' 'anillo.a@prueba.local'

# A.4 tiene que encontrar la casa compartida, y la tiene que encontrar por la
# CALLE. Si alguien quita el d.tiene_calle, esto sigue en verde -- por eso la
# comprobacion de que no cuela una direccion sin calle esta abajo, contra el
# grafo real.
tiene_fila "A.4 encontro la direccion compartida (con calle)" \
    "$TMP/A4_misma_casa.sembrado" 'Casa 1'

# A.5 tiene que darle CUATRO senales al par del anillo y TRES al par doble, que
# no comparte direccion. Que los dos numeros sean distintos es lo que demuestra
# que el puntaje discrimina en vez de darle el maximo a todo lo sembrado.
tiene_fila "A.5 le dio 4 senales al par anillo.a / anillo.b" \
    "$TMP/A5_puntaje.sembrado" 'anillo.a@prueba.local' 'anillo.b@prueba.local' ', 4'

tiene_fila "A.5 le dio 3 senales al par doble.a / doble.b (no comparten casa)" \
    "$TMP/A5_puntaje.sembrado" 'doble.a@prueba.local' 'doble.b@prueba.local' ', 3'

# Y la comprobacion que mira el grafo REAL, no el sembrado: A.4 no puede estar
# llamando "misma casa" a dos cuentas que solo coinciden en la ciudad. Los dos
# pares que devolvia antes -- comprador.sur + compradora.norte en Antigua y
# tienda + Meme#gordo en San Jose Pinula -- tenian direccion_exacta NULL, y su
# propia salida lo imprimia al lado.
#
# Se corta la salida en el rotulo de A.4b: de ahi para abajo estan los pares que
# solo comparten CIUDAD, que se listan a proposito y no son senal. Sin el corte
# esta comprobacion estaria mirando justo lo que no tiene que mirar.
sed -n '1,/=== A.4b/p' "$TMP/A4_misma_casa.real" > "$TMP/A4_solo_casa"
no_tiene_fila "A.4 no cuela un domicilio sin calle (direccion_exacta NULL)" \
    "$TMP/A4_solo_casa" 'NULL'


titulo "LIMPIEZA -- el grafo tiene que quedar EXACTAMENTE como estaba"

# DETACH DELETE se lleva el nodo y sus relaciones de una. Un DELETE pelado
# fallaria: todos los nodos sembrados tienen relaciones. La etiqueta :Prueba es
# lo unico que hay que recordar, y por eso se puso: sin ella habria que enumerar
# seis cuentas, cuatro productos, doce resenas y una direccion, y el dia que
# alguien agregue una resena a la siembra se va a olvidar de agregarla tambien
# al borrado.
echo 'MATCH (n:Prueba) DETACH DELETE n;' | cypher > /dev/null

DESPUES=$(conteo_del_grafo)
echo "  antes:   $ANTES"
echo "  despues: $DESPUES"
if [ "$ANTES" = "$DESPUES" ]; then
    ok "el conteo de nodos y relaciones volvio al mismo valor"
else
    mal "el grafo NO quedo como estaba: la siembra dejo o se llevo algo"
fi


titulo "RESULTADO"
if [ "$fallos" = "0" ]; then
    echo "  Las cinco consultas corrieron contra el grafo real y contra el grafo"
    echo "  sembrado, y son EL MISMO texto en los dos casos. Cada patron que se"
    echo "  sembro fue encontrado, ninguno de los dos anillos inventados"
    echo "  aparecio, y el grafo quedo como estaba."
    exit 0
else
    echo "  $fallos comprobacion(es) FALLARON."
    exit 1
fi
