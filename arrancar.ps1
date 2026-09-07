# arrancar.ps1
# Levanta todo el ambiente de Mesh de una sola vez.
#
#   .\arrancar.ps1                   levanta PostgreSQL, pgAdmin, MongoDB, Redis y Neo4j
#   .\arrancar.ps1 -Reiniciar        borra TODOS los datos y empieza de cero
#   .\arrancar.ps1 -ReiniciarMongo   rehace solo MongoDB, sin tocar PostgreSQL
#   .\arrancar.ps1 -ReiniciarGrafo   rehace solo el grafo de Neo4j, desde cero
#   .\arrancar.ps1 -Mongo            abre la consola de MongoDB y ya
#   .\arrancar.ps1 -Etl              vuelve a migrar el catalogo a Mongo Y el grafo a Neo4j
#   .\arrancar.ps1 -Productos 300              arranca normal y ademas genera 300 productos
#                                              con sus variantes y sus ofertas. De 1 a 9999,
#                                              en digitos: 300 si, 300.5 y 0x10 no.
#                                              Sin -Semilla elige una libre y te DICE cual,
#                                              asi que se puede correr las veces que haga
#                                              falta y cada vez sale un lote distinto
#   .\arrancar.ps1 -Productos 300 -Semilla 7   lo mismo pero con la semilla puesta a mano:
#                                              la misma semilla vuelve a dar exactamente el
#                                              mismo lote, en cualquier maquina
#   .\arrancar.ps1 -Borrar 500                 borra los 500 productos generados MAS NUEVOS,
#                                              en PostgreSQL y en MongoDB. Si pides mas de
#                                              los que hay, borra los que hay y lo dice
#   .\arrancar.ps1 -Borrar todos               borra todos los generados y deja los curados
#   .\arrancar.ps1 -Borrar todos -Semilla 7    borra solo el lote de esa semilla
#
#   Los 102 productos curados NO los borra -Borrar, y no se puede: 59 de ellos tienen
#   ventas detras y pedido_producto los sujeta con ON DELETE RESTRICT. Para dejar la base
#   como recien instalada esta -Reiniciar, que la reconstruye entera desde el repositorio.
#
#   .\arrancar.ps1 -ProductosMongo 200          crea 200 productos que viven SOLO en
#                                              MongoDB, como los que publica un vendedor
#                                              desde el panel. Sin -Semilla elige una libre
#   .\arrancar.ps1 -ProductosMongo 200 -Semilla 7   el mismo lote, repetible
#   .\arrancar.ps1 -BorrarMongo 7                borra el lote M7 de las dos bases
#
#   La diferencia entre -Productos y -ProductosMongo no es de tamano ni de velocidad, es
#   de ORIGEN, y decide como se comportan despues:
#
#     -Productos       nacen en PostgreSQL y el ETL los lleva a Mongo. Tienen historial
#                      completo y son reconstruibles por fecha. Cada corrida del ETL los
#                      vuelve a escribir.
#     -ProductosMongo  nacen en MongoDB y no tienen fila en `productos`. El ETL no los
#                      mira NUNCA. Es como nacen hoy los productos de verdad, porque el
#                      panel de vendedor ya no los registra en PostgreSQL.

# Por que -Etl fuerza LOS DOS ETL y no hay un -EtlGrafo aparte
# ------------------------------------------------------------
# La bandera existe para el caso "cambie algo en PostgreSQL que no mueve
# ninguna cuenta" -- corregir el precio de una oferta que ya existe, arreglar
# la fecha de una resena mal fechada. Ese caso no distingue de que ETL se
# trata: quien lo teclea no sabe si el dato que toco viaja a Mongo, a Neo4j o
# a los dos. Una bandera por destino obligaria a saberlo, y el dia que alguien
# elija mal se va con la mitad al dia y la otra mitad vieja, sin un solo error.
# Los dos ETL son idempotentes, asi que correr de mas es gratis; correr de
# menos es el fallo que este script ya cometio dos veces con Mongo (ver la
# seccion 7).
#
# -ReiniciarGrafo si es aparte, porque no es "correr de mas": BORRA el grafo
# entero antes de reconstruirlo. Es el equivalente de --limpiar en
# etl/cargar_grafo.sh y hace falta porque el ETL solo suma -- una resena
# borrada en PostgreSQL se queda en el grafo hasta que alguien lo vacie. Va
# detras de su propia bandera y no pegado a -Etl por lo mismo que dice ese
# script: si alguien sembro un anillo de prueba a mano para una demostracion,
# un borrado automatico se lo lleva en medio de la demostracion.
#
# Se llama -ReiniciarGrafo y no -LimpiarGrafo para que se parezca a
# -ReiniciarMongo, que es lo mismo un piso mas abajo: tirar una base derivada
# y volverla a llenar sin tocar PostgreSQL, que es la fuente de verdad.

# Por que -Productos y -Semilla se reciben como TEXTO y no como [int]
# ---------------------------------------------------------------------
# Porque [int] no valida: CONVIERTE, y convierte antes de que este script pueda
# mirar nada. Esto no es teorico, esta medido en PowerShell 5.1 contra este
# mismo param(), y ninguno de estos casos da error ni aviso:
#
#   -Productos 2.7     llega 3       redondea, y al PAR: 2.5 llega 2 y 3.5 llega 4
#   -Productos 0.4     llega 0       o sea, "no generes nada"
#   -Productos 0x10    llega 16      lee hexadecimal
#   -Productos 1e3     llega 1000    lee notacion cientifica
#   -Productos 2,5     llega 25      la coma es separador de MILES en la cultura
#                                    de la maquina, asi que no parte el numero:
#                                    lo junta, y "dos y medio" sale veinticinco
#   -Productos " 5 "   llega 5       recorta los espacios
#   -Productos ""      llega 0       y con la bandera contada como escrita
#
# Todos escriben en la base un numero distinto del que la persona tecleo, o se
# tragan la peticion entera. Un dedo que resbala en el punto convierte "quiero
# 2 productos" en 3 filas que nadie pidio, y encima quema esa semilla: la
# guardia del generador no deja repetirla, asi que el intento de arreglarlo
# rebota.
#
# Y NO se arregla mirando $PSBoundParameters, que es lo primero que uno piensa.
# Tambien esta medido: $PSBoundParameters['Productos'] ya viene convertido a
# Int32. La conversion ocurre al ENLAZAR el parametro, o sea antes de que corra
# la primera linea del script, y a esa altura el texto que la persona escribio
# ya no existe en ninguna parte. $PSBoundParameters sirve para la unica cosa que
# si sabe -- SI la bandera se escribio o no -- y para eso si se usa aqui abajo.
#
# Asi que las dos banderas entran como [string], que PowerShell entrega tal
# cual, y de convertirlas se encarga Leer-Entero, que exige digitos y nada mas.
#
# Por que -Productos 0 se RECHAZA y ya no quiere decir "no generes nada"
# ----------------------------------------------------------------------
# Mientras el parametro era [int], el cero tecleado a mano y el cero por defecto
# eran el mismo cero y no habia forma de separarlos, asi que los dos se
# colapsaban en "no toques nada". Con el parametro como texto esa excusa se
# termino: $PSBoundParameters dice si la bandera se escribio, y entonces
# -Productos 0 es una peticion de generar que no se puede cumplir, no una
# ausencia de peticion.
#
# Se rechaza por la misma razon por la que se rechaza -Semilla sola: quien
# escribio la bandera quiere un lote, y terminar en verde sin haber generado
# nada le entrega un "todo bien" que no responde a lo que pidio. "Genera
# exactamente cero productos" no es un caso de uso -- quien quiere cero no
# escribe la bandera -- asi que un cero escrito es un dedo que resbalo o un
# script que calculo mal, y las dos cosas se dicen en voz alta.
#
# Sin la bandera, el arranque de todos los dias sigue siendo exactamente el de
# antes: no entra al paso 5c, no imprime un encabezado de mas y no corre contra
# PostgreSQL una migracion que nadie pidio. Equivocarse hacia ese lado no
# produce un error, produce ruido permanente, que es peor porque nadie lo
# denuncia nunca.
#
# El rango 1 a 9999 no se inventa aqui: es el que exige la guardia de
# migrations/lote/generar_lote.sql, y el tope sale de que el marcador que ese
# archivo pega al nombre de cada producto lleva cuatro digitos. Se repite de
# este lado para que un numero fuera de rango se sepa en un segundo, y no
# despues de levantar los contenedores y correr las migraciones enteras.
#
# Por que -Semilla sin -Productos se para y no hace absolutamente nada
# --------------------------------------------------------------------
# Una semilla sola no tiene ningun significado posible, asi que solo quedan tres
# salidas y dos son malas. Adivinar un numero de productos es inventarle una
# intencion a quien tecleo la linea. Tragarse la bandera en silencio y arrancar
# normal es peor todavia: esa linea se escribio para generar, el arranque
# terminaria en verde sin haber generado nada, y quien la tecleo se llevaria un
# "todo bien" que no responde a lo que pidio. Queda la tercera, que es la que se
# hace: decirlo y parar antes de tocar Docker, donde no hay nada que deshacer y
# volver a teclear la linea completa cuesta cinco segundos.
#
# El caso que antes se colaba -- -Semilla 0 sin -Productos, indistinguible de no
# haberla escrito -- ya no se cuela, por lo mismo que -Productos 0: con el
# parametro como texto se sabe si la bandera se escribio.
#
# Por que la semilla admite hasta un bigint y no hasta un [int]
# --------------------------------------------------------------
# Porque bigint es el tipo al que la castea el generador, y porque su propia
# documentacion propone usar el CID como semilla. Un CID de trece digitos NO
# cabe en un Int32, asi que con el parametro como [int] PowerShell lo rechazaba
# de entrada con "Value was either too large or too small for an Int32" --
# comprobado -- un mensaje que habla de un tipo de .NET y no de una semilla, y
# que manda a buscar el problema donde no esta.

param(
    [switch]$Reiniciar,
    [switch]$ReiniciarMongo,
    [switch]$ReiniciarGrafo,
    [switch]$Mongo,
    [switch]$Etl,
    [string]$Productos = '',
    [string]$Semilla   = '',
    [string]$Borrar    = '',
    [string]$ProductosMongo = '',
    [string]$BorrarMongo    = '',
    [string]$Vistas         = '',
    [string]$BorrarVistas   = ''
)

Set-Location -LiteralPath $PSScriptRoot

function Paso($t)  { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "   $t"   -ForegroundColor Green }
function Aviso($t) { Write-Host "   $t"   -ForegroundColor Yellow }
function Error1($t){ Write-Host "   $t"   -ForegroundColor Red }


# ------------------------------------------------------------
# Leer un numero de la linea de comandos sin que PowerShell lo cambie antes
# ------------------------------------------------------------
# Esta funcion es la razon de que -Productos y -Semilla entren como [string].
# Lo que hace es lo que [int] NO hace: mirar el texto que la persona escribio y
# rechazar todo lo que no sea un entero escrito tal cual.
#
# La expresion regular es deliberadamente estrecha -- signo opcional y digitos,
# nada mas -- y esa estrechez es el punto: cada cosa que deja fuera es una que
# [int] aceptaba convirtiendola en otro numero (el punto decimal, la coma de
# miles, el 0x, la e de la notacion cientifica, los espacios de los lados).
# Cualquier permiso que se le agregue aqui reabre uno de esos agujeros.
#
# Devuelve $null cuando rechaza, y quien llama sale. No se puede usar el valor
# como condicion (if ($n) ...) porque 0 es un valor legitimo para la semilla:
# hay que comparar contra $null de forma explicita.
#
# El limite lo pone [long] y no [int] porque el generador castea la semilla a
# bigint. TryParse ademas atrapa el numero con demasiados digitos, que la
# expresion regular deja pasar y un cast pelado tumbaria con una excepcion de
# .NET en vez de con una frase.
function Leer-Entero($texto, $bandera, $minimo, $maximo) {
    $texto = "$texto"

    if ($texto.Trim() -eq "") {
        Error1 "$bandera se escribio sin valor."
        Error1 "Se esperaba un entero entre $minimo y $maximo, escrito en digitos."
        return $null
    }

    if ($texto -notmatch '^-?[0-9]+$') {
        Error1 "$bandera recibio [$texto], que no es un entero escrito en digitos."
        Error1 "Se esperaba un entero entre $minimo y $maximo, tal cual: sin punto"
        Error1 "ni coma, sin 0x, sin notacion cientifica y sin espacios."
        return $null
    }

    [long]$n = 0
    if (-not [long]::TryParse($texto, [ref]$n)) {
        Error1 "$bandera recibio [$texto], que tiene demasiados digitos."
        Error1 "Se esperaba un entero entre $minimo y $maximo."
        return $null
    }

    if ($n -lt $minimo -or $n -gt $maximo) {
        Error1 "$bandera recibio $n, que esta fuera de rango."
        Error1 "Se esperaba un entero entre $minimo y $maximo."
        return $null
    }

    return $n
}


# Las banderas del lote se revisan AQUI, antes de la primera linea que habla con
# Docker, y no pegadas al paso que las usa. El paso vive despues de las
# migraciones, asi que avisar alli obligaria a esperar el arranque entero para
# enterarse de un error de tecleo, y a esas alturas ya se levantaron todos los
# contenedores del compose para nada. El por que de cada regla esta escrito
# arriba, junto al param(), que es donde alguien va a ir a buscarlo.
#
# Se pregunta por $PSBoundParameters y no por el valor, porque es lo unico que
# distingue "la bandera no se escribio" de "la bandera se escribio con un valor
# que resulto ser el mismo que el de por defecto". Esa diferencia es justo la
# que antes no existia y dejaba pasar -Productos 0 y -Semilla 0 en silencio.
$pidioLote    = $PSBoundParameters.ContainsKey('Productos')
$pidioSemilla = $PSBoundParameters.ContainsKey('Semilla')

# -Mongo es una salida temprana TOTAL: abre la consola y sale del script sin
# llegar a ninguna otra seccion. O sea que con -Mongo la bandera del lote no es
# que corra tarde, es que no corre nunca, y hasta hoy no se decia una palabra.
# El comentario del param() ya llamaba a eso la peor de las tres salidas --
# terminar sin haber hecho lo que se pidio, sin un solo aviso -- y estaba
# pasando aqui mismo.
#
# Se para en vez de avisar y seguir a la consola, por lo mismo que -Semilla
# sola: el aviso se iria hacia arriba en cuanto mongosh pinte su banner, y quien
# tecleo la linea saldria de la consola creyendo que su lote esta en la base.
#
# OJO, lo que esto NO cubre: -Mongo se traga IGUAL a -Reiniciar, -ReiniciarMongo,
# -ReiniciarGrafo y -Etl. No se persiguen aqui porque no tienen lectura posible
# junto a "abreme la consola", mientras que -Productos con -Mongo si la tiene
# (generar y despues mirar el resultado), que es lo que la hace peligrosa.
if ($Mongo -and ($pidioLote -or $pidioSemilla)) {
    Error1 "-Mongo abre la consola de MongoDB y sale, asi que no genera ningun lote."
    Error1 "Son dos ordenes distintas y van en dos lineas, en este orden:"
    Error1 "   .\arrancar.ps1 -Productos 300"
    Error1 "   .\arrancar.ps1 -Mongo"
    exit 1
}

# AQUI HABIA UN FALLO VIVO, y se arregla al agregar el tercer generador porque es
# la tercera vez que muerde la misma linea.
#
# Esta guardia miraba solo $pidioLote, que es -Productos. O sea que
# `-ProductosMongo 200 -Semilla 7` moria diciendo "-Semilla no dice nada sin
# -Productos" sobre una linea que SI decia cuantos generar y con que semilla. El
# generador de Mongo acepta semilla desde el dia que se escribio; lo que no la
# aceptaba era la puerta.
#
# Ahora se pregunta por CUALQUIERA de los tres generadores. La regla de verdad,
# que es la que habia que escribir desde el principio, es que -Semilla necesita
# que alguien le diga CUANTOS generar, y eso lo dice cualquiera de las tres
# banderas, no una en concreto.
$pidioLoteMongo = $PSBoundParameters.ContainsKey('ProductosMongo')
$pidioVistas    = $PSBoundParameters.ContainsKey('Vistas')
$pidioAlgunLote = $pidioLote -or $pidioLoteMongo -or $pidioVistas

if ($pidioSemilla -and -not $pidioAlgunLote) {
    Error1 "-Semilla no dice nada sola, porque cuantos generar no se adivina."
    Error1 "Va con la bandera que dice cuantos, y son tres:"
    Error1 "   .\arrancar.ps1 -Productos 300 -Semilla $Semilla"
    Error1 "   .\arrancar.ps1 -ProductosMongo 200 -Semilla $Semilla"
    Error1 "   .\arrancar.ps1 -Vistas 5000 -Semilla $Semilla"
    exit 1
}

# El rango de -Productos es el de la guardia de generar_lote.sql, copiado a
# proposito para que el error llegue en un segundo y no despues del arranque
# entero. Si algun dia esa guardia cambia de rango, este numero se queda viejo y
# el error volveria a llegar tarde, pero nunca de mas: aqui se rechaza lo que el
# SQL tambien rechazaria.
$ProductosPedidos = 0
$SemillaPedida    = 0

# Se declara aqui arriba y no donde se usa, para que el resumen del final pueda
# preguntarle sin depender de que el paso 5c haya llegado a correr. Guarda el
# texto del lote que el generador rechazo, o queda en $null si no hubo ninguno.
$loteRechazado    = $null

if ($pidioLote) {
    $ProductosPedidos = Leer-Entero $Productos '-Productos' 1 9999
    if ($null -eq $ProductosPedidos) { exit 1 }
}

if ($pidioSemilla) {
    $SemillaPedida = Leer-Entero $Semilla '-Semilla' 0 ([long]::MaxValue)
    if ($null -eq $SemillaPedida) { exit 1 }
}

# -Vistas siembra el lote de eventos de ClickHouse, y -BorrarVistas lo deshace.
#
# El tope de abajo no es un numero redondo elegido a ojo: es el mismo que exige
# la guardia de clickhouse/lote/generar_vistas.sql, copiado aqui a proposito para
# que el error llegue en un segundo y no despues del arranque entero. Por debajo
# de 840 el fondo no llega a una vista por producto y por dia, y el panel sale
# con las dos senales solas y nada contra que compararlas, que es un panel que
# no ensena nada.
$VistasPedidas  = -1
$VistasBorrar   = -1

if ($pidioVistas) {
    $VistasPedidas = Leer-Entero $Vistas '-Vistas' 840 5000000
    if ($null -eq $VistasPedidas) { exit 1 }

    # Misma regla que las otras cuatro banderas de lote: generar y borrar en la
    # misma corrida deja la base como estaba despues de hacer todo el trabajo.
    if ($BorrarVistas -ne '') {
        Error1 "-Vistas y -BorrarVistas no se pueden usar en la misma corrida."
        Aviso  "   Una siembra y la otra deshace. Juntas dejan la base igual que estaba."
        exit 1
    }
}

if ($PSBoundParameters.ContainsKey('BorrarVistas')) {
    $VistasBorrar = Leer-Entero $BorrarVistas '-BorrarVistas' 0 ([long]::MaxValue)
    if ($null -eq $VistasBorrar) { exit 1 }
}


# -Borrar acepta un numero o la palabra "todos", y esa es la unica bandera del
# script que no es ni un interruptor ni un entero. La palabra existe porque
# "borrame todos" no tiene un numero que teclear: obligar a poner 999999 seria
# pedirle a alguien que adivine un tope, y un cero para decir "todos" ya
# significa "ninguno" en -Productos. Dos banderas del mismo script no pueden
# darle sentidos opuestos al mismo cero.
$BorrarPedido  = ''
$BorrarCuantos = 0
$BorrarTodos   = $false

if ($PSBoundParameters.ContainsKey('Borrar')) {
    $BorrarPedido = $Borrar.Trim()

    if ($BorrarPedido -eq '') {
        Error1 "-Borrar necesita un valor: un numero, o la palabra todos."
        Aviso  "   .\arrancar.ps1 -Borrar 500"
        Aviso  "   .\arrancar.ps1 -Borrar todos"
        exit 1
    }

    if ($BorrarPedido -match '^(todos|todo)$') {
        $BorrarTodos = $true
    } else {
        $BorrarCuantos = Leer-Entero $BorrarPedido '-Borrar' 1 2147483647
        if ($null -eq $BorrarCuantos) {
            Aviso "   Tambien vale la palabra todos:  .\arrancar.ps1 -Borrar todos"
            exit 1
        }
    }

    # Las dos juntas se rechazan, y no por prudencia: el paso que genera corre
    # ANTES del que borra, asi que "-Productos 100 -Borrar todos" generaria cien
    # productos y acto seguido los borraria, dejando la base igual que estaba
    # despues de dos minutos de trabajo. Lo que quien teclea eso quiere es lo
    # contrario, y adivinarselo seria peor que pararse aqui.
    if ($pidioLote) {
        Error1 "-Productos y -Borrar no se pueden usar en la misma corrida."
        Aviso  "   El lote se genera antes de borrar, asi que juntas se anulan."
        Aviso  "   Corre primero el borrado y despues la generacion:"
        Aviso  "     .\arrancar.ps1 -Borrar todos"
        Aviso  "     .\arrancar.ps1 -Productos 100 -Semilla 5"
        exit 1
    }

    # -Reiniciar ya deja la base con sus 102 productos curados y nada mas, asi
    # que borrar despues de reiniciar es pedirle que borre algo que acaba de no
    # existir. Se avisa y se sigue, porque no rompe nada.
    if ($Reiniciar) {
        Aviso "-Reiniciar ya deja la base sin productos generados: -Borrar no va a encontrar nada."
    }
}


# Las dos banderas del lote de MongoDB. Se revisan igual que las de PostgreSQL y
# por el mismo motivo: un error de tecleo tiene que costar un segundo y no un
# arranque entero.
$MongoPedidos = 0
$MongoBorrar  = -1

if ($PSBoundParameters.ContainsKey('ProductosMongo')) {
    $MongoPedidos = Leer-Entero $ProductosMongo '-ProductosMongo' 1 9999
    if ($null -eq $MongoPedidos) { exit 1 }

    # Las cuatro banderas de lote se rechazan entre si, y no por prudencia: los
    # pasos corren en un orden fijo, asi que combinarlas hace cosas que nadie
    # pidio. Generar y borrar en la misma corrida deja la base igual que
    # estaba, despues de dos minutos de trabajo.
    if ($pidioLote) {
        Error1 "-Productos y -ProductosMongo no se pueden usar en la misma corrida."
        Aviso  "   Son dos origenes distintos y conviene ver el resultado de uno antes"
        Aviso  "   de encimarle el otro. Corre primero uno y despues el otro."
        exit 1
    }
    if ($BorrarPedido -ne '') {
        Error1 "-ProductosMongo y -Borrar no se pueden usar en la misma corrida."
        exit 1
    }
}

if ($PSBoundParameters.ContainsKey('BorrarMongo')) {
    $MongoBorrar = Leer-Entero $BorrarMongo '-BorrarMongo' 0 ([long]::MaxValue)
    if ($null -eq $MongoBorrar) {
        Aviso "   -BorrarMongo lleva la SEMILLA del lote, no cuantos borrar."
        Aviso "   No hay un borra-todos aqui: en MongoDB un producto de lote y uno que"
        Aviso "   publico una persona son indistinguibles salvo por el marcador del nombre."
        exit 1
    }
    if ($MongoPedidos -gt 0) {
        Error1 "-ProductosMongo y -BorrarMongo no se pueden usar en la misma corrida."
        exit 1
    }
}


# ------------------------------------------------------------
# Esperar a que un contenedor este SANO
# ------------------------------------------------------------
# Los cuatro contenedores con datos se esperan igual, asi que el bucle vive
# aqui una sola vez en vez de estar copiado cuatro. Estaba copiado dos, y al
# agregar Redis y Neo4j iban a ser cuatro copias de la misma espera con cuatro
# timeouts que se pueden desincronizar.
#
# Se mira el HEALTHCHECK del compose y no "docker ps": un contenedor puede
# estar corriendo y todavia no aceptar consultas. Con Neo4j eso no es teorico
# -- su puerto 7474 contesta antes de que la base acepte Cypher, y por eso su
# healthcheck usa cypher-shell y no un HTTP (esta explicado en
# docker-compose.yml). Si aqui se mirara "running", el ETL del grafo saldria
# contra un contenedor en verde que todavia no sabe contestar.
#
# El plazo va en SEGUNDOS y lo pone cada llamada, porque no todos tardan lo
# mismo: PostgreSQL levanta en dos, Neo4j se toma unos 40 y su healthcheck
# tiene start_period de 40s con 10 reintentos cada 15s. Un timeout corto aqui
# haria fallar el arranque en una maquina lenta con todo bien configurado.
#
# La plantilla lleva el {{if .State.Health}} y NO es adorno. Sobre un
# contenedor sin healthcheck declarado, "-f {{.State.Health.Status}}" no
# devuelve vacio ni "<no value>": revienta con
#
#   template parsing error: template: :1:8: executing "" at
#   <.State.Health.Status>: map has no entry for key "Health"
#
# que nunca va a ser igual a "healthy". Sin el if, esperar a un contenedor sin
# healthcheck consume el plazo ENTERO y despues declara muerto algo que estaba
# perfecto -- y el mensaje de error habla de PostgreSQL o de Neo4j, no de una
# plantilla de Go, asi que manda a buscar el problema al lugar equivocado.
# Medido contra mesh-pgadmin, que es justamente el contenedor de este proyecto
# que no tiene healthcheck.
function Esperar-Contenedor($nombre, $segundos) {
    $plantilla = '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}'
    $vueltas   = [int][math]::Ceiling($segundos / 2)

    for ($i = 0; $i -lt $vueltas; $i++) {
        $estado = "$(docker inspect -f $plantilla $nombre 2>&1)".Trim()
        if ($estado -eq "healthy") { return $true }

        # Sin healthcheck no hay nada que esperar: nadie va a poner ese
        # contenedor en "healthy" nunca. Se contesta que si en vez de gastar el
        # plazo entero para terminar mintiendo.
        if ($estado -eq "sin-healthcheck") { return $true }

        Start-Sleep -Seconds 2
    }
    return $false
}


# ------------------------------------------------------------
# Atajo: abrir la consola de MongoDB
# ------------------------------------------------------------
# Sin esto habria que acordarse de la linea completa con -u, -p y
# --authenticationDatabase. El usuario y la contrasena no se escriben: ya estan
# dentro del contenedor, puestos por el compose desde el .env.

if ($Mongo) {
    $corriendo = docker ps --filter "name=mesh-mongo" --filter "status=running" --format "{{.Names}}" 2>&1
    if ("$corriendo" -notmatch "mesh-mongo") {
        Error1 "MongoDB no esta corriendo. Corre primero:  .\arrancar.ps1"
        exit 1
    }
    # -it necesita una terminal de verdad. Si a este script lo llama otro
    # script (o algo sin consola), docker corta con "cannot attach stdin to a
    # TTY-enabled container". Con la entrada redirigida se usa solo -i.
    $banderas = if ([Console]::IsInputRedirected) { '-i' } else { '-it' }

    docker exec $banderas mesh-mongo sh -c 'mongosh -u $MONGO_INITDB_ROOT_USERNAME -p $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin $MONGO_INITDB_DATABASE'
    exit $LASTEXITCODE
}


# ------------------------------------------------------------
# Como se le habla a mongosh desde aqui
# ------------------------------------------------------------
# Las dos reglas salieron de probarlo, y las dos fallan de forma que enganan:
#
# 1. El comando va como argumento de "sh -c", NUNCA por la tuberia
#    (| docker exec -i). PowerShell 5.1 codifica lo que manda por la tuberia
#    con [Console]::OutputEncoding, que en Windows es UTF-8 CON BOM, y le pega
#    los bytes EF BB BF al inicio. La shell del contenedor los lee pegados al
#    primer comando y contesta "mongosh: not found" con un caracter invisible
#    delante. Cambiar [Console]::OutputEncoding a media corrida NO lo arregla:
#    PowerShell ya creo el escritor y lo sigue mandando.
#    Se comprueba asi:   'hola' | docker exec -i mesh-mongo od -c
#
# 2. Todo lo que lleve parentesis va en COMILLAS SIMPLES. PowerShell se come
#    las comillas dobles al armar la linea de un programa externo, y la shell
#    recibe los parentesis sueltos:  sh: 1: Syntax error: "(" unexpected
#
# psql no sufre lo primero: se traga el BOM sin quejarse, y por eso la
# contrasena de PostgreSQL si puede ir por tuberia mas abajo.
#
# El usuario y la contrasena no se escriben aqui: ya estan dentro del
# contenedor como variables de entorno, puestas por el compose desde el .env.
# Las expande la shell de adentro, asi que la contrasena nunca aparece en la
# lista de procesos de Windows. Van sin comillas porque los valores del .env
# no llevan espacios.

function Comando-Mongo($resto) {
    return 'mongosh --quiet' +
           ' -u $MONGO_INITDB_ROOT_USERNAME' +
           ' -p $MONGO_INITDB_ROOT_PASSWORD' +
           ' --authenticationDatabase admin' +
           ' $MONGO_INITDB_DATABASE ' + $resto
}


# ------------------------------------------------------------
# Como se le habla a cypher-shell desde aqui
# ------------------------------------------------------------
# La regla 2 de mongosh vale IGUAL aqui, y se pago por comprobarlo: la consulta
# de Cypher va entre COMILLAS SIMPLES dentro de la cadena, nunca entre dobles.
# Con dobles, PowerShell 5.1 las escapa al armar la linea del programa externo
# y cypher-shell las recibe como parte del texto de la consulta. No falla con
# "faltan comillas" ni con nada que mencione a PowerShell: falla con
#
#   Invalid input '': expected a graph pattern (line 1, column 6)
#   "MATCH"
#         ^
#
# que parece un error de Cypher y manda a revisar la consulta, que esta bien.
# Se comprueba asi:  docker exec mesh-neo4j sh -c '... "MATCH (n) RETURN n"'
#
# La contrasena no se escribe aqui. Sale de MESH_NEO4J_PASSWORD, que ya vive
# dentro del contenedor puesta por el compose desde el .env -- la misma que usa
# el healthcheck. La expande la shell de adentro, asi que no aparece en la
# lista de procesos de Windows, igual que con Mongo.
#
# El nombre de esa variable NO lleva el prefijo NEO4J_ y eso es obligatorio: la
# imagen trata cualquier NEO4J_* como un ajuste de neo4j.conf y tumba el
# arranque en bucle. Esta contado entero en docker-compose.yml.
#
# --format plain porque la salida la lee este script o una persona, no una
# tabla dibujada con guiones que despues habria que desarmar.
function Comando-Cypher($resto) {
    return 'cypher-shell -u neo4j -p $MESH_NEO4J_PASSWORD --format plain ' + $resto
}


# Una consulta a ClickHouse. Devuelve el texto de la respuesta, o $null si no se
# pudo preguntar. La regla es la misma que la de Contar-Nodos, aqui abajo: no se
# inventa un valor cuando la consulta falla, porque quien llama necesita poder
# distinguir "contesto cero" de "no contesto".
#
# En la marca de agua de los eventos esa diferencia cuesta caro. Un cero
# inventado significa "no he copiado nada todavia" y manda a recopiar la tabla
# entera; peor todavia, tapa el motivo real, que es que la base no contesta.
#
# LAS CREDENCIALES VAN COMO ARGUMENTOS Y NO DENTRO DE UN sh -c, y no es por
# gusto. El truco de Comando-Mongo y Comando-Cypher -- leerlas de las variables
# del propio contenedor -- aqui no se puede: obliga a armar una linea con
# comillas dobles, y PowerShell 5.1 se las come. Medido el 2026-09-06, la
# consulta llegaba cortada y ClickHouse contestaba
# "Syntax error: failed at position 7 (end of query)".
#
# El precio es que la contrasena queda a la vista de un `ps` mientras dura la
# llamada. Es el mismo precio que ya se paga en redis/prueba_carrito.sh con su
# `-a $REDIS_PASSWORD`, y en una maquina de clase se acepta. El dia que esto
# salga de local, la salida es mandar la consulta por la entrada estandar.
function Consultar-ClickHouse($sql) {
    $salida = docker exec -i mesh-clickhouse clickhouse-client `
        --user $env_['CLICKHOUSE_USER'] --password $env_['CLICKHOUSE_PASSWORD'] `
        --database $env_['CLICKHOUSE_DB'] --query $sql 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) { return $null }
    return $salida.Trim()
}


# Cuenta los nodos de una etiqueta del grafo. Devuelve $null si no se pudo
# contar, y quien llame decide que hacer: aqui no se inventa un cero, porque un
# cero inventado hace creer que el grafo esta vacio y dispara un ETL de mas (o
# peor, deja el arranque en rojo con todo bien).
#
# Se queda con la ULTIMA linea que sea solo digitos porque --format plain
# imprime primero el nombre de la columna y despues el valor.
function Contar-Nodos($etiqueta) {
    $salida = docker exec mesh-neo4j sh -c (Comando-Cypher "'MATCH (n:$etiqueta) RETURN count(n) AS n;'") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }

    $numeros = @($salida -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
    if ($numeros.Count -eq 0) { return $null }
    return [int]$numeros[-1]
}


# Lo mismo, pero para las ARISTAS. Existe porque no existia, y esa ausencia era
# el agujero mas grande de todo el arranque:
#
# Con el grafo cargado se borraron TODAS las relaciones dejando los 163 nodos
# intactos (MATCH ()-[r]->() DELETE r, 272 relaciones a 0) y se corrio
# .\arrancar.ps1 sin banderas. Imprimio "Ya cargado (Usuario 10/10, Producto
# 54/54, Resena 86/86)" -- o sea SALTO el ETL -- despues las mismas tres cuentas
# en verde, "Listo", y termino con EXIT 0. Sobre ese grafo la consulta de varios
# saltos contesta "0 anillos" y la de direcciones "0 pares": la entrega de 3
# puntos no senala ni una cuenta y el arranque dice que todo esta bien.
#
# Y no se autorepara: como los tres conteos de NODOS cuadran, el ETL no vuelve a
# correr en ningun arranque posterior. El hueco era permanente.
#
# El comentario de la seccion 9c ya nombraba ese peligro exacto -- "la consulta
# de anillos contestaria no hay nada raro, que es una respuesta creible y falsa"
# -- y despues el codigo solo contaba nodos. La consulta que faltaba estaba
# escrita hace rato en etl/cargar_grafo.sh, que si cuenta las cuatro relaciones.
function Contar-Aristas($tipo) {
    $salida = docker exec mesh-neo4j sh -c (Comando-Cypher "'MATCH ()-[r:$tipo]->() RETURN count(r) AS n;'") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }

    $numeros = @($salida -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
    if ($numeros.Count -eq 0) { return $null }
    return [int]$numeros[-1]
}


# El ETL corre en bash porque PowerShell se come las comillas al llamar a
# docker. Y OJO: "bash" a secas en el PATH de Windows es el de WSL, no el de
# Git, y ahi no hay docker ni las mismas rutas. Se busca al lado de git.exe,
# que esta instalado si o si en cualquier maquina que haya clonado el repo.
function Buscar-Bash {
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if ($git) {
        $alLado = Join-Path (Split-Path (Split-Path $git)) 'bin\bash.exe'
        if (Test-Path $alLado) { return $alLado }
    }
    foreach ($ruta in @(
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files (x86)\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if (Test-Path $ruta) { return $ruta }
    }
    return $null
}

# Nombre del volumen de Mongo. Compose lo arma con el nombre de la carpeta del
# proyecto en minusculas, asi que se calcula igual y no se escribe a mano: si
# alguien clona el repo en una carpeta con otro nombre, esto lo sigue.
$proyecto     = (Split-Path -Leaf $PSScriptRoot).ToLower()
$volumenMongo = "${proyecto}_mongo-data"


# Reescribe el usuario de Mongo con lo que dice el .env, SIN borrar los datos.
#
# La contrasena de Mongo no vive en el contenedor, vive en el volumen, y solo
# se valida si mongod arranca con autenticacion. Asi que se levanta un mongod
# temporal sobre el MISMO volumen con --noauth, se reescribe el usuario desde
# adentro, y se vuelve a levantar el de siempre. El catalogo no se toca.
#
# Es el equivalente al ALTER USER que se le hace a PostgreSQL mas arriba.
function Reparar-Mongo {
    Aviso "La contrasena del .env no es la que tiene la base. Reparando..."

    docker compose stop mongo 2>&1 | Out-Null
    docker rm -f mesh-mongo-reparar 2>&1 | Out-Null

    # --env-file y no -e: asi la contrasena no queda escrita en la linea de
    # comandos de Windows, igual que en el resto del script.
    docker run -d --name mesh-mongo-reparar `
        --env-file "$PSScriptRoot\.env" `
        -v "${volumenMongo}:/data/db" `
        mongo:8 mongod --noauth --bind_ip 127.0.0.1 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Error1 "No se pudo levantar el contenedor temporal de reparacion"
        docker compose up -d mongo 2>&1 | Out-Null
        return $false
    }

    $vivo = $false
    for ($i = 0; $i -lt 30; $i++) {
        docker exec mesh-mongo-reparar mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok' 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $vivo = $true; break }
        Start-Sleep -Seconds 2
    }

    if (-not $vivo) {
        Error1 "El mongod temporal no respondio"
        docker rm -f mesh-mongo-reparar 2>&1 | Out-Null
        docker compose up -d mongo 2>&1 | Out-Null
        return $false
    }

    # El usuario y la contrasena salen del .env que se le paso al contenedor,
    # no de esta linea. Las comillas simples van dobladas porque toda la
    # cadena es de comillas simples de PowerShell.
    $js = 'var u = process.env.MONGO_USER, p = process.env.MONGO_PASSWORD;' +
          ' var a = db.getSiblingDB(''admin'');' +
          ' if (a.getUser(u)) { a.updateUser(u, { pwd: p }); print(''usuario actualizado''); }' +
          ' else { a.createUser({ user: u, pwd: p, roles: [ { role: ''root'', db: ''admin'' } ] }); print(''usuario creado''); }'

    $resultado = docker exec mesh-mongo-reparar mongosh --quiet --eval $js 2>&1 | Out-String
    $codigo = $LASTEXITCODE

    docker rm -f mesh-mongo-reparar 2>&1 | Out-Null
    docker compose up -d mongo 2>&1 | Out-Null

    if ($codigo -ne 0) {
        Error1 "No se pudo reescribir el usuario:"
        Write-Host $resultado -ForegroundColor Red
        return $false
    }

    Ok $resultado.Trim()

    # Esperar a que el contenedor normal vuelva a estar sano
    if (Esperar-Contenedor "mesh-mongo" 120) { return $true }

    Error1 "MongoDB no volvio a levantar despues de la reparacion"
    return $false
}


# ------------------------------------------------------------
# 0. Credenciales
# ------------------------------------------------------------
Paso "Revisando el archivo .env"

if (-not (Test-Path "$PSScriptRoot\.env")) {
    Error1 "Falta el archivo .env"
    Error1 "Copialo de la plantilla y llena los valores:"
    Error1 "   copy .env.example .env"
    exit 1
}

# Lee el .env a un diccionario para poder generar los archivos de pgAdmin
$env_ = @{}
foreach ($linea in Get-Content "$PSScriptRoot\.env") {
    $texto = $linea.Trim()
    if ($texto -eq "" -or $texto.StartsWith("#")) { continue }
    $partes = $texto.Split("=", 2)
    if ($partes.Count -eq 2) { $env_[$partes[0].Trim()] = $partes[1].Trim() }
}

# Esta lista tiene que llevar TODAS las variables que docker-compose.yml marca
# con ":?" -- si no, el arranque muere doce pasos mas adelante con un
# "Fallo docker compose up" que no dice cual falta.
#
# Ya paso: al agregar Redis y Neo4j se agregaron REDIS_PASSWORD y
# NEO4J_PASSWORD al compose y NO a esta lista. El .env no se sube al
# repositorio, asi que a quien hizo pull le faltaban las dos, y el script le
# dijo "Credenciales leidas" -- en verde -- antes de morir con un mensaje que
# no mencionaba ni Redis ni Neo4j ni el .env. Perdio la tarde buscando en Docker
# un problema que estaba en un archivo de texto.
#
# La regla: agregar un servicio al compose con una variable obligatoria incluye
# agregarla AQUI y a .env.example, en la misma pasada.
$faltantes = @()
# Son las TRECE que docker-compose.yml marca con ":?". Se comprueba con:
#   las de   grep -o '\${[A-Z0-9_]*:?' docker-compose.yml
#   tienen que estar todas en esta lista.
# PGADMIN_EMAIL y PGADMIN_PASSWORD llevaban aqui desde siempre y faltaban: el
# mismo fallo, sin descubrir, esperando al primero que armara su .env a mano.
foreach ($obligatoria in @("DB_USER", "DB_PASSWORD", "DB_NAME",
                          "MONGO_USER", "MONGO_PASSWORD", "MONGO_DB",
                          "PGADMIN_EMAIL", "PGADMIN_PASSWORD",
                          "REDIS_PASSWORD", "NEO4J_PASSWORD",
                          "CLICKHOUSE_DB", "CLICKHOUSE_USER", "CLICKHOUSE_PASSWORD")) {
    if (-not $env_[$obligatoria] -or $env_[$obligatoria] -eq "cambiame") {
        $faltantes += $obligatoria
    }
}

# Se juntan y se reportan TODAS de una vez. Reportar la primera y salir obliga a
# correr el script una vez por variable que falte, y con dos nuevas eso son tres
# arranques para enterarse de algo que se sabia desde el primero.
if ($faltantes.Count -gt 0) {
    Error1 "Falta llenar en el .env: $($faltantes -join ', ')"
    Error1 ""
    Error1 "Si actualizaste el repositorio, son variables NUEVAS: tu .env es tuyo"
    Error1 "y no viene en el pull. Copia las lineas que te falten de .env.example"
    Error1 "y ponles el mismo valor que ya usas en las otras."
    Error1 ""
    Error1 "NEO4J_PASSWORD tiene que tener 8 caracteres o mas, o Neo4j no arranca."
    exit 1
}
Ok "Credenciales leidas"

# pgAdmin necesita estos dos archivos para conectarse solo. Se generan aqui a
# partir del .env para que las contrasenas no queden en el repositorio.
#
# OJO: pgAdmin lee servers.json UNA SOLA VEZ, cuando crea su base de configuracion
# en el volumen pgadmin-data. Si ya existe, este archivo se regenera pero pgAdmin
# ni lo mira, y el arbol sigue como estaba. Para que un cambio de aqui surta
# efecto hay que recrear ese volumen:
#
#   docker compose rm -sf pgadmin
#   docker volume rm proyecto-tienda-base-datos-2_pgadmin-data
#   docker compose up -d pgadmin
#
# Eso NO toca la base de datos: el volumen de pgAdmin solo guarda sus preferencias.
Paso "Generando la configuracion de pgAdmin"

$carpetaPgadmin = "$PSScriptRoot\docker\pgadmin"
if (-not (Test-Path $carpetaPgadmin)) {
    New-Item -ItemType Directory -Path $carpetaPgadmin -Force | Out-Null
}

$servidores = @{
    Servers = @{
        "1" = @{
            Name           = "Mesh"
            Group          = "Servers"
            Host           = "postgres"
            Port           = 5432
            MaintenanceDB  = $env_["DB_NAME"]
            Username       = $env_["DB_USER"]
            SSLMode        = "prefer"
            PassFile       = "/tmp/pgpass"
        }
    }
}
# Se escribe con WriteAllText y no con Set-Content a proposito. En PowerShell 5.1
# "-Encoding utf8" mete un BOM al inicio del archivo, y pgAdmin lo rechaza con
# "Unexpected UTF-8 BOM": el servidor no queda registrado y su arbol sale vacio
# aunque las tablas existan. UTF8Encoding($false) es el que no pone BOM.
$json = $servidores | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText(
    "$carpetaPgadmin\servers.json",
    $json,
    (New-Object System.Text.UTF8Encoding($false))
)

# Formato del pgpass: servidor:puerto:base:usuario:contrasena
# El * en la base hace que sirva para todas, no solo para la principal.
"postgres:5432:*:$($env_['DB_USER']):$($env_['DB_PASSWORD'])" |
    Set-Content -LiteralPath "$carpetaPgadmin\pgpass" -Encoding ascii
Ok "servers.json y pgpass generados"


# ------------------------------------------------------------
# 1. Docker
# ------------------------------------------------------------
Paso "Revisando Docker"

docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Aviso "Docker esta apagado, lo arranco"
    $exe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path $exe)) {
        Error1 "No encuentro Docker Desktop. Instalalo primero."
        exit 1
    }
    Start-Process -FilePath $exe -ArgumentList "-Autostart"

    for ($i = 0; $i -lt 120; $i += 5) {
        Start-Sleep -Seconds 5
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        Write-Host "   esperando al engine... ${i}s" -ForegroundColor DarkGray
    }

    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Error1 "Docker no arranco en 2 minutos."
        exit 1
    }
}
Ok "Docker listo"


# ------------------------------------------------------------
# 2. Contenedores
# ------------------------------------------------------------
if ($Reiniciar) {
    Paso "Borrando datos anteriores"
    docker compose down -v 2>&1 | Out-Null
    Ok "Volumenes eliminados"
}

if ($ReiniciarMongo) {
    Paso "Rehaciendo solo MongoDB"
    docker compose rm -sf mongo 2>&1 | Out-Null
    docker volume rm $volumenMongo 2>&1 | Out-Null
    Ok "Volumen de MongoDB eliminado. PostgreSQL no se toco."
}

Paso "Levantando contenedores"
docker compose up -d 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Error1 "Fallo docker compose up. Corre el comando a mano para ver el error."
    exit 1
}
Ok "Contenedores arriba"


# ------------------------------------------------------------
# 3. Esperar a PostgreSQL
# ------------------------------------------------------------
Paso "Esperando a PostgreSQL"

$listo = Esperar-Contenedor "mesh-postgres" 120

if (-not $listo) {
    Error1 "PostgreSQL no respondio. Mira el log:"
    Error1 "docker logs mesh-postgres --tail 30"
    exit 1
}
Ok "PostgreSQL respondiendo"


# ------------------------------------------------------------
# 4. Contrasena
# ------------------------------------------------------------
Paso "Sincronizando la contrasena"

# POSTGRES_PASSWORD del docker-compose solo se aplica UNA vez: cuando el volumen
# esta vacio y la base se crea. Si despues se edita el .env, el contenedor informa
# la contrasena nueva pero la base sigue guardando la vieja. Desde dentro no se
# nota (pg_hba.conf usa "trust" y no pregunta nada), pero el backend se conecta
# desde fuera, donde si se valida, y falla con:
#
#   28P01: la autentificacion password fallo para el usuario "..."
#
# Justamente porque desde dentro es "trust", aqui se puede reescribir sin conocer
# la anterior. Si ya coincidia no cambia nada, asi que correrlo siempre es seguro.
#
# Va contra la base "postgres", que existe siempre, y no contra DB_NAME: asi el
# paso tambien funciona cuando la base del proyecto todavia no esta creada.

$usuario = $env_["DB_USER"]
# Se duplican las comillas simples por si la contrasena lleva una
$clave = $env_["DB_PASSWORD"].Replace("'", "''")
$sql = 'ALTER USER "{0}" WITH PASSWORD ''{1}'';' -f $usuario, $clave

# La sentencia entra por stdin y no por -c para que la contrasena no quede
# escrita en la linea de comandos del proceso
$salidaClave = $sql | docker exec -i mesh-postgres psql -U $usuario -d postgres -v ON_ERROR_STOP=1 -q 2>&1 | Out-String

if ($LASTEXITCODE -eq 0) {
    Ok "Contrasena al dia"
} elseif ($salidaClave -match "does not exist|no existe") {
    # El volumen se creo con OTRO usuario: no hay nada que reescribir
    Error1 "El usuario '$usuario' no existe en la base."
    Error1 "El volumen se creo con otras credenciales. Para empezar de cero:"
    Error1 "   .\arrancar.ps1 -Reiniciar"
    exit 1
} else {
    Error1 "No se pudo fijar la contrasena:"
    Write-Host $salidaClave -ForegroundColor Red
    exit 1
}


# ------------------------------------------------------------
# 5. Migraciones
# ------------------------------------------------------------
# Son dos clases de archivo y dos pasos, no uno:
#
#   migrations/*.sql        el esquema: las tablas y los catalogos de estado
#   migrations/datos/*.sql  los conjuntos de datos de prueba
#
# El esquema primero, porque los datos no tienen donde entrar sin el. Cada paso
# va en orden de nombre. El Get-ChildItem no lleva -Recurse a proposito: asi la
# carpeta datos/ no se le cuela al primer paso y no queda un archivo de datos
# corriendo en medio del esquema, dependiendo de como ordene los nombres.
#
# La carpeta esta montada dentro del contenedor en /migrations, y la de datos
# cae sola en /migrations/datos.

# ------------------------------------------------------------
# El ETL, en PowerShell nativo
# ------------------------------------------------------------
# Hace lo mismo que etl/correr.sh -- extrae de PostgreSQL y carga en Mongo --
# pero SIN depender de Git Bash.
#
# Antes esto llamaba a correr.sh a traves del bash de Git, y si no lo
# encontraba se saltaba el ETL con un aviso amarillo: el script terminaba en
# verde con el catalogo de Mongo vacio. Los productos estaban en PostgreSQL,
# pero la tienda los lee de Mongo, asi que salia vacia sin que nada lo dijera.
#
# Los archivos van y vienen con `docker cp`, NUNCA por tuberia. PowerShell 5.1
# codifica lo que manda por la tuberia en UTF-8 con BOM y le pega EF BB BF al
# principio, que del otro lado rompe el SQL y el JavaScript. `docker cp` mueve
# los bytes tal cual.
#
# El JSON intermedio da un rodeo por el disco (contenedor -> local -> otro
# contenedor) porque los dos contenedores no comparten volumen. Son unos pocos
# cientos de KB y se borra al terminar.
function Correr-Etl {
    $tmp = Join-Path $env:TEMP "mesh-etl"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    $usuario = $env_["DB_USER"]
    $base    = $env_["DB_NAME"]

    # Cada consulta y su archivo de salida
    $pasos = @(
        @{ sql = "extraer.sql";            salida = "mesh-productos.json";  que = "productos" },
        @{ sql = "extraer_categorias.sql"; salida = "mesh-categorias.json"; que = "categorias" }
    )

    foreach ($p in $pasos) {
        $local = Join-Path $tmp $p.salida

        docker cp "$PSScriptRoot\etl\$($p.sql)" "mesh-postgres:/tmp/$($p.sql)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Error1 "No se pudo copiar $($p.sql) al contenedor"; exit 1 }

        # La redireccion ocurre DENTRO del contenedor: asi la salida nunca pasa
        # por PowerShell y no se le cambia la codificacion por el camino.
        $err = docker exec mesh-postgres sh -c "psql -U $usuario -d $base -qtAX -v ON_ERROR_STOP=1 -f /tmp/$($p.sql) > /tmp/$($p.salida)" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Error1 "El ETL fallo extrayendo $($p.que):"
            Write-Host $err -ForegroundColor Red
            exit 1
        }

        docker cp "mesh-postgres:/tmp/$($p.salida)" "$local" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Error1 "No se pudo traer $($p.salida) de PostgreSQL"; exit 1 }

        # Un archivo vacio aqui quiere decir que la consulta no devolvio nada.
        # Cargarlo dejaria Mongo vacio sin un solo error, que es justo el fallo
        # que esta comprobacion existe para evitar.
        if (-not (Test-Path $local) -or (Get-Item $local).Length -eq 0) {
            Error1 "La consulta de $($p.que) no devolvio ni una fila."
            Error1 "Revisa que migrations/datos/ se haya cargado en PostgreSQL."
            exit 1
        }

        docker cp "$local" "mesh-mongo:/tmp/$($p.salida)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Error1 "No se pudo copiar $($p.salida) a Mongo"; exit 1 }
    }

    docker cp "$PSScriptRoot\etl\cargar.js" "mesh-mongo:/tmp/cargar.js" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Error1 "No se pudo copiar cargar.js a Mongo"; exit 1 }

    $salida = docker exec mesh-mongo sh -c (Comando-Mongo "--file /tmp/cargar.js") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Error1 "El ETL fallo cargando en MongoDB:"
        Write-Host $salida -ForegroundColor Red
        exit 1
    }

    foreach ($linea in ($salida -split "`n")) {
        if ($linea.Trim()) { Ok $linea.Trim() }
    }

    # ------------------------------------------------------------
    # TERCERA etapa: la nota del catalogo
    # ------------------------------------------------------------
    # Va aparte del bucle de $pasos de arriba por una razon concreta: ese bucle
    # trata un archivo VACIO como un fallo que corta el arranque, y aqui un
    # archivo vacio es perfectamente legitimo. Quiere decir que no hay ni una
    # resena en toda la base, que es como nace una base recien reiniciada.
    #
    # Y va DESPUES de cargar.js, nunca antes: cargar.js reemplaza el documento
    # entero con replaceOne y le pasaria por encima. La cabecera de
    # etl/cargar_notas.js lo explica.
    #
    # Esto tiene que existir aqui aunque etl/correr.sh ya lo haga, porque
    # arrancar.ps1 NO llama a correr.sh: rehace los pasos en PowerShell para no
    # depender de Git Bash. Son dos caminos para lo mismo y los dos tienen que
    # llevar las tres etapas, o la nota se arreglaria solo para quien corra el
    # ETL desde bash.
    $notasJson = Join-Path $tmp "mesh-notas.json"

    docker cp "$PSScriptRoot\etl\extraer_notas.sql" "mesh-postgres:/tmp/extraer_notas.sql" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Error1 "No se pudo copiar extraer_notas.sql al contenedor"; exit 1 }

    $err = docker exec mesh-postgres sh -c "psql -U $usuario -d $base -qtAX -v ON_ERROR_STOP=1 -f /tmp/extraer_notas.sql > /tmp/mesh-notas.json" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Error1 "El ETL fallo extrayendo las notas:"
        Write-Host $err -ForegroundColor Red
        exit 1
    }

    docker cp "mesh-postgres:/tmp/mesh-notas.json" "$notasJson" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Error1 "No se pudo traer mesh-notas.json de PostgreSQL"; exit 1 }

    docker cp "$notasJson" "mesh-mongo:/tmp/mesh-notas.json" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Error1 "No se pudo copiar mesh-notas.json a Mongo"; exit 1 }

    docker cp "$PSScriptRoot\etl\cargar_notas.js" "mesh-mongo:/tmp/cargar_notas.js" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Error1 "No se pudo copiar cargar_notas.js a Mongo"; exit 1 }

    $salidaNotas = docker exec mesh-mongo sh -c (Comando-Mongo "--file /tmp/cargar_notas.js") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Error1 "El ETL fallo escribiendo la nota del catalogo:"
        Write-Host $salidaNotas -ForegroundColor Red
        exit 1
    }

    foreach ($linea in ($salidaNotas -split "`n")) {
        if ($linea.Trim()) { Ok $linea.Trim() }
    }

    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}


# ------------------------------------------------------------
# El ETL del buscador, tambien en PowerShell nativo
# ------------------------------------------------------------
# Donde vive el motor y como se llama su indice. Los mismos valores por defecto
# que etl/cargar_busqueda.sh y pruebas/busqueda.sh; si un dia cambian, cambian
# en los tres.
$ES_URL    = 'http://localhost:9200'
$ES_INDICE = 'mesh_productos'

# Hace lo mismo que etl/cargar_busqueda.sh sin depender de Git Bash, por la
# misma razon que los otros dos: cuando esto llamaba a un .sh y no lo
# encontraba, se saltaba el paso y el script terminaba EN VERDE con la base
# derivada vacia.
#
# SALE DE MONGO Y NO DE POSTGRESQL. Es la decision del ETL entero y esta
# contada en elastic/README.md: hay productos que existen solo en el catalogo
# de Mongo, se venden, y un indice armado desde `productos` de PostgreSQL no
# los tendria. El sintoma seria un producto que el buscador jura que no existe.
#
# Aqui SI se usa docker cp, al reves que en el .sh. No es incoherencia: el .sh
# lo evita porque Git Bash le destroza las rutas, y PowerShell no tiene ese
# problema.
function Correr-EtlBusqueda {
    $tmp = Join-Path $env:TEMP "mesh-busqueda"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $ndjson = Join-Path $tmp "busqueda.ndjson"

    try {
        docker cp "$PSScriptRoot\etl\extraer_busqueda.js" "mesh-mongo:/tmp/extraer_busqueda.js" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Aviso "No se pudo copiar extraer_busqueda.js a Mongo"; return $false }

        $salida = docker exec mesh-mongo sh -c (Comando-Mongo "/tmp/extraer_busqueda.js") 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Aviso "El extractor del buscador fallo:"
            Write-Host $salida -ForegroundColor Yellow
            return $false
        }
        foreach ($linea in ($salida -split "`n")) { if ($linea.Trim()) { Ok $linea.Trim() } }

        docker cp "mesh-mongo:/tmp/mesh-busqueda.ndjson" "$ndjson" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Aviso "No se pudo traer el ndjson de Mongo"; return $false }

        # Un archivo vacio aqui deja el indice vacio sin un solo error, que es
        # justo el fallo que esta comprobacion existe para evitar.
        if (-not (Test-Path $ndjson) -or (Get-Item $ndjson).Length -eq 0) {
            Aviso "El extractor no devolvio ni un producto: no se toca el indice"
            return $false
        }

        # El indice se tira entero y se rehace. Es una proyeccion: no guarda
        # nada que no este en Mongo, y reconstruir es la unica forma de que
        # DESAPAREZCA lo que dejo de ser publico.
        #
        # El 404 del DELETE se traga a proposito: la primera vez no existe.
        try { Invoke-RestMethod -Method Delete -Uri "$ES_URL/$ES_INDICE" -TimeoutSec 30 | Out-Null } catch { }

        try {
            Invoke-RestMethod -Method Put -Uri "$ES_URL/$ES_INDICE" `
                -ContentType 'application/json' `
                -InFile "$PSScriptRoot\elastic\001_indice.json" -TimeoutSec 60 | Out-Null
        } catch {
            Aviso "No se pudo crear el indice: $($_.Exception.Message)"
            return $false
        }
        Ok "indice creado con el mapeo de elastic/001_indice.json"

        # -InFile y no -Body: el ndjson viaja tal cual, sin que PowerShell le
        # cambie la codificacion ni le meta un BOM por el camino. Un BOM al
        # principio del bulk lo rechaza entero.
        #
        # refresh=true para que lo cargado se pueda buscar en cuanto termine,
        # y para que el conteo de aqui abajo no cuente cero sobre un indice
        # que si tiene datos.
        try {
            $r = Invoke-RestMethod -Method Post -Uri "$ES_URL/$ES_INDICE/_bulk?refresh=true" `
                -ContentType 'application/x-ndjson' -InFile $ndjson -TimeoutSec 300
        } catch {
            Aviso "El bulk fallo: $($_.Exception.Message)"
            return $false
        }

        # _bulk contesta 200 aunque documentos sueltos hayan fallado. El unico
        # sitio donde eso se ve es `errors`.
        if ($r.errors) {
            Aviso "El bulk acepto la peticion pero algun documento fallo"
            return $false
        }

        $cuenta = (Invoke-RestMethod -Uri "$ES_URL/$ES_INDICE/_count" -TimeoutSec 30).count
        Ok "documentos en el indice: $cuenta"
        return $true
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}


# ------------------------------------------------------------
# El ETL del grafo, tambien en PowerShell nativo
# ------------------------------------------------------------
# Hace lo mismo que etl/cargar_grafo.sh -- aplica el esquema, extrae de
# PostgreSQL y carga en Neo4j -- pero SIN depender de Git Bash, exactamente por
# la razon que dice el ETL de Mongo aqui arriba y que etl/README.md cuenta con
# nombre y apellido: cuando esto llamaba a un .sh a traves del bash de Git y no
# lo encontraba, se saltaba el ETL con un aviso amarillo y el script terminaba
# EN VERDE con la base derivada vacia. Paso de verdad con Mongo, en la maquina
# de un companero, y no se va a repetir con el grafo: aqui no hay ni una rama
# que avise y siga. Todo fallo de este ETL corta el arranque.
#
# Los archivos van con `docker cp`, igual que los de Mongo y NUNCA por tuberia.
# PowerShell 5.1 codifica lo que manda por la tuberia en UTF-8 con BOM y le
# pega EF BB BF al principio; del otro lado el SQL y el Cypher llegan rotos.
#
# El .cypher intermedio da el mismo rodeo por el disco que el JSON de Mongo
# (contenedor -> local -> otro contenedor) porque mesh-postgres y mesh-neo4j no
# comparten volumen. Son unos 20 KB y se borra al terminar.
#
# Ni el esquema ni la consulta se leen del volumen ./neo4j que el compose monta
# en el contenedor: van por docker cp los dos. Es a proposito y es la misma
# decision que tomo cargar_grafo.sh -- si alguien toca ese montaje en
# docker-compose.yml, esto sigue cargando en vez de fallar por un archivo que
# "estaba ahi".
function Correr-EtlGrafo($limpiar) {
    $tmp = Join-Path $env:TEMP "mesh-etl-grafo"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    $usuario = $env_["DB_USER"]
    $base    = $env_["DB_NAME"]

    # --- 1. El esquema, SIEMPRE y antes de cargar ---
    # Va en cada corrida y no una sola vez porque el MERGE del ETL se apoya en
    # las restricciones de unicidad para no duplicar. Si alguien levanta Neo4j
    # con el volumen vacio, las restricciones se fueron con el, y un ETL que no
    # las reaplique empieza a crear nodos repetidos sin dar un solo error.
    # Todo el 001 lleva IF NOT EXISTS, asi que repetirlo cuesta milisegundos.
    docker cp "$PSScriptRoot\neo4j\001_esquema.cypher" "mesh-neo4j:/tmp/001_esquema.cypher" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Error1 "No se pudo copiar 001_esquema.cypher a Neo4j"; exit 1 }

    $salidaEsquema = docker exec mesh-neo4j sh -c (Comando-Cypher "--file /tmp/001_esquema.cypher") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Error1 "El ETL del grafo fallo aplicando el esquema:"
        Write-Host $salidaEsquema -ForegroundColor Red
        exit 1
    }
    Ok "esquema del grafo aplicado (restricciones e indices)"

    # --- 2. El borrado, solo si lo piden ---
    # DETACH DELETE y no DELETE: DELETE sobre un nodo con relaciones falla, y
    # con 86 resenas todo nodo tiene relaciones. Se puede borrar sin miedo
    # porque el grafo es una PROYECCION: no hay ni un dato aqui que no exista
    # en PostgreSQL.
    if ($limpiar) {
        $salidaBorrado = docker exec mesh-neo4j sh -c (Comando-Cypher "'MATCH (n) DETACH DELETE n;'") 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Error1 "No se pudo vaciar el grafo:"
            Write-Host $salidaBorrado -ForegroundColor Red
            exit 1
        }
        Ok "grafo vaciado: se reconstruye desde cero"
    }

    # --- 3. Extraer de PostgreSQL ---
    # ON_ERROR_STOP=1 es obligatorio y no una precaucion: sin el, psql se salta
    # la sentencia que fallo, sigue con las demas y termina en cero. El archivo
    # de salida quedaria con un script de Cypher INCOMPLETO, cypher-shell lo
    # cargaria contento, y el grafo se quedaria con la mitad de las relaciones
    # sin que nadie se entere. Es el peor final posible: parece que funciono.
    docker cp "$PSScriptRoot\etl\extraer_grafo.sql" "mesh-postgres:/tmp/extraer_grafo.sql" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Error1 "No se pudo copiar extraer_grafo.sql al contenedor"; exit 1 }

    # La redireccion ocurre DENTRO del contenedor, igual que en el ETL de
    # Mongo: asi la salida nunca pasa por PowerShell y no se le cambia la
    # codificacion por el camino.
    $errExtraer = docker exec mesh-postgres sh -c "psql -U $usuario -d $base -qtAX -v ON_ERROR_STOP=1 -f /tmp/extraer_grafo.sql > /tmp/mesh-grafo.cypher" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Error1 "El ETL del grafo fallo extrayendo de PostgreSQL:"
        Write-Host $errExtraer -ForegroundColor Red
        exit 1
    }

    $local = Join-Path $tmp "mesh-grafo.cypher"
    docker cp "mesh-postgres:/tmp/mesh-grafo.cypher" "$local" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Error1 "No se pudo traer mesh-grafo.cypher de PostgreSQL"; exit 1 }

    # Un archivo vacio aqui quiere decir que la consulta no devolvio nada.
    # Cargarlo dejaria el grafo vacio sin un solo error, que es justo el fallo
    # que esta comprobacion existe para evitar: las sentencias de resenas
    # empiezan con tres MATCH, y si los nodos no estuvieran no fallarian,
    # simplemente no crearian nada.
    if (-not (Test-Path $local) -or (Get-Item $local).Length -eq 0) {
        Error1 "La consulta del grafo no devolvio ni una linea."
        Error1 "Revisa que migrations/datos/ se haya cargado en PostgreSQL."
        exit 1
    }

    # --- 4. Cargar en Neo4j ---
    docker cp "$local" "mesh-neo4j:/tmp/mesh-grafo.cypher" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Error1 "No se pudo copiar mesh-grafo.cypher a Neo4j"; exit 1 }

    $salidaCarga = docker exec mesh-neo4j sh -c (Comando-Cypher "--file /tmp/mesh-grafo.cypher") 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Error1 "El ETL del grafo fallo cargando en Neo4j:"
        Write-Host $salidaCarga -ForegroundColor Red
        exit 1
    }
    Ok "grafo cargado desde PostgreSQL"

    # --- 5. Vaciar la cola del outbox ---
    # `evento_grafo` es la cola de la migracion 015: un trigger sobre `resena`
    # encola el id de cada resena que se toca, en la misma transaccion.
    #
    # Esto hace falta AQUI y no solo en etl/cargar_grafo.sh porque esta funcion
    # NO llama a ese script -- repite sus pasos en linea, por las razones que
    # explica su cabecera. Sin este bloque, un arranque normal dejaria la base
    # recien creada con sus 90 eventos pendientes para siempre sobre un grafo
    # perfectamente correcto: la semilla los encola (el trigger ya existe
    # cuando migrations/datos/ corre) y nadie los marcaria nunca.
    #
    # Va DESPUES de cargar, nunca antes: si la carga falla el script ya salio
    # con exit 1 mas arriba y los eventos siguen pendientes, que es lo correcto.
    # Un evento marcado como hecho sin haberse proyectado es una resena que
    # nadie va a volver a mirar.
    #
    # Y se marca TODO lo pendiente porque esta carga fue COMPLETA: acaba de
    # aplicar el estado actual de todas las resenas, asi que no queda nada de la
    # cola por hacer.
    #
    # Si la tabla no existe (una base que todavia no aplico la 015) no es un
    # error: se calla y sigue. Por eso el to_regclass en vez de un try/catch.
    $sqlCola = @"
SELECT (to_regclass('public.evento_grafo') IS NOT NULL) AS hay_cola \gset
\if :hay_cola
    WITH marcados AS (
        UPDATE evento_grafo SET procesado_en = now()
         WHERE procesado_en IS NULL
        RETURNING 1)
    SELECT count(*) FROM marcados;
\else
    SELECT 0;
\endif
"@
    $archivoCola = Join-Path $tmp "vaciar_cola.sql"
    Set-Content -Path $archivoCola -Value $sqlCola -Encoding utf8
    docker cp "$archivoCola" "mesh-postgres:/tmp/vaciar_cola.sql" 2>&1 | Out-Null

    $marcados = (docker exec mesh-postgres psql -U $usuario -d $base -qtAX -f /tmp/vaciar_cola.sql 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $marcados -match '^\d+$') {
        Ok "cola del outbox vaciada ($marcados evento(s) marcados como proyectados)"
    } else {
        # No se aborta el arranque por esto. El grafo esta cargado y correcto;
        # lo unico que queda mal es que la cola diga que falta algo que no
        # falta, y eso se arregla con la proxima corrida del ETL.
        Aviso "   No se pudo vaciar la cola del outbox. El grafo esta cargado igual."
    }

    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}


# El cuarto argumento dice si se le perdona a un archivo el error "already
# exists". Existe porque las dos carpetas NO se parecen en esto:
#
#   migrations/*.sql        se perdona. Son CREATE TABLE / CREATE TYPE, y sobre
#                           una base ya migrada fallan asi de propio. Es la
#                           forma en que este script sabe que ya estaban.
#
#   migrations/datos/*.sql  NO se perdona, y es lo que arregla un fallo real.
#                           Ese archivo no es idempotente, asi que sobre una
#                           base con datos muere en el primer INSERT repetido
#                           con "duplicate key value violates unique
#                           constraint" -- cuyo DETAIL de psql dice, palabra
#                           por palabra, "Key (nombre)=(Electronica) already
#                           exists." El perdon lo agarraba por esa linea y
#                           pintaba un "ya estaba aplicada" amarillo y
#                           tranquilizador con el archivo cargado hasta la
#                           linea 99 de 10000. Sobre una base a medias, eso
#                           deja el conjunto de datos incompleto y el arranque
#                           en verde.
#
# O sea: el perdon no distingue "esto ya estaba" de "esto choco a la mitad".
# Para el esquema la diferencia no importa porque un CREATE no deja nada a
# medias; para los datos es la diferencia entre cargado y roto. Ahora los datos
# se saltan enteros cuando la base ya los tiene (ver mas abajo) y, si igual
# llegan a correr, cualquier error los tumba fuerte.
function Correr-Migraciones($carpeta, $rutaContenedor, $etiqueta, $perdonarExistente) {
    $scripts = @(Get-ChildItem -LiteralPath $carpeta -Filter "*.sql" -ErrorAction SilentlyContinue | Sort-Object Name)

    if ($scripts.Count -eq 0) {
        Aviso "No hay archivos .sql en $etiqueta"
        return
    }

    foreach ($s in $scripts) {
        # ON_ERROR_STOP corta si algo falla, en vez de dejar la base a medias
        $salida = docker exec mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -v ON_ERROR_STOP=1 -q -f "$rutaContenedor/$($s.Name)" 2>&1 | Out-String

        if ($LASTEXITCODE -eq 0) {
            Ok "$etiqueta$($s.Name)"
        } elseif ($perdonarExistente -and ($salida -match "already exists")) {
            Aviso "$etiqueta$($s.Name) ya estaba aplicada"
        } else {
            Error1 "$etiqueta$($s.Name) FALLO"
            Write-Host $salida -ForegroundColor Red
            exit 1
        }
    }
}

Paso "Corriendo migraciones del esquema"
Correr-Migraciones "$PSScriptRoot\migrations" "/migrations" "migrations/" $true


# ------------------------------------------------------------
# 5b. Los conjuntos de datos solo entran en una base VACIA
# ------------------------------------------------------------
# migrations/datos/001_catalogo.sql NO es idempotente: 15 de sus 20 INSERT no
# llevan guardia. Corrrerlo sobre una base que ya tiene el conjunto muere en la
# primera categoria repetida, y hasta hoy este script lo corria en CADA
# arranque. Que pasaba en el segundo arranque, medido y no supuesto:
#
#   psql:/migrations/datos/001_catalogo.sql:99: ERROR: duplicate key value
#   violates unique constraint "idx_categorias_nombre_raiz"
#   DETAIL: Key (nombre)=(Electronica) already exists.
#
# psql sale con codigo 3, y el "already exists" del DETAIL caia justo en el
# perdon de Correr-Migraciones. Resultado: un "ya estaba aplicada" amarillo, el
# arranque terminando en verde, y el archivo aplicado hasta la linea 99 de mas
# de diez mil. Sobre una base entera no se nota; sobre una base a medias
# (alguien recargando datos, un -Reiniciar interrumpido) deja el conjunto
# incompleto DICIENDO que estaba bien.
#
# La guardia es la base misma y no una tabla de control: si hay productos, el
# conjunto ya entro. Se mira `productos` porque es lo primero que carga el
# archivo despues de las categorias, y porque es la tabla de la que cuelga todo
# lo demas -- ofertas, resenas y pedidos no existen sin ella.
#
# Lo que esta guardia NO puede hacer, y hay que decirlo: si manana se agrega un
# migrations/datos/002_*.sql, este arranque tampoco lo va a correr, porque la
# base ya tiene productos. No es un descuido -- es que estos archivos no se
# pueden correr sobre una base cargada, punto. La via para ese caso es
# -Reiniciar (rehace todo desde cero) o correr ese archivo a mano. Se avisa en
# amarillo en cada arranque justamente para que nadie suponga otra cosa.
Paso "Corriendo conjuntos de datos"

$productosEnBase = ("SELECT count(*) FROM productos;" |
    docker exec -i mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX 2>&1 | Out-String).Trim()

if (($productosEnBase -match '^\d+$') -and ([int]$productosEnBase -gt 0)) {
    Aviso "La base ya tiene $productosEnBase productos: me salto migrations/datos/"
    Aviso "Esos archivos no son idempotentes y solo entran en una base vacia."
    Aviso "Para recargarlos desde cero:  .\arrancar.ps1 -Reiniciar"
} else {
    # Sin perdon: aqui la base esta vacia, asi que cualquier error es un error
    # de verdad y tiene que tumbar el arranque en vez de disfrazarse de "ya
    # estaba aplicada".
    Correr-Migraciones "$PSScriptRoot\migrations\datos" "/migrations/datos" "migrations/datos/" $false
}


# ------------------------------------------------------------
# 5c. Un lote extra de productos y ofertas, solo si se pidio
# ------------------------------------------------------------
# El generador es migrations/lote/generar_lote.sql y vive en una SUBCARPETA a
# proposito. Los dos bucles de migraciones de aqui arriba usan Get-ChildItem sin
# -Recurse, asi que ninguno lo ve nunca: no hay forma de que un arranque normal
# lo corra por accidente, ni siquiera el dia que alguien renombre archivos. La
# unica puerta que tiene es la bandera -Productos.
#
# Por que este paso va AQUI, entre los conjuntos de datos y MongoDB
# ------------------------------------------------------------------
# Son dos razones y la segunda es la que de verdad manda.
#
# 1. Es la ultima costura donde todavia se escribe en PostgreSQL. A esta altura
#    ya estan garantizados el contenedor sano, la contrasena sincronizada y el
#    esquema aplicado, que es todo lo que el generador necesita para correr, y
#    todavia no ha empezado nada que dependa de las filas que va a crear.
#
# 2. Sobre todo: puesto aqui NO hace falta forzar el ETL. La guardia del tope de
#    id de la seccion 7 hace ese trabajo sola, y hace falta ser preciso sobre
#    CUAL de las dos guardias es, porque la otra no se puede usar de excusa:
#
#    - La comparacion de CUENTAS no sirve para esto. Compara con -lt, y Mongo
#      esta legitimamente por encima de PostgreSQL: los productos que publica un
#      vendedor desde el panel nacen solo en Mongo y no tienen fila del otro
#      lado (es lo mismo que explica el -lt de la seccion 7b). Mientras ese
#      sobrante sea mayor que el lote, PostgreSQL sigue por debajo y la
#      comparacion no dice ni una palabra. O sea que puede quedarse callada
#      justo cuando la necesitas, y depende de un numero que este script no
#      controla.
#
#    - La del TOPE DE ID si dispara siempre, y por construccion, no por suerte.
#      El generador arranca sus id POR ENCIMA del mayor _id que Mongo tiene
#      (para eso se le pasan los dos topes, ver mas abajo). Asi que en cuanto el
#      lote entra, max(id_producto) de PostgreSQL queda por encima del _id mas
#      alto que Mongo tiene dentro del tramo del ETL, los dos dejan de coincidir
#      y $alDia se cae. No hay lote que pueda entrar sin moverlo.
#
#    Cualquiera de las dos que se caiga deja $alDia en falso y Correr-Etl sale
#    por su cuenta, pero la que garantiza que pase es la segunda. O sea que el
#    lote llega a Mongo sin que este paso sepa nada del ETL ni lo llame, que es
#    justamente lo que evita tener que acordarse de nada.
#
# Y la advertencia, que es lo que no hay que olvidar nunca: poner este paso
# DESPUES del ETL seria un error grave y ademas silencioso hasta el final. El
# verificador de la seccion 7b compara cada coleccion de Mongo contra el count
# de su tabla en PostgreSQL con -lt, o sea que Mongo por debajo es fallo. Con el
# lote generado despues del ETL, PostgreSQL tendria las filas nuevas y Mongo no,
# el verificador leeria una cuenta de Mongo por debajo de la de PostgreSQL y
# mataria el arranque con exit 1 acusando al ETL, con absolutamente todo bien.
#
# El grafo de Neo4j no se mueve con esto y esta bien que no se mueva, pero la
# razon NO es que el grafo ignore los productos: si tiene un contador :Producto,
# esta en $NODOS_ETL y cuenta nodos de verdad. La razon es cual es su consulta.
# Ese contador no cuenta el catalogo, cuenta los productos CON RESENA
# (count(DISTINCT id_producto_mongo) FROM resena), y este generador no escribe
# ni una resena: sus INSERT van a productos, variantes, caracteristicas,
# imagenes, ofertas y kardex, y ninguno toca resena, usuarios ni direcciones,
# que son las tres tablas de las que sale el grafo entero. Asi que un lote no
# mueve ninguno de los contadores del grafo y no lo deja viejo.
#
# La vuelta que si hay que ver venir: el dia que alguien escriba resenas sobre
# los productos del lote, esas resenas SI mueven los contadores de la seccion 9b
# -- :Producto, :Resena y sus aristas -- y esa guardia dispara el ETL del grafo
# sola, sin que este paso tenga que hacer nada tampoco.
#
# Por que el generador recibe los topes de Mongo y no solo la secuencia
# ----------------------------------------------------------------------
# Los dos asignadores de id ya divergieron. Hay productos que nacieron en el
# panel de un vendedor y viven SOLO en Mongo, por encima del ultimo id que
# PostgreSQL llego a entregar. Si el generador arrancara desde la secuencia de
# PostgreSQL, los id nuevos caerian justo encima de esos, y el replaceOne del
# ETL los machacaria sin decir una palabra: el producto de un vendedor
# desaparecido y reemplazado por uno generado, sin un solo error por ningun
# lado. Por eso se le pasan los dos topes que tiene Mongo y el empieza por
# encima del mas alto de los dos mundos.
#
# Las dos consultas van con el mismo Comando-Mongo que usa el resto del archivo.
# Dos detalles medidos contra el contenedor vivo, los dos porque fallan de forma
# que engana:
#
#   - Las comillas dobles de "$variantes" tienen que ir escritas \" . Sin la
#     barra invertida PowerShell se las come al armar la linea de docker (es la
#     regla 2 del comentario de mas arriba), mongosh recibe el nombre suelto y
#     contesta "ReferenceError: $variantes is not defined". Con la barra
#     contesta un numero, que es el id de variante mas alto que hay en Mongo.
#     Aqui no se escribe cual: es un dato vivo que sube con cada lote y con cada
#     producto que publique un vendedor, asi que cualquier cifra clavada en este
#     comentario miente a las pocas horas. Se comprueba corriendo la consulta.
#
#   - Las dos consultas llevan pegado un guardia para cuando no hay nada. La
#     forma directa, toArray()[0]._id, sobre un Mongo recien creado muere con
#     "TypeError: Cannot read properties of undefined (reading '_id')". Con el
#     .map(...)[0]||0 devuelve 0, que es lo que el generador espera oir cuando
#     del otro lado no hay nada que respetar.
#
# Y si aun asi la respuesta no es un numero, este paso se para en vez de mandar
# un cero a ciegas: un cero inventado le dice al generador que Mongo esta vacio
# cuando no lo esta, y eso es exactamente el pisoton que el tope existe para
# impedir. Una cadena vacia colandose a psql como valor de -v es peor todavia,
# porque no da un error de conexion, da un SQL con un hueco en medio.
if ($ProductosPedidos -gt 0) {
    Paso "Generando un lote de $ProductosPedidos productos"

    # El archivo se comprueba desde el host aunque psql lo vaya a leer desde
    # /migrations/lote. Si falta, el error de psql habla de una ruta de dentro
    # del contenedor y manda a buscarlo donde no esta.
    $rutaLote = "$PSScriptRoot\migrations\lote\generar_lote.sql"
    if (-not (Test-Path -LiteralPath $rutaLote)) {
        Error1 "Falta migrations\lote\generar_lote.sql, que es lo que genera el lote."
        exit 1
    }

    # A Mongo todavia no lo ha esperado nadie: eso pasa en la seccion 6, mas
    # abajo. En un arranque en frio puede estar levantando cuando este paso le
    # pregunta, asi que se espera aqui explicitamente en vez de suponerlo.
    # Esperarlo dos veces es gratis: la funcion contesta en la primera vuelta
    # cuando el contenedor ya esta sano.
    if (-not (Esperar-Contenedor "mesh-mongo" 120)) {
        Error1 "MongoDB no respondio, y sin el no se sabe por que id empezar."
        Error1 "Arranca sin la bandera y repite despues:  .\arrancar.ps1"
        exit 1
    }

    $evalTopeProducto = '--eval ''db.productos.find().sort({_id:-1}).limit(1).toArray().map(d=>d._id)[0]||0'''
    $evalTopeVariante = '--eval ''db.productos.aggregate([{$unwind:\"$variantes\"},{$group:{_id:null,m:{$max:\"$variantes.id_producto_variante\"}}}]).toArray().map(d=>d.m)[0]||0'''

    $topeProducto = (docker exec mesh-mongo sh -c (Comando-Mongo $evalTopeProducto) 2>&1 | Out-String).Trim()
    $topeVariante = (docker exec mesh-mongo sh -c (Comando-Mongo $evalTopeVariante) 2>&1 | Out-String).Trim()

    # La otra razon por la que esto puede no ser un numero, y no es rara: la
    # contrasena de Mongo se repara en la seccion 6, que todavia no ha corrido.
    # Sobre una maquina con el .env cambiado, aqui mongosh contesta
    # "Authentication failed". No se sigue a ciegas -- se dice que arranque una
    # vez sin la bandera, que es lo que repara la contrasena, y que repita.
    if (($topeProducto -notmatch '^\d+$') -or ($topeVariante -notmatch '^\d+$')) {
        Error1 "No se pudo leer de MongoDB por que id seguir, y sin eso el lote"
        Error1 "podria pisar los productos que solo existen alli."
        Error1 "Arranca una vez sin la bandera y repite despues:  .\arrancar.ps1"
        exit 1
    }

    Ok "Mongo va por el producto $topeProducto y la variante $topeVariante"

    # SIN -Semilla SE ELIGE UNA LIBRE, y esta es la decision que hace que la
    # bandera se comporte como uno espera.
    #
    # Antes, sin -Semilla se usaba la semilla 0 siempre, asi que
    # ".\arrancar.ps1 -Productos 1000" funcionaba la primera vez y la segunda
    # moria contra la guardia diciendo que el lote L0 ya existia. Eso es lo
    # contrario de lo que quiere quien teclea solo -Productos: esa persona no
    # esta pidiendo un lote reproducible, esta pidiendo mas productos y ya.
    #
    # Ahora se toma la mayor semilla que ya existe en la base y se suma uno. Los
    # lotes salen L1, L2, L3 y nunca chocan.
    #
    # Y LO QUE HACE QUE ESTO NO PIERDA NADA: la semilla elegida SE IMPRIME. Un
    # lote generado sin -Semilla sigue siendo tan reproducible como cualquier
    # otro, solo que el numero lo eligio el script y hay que leerlo de la
    # pantalla en vez de haberlo tecleado. Sin ese Ok, "aleatorio" querria decir
    # "irrepetible", y entonces la mitad de la funcion se habria perdido.
    #
    # No se usa la hora ni un numero al azar a proposito: max+1 es predecible,
    # cabe en el marcador del nombre, y deja los lotes numerados en el orden en
    # que se crearon, que es como alguien los va a querer mirar despues.
    if (-not $pidioSemilla) {
        $sqlSemilla = "SELECT coalesce(max(substring(nombre from ' L([0-9]+)-[0-9]{4}$')::bigint), 0) + 1 FROM productos WHERE nombre ~ ' L[0-9]+-[0-9]{4}$'"
        $libre = "$(docker exec mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX -c $sqlSemilla 2>&1)".Trim()

        if ($LASTEXITCODE -ne 0 -or $libre -notmatch '^\d+$') {
            Error1 "No se pudo averiguar que semilla esta libre."
            Write-Host $libre -ForegroundColor Red
            Aviso "Pasala a mano:  .\arrancar.ps1 -Productos $ProductosPedidos -Semilla 1"
            exit 1
        }

        $SemillaPedida = [long]$libre
        Ok "Sin -Semilla: se usa la $SemillaPedida, que esta libre"
        Ok "Para volver a generar ESTE mismo lote:  .\arrancar.ps1 -Productos $ProductosPedidos -Semilla $SemillaPedida"
    }

    # -f y no stdin, igual que Correr-Migraciones: el archivo esta montado dentro
    # del contenedor y asi no pasa por la codificacion de PowerShell. Los cuatro
    # -v son numeros pelados, sin espacios ni comillas, asi que estos si viajan
    # enteros por la linea de comandos.
    #
    # VERBOSITY=verbose no es adorno, es lo que permite distinguir un lote
    # RECHAZADO de un fallo de verdad, y esta explicado entero mas abajo, donde
    # se usa. Sin el, psql imprime el texto del error pero no su SQLSTATE.
    $salidaLote = docker exec mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] `
        -v ON_ERROR_STOP=1 -q -v VERBOSITY=verbose `
        -v productos=$ProductosPedidos `
        -v semilla=$SemillaPedida `
        -v max_mongo_producto=$topeProducto `
        -v max_mongo_variante=$topeVariante `
        -f "/migrations/lote/generar_lote.sql" 2>&1 | Out-String

    # Un lote rechazado NO tumba el arranque, y un fallo de verdad si
    # -------------------------------------------------------------------
    # Hasta hoy este bloque hacia exit 1 con cualquier fallo, y eso convertia
    # una peticion opcional en un arranque muerto: quien escribia dos veces la
    # misma semilla se quedaba sin que nadie comprobara Mongo, Redis ni Neo4j,
    # con el ambiente perfectamente sano. El lote es un extra; el ambiente es lo
    # que este script existe para dejar en pie.
    #
    # Los dos casos SI se distinguen, y no por el texto del mensaje. Medido
    # contra el contenedor vivo, con las cuatro formas de fallar:
    #
    #   generador rechaza la peticion   psql sale 3  y el error lleva P0001
    #   no encuentra el archivo .sql    psql sale 1  y no lleva P0001
    #   no puede conectarse a la base   psql sale 2  y no lleva P0001
    #   error de SQL de cualquier otra  psql sale 3  con el SQLSTATE de ese
    #   clase                                        error, que no es P0001
    #
    # P0001 es el SQLSTATE de RAISE EXCEPTION, o sea de las guardias que el
    # propio generador escribio: fuera de rango, semilla repetida, topes de
    # Mongo incoherentes, y las verificaciones que corre sobre su propio
    # resultado al final. Todas quieren decir lo mismo -- "no voy a escribir
    # esto" -- y todas dejan la base intacta, porque generar_lote.sql envuelve
    # el archivo entero en BEGIN/COMMIT y cualquier excepcion lo revierte. Esto
    # tambien esta comprobado: con la guardia disparada, el count de productos
    # antes y despues es el mismo.
    #
    # Se mira el SQLSTATE y NO el texto del mensaje a proposito. Este mismo
    # archivo tiene la cicatriz de haber hecho lo contrario: el perdon de
    # Correr-Migraciones agarraba la frase "already exists" y pintaba de amarillo
    # un conjunto de datos cargado a la mitad. Una frase la reescribe cualquiera
    # el dia que traduzca un mensaje; un SQLSTATE lo fija PostgreSQL.
    #
    # Lo que esta distincion NO cubre, dicho de frente: un P0001 tambien puede
    # venir de las verificaciones finales del generador, que no son "tu peticion
    # no me gusta" sino "genere algo que no cuadra". Se tratan igual, como aviso
    # y no como muerte, y la razon es que el resultado para el ambiente es
    # identico: la transaccion se revirtio y PostgreSQL quedo como estaba. El
    # riesgo de equivocarse hacia este lado es imprimir amarillo por algo grave;
    # el de equivocarse hacia el otro es matar un arranque sano. El aviso se
    # repite al final del script justamente para que ese amarillo no se pierda.
    if ($LASTEXITCODE -ne 0) {
        if ($LASTEXITCODE -eq 3 -and ($salidaLote -match 'ERROR:\s+P0001:')) {
            $loteRechazado = "se pidieron $ProductosPedidos productos con semilla $SemillaPedida"

            Aviso "El generador RECHAZO el lote. No se escribio ni una fila:"
            Aviso "generar_lote.sql envuelve todo en una transaccion y la revirtio."
            Write-Host ""
            # La linea LOCATION de psql se quita al imprimir. Dice el archivo y
            # la linea del codigo C de PostgreSQL donde nacio la excepcion
            # (exec_stmt_raise, pl_exec.c), que no le sirve a nadie aqui y manda
            # a leer las fuentes de PostgreSQL en vez del motivo, que esta en la
            # linea de arriba. El resto de la salida se imprime entera.
            foreach ($linea in ($salidaLote -split "`n")) {
                if ($linea -notmatch '^\s*LOCATION:') { Write-Host $linea -ForegroundColor Yellow }
            }
            Aviso "El arranque sigue: el lote es un extra y el ambiente esta bien."
        } else {
            Error1 "migrations/lote/generar_lote.sql FALLO"
            Write-Host $salidaLote -ForegroundColor Red
            exit 1
        }
    } else {
        # La salida del generador no se imprime cuando todo va bien, y es a
        # proposito: es un generador de N filas, y el dia que alguien le ponga un
        # aviso por producto un lote de mil llena la pantalla y tapa el resto del
        # arranque. Que llego es algo que se ve dos pasos mas abajo, cuando la
        # seccion 7b imprime las cuentas de cada coleccion. Cuando falla si se
        # imprime entera, que es cuando hace falta.
        Ok "Pedidos $ProductosPedidos productos con semilla $SemillaPedida"
    }
}


# ------------------------------------------------------------
# 5d. Borrar productos generados
# ------------------------------------------------------------
# El que deshace lo que hace 5c.
#
#   .\arrancar.ps1 -Borrar 500       los 500 generados MAS NUEVOS
#   .\arrancar.ps1 -Borrar todos     todos los generados
#   .\arrancar.ps1 -Borrar todos -Semilla 7   solo el lote de esa semilla
#
# Va detras del paso que genera y no delante, para que las dos banderas juntas
# hagan lo que uno lee: primero borra lo viejo, despues genera lo nuevo... no.
# Al reves, y conviene decirlo porque es la trampa: generar va PRIMERO, asi que
# ".\arrancar.ps1 -Productos 100 -Borrar todos" generaria 100 y despues los
# borraria, dejando la base igual que antes y con un minuto perdido. Por eso las
# dos juntas se rechazan arriba, en la revision de banderas.
#
# SON DOS MITADES, Y LA SEGUNDA ES LA QUE SE OLVIDA
#
# borrar_lote.sql solo habla con PostgreSQL. Los productos tambien viven en
# MongoDB, y correr el ETL despues NO los quita: etl/cargar.js escribe con
# replaceOne y upsert, o sea que agrega y actualiza pero nunca borra, y su unico
# barrido de sobrantes cubre `categorias` y `productos_eventos`. Para
# `db.productos` no hay ninguno. Medido: borrar 300 productos en PostgreSQL y
# correr el ETL dejaba los 300 en Mongo, y el verificador ni protestaba, porque
# solo se queja si Mongo tiene MENOS que PostgreSQL.
#
# Asi que aqui se hace la segunda mitad. Y se hace por RECONCILIACION y no
# borrando una lista: se le pasa a Mongo la lista de los generados que SIGUEN
# vivos en PostgreSQL, y Mongo borra todo documento con marcador de lote que no
# este en ella. Tiene dos ventajas sobre mandar la lista de borrados:
#
#   - Limpia tambien los fantasmas de borrados anteriores que se hicieron a
#     mano y se dejaron a medias. Se arregla solo.
#   - No depende de que psql y mongosh se pongan de acuerdo sobre que se borro.
#     La fuente de verdad es PostgreSQL, y Mongo se ajusta a ella, que es la
#     misma regla que sigue todo el ETL.
#
# La lista viaja por ARCHIVO y no por linea de comandos, con el mismo docker cp
# que ya usa Correr-Etl. Con dos mil ids una linea de comandos se pasa de largo
# en PowerShell 5.1 y el fallo seria un error de sintaxis de JavaScript, que
# manda a buscar el problema al sitio equivocado.
#
# Solo se tocan los documentos con MARCADOR DE LOTE. Los 102 curados y los que
# nacieron en el panel no llevan marcador y este paso no los mira nunca.
if ($BorrarPedido -ne '') {

    $rutaBorrar = "$PSScriptRoot\migrations\lote\borrar_lote.sql"
    if (-not (Test-Path -LiteralPath $rutaBorrar)) {
        Error1 "Falta migrations\lote\borrar_lote.sql, que es lo que borra el lote."
        exit 1
    }

    if ($BorrarTodos) {
        Paso "Borrando los productos generados"
    } else {
        Paso "Borrando $BorrarCuantos productos generados"
    }

    # cuantos = 0 quiere decir "todos" para el SQL. semilla = -1 quiere decir
    # "de cualquier lote".
    $cuantosArg = if ($BorrarTodos) { 0 } else { $BorrarCuantos }
    $semillaArg = if ($SemillaPedida -eq $null -or $SemillaPedida -eq '') { -1 } else { $SemillaPedida }

    $salidaBorrado = docker exec mesh-postgres psql `
        -U $env_["DB_USER"] -d $env_["DB_NAME"] `
        -v ON_ERROR_STOP=1 `
        -v cuantos=$cuantosArg `
        -v semilla=$semillaArg `
        -q -f "/migrations/lote/borrar_lote.sql" 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) {
        # Igual que en el paso que genera: un rechazo del propio archivo (no hay
        # nada que borrar, o algo tiene ventas detras) es un aviso y no un
        # arranque roto. El ambiente estaba bien y lo unico que fallo es una
        # peticion opcional, asi que se avisa en amarillo y el arranque sigue.
        if ($salidaBorrado -match "No hay ningun producto generado|no genero ningun producto|tienen ventas detras") {
            Aviso "No se borro nada."
            foreach ($linea in ($salidaBorrado -split "`r?`n")) {
                if ($linea -match "ERROR:|HINT:") { Aviso ("   " + $linea.Trim()) }
            }
            Aviso "borrar_lote.sql envuelve todo en una transaccion y la revirtio."
        } else {
            Error1 "migrations/lote/borrar_lote.sql FALLO"
            Write-Host $salidaBorrado -ForegroundColor Red
            exit 1
        }
    } else {
        foreach ($linea in ($salidaBorrado -split "`r?`n")) {
            if ($linea -match "NOTICE:\s+(Se pidieron|Borrado verificado)") {
                Ok ($linea -replace '^.*NOTICE:\s+', '')
            }
        }

        # La segunda mitad: MongoDB.
        $listaHost = Join-Path $env:TEMP "mesh-vivos.txt"
        docker exec mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX `
            -c "SELECT id_producto FROM productos WHERE nombre ~ ' L[0-9]+-[0-9]{4}$'" `
            > $listaHost 2>$null

        if ($LASTEXITCODE -ne 0) {
            Error1 "No se pudo leer de PostgreSQL que productos generados quedan vivos."
            Aviso "PostgreSQL quedo bien; lo que falta es limpiar MongoDB."
            exit 1
        }

        docker cp $listaHost mesh-mongo:/tmp/mesh-vivos.txt | Out-Null

        $js = @'
const texto = fs.readFileSync('/tmp/mesh-vivos.txt', 'utf8');
const vivos = texto.split('\n').map(s => s.trim()).filter(s => s.length > 0).map(Number);
const marcador = / L[0-9]+-[0-9]{4}$/;
const sobran = db.productos.find({ nombre: marcador }, { _id: 1 })
                 .toArray().map(d => d._id)
                 .filter(id => vivos.indexOf(id) === -1);
if (sobran.length > 0) {
    db.productos.deleteMany({ _id: { $in: sobran } });
    db.productos_eventos.deleteMany({ id_producto: { $in: sobran } });
}
print('mongo_borrados=' + sobran.length);
print('mongo_quedan=' + db.productos.countDocuments({}));
'@
        $rutaJs = Join-Path $env:TEMP "mesh-limpiar-mongo.js"
        [System.IO.File]::WriteAllText($rutaJs, $js, (New-Object System.Text.UTF8Encoding($false)))
        docker cp $rutaJs mesh-mongo:/tmp/mesh-limpiar-mongo.js | Out-Null

        $salidaMongo = docker exec mesh-mongo mongosh --quiet `
            -u $env_["MONGO_USER"] -p $env_["MONGO_PASSWORD"] `
            --authenticationDatabase admin $env_["MONGO_DB"] `
            --file /tmp/mesh-limpiar-mongo.js 2>&1 | Out-String

        if ($LASTEXITCODE -ne 0) {
            Error1 "PostgreSQL quedo limpio pero MongoDB NO."
            Write-Host $salidaMongo -ForegroundColor Red
            Aviso "Los productos borrados siguen en el catalogo de Mongo. Hay que"
            Aviso "quitarlos a mano; el procedimiento esta en migrations/lote/README.md."
            exit 1
        }

        if ($salidaMongo -match "mongo_borrados=(\d+)") {
            Ok "MongoDB: $($Matches[1]) documentos quitados del catalogo"
        }
        Remove-Item -LiteralPath $listaHost, $rutaJs -ErrorAction SilentlyContinue
    }
}


# ------------------------------------------------------------
# 6. MongoDB
# ------------------------------------------------------------
# El contenedor ya subio con el "docker compose up -d" de arriba. Aqui se
# espera a que responda, se comprueba el acceso y se corren los scripts de
# mongo/ que crean las colecciones.

Paso "Esperando a MongoDB"

$listoMongo = Esperar-Contenedor "mesh-mongo" 120

if (-not $listoMongo) {
    Error1 "MongoDB no respondio. Mira el log:"
    Error1 "   docker logs mesh-mongo --tail 30"
    exit 1
}
Ok "MongoDB respondiendo"


Paso "Comprobando el acceso"

# MONGO_INITDB_ROOT_* solo se aplica cuando el volumen esta vacio. Si despues
# se edita el .env, el contenedor informa la contrasena nueva pero la base
# sigue guardando la vieja, y todo falla con "Authentication failed".
#
# PostgreSQL se arregla solo mas arriba porque desde dentro es "trust". Mongo
# no tiene eso, pero tiene otra puerta: la contrasena vive en el volumen, y el
# volumen se puede abrir sin autenticacion. Eso es lo que hace Reparar-Mongo.

docker exec mesh-mongo sh -c (Comando-Mongo "--eval 'db.getName()'") 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    if (-not (Reparar-Mongo)) { exit 1 }

    docker exec mesh-mongo sh -c (Comando-Mongo "--eval 'db.getName()'") 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Error1 "MongoDB sigue sin aceptar las credenciales del .env."
        Error1 "Para rehacer SOLO Mongo (borra el catalogo, no toca PostgreSQL):"
        Error1 "   .\arrancar.ps1 -ReiniciarMongo"
        exit 1
    }
    Ok "Contrasena reparada"
} else {
    Ok "Acceso correcto"
}


Paso "Creando colecciones"

$coleccionesJs = @(Get-ChildItem -LiteralPath "$PSScriptRoot\mongo" -Filter "*.js" -ErrorAction SilentlyContinue | Sort-Object Name)

if ($coleccionesJs.Count -eq 0) {
    Aviso "No hay archivos .js en mongo/"
} else {
    foreach ($j in $coleccionesJs) {
        $comandoJs = Comando-Mongo ('--file /mongo/' + $j.Name)
        $salidaJs = docker exec mesh-mongo sh -c $comandoJs 2>&1 | Out-String

        if ($LASTEXITCODE -eq 0) {
            Ok "$($j.Name)  $($salidaJs.Trim())"
        } else {
            Error1 "$($j.Name) FALLO"
            Write-Host $salidaJs -ForegroundColor Red
            exit 1
        }
    }
}


# ------------------------------------------------------------
# 6b. Lote de productos que viven SOLO en MongoDB
# ------------------------------------------------------------
# El gemelo de la seccion 5c, por el otro extremo.
#
#   5c  producto en PostgreSQL -> el ETL lo lleva a Mongo
#   6b  documento en Mongo, y sus ofertas en PostgreSQL. SIN fila en `productos`
#
# La diferencia no es de gusto. El backend dice por escrito, en
# vendedores/productos.service.ts, que "los productos ya no se registran en
# PostgreSQL": los que publica un vendedor nacen asi. Este paso es la unica
# forma de tener muchos de ese tipo para probar, y de comprobar que un catalogo
# con los dos origenes mezclados se comporta.
#
# POR QUE VA AQUI Y NO EN LA 5c
#
# Porque necesita MongoDB vivo y con sus colecciones creadas, y eso pasa en la
# seccion 6. En la 5c todavia no se comprobo ni el acceso.
#
# Y va ANTES de la 7 a proposito: la 7 es el ETL, que compara cuentas para
# decidir si corre. Estos productos NO salen de PostgreSQL, asi que suben el
# conteo de Mongo sin subir el de PostgreSQL. El verificador 7b compara con
# -lt, o sea que solo se queja si Mongo tiene MENOS, y tener de mas es
# exactamente lo normal aqui: ahi viven tambien los productos del panel.
#
# SON DOS PASOS Y NO UNO, Y ES LO QUE HAY QUE ENTENDER
#
# El producto es un documento de Mongo; sus ofertas son filas de PostgreSQL
# (ADR-2: el descuento de stock tiene que ser atomico). Ningun script habla con
# las dos bases, asi que el precio lo sortea el generador de Mongo, lo escribe
# en un csv, y este paso lleva el archivo de un contenedor al otro con el mismo
# docker cp que ya usa Correr-Etl.
#
# Que el precio viaje como DATO y no se vuelva a sortear del otro lado es la
# decision que evita el fallo clasico: dos implementaciones del mismo azar que
# tienen que coincidir para siempre, y que el dia que una cambie dejan el
# documento diciendo un precio y la oferta otro.
if ($MongoPedidos -gt 0) {

    $rutaGen = "$PSScriptRoot\mongo\lote\generar_lote_mongo.js"
    $rutaOf  = "$PSScriptRoot\migrations\lote\ofertas_mongo.sql"
    foreach ($f in @($rutaGen, $rutaOf)) {
        if (-not (Test-Path -LiteralPath $f)) {
            Error1 "Falta $f"
            exit 1
        }
    }

    Paso "Generando un lote de $MongoPedidos productos en MongoDB"

    # Los dos topes de PostgreSQL. El generador NO puede consultarlos: solo
    # habla con Mongo. Y sin ellos numeraria desde el mayor _id de Mongo, que es
    # justo el error que deja una bomba puesta -- un id que PostgreSQL todavia
    # puede repartir, y que el ETL machacaria en su proxima corrida.
    $maxPgProd = "$(docker exec mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX -c "SELECT coalesce(max(id_producto),0) FROM productos;" 2>&1)".Trim()
    $maxPgVar  = "$(docker exec mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX -c "SELECT coalesce(max(id_producto_variante),0) FROM productos_variantes;" 2>&1)".Trim()

    if ($maxPgProd -notmatch '^\d+$' -or $maxPgVar -notmatch '^\d+$') {
        Error1 "No se pudieron leer los topes de PostgreSQL."
        Write-Host "$maxPgProd / $maxPgVar" -ForegroundColor Red
        exit 1
    }
    Ok "PostgreSQL va por el producto $maxPgProd y la variante $maxPgVar"

    # La semilla NO se busca aqui: la elige el propio generador si no viene, y
    # la imprime. El dato que hay que mirar son los nombres de los productos de
    # MongoDB, y el unico que los ve es el script. Averiguarlo desde aqui
    # obligaria a mandar una agregacion entera por la linea de comandos.
    $semillaMongo = if ($pidioSemilla) { "$SemillaPedida" } else { "" }

    docker cp $rutaGen mesh-mongo:/tmp/generar_lote_mongo.js | Out-Null

    $salidaGen = docker exec `
        -e "LOTE_PRODUCTOS=$MongoPedidos" `
        -e "LOTE_SEMILLA=$semillaMongo" `
        -e "LOTE_MAX_PG_PRODUCTO=$maxPgProd" `
        -e "LOTE_MAX_PG_VARIANTE=$maxPgVar" `
        mesh-mongo sh -c (Comando-Mongo "--file /tmp/generar_lote_mongo.js") 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) {
        # Igual que en la 5c: un rechazo del propio generador (semilla repetida,
        # parametro fuera de rango) es un aviso y no un arranque roto. El
        # ambiente estaba bien y lo unico que fallo es una peticion opcional.
        if ($salidaGen -match "ya genero|tiene que ser un entero|no llego") {
            Aviso "No se genero el lote de MongoDB."
            foreach ($linea in ($salidaGen -split "`r?`n")) {
                if ($linea -match "^(ERROR|HINT)") { Aviso ("   " + $linea.Trim()) }
            }
        } else {
            Error1 "mongo/lote/generar_lote_mongo.js FALLO"
            Write-Host $salidaGen -ForegroundColor Red
            exit 1
        }
    } else {
        # La semilla que de verdad se uso. Hace falta capturarla porque sin
        # -Semilla la eligio el generador, y los avisos de mas abajo dicen como
        # deshacer el lote: un "-BorrarMongo " sin numero no sirve de nada.
        foreach ($linea in ($salidaGen -split "`r?`n")) {
            if ($linea -match "^LOTE_SEMILLA_USADA=(\d+)") { $semillaMongo = $Matches[1] }
            if ($linea -match "^Sin -Semilla|^Para volver a generar|^Lote M|^FALTA POSTGRESQL") {
                Ok $linea.Trim()
            }
        }

        # La segunda mitad: las ofertas. El csv va de un contenedor al otro
        # pasando por el host, que es el unico camino -- mesh-mongo y
        # mesh-postgres no comparten sistema de archivos.
        $csvHost = Join-Path $env:TEMP "mesh-lote-mongo.csv"
        docker cp mesh-mongo:/tmp/mesh-lote-mongo.csv $csvHost | Out-Null
        if (-not (Test-Path -LiteralPath $csvHost)) {
            Error1 "El generador no dejo el csv de las ofertas."
            Aviso  "Los productos YA estan en MongoDB pero sin ofertas: no tienen precio."
            Aviso  "Borralos con:  .\arrancar.ps1 -BorrarMongo $semillaMongo"
            exit 1
        }
        docker cp $csvHost mesh-postgres:/tmp/mesh-lote-mongo.csv | Out-Null

        $salidaOf = docker exec mesh-postgres psql `
            -U $env_["DB_USER"] -d $env_["DB_NAME"] `
            -v ON_ERROR_STOP=1 -q -f "/migrations/lote/ofertas_mongo.sql" 2>&1 | Out-String

        if ($LASTEXITCODE -ne 0) {
            Error1 "migrations/lote/ofertas_mongo.sql FALLO"
            Write-Host $salidaOf -ForegroundColor Red
            Aviso "Los productos YA estan en MongoDB pero sin ofertas: no tienen precio."
            Aviso "Borralos con:  .\arrancar.ps1 -BorrarMongo $semillaMongo"
            exit 1
        }
        foreach ($linea in ($salidaOf -split "`r?`n")) {
            if ($linea -match "NOTICE:\s+Ofertas verificadas") {
                Ok ($linea -replace '^.*NOTICE:\s+', '')
            }
        }
        Remove-Item -LiteralPath $csvHost -ErrorAction SilentlyContinue
    }
}


# ------------------------------------------------------------
# 6c. Borrar un lote de MongoDB
# ------------------------------------------------------------
# Las mismas dos mitades al reves: primero los documentos, despues sus ofertas.
# Ese orden y no el contrario, porque la lista de ids sale de los documentos: si
# se borraran primero las ofertas no habria por donde empezar.
if ($MongoBorrar -ge 0) {

    $rutaBorrarJs  = "$PSScriptRoot\mongo\lote\borrar_lote_mongo.js"
    $rutaBorrarSql = "$PSScriptRoot\migrations\lote\borrar_ofertas_mongo.sql"
    foreach ($f in @($rutaBorrarJs, $rutaBorrarSql)) {
        if (-not (Test-Path -LiteralPath $f)) {
            Error1 "Falta $f"
            exit 1
        }
    }

    Paso "Borrando el lote M$MongoBorrar de MongoDB"

    docker cp $rutaBorrarJs mesh-mongo:/tmp/borrar_lote_mongo.js | Out-Null

    $salidaBorr = docker exec -e "LOTE_SEMILLA=$MongoBorrar" `
        mesh-mongo sh -c (Comando-Mongo "--file /tmp/borrar_lote_mongo.js") 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) {
        if ($salidaBorr -match "no genero ningun producto|tiene que ser un entero") {
            Aviso "No se borro nada."
            foreach ($linea in ($salidaBorr -split "`r?`n")) {
                if ($linea -match "^(ERROR|HINT)") { Aviso ("   " + $linea.Trim()) }
            }
        } else {
            Error1 "mongo/lote/borrar_lote_mongo.js FALLO"
            Write-Host $salidaBorr -ForegroundColor Red
            exit 1
        }
    } else {
        foreach ($linea in ($salidaBorr -split "`r?`n")) {
            if ($linea -match "^Lote M") { Ok $linea.Trim() }
        }

        $idsHost = Join-Path $env:TEMP "mesh-lote-mongo-borrados.csv"
        docker cp mesh-mongo:/tmp/mesh-lote-mongo-borrados.csv $idsHost | Out-Null
        docker cp $idsHost mesh-postgres:/tmp/mesh-lote-mongo-borrados.csv | Out-Null

        $salidaBorrSql = docker exec mesh-postgres psql `
            -U $env_["DB_USER"] -d $env_["DB_NAME"] `
            -v ON_ERROR_STOP=1 -q -f "/migrations/lote/borrar_ofertas_mongo.sql" 2>&1 | Out-String

        if ($LASTEXITCODE -ne 0) {
            Error1 "migrations/lote/borrar_ofertas_mongo.sql FALLO"
            Write-Host $salidaBorrSql -ForegroundColor Red
            Aviso "Los documentos YA se borraron de MongoDB; sus ofertas siguen en PostgreSQL."
            exit 1
        }
        foreach ($linea in ($salidaBorrSql -split "`r?`n")) {
            if ($linea -match "NOTICE:\s+(Borrado verificado|Se saltan)") {
                Ok ($linea -replace '^.*NOTICE:\s+', '')
            }
        }
        Remove-Item -LiteralPath $idsHost -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# 7. El catalogo en MongoDB
# ------------------------------------------------------------
# El ETL lee los productos de PostgreSQL y los escribe en Mongo: el documento
# de cada producto y su historial convertido en eventos.
#
# No se corre en cada arranque a proposito: el dia que se agreguen productos
# desde la aplicacion, correrlo siempre pisaria lo que haya en Mongo.
#
# La condicion era "la coleccion esta vacia", y con un solo conjunto de datos
# alcanzaba: o la maquina era nueva o ya estaba todo. Dejo de alcanzar cuando
# los datos se repartieron en varios archivos, porque agregar uno deja filas
# nuevas en PostgreSQL y una coleccion que ya no esta vacia: el ETL no volvia a
# correr y esas filas no llegaban nunca a Mongo.
#
# Despues fallo OTRA vez, y por lo mismo: se comparaban solo los productos, y
# el dia que el ETL empezo a escribir tambien la paleta de categorias, una
# maquina que ya tenia los productos daba las cuentas iguales, se saltaba el
# ETL y nunca llegaba a tener esa coleccion, diciendo "ya cargado".
#
# Van dos veces el mismo fallo por mirar de menos, asi que esto ya no se
# escribe a mano por coleccion: es una LISTA. Agregar una coleccion al ETL es
# agregarle un renglon aqui, y si a alguien se le olvida, el ETL corre de mas
# (que es inofensivo, porque es idempotente) en vez de correr de menos.
#
# Lo que esto no ve es un cambio que no mueva la cuenta: corregir el precio de
# una oferta que ya existe deja los dos numeros iguales. Para eso esta -Etl.

$COLECCIONES_ETL = @(
    @{ mongo = 'productos';  sql = 'SELECT count(*) FROM productos;'  },
    @{ mongo = 'categorias'; sql = 'SELECT count(*) FROM categorias;' }
)

Paso "Catalogo en MongoDB"

$alDia = $true
$resumen = @()

foreach ($col in $COLECCIONES_ETL) {
    $enMongo = (docker exec mesh-mongo sh -c (Comando-Mongo "--eval 'db.$($col.mongo).countDocuments()'") 2>&1 | Out-String).Trim()

    # Por stdin y no con -c: asi la consulta no pasa por el armado de linea de
    # comandos de PowerShell, que es donde se pierden las comillas.
    $enPostgres = ($col.sql |
        docker exec -i mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX 2>&1 | Out-String).Trim()

    # Si una cuenta no salio, se corre el ETL igual. Es idempotente, y
    # saltarselo por no poder contar dejaria el catalogo a medias sin avisar.
    if (($enMongo -notmatch '^\d+$') -or ($enPostgres -notmatch '^\d+$')) {
        $alDia = $false
    } elseif ([int]$enMongo -lt [int]$enPostgres) {
        $alDia = $false
    }

    $resumen += "$($col.mongo) $enMongo/$enPostgres"
}

# Contar no alcanza: si los id se renumeran, la cuenta queda igual y el ETL se
# saltaria dejando en Mongo los documentos con los id viejos. El _id de un
# producto ES su id_producto, asi que comparar el mas alto de cada lado delata
# el cambio.
#
# Se mira SOLO el tramo del ETL (los id que vienen de PostgreSQL). Por encima
# de ese tope estan los productos que publico un vendedor, que solo existen en
# Mongo: contarlos aqui haria que el ETL se creyera desfasado y volviera a
# correr en cada arranque. Sin comillas en la consulta: PowerShell se las come.
$topEnPostgres = ("SELECT COALESCE(max(id_producto), 0) FROM productos;" |
    docker exec -i mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX 2>&1 | Out-String).Trim()

$consultaTope = "--eval 'db.productos.find({_id:{`$lte:$topEnPostgres}}).sort({_id:-1}).limit(1).toArray().map(d=>d._id)[0]||0'"
$topEnMongo = (docker exec mesh-mongo sh -c (Comando-Mongo $consultaTope) 2>&1 | Out-String).Trim()

if (($topEnMongo -notmatch '^\d+$') -or ($topEnPostgres -notmatch '^\d+$') -or
    ([int]$topEnMongo -ne [int]$topEnPostgres)) {
    $alDia = $false
}

if (-not $Etl -and $alDia) {
    Ok "Ya cargado ($($resumen -join ', ')). Para volver a migrarlo: .\arrancar.ps1 -Etl"
} else {
    Correr-Etl
}


# ------------------------------------------------------------
# 7b. El catalogo NO puede quedar vacio
# ------------------------------------------------------------
# Esta comprobacion existe porque el fallo real fue este: el ETL se saltaba y
# el script terminaba en verde. Los productos si estaban en PostgreSQL, pero
# el catalogo que ve la aplicacion sale de MongoDB, asi que la tienda salia
# vacia y nada lo habia dicho.
#
# Se comprueba el RESULTADO, no que los pasos "parezcan" haber ido bien: un
# paso puede contestar 0 sin fallar.

Paso "Comprobando que el catalogo quedo cargado"

# Las TRES colecciones que escribe el ETL, no las dos de $COLECCIONES_ETL.
#
# productos_eventos no esta en esa lista y es a proposito: alli cada coleccion
# se compara contra una tabla de PostgreSQL para decidir si hace falta correr
# el ETL, y los eventos no tienen tabla equivalente -- salen de fusionar dos
# historiales por fecha, asi que su cuenta no cuadra con ninguna. Compararlos
# haria que el ETL se creyera desfasado en cada arranque.
#
# Pero para "quedo vacio o no" si cuentan, y mucho: los eventos son de donde
# sale la reconstruccion de un producto a una fecha pasada. Sin ellos esa
# consulta devuelve vacio y la pantalla del historial se queda muda.
# Cada coleccion, con la consulta que dice cuantas TENDRIA que haber.
#
# No basta con "no esta vacia": un ETL que cargue 3 productos de 102 pasaria en
# verde y el catalogo saldria incompleto, que no se nota hasta que alguien busca
# algo que deberia estar ahi. Se compara la cuenta contra PostgreSQL.
#
# productos_eventos es el caso aparte: no tiene tabla equivalente, porque sale
# de fusionar dos historiales por fecha. De ese solo se puede exigir que no este
# vacio -- sin el, reconstruir un producto a una fecha pasada devuelve vacio y
# la pantalla del historial se queda muda.
$COLECCIONES_CARGADAS = @(
    @{ mongo = 'productos';         sql = 'SELECT count(*) FROM productos;'  },
    @{ mongo = 'categorias';        sql = 'SELECT count(*) FROM categorias;' },
    @{ mongo = 'productos_eventos'; sql = $null }
)

$faltantes = @()
foreach ($col in $COLECCIONES_CARGADAS) {
    $nombre = $col.mongo
    $cuenta = (docker exec mesh-mongo sh -c (Comando-Mongo "--eval 'db.$nombre.countDocuments()'") 2>&1 | Out-String).Trim()

    if (($cuenta -notmatch '^\d+$') -or ([int]$cuenta -eq 0)) {
        $faltantes += "$nombre (vacia)"
        continue
    }

    if ($null -eq $col.sql) {
        Ok "$nombre  $cuenta"
        continue
    }

    $esperados = ($col.sql |
        docker exec -i mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX 2>&1 | Out-String).Trim()

    if ($esperados -notmatch '^\d+$') {
        # No se pudo contar del otro lado. No se inventa un veredicto: se dice.
        Aviso "$nombre  $cuenta  (no se pudo contar en PostgreSQL para comparar)"
    } elseif ([int]$cuenta -lt [int]$esperados) {
        # -lt y no -ne: que Mongo tenga MAS que PostgreSQL es lo normal, no un
        # fallo. Un producto publicado desde el panel nace solo en Mongo y no
        # tiene fila del otro lado (ver docs/base-de-datos.md, "El catalogo se
        # mudo a MongoDB"). Con -ne, cada producto creado desde la app dejaba
        # el arranque en rojo con todo bien cargado.
        $faltantes += "$nombre ($cuenta de $esperados)"
    } else {
        Ok "$nombre  $cuenta de $esperados"
    }
}

if ($faltantes.Count -gt 0) {
    Error1 "El catalogo de MongoDB NO quedo completo: $($faltantes -join ', ')"
    Error1 ""
    Error1 "Los productos si estan en PostgreSQL, pero la tienda los lee de MongoDB,"
    Error1 "asi que el catalogo va a salir vacio. Lo que falla es el ETL."
    Error1 ""
    Error1 "Para ver el error completo:  .\arrancar.ps1 -Etl"
    exit 1
}


# ------------------------------------------------------------
# 7c. Los dos repartidores de id no se estan pisando
# ------------------------------------------------------------
# Esto NO decide el pendiente 5, que es de backend: decide quien repartira los
# id de producto. Lo unico que hace es que el choque deje de ser invisible.
#
# El problema, en una linea: hay dos numeradores sobre el mismo espacio de id.
# PostgreSQL usa el bigserial de productos.id_producto, y el panel del vendedor
# usa "el mayor _id que hay en Mongo, mas uno". Ninguno de los dos mira al otro.
#
# Cuando se cruzan, el ETL hace un replaceOne sobre un _id que ya era de otro
# producto y se lo lleva por delante SIN UN SOLO ERROR. Es la peor forma de
# fallar que tiene este proyecto: el arranque queda en verde, las cuentas
# cuadran, y lo que se perdio es un producto entero.
#
# LO QUE SE COMPARA NO ES max(id_producto), y esa es la parte que costo. La
# secuencia y el maximo real no son el mismo numero: un nextval consumido por
# una transaccion que despues hizo ROLLBACK no vuelve. Medido el 2026-09-04 en
# la base viva, la secuencia iba en 1126 con un maximo real de 1105, o sea 21
# numeros de diferencia. Preguntar por el maximo diria que hay 21 de margen mas
# de los que hay de verdad.
#
# No corta el arranque. Un choque futuro no rompe nada de lo que esta cargado
# hoy, y parar aqui dejaria la maquina sin levantar por algo que todavia no ha
# pasado. Avisa, dice cuanto margen queda, y sigue.

Paso "Comprobando que los id de producto no se pisan"

$proximoId = ("SELECT CASE WHEN is_called THEN last_value + 1 ELSE last_value END FROM productos_id_producto_seq;" |
    docker exec -i mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX 2>&1 | Out-String).Trim()

if ($proximoId -notmatch '^\d+$') {
    Aviso "No se pudo leer la secuencia de productos: no se comprobo el cruce de id"
} else {
    # Cuantos documentos de Mongo estan parados encima de un numero que la
    # secuencia todavia va a repartir. Con la secuencia en 1127, cualquier _id
    # de 1127 para arriba es un choque esperando a que alguien inserte.
    $consultaChoque = "--eval 'db.productos.countDocuments({_id:{`$gte:$proximoId}})'"
    $enPeligro = (docker exec mesh-mongo sh -c (Comando-Mongo $consultaChoque) 2>&1 | Out-String).Trim()

    $consultaTecho = "--eval 'db.productos.find({},{_id:1}).sort({_id:-1}).limit(1).toArray().map(d=>d._id)[0]||0'"
    $mayorEnMongo = (docker exec mesh-mongo sh -c (Comando-Mongo $consultaTecho) 2>&1 | Out-String).Trim()

    if ($enPeligro -notmatch '^\d+$') {
        Aviso "No se pudo contar en MongoDB: no se comprobo el cruce de id"
    } elseif ([int]$enPeligro -gt 0) {
        Aviso "$enPeligro documento(s) de MongoDB ocupan un id que PostgreSQL va a repartir"
        Aviso "  PostgreSQL entregara el $proximoId en el proximo INSERT INTO productos"
        Aviso "  y en MongoDB ya hay documentos de ese numero para arriba."
        Aviso "  El ETL los machacaria sin dar ningun error. Ver docs/PENDIENTES.md, punto 5."
    } else {
        $margen = [int]$proximoId - [int]$mayorEnMongo
        Ok "sin cruce: PostgreSQL reparte el $proximoId y el mayor de Mongo es $mayorEnMongo ($margen de margen)"
    }
}


# ------------------------------------------------------------
# 8. Redis
# ------------------------------------------------------------
# Redis no tiene ETL ni migraciones: es el carrito y el contador de la oferta
# de inventario limitado, y los dos nacen vacios a proposito -- un carrito
# sembrado no es de nadie, y el contador se siembra desde oferta.stock cuando
# se abre la venta, no al arrancar la maquina.
#
# Los scripts de redis/*.lua tampoco se cargan aqui: los carga el backend al
# arrancar, porque un SCRIPT LOAD se pierde con cada reinicio de Redis y el
# unico que puede volver a cargarlo en ese momento es quien lo va a usar. Esta
# escrito en redis/README.md, seccion 5.
#
# Asi que lo unico que hace falta de este lado es esperar a que este sano. El
# healthcheck del compose hace un "redis-cli -a $REDIS_PASSWORD ping" con la
# contrasena de adentro, asi que sano quiere decir tambien que la contrasena
# del .env es la que la base acepta. No hace falta comprobarlo aparte.
Paso "Esperando a ClickHouse"

# La base columnar de los eventos. Igual que Elasticsearch, NO corta el arranque
# si no sube: hoy no cuelga ninguna pantalla de ella, y tumbar la maquina entera
# por la base mas nueva dejaria sin trabajar a todos los demas.
#
# 90 y no 120: no es una JVM, arranca bastante mas rapido que Elasticsearch y
# que Neo4j.
if (-not (Esperar-Contenedor "mesh-clickhouse" 90)) {
    Aviso "ClickHouse no respondio. El resto sigue funcionando."
    Aviso "   Mira el log:  docker logs mesh-clickhouse --tail 30"
} else {
    Ok "ClickHouse respondiendo"

    # El esquema es idempotente: todo va con IF NOT EXISTS, asi que se corre en
    # cada arranque sin preguntar y sin borrar nada. No hace falta la logica de
    # "si no cuadra lo reconstruyo" que si necesitan el catalogo de Mongo y el
    # indice del buscador, porque aqui no hay ningun dato que reconstruir: los
    # eventos no se derivan de PostgreSQL, se acumulan.
    $sql = Get-Content "$PSScriptRoot\clickhouse\001_esquema.sql" -Raw
    $sql | docker exec -i mesh-clickhouse clickhouse-client `
        --user $env_['CLICKHOUSE_USER'] `
        --password $env_['CLICKHOUSE_PASSWORD'] `
        --database $env_['CLICKHOUSE_DB'] `
        --multiquery 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Aviso "El esquema de ClickHouse no se pudo aplicar. Mira clickhouse/001_esquema.sql"
    } else {
        Ok "esquema de eventos aplicado (clickhouse/001_esquema.sql)"

        # ------------------------------------------------------------
        # La copia de los logueos y los registros
        # ------------------------------------------------------------
        # Es el gemelo en PowerShell de etl/cargar_eventos.sh, igual que el resto
        # de este script es el gemelo del ETL de Mongo. Se repite en vez de
        # llamar al .sh por lo mismo de siempre: PowerShell 5.1 le pega un BOM a
        # lo que manda por tuberia y el otro lado recibe basura.
        #
        # Y NO tiene rama de "aviso y sigo". Eso ya paso una vez con el ETL de
        # Mongo: cuando no encontraba el bash de Git se saltaba la carga, avisaba,
        # y el arranque terminaba EN VERDE con el catalogo vacio. Aqui seria peor,
        # porque una base de eventos vacia no se nota nunca y el dia de la entrega
        # contesta "no hay cuentas anomalas", que es creible y falso.
        #
        # Corre en cada arranque y es barata: en un arranque normal no copia nada
        # y tarda un parpadeo, porque solo pide lo que esta por encima de la marca.
        function Copiar-Eventos($etiqueta, $tabla, $colId, $tablaCh, $seleccion) {
            # LA MARCA DE AGUA SALE SOLO DE LAS FILAS QUE ESTA COPIA ESCRIBIO.
            # El filtro por lote = 'real' no es cosmetico: el generador de
            # clickhouse/lote siembra en ESTA MISMA TABLA con ids inventados del
            # orden de los mil millones. Sin el filtro, la marca se iria hasta
            # alla y la copia se saltaria logueos REALES para siempre, diciendo
            # "nada nuevo" y dando las cuentas por cuadradas.
            #
            # Es el pendiente 5 otra vez, con otro par de numeros: dos cosas
            # repartiendo ids sobre el mismo espacio sin hablarse. Medido el
            # 2026-09-06, la marca sin filtrar daba 1887513295.
            $marca = Consultar-ClickHouse "SELECT max($colId) FROM $tablaCh WHERE lote = 'real'"

            # $null quiere decir que la base NO contesto, y eso no es un cero.
            # Un cero aqui mandaria a recopiar la tabla entera y, sobre todo,
            # taparia el motivo de verdad. Se devuelve el fallo hacia arriba.
            if ($null -eq $marca) { return -1 }

            # Vacio SI es un cero legitimo: max() sobre una tabla sin filas de
            # lote real devuelve la cadena vacia, y eso significa "no he copiado
            # nada todavia, empieza por el principio".
            if ($marca -eq '') { $marca = "0" }

            $sql = $seleccion -replace '@MARCA@', $marca
            $crudo = docker exec -i mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] `
                -qtA -F "`t" -v ON_ERROR_STOP=1 -c $sql

            # EL FIN DE LINEA DE WINDOWS, QUE AQUI MUERDE DOS VECES Y POR DOS
            # SITIOS DISTINTOS.
            #
            # Primero al LEER. psql dentro del contenedor devuelve fin de linea
            # de Unix, pero PowerShell lo parte con el de Windows al recogerlo,
            # y cada elemento del arreglo se queda con un \r pegado al final.
            # Sin quitarlo, ClickHouse rechaza el TabSeparated entero con
            # "You have carriage return at end of first row" y sale con 117.
            $lineas = @($crudo | ForEach-Object { $_ -replace "`r", "" } | Where-Object { $_ -ne '' })

            if ($lineas.Count -eq 0) { return 0 }

            # Y despues al ESCRIBIR, que es la mitad que se escapo la primera
            # vez. Aunque el texto se una con "`n" a mano, PowerShell 5.1
            # escribe a la entrada de un programa externo con el fin de linea de
            # la plataforma, o sea CRLF. Vuelve a meter el \r que se acababa de
            # quitar, y ClickHouse contesta
            #
            #   Code: 27. Cannot parse input: expected '\n' before: '\r\n'
            #   ERROR: garbage after UInt64: "<CARRIAGE RETURN><LINE FEED>"
            #
            # Se arregla con el ajuste que el propio ClickHouse nombra en su
            # mensaje de error, y no peleando con PowerShell. El bash de
            # etl/cargar_eventos.sh no lo necesita porque ahi la tuberia es
            # directa entre dos procesos y nadie toca los bytes por el camino.
            #
            # SE ENCONTRO CORRIENDO EL ARRANQUE ENTERO, no antes. La prueba
            # suelta de este mismo camino habia dado verde un rato antes, y dio
            # verde porque en ese momento no habia ni una fila pendiente que
            # copiar: el INSERT no llego a ejecutarse. Un verde sobre una linea
            # que no se ejecuta no es un verde.
            ($lineas -join "`n") | docker exec -i mesh-clickhouse clickhouse-client `
                --user $env_['CLICKHOUSE_USER'] --password $env_['CLICKHOUSE_PASSWORD'] `
                --database $env_['CLICKHOUSE_DB'] `
                --input_format_tsv_crlf_end_of_line 1 `
                --query $tabla | Out-Null

            if ($LASTEXITCODE -ne 0) {
                Aviso "$etiqueta no se pudo copiar a ClickHouse."
                return -1
            }
            return $lineas.Count
        }

        $selLogueos = @"
SELECT to_char(l.fecha_login AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.MS'),
       l.id_usuario, host(l.ip_origen), t.tipo_login_nombre, 'real', l.id_log_login
  FROM log_login l JOIN tipo_login t USING (id_tipo_login)
 WHERE l.id_log_login > @MARCA@ ORDER BY l.id_log_login
"@
        $selRegistros = @"
SELECT to_char(r.fecha_registro AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.MS'),
       r.id_usuario, host(r.ip_origen), r.id_log_registro, 'real'
  FROM log_registro r
 WHERE r.id_log_registro > @MARCA@ ORDER BY r.id_log_registro
"@

        $nL = Copiar-Eventos "Los logueos" `
            "INSERT INTO evento_login (fecha, id_usuario, ip, tipo, lote, id_log_login) FORMAT TabSeparated" `
            "id_log_login" "evento_login" $selLogueos
        $nR = Copiar-Eventos "Los registros" `
            "INSERT INTO evento_registro (fecha, id_usuario, ip, id_log_registro, lote) FORMAT TabSeparated" `
            "id_log_registro" "evento_registro" $selRegistros

        if ($nL -lt 0 -or $nR -lt 0) {
            Error1 "Los eventos no se copiaron a ClickHouse."
            Error1 "El panel de tendencias y el de fraude por IP van a salir vacios,"
            Error1 "y vacio ahi no se distingue de 'no hay nada sospechoso'."
            exit 1
        }

        if ($nL -eq 0 -and $nR -eq 0) {
            Ok "eventos ya copiados, nada nuevo"
        } else {
            Ok "eventos copiados: $nL logueo(s) y $nR registro(s)"
        }

        # ------------------------------------------------------------
        # El lote de eventos de mentira, solo si se pidio
        # ------------------------------------------------------------
        # Va DESPUES de la copia, y ese orden se puede razonar en una linea: el
        # generador escribe con lote 'generado-N' y la copia lee su marca de agua
        # filtrando por lote 'real', asi que no se pisan en ningun orden. Se pone
        # despues porque leerlo asi es mas facil que confiar en esa propiedad.
        #
        # La semilla por defecto es 42 y no una al azar. Un lote reproducible es
        # lo unico que permite que dos personas del equipo miren el mismo panel y
        # vean los mismos numeros.
        if ($pidioVistas) {
            $semillaVistas = if ($pidioSemilla) { $SemillaPedida } else { 42 }

            Paso "Sembrando el lote de eventos (semilla $semillaVistas)"

            $sqlLote = Get-Content "$PSScriptRoot\clickhouse\lote\generar_vistas.sql" -Raw
            $sqlLote | docker exec -i mesh-clickhouse clickhouse-client `
                --user $env_['CLICKHOUSE_USER'] --password $env_['CLICKHOUSE_PASSWORD'] `
                --database $env_['CLICKHOUSE_DB'] `
                --param_semilla=$semillaVistas --param_vistas=$VistasPedidas `
                --multiquery 2>&1 | Out-Null

            if ($LASTEXITCODE -ne 0) {
                # La guardia del propio SQL rechaza una semilla ya sembrada, y ese
                # rechazo NO es un fallo del arranque: es el generador haciendo su
                # trabajo. Se dice y se sigue, igual que hace el lote de Mongo.
                Aviso "La semilla $semillaVistas ya estaba sembrada, o el lote fallo."
                Aviso "   Para rehacerlo:  .\arrancar.ps1 -BorrarVistas $semillaVistas"
                Aviso "   Y despues:       .\arrancar.ps1 -Vistas $VistasPedidas -Semilla $semillaVistas"
            } else {
                $cuantas = Consultar-ClickHouse "SELECT count() FROM vista_producto WHERE lote = 'generado-$semillaVistas'"
                Ok "lote sembrado: $cuantas vista(s) con lote generado-$semillaVistas"
            }
        }

        if ($VistasBorrar -ge 0) {
            Paso "Borrando el lote de eventos de la semilla $VistasBorrar"

            # LAS DOS MITADES. El resumen vistas_por_producto_dia se llena por una
            # vista materializada, y una vista materializada solo mira lo que
            # ENTRA: borrar de vista_producto no le quita ni una fila. El SQL de
            # borrar_lote.sql borra de las dos, y por eso se llama a el en vez de
            # lanzar un DELETE desde aqui.
            $sqlBorrar = Get-Content "$PSScriptRoot\clickhouse\lote\borrar_lote.sql" -Raw
            $sqlBorrar | docker exec -i mesh-clickhouse clickhouse-client `
                --user $env_['CLICKHOUSE_USER'] --password $env_['CLICKHOUSE_PASSWORD'] `
                --database $env_['CLICKHOUSE_DB'] `
                --param_semilla=$VistasBorrar --multiquery 2>&1 | Out-Null

            if ($LASTEXITCODE -ne 0) {
                Aviso "No se pudo borrar el lote $VistasBorrar."
            } else {
                Ok "lote generado-$VistasBorrar borrado de las dos tablas"
            }
        }
    }
}

Paso "Esperando a Elasticsearch"

# El motor de busqueda de la Entrega 3. Todavia no lo alimenta ningun ETL, asi
# que hoy nada mas depende de el; se espera igual para que el script no termine
# en verde con el contenedor a medio arrancar, que es como se dejan de ver los
# fallos.
#
# 120 y no 60: arranca mas lento que los demas porque es una JVM que ademas
# instala sus plantillas la primera vez.
#
# NO corta el arranque si no sube. Es la unica base de la que hoy no cuelga
# ninguna pantalla, y tumbar la maquina entera por ella dejaria sin trabajar a
# quien venia a tocar el catalogo. Se avisa y se sigue.
if (-not (Esperar-Contenedor "mesh-elastic" 120)) {
    Aviso "Elasticsearch no respondio. El resto sigue funcionando."
    Aviso "   Es la JVM mas pesada de las dos que hay; si la maquina anda"
    Aviso "   corta de memoria es lo primero que se cae."
    Aviso "   Mira el log:  docker logs mesh-elastic --tail 30"
} else {
    Ok "Elasticsearch respondiendo"

    # ------------------------------------------------------------
    # El indice del buscador
    # ------------------------------------------------------------
    # Se decide igual que el catalogo de Mongo: si lo que hay no cuadra con lo
    # que deberia haber, se reconstruye. Y -Etl lo fuerza.
    #
    # Se compara contra los productos ACTIVOS de Mongo, que es exactamente lo
    # que el extractor mete. Comparar contra el total dejaria el indice
    # reconstruyendose en cada arranque, porque el rechazado nunca va a entrar.
    Paso "Indice del buscador"

    # La condicion va con una EXPRESION REGULAR y no con la cadena "activo",
    # y no es por gusto. PowerShell 5.1 se come las comillas dobles al armar la
    # linea del programa externo, asi que {estado:"activo"} le llega a mongosh
    # como {estado:activo} y contesta "ReferenceError: activo is not defined".
    # Medido. Es la misma regla que este archivo ya avisa mas arriba para
    # mongosh y para cypher-shell, y la regex la esquiva sin comillas de
    # ninguna clase.
    #
    # Con anclas a los dos lados para que sea igualdad exacta y no un "empieza
    # por": un estado "activo_pendiente" que alguien invente manana no debe
    # colarse en esta cuenta.
    $activos = (docker exec mesh-mongo sh -c (Comando-Mongo "--eval 'db.productos.countDocuments({estado:/^activo`$/})'") 2>&1 | Out-String).Trim()

    $enIndice = '-1'
    try {
        $enIndice = [string](Invoke-RestMethod -Uri "$ES_URL/$ES_INDICE/_count" -TimeoutSec 20).count
    } catch {
        # 404 la primera vez, que no es un fallo: es que todavia no existe.
        $enIndice = '0'
    }

    if ($Etl -or ($activos -notmatch '^\d+$') -or ($enIndice -ne $activos)) {
        if (-not (Correr-EtlBusqueda)) {
            Aviso "El indice del buscador no se pudo rehacer. El resto sigue."
            Aviso "   A mano:  bash etl/cargar_busqueda.sh"
        }
    } else {
        Ok "Ya cargado ($enIndice de $activos productos activos). Para rehacerlo: .\arrancar.ps1 -Etl"
    }
}


Paso "Esperando a Redis"

if (-not (Esperar-Contenedor "mesh-redis" 60)) {
    Error1 "Redis no respondio. Mira el log:"
    Error1 "   docker logs mesh-redis --tail 30"
    exit 1
}
Ok "Redis respondiendo"


# ------------------------------------------------------------
# 9. Neo4j
# ------------------------------------------------------------
# El plazo es de 4 minutos y no de 1, y no es por si acaso: Neo4j tarda unos 40
# segundos en aceptar Cypher, y su healthcheck lo refleja con start_period 40s
# y 10 reintentos cada 15s. O sea que el propio compose se da hasta ~190
# segundos antes de declararlo enfermo. Un plazo mas corto aqui declararia
# muerto un contenedor que todavia esta arrancando bien.
Paso "Esperando a Neo4j"

if (-not (Esperar-Contenedor "mesh-neo4j" 240)) {
    Error1 "Neo4j no respondio. Mira el log:"
    Error1 "   docker logs mesh-neo4j --tail 30"
    exit 1
}
Ok "Neo4j respondiendo"


# ------------------------------------------------------------
# 9b. El grafo de resenas
# ------------------------------------------------------------
# La misma idea que el catalogo de Mongo: no se migra en cada arranque, se
# compara lo que hay contra lo que tendria que haber. Y la lista se escribe
# igual, por la misma razon que dice la seccion 7 -- dos veces fallo alli por
# mirar de menos una coleccion, asi que aqui no se compara "las resenas" a
# secas sino cada clase de nodo que el ETL escribe.
#
# La consulta de cada uno NO es un count(*) de la tabla que se le parece:
#
#   Usuario   si es count(*) de usuarios. El ETL carga todas las cuentas,
#             incluso las que no escribieron ni una resena, porque una cuenta
#             sin resenas igual puede compartir direccion con otra y eso es
#             una senal.
#   Producto  son los productos CON resena, no los 102 del catalogo. Un
#             producto que nadie califico no es alcanzable por ningun camino
#             del modelo, y cargarlo solo agrega nodos sueltos.
#   Resena    count(*) de resena, uno a uno.
#
#
# LAS RELACIONES TAMBIEN SE CUENTAN, Y ESO ERA EL AGUJERO
# ============================================================
# Antes esta lista tenia solo nodos, y con eso el arranque daba verde sobre un
# grafo INUTIL. Reproducido: se borraron las 272 relaciones dejando los 163
# nodos intactos y arrancar.ps1 imprimio "Ya cargado (Usuario 10/10, Producto
# 54/54, Resena 86/86)" -- salto el ETL -- despues las tres cuentas en verde y
# EXIT 0. Sobre ese grafo la consulta de varios saltos contesta "0 anillos".
# Peor: como los conteos de nodos cuadraban, el ETL no volvia a correr NUNCA.
#
# Las tres primeras valen todas count(*) de `resena` y son gratis: la sentencia
# 5 de etl/extraer_grafo.sql crea el nodo :Resena y sus tres aristas en la misma
# fila, asi que si hay 86 resenas tiene que haber 86 de cada una.
#
#
# :Direccion Y :VIVE_EN SI TIENEN NUMERO COMPARABLE
# ============================================================
# Antes :Direccion se imprimia en verde y no decidia nada -- no estaba en esta
# lista ni entraba en el veredicto. Reproducido: borrando los 12 nodos
# :Direccion (y con ellos las 14 :VIVE_EN), el arranque imprimia "Direccion 0"
# con el color de Ok, saltaba el ETL y terminaba en 0, mientras la consulta de
# domicilios contestaba "0 pares". Y no se autoreparaba nunca.
#
# El argumento que lo dejaba fuera era que "11 nodos contra 15 filas dispararia
# el ETL en cada arranque". Eso vale contra count(*) de la tabla, no contra el
# count(DISTINCT) de la clave NORMALIZADA, que es exactamente lo que el ETL
# construye: hoy da 12 y hay 12 nodos, clavado.
#
# EL PRECIO, dicho de frente: la normalizacion queda escrita en DOS lugares,
# aqui y en pg_temp.clave_direccion de etl/extraer_grafo.sql. Si alguien toca
# una y no la otra, los numeros dejan de cuadrar y ESTE arranque se pone rojo --
# o sea que la copia se vigila sola, en la direccion que importa: si esta se
# vuelve mas estricta que el ETL, rojo; si se vuelve mas laxa, el -lt lo deja
# pasar y ahi si hay que estar despierto. No se puede evitar la copia sin dejar
# una funcion permanente en la base, y extraer_grafo.sql es un extractor: no
# debe escribir nada.
$CLAVE_DIRECCION = @'
lower(regexp_replace(
    trim(translate(
        coalesce(pais, '') || '|' || coalesce(departamento, '') || '|' ||
        coalesce(ciudad, '') || '|' || coalesce(direccion_exacta, ''),
        chr(225) || chr(233) || chr(237) || chr(243) || chr(250) ||
        chr(252) || chr(241) || chr(193) || chr(201) || chr(205) ||
        chr(211) || chr(218) || chr(220) || chr(209),
        'aeiouunAEIOUUN')),
    '\s+', ' ', 'g'))
'@

$NODOS_ETL = @(
    @{ etiqueta = 'Usuario';   clase = 'nodo';   sql = 'SELECT count(*) FROM usuarios;' },
    @{ etiqueta = 'Producto';  clase = 'nodo';   sql = 'SELECT count(DISTINCT id_producto_mongo) FROM resena;' },
    @{ etiqueta = 'Resena';    clase = 'nodo';   sql = 'SELECT count(*) FROM resena;' },
    @{ etiqueta = 'Direccion'; clase = 'nodo';   sql = "SELECT count(DISTINCT $CLAVE_DIRECCION) FROM direcciones;" },
    @{ etiqueta = 'ESCRIBIO';   clase = 'arista'; sql = 'SELECT count(*) FROM resena;' },
    @{ etiqueta = 'CALIFICA_A'; clase = 'arista'; sql = 'SELECT count(*) FROM resena;' },
    @{ etiqueta = 'SOBRE';      clase = 'arista'; sql = 'SELECT count(*) FROM resena;' },
    @{ etiqueta = 'VIVE_EN';    clase = 'arista'; sql = "SELECT count(*) FROM (SELECT DISTINCT id_usuario, $CLAVE_DIRECCION AS clave FROM direcciones) v;" }
)

# Cuenta lo que sea, nodo o arista, segun lo diga la entrada de la lista.
function Contar-EnGrafo($entrada) {
    if ($entrada.clase -eq 'arista') { return Contar-Aristas $entrada.etiqueta }
    return Contar-Nodos $entrada.etiqueta
}

Paso "Grafo de resenas en Neo4j"

$grafoAlDia   = $true
$resumenGrafo = @()

foreach ($n in $NODOS_ETL) {
    $enGrafo = Contar-EnGrafo $n

    # Por stdin y no con -c, igual que las cuentas de Mongo: asi la consulta no
    # pasa por el armado de linea de comandos de PowerShell, que es donde se
    # pierden las comillas y los parentesis.
    $enPostgres = ($n.sql |
        docker exec -i mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX 2>&1 | Out-String).Trim()

    # Si una cuenta no salio se corre el ETL igual. Es idempotente, y saltarselo
    # por no poder contar dejaria el grafo a medias sin avisar.
    if (($null -eq $enGrafo) -or ($enPostgres -notmatch '^\d+$')) {
        $grafoAlDia = $false
        $resumenGrafo += "$($n.etiqueta) ?/$enPostgres"
        continue
    }

    # -lt y no -ne, por lo mismo que en Mongo: que el grafo tenga MAS no es un
    # fallo. Lo sembrado a mano para una demostracion
    # (neo4j/consultas/siembra.cypher crea seis cuentas de prueba y las borra)
    # sube la cuenta un rato, y con -ne cada demostracion a medias dejaria el
    # arranque migrando de mas.
    if ($enGrafo -lt [int]$enPostgres) { $grafoAlDia = $false }

    $resumenGrafo += "$($n.etiqueta) $enGrafo/$enPostgres"
}

if (-not $Etl -and -not $ReiniciarGrafo -and $grafoAlDia) {
    Ok "Ya cargado ($($resumenGrafo -join ', ')). Para volver a migrarlo: .\arrancar.ps1 -Etl"
} else {
    Correr-EtlGrafo $ReiniciarGrafo
}


# ------------------------------------------------------------
# 9c. El grafo NO puede quedar vacio
# ------------------------------------------------------------
# El gemelo de la comprobacion 7b, y existe por el mismo fallo: un ETL que se
# salta y un script que termina en verde. Aqui es peor de detectar que en
# Mongo, porque nadie mira el grafo todos los dias -- se mira el dia de la
# entrega, cuando la consulta de varios saltos tiene que senalar las cuentas
# anomalas, y para entonces ya no hay tiempo de arreglarlo.
#
# Se comprueba el RESULTADO y no que los pasos "parezcan" haber ido bien: las
# sentencias de resenas empiezan con tres MATCH y no fallan si los nodos no
# estan, simplemente no crean nada y salen con codigo cero.
#
# Se compara contra PostgreSQL en vez de exigir "que no este vacio" porque un
# grafo con 3 resenas de 86 pasaria en verde: la consulta de anillos correria
# sobre un vecindario incompleto y contestaria "no hay nada raro", que es una
# respuesta creible y falsa. Y se compara con -lt para que una base sin resenas
# (0 contra 0) no de un rojo por estar legitimamente vacia.
#
# Y se comprueban NODOS Y ARISTAS, no solo nodos. Contar nodos NO es comprobar
# el resultado: un grafo con los 163 nodos y CERO relaciones pasaba esta seccion
# entera en verde, y sobre el las cinco consultas de la entrega contestan que no
# hay nada. Esta medido y contado arriba, donde se arma $NODOS_ETL.
Paso "Comprobando que el grafo quedo cargado"

$faltanNodos = @()
foreach ($n in $NODOS_ETL) {
    $enGrafo = Contar-EnGrafo $n

    if ($null -eq $enGrafo) {
        $faltanNodos += "$($n.etiqueta) (no se pudo contar)"
        continue
    }

    $esperados = ($n.sql |
        docker exec -i mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -qtAX 2>&1 | Out-String).Trim()

    if ($esperados -notmatch '^\d+$') {
        # No se pudo contar del otro lado. No se inventa un veredicto: se dice.
        Aviso "$($n.etiqueta)  $enGrafo  (no se pudo contar en PostgreSQL para comparar)"
    } elseif ($enGrafo -lt [int]$esperados) {
        $faltanNodos += "$($n.etiqueta) ($enGrafo de $esperados)"
    } else {
        Ok "$($n.etiqueta)  $enGrafo de $esperados"
    }
}

if ($faltanNodos.Count -gt 0) {
    Error1 "El grafo de Neo4j NO quedo completo: $($faltanNodos -join ', ')"
    Error1 ""
    Error1 "Las resenas si estan en PostgreSQL, pero la deteccion de cuentas"
    Error1 "anomalas se corre sobre el grafo, asi que va a contestar que no hay"
    Error1 "nada raro. Lo que falla es el ETL del grafo."
    Error1 ""
    Error1 "Para ver el error completo:  .\arrancar.ps1 -Etl"
    Error1 "Para reconstruirlo desde cero:  .\arrancar.ps1 -ReiniciarGrafo"
    exit 1
}


# ------------------------------------------------------------
# 10. Resumen
# ------------------------------------------------------------
Paso "Listo"
docker ps --format "   {{.Names}}  {{.Status}}"

Write-Host ""
Write-Host "   pgAdmin        http://localhost:5050    ventana de PostgreSQL" -ForegroundColor White
Write-Host "   DbGate         http://localhost:3001    ventana de MongoDB" -ForegroundColor White
Write-Host "   RedisInsight   http://localhost:5540    ventana de Redis, con el TTL contando" -ForegroundColor White
# El navegador de Neo4j no es un visor mas: DIBUJA el grafo, y un anillo de
# cuentas que se califican entre si solo se ve dibujado. En una tabla de filas
# es una lista de pares que no dice nada.
Write-Host "   Neo4j          http://localhost:7474    ventana del grafo, lo dibuja" -ForegroundColor White
# ClickHouse trae su propia consola dentro de la imagen, asi que no lleva un
# contenedor de visor al lado como PostgreSQL, MongoDB y Redis.
Write-Host "   ClickHouse     http://localhost:8123/play   consola de los eventos" -ForegroundColor White
Write-Host ""
Write-Host "   PostgreSQL     localhost:5432   base $($env_['DB_NAME'])   usuario $($env_['DB_USER'])" -ForegroundColor White
Write-Host "   MongoDB        localhost:27018  base $($env_['MONGO_DB'])   usuario $($env_['MONGO_USER'])" -ForegroundColor White
Write-Host "   Redis          localhost:6379   con contrasena (requirepass)" -ForegroundColor White
Write-Host "   Neo4j          localhost:7687   bolt   usuario neo4j" -ForegroundColor White
Write-Host "   Elasticsearch  localhost:9200   sin contrasena, solo en local" -ForegroundColor White
Write-Host "   ClickHouse     localhost:8123   base $($env_['CLICKHOUSE_DB'])   usuario $($env_['CLICKHOUSE_USER'])" -ForegroundColor White
Write-Host ""
Write-Host "   Falta arrancar a mano:" -ForegroundColor DarkGray
Write-Host "     cd backend  ; npm run start:dev" -ForegroundColor DarkGray
Write-Host "     cd frontend ; npm run dev" -ForegroundColor DarkGray
Write-Host ""
Write-Host "   Consola de MongoDB:  .\arrancar.ps1 -Mongo" -ForegroundColor DarkGray
# Se imprime con "bash" delante y no con la redireccion que habia antes. La
# linea vieja era esta:
#
#   docker exec -i mesh-neo4j cypher-shell ... --format plain < neo4j/002_fraude.cypher
#
# y quien acaba de correr este .ps1 esta en PowerShell, donde ese comando ni
# siquiera llega a ejecutarse: PowerShell 5.1 contesta "The '<' operator is
# reserved for future use" y sale con codigo 1 sin correr una sola consulta.
# Comprobado pegandola tal cual. La linea de al lado ya marcaba "bash" para las
# pruebas de Redis, asi que esta se leia como ejecutable en la misma consola.
Write-Host "   Consultas de fraude: bash neo4j/correr_fraude.sh" -ForegroundColor DarkGray
Write-Host "   Pruebas de Redis:    bash redis/prueba_concurrencia.sh   y   bash redis/prueba_carrito.sh" -ForegroundColor DarkGray
Write-Host ""

# El aviso del lote rechazado se repite AQUI, y es lo ultimo que se imprime.
#
# El arranque siguio adelante a proposito (esta explicado en el paso 5c), pero
# seguir adelante no puede acabar en una pantalla que solo diga cosas buenas: el
# amarillo del paso 5c queda enterrado bajo las cuentas de Mongo, las de Neo4j y
# el resumen entero, y quien tecleo la linea se va creyendo que su lote esta en
# la base. Repetirlo al final es lo que evita el "todo bien" que no responde a
# lo que se pidio, que es el fallo que este archivo persigue en todas partes.
#
# El script igual sale con codigo 0, y hay que decir por que se eligio asi: el
# codigo de salida habla del AMBIENTE, que es lo que este script promete dejar
# en pie, y el ambiente quedo bien. El lote es una peticion opcional que se
# rechazo sin escribir nada. El precio de esa eleccion es que un script que
# encadene con este no se entera del rechazo; el precio del otro lado seria
# pintar de rojo un arranque sano, que es peor porque manda a buscar una averia
# que no existe.
if ($loteRechazado) {
    Aviso "OJO: el lote NO se genero ($loteRechazado)."
    Aviso "Las bases quedaron arriba y completas, pero sin ese lote."
    Aviso "El motivo esta mas arriba, en el paso de generacion."
    Write-Host ""
}
