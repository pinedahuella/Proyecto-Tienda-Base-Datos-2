# arrancar.ps1
# Levanta todo el ambiente de Mesh de una sola vez.
#
#   .\arrancar.ps1                   levanta PostgreSQL, pgAdmin, MongoDB, Redis y Neo4j
#   .\arrancar.ps1 -Reiniciar        borra TODOS los datos y empieza de cero
#   .\arrancar.ps1 -ReiniciarMongo   rehace solo MongoDB, sin tocar PostgreSQL
#   .\arrancar.ps1 -ReiniciarGrafo   rehace solo el grafo de Neo4j, desde cero
#   .\arrancar.ps1 -Mongo            abre la consola de MongoDB y ya
#   .\arrancar.ps1 -Etl              vuelve a migrar el catalogo a Mongo Y el grafo a Neo4j

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

param(
    [switch]$Reiniciar,
    [switch]$ReiniciarMongo,
    [switch]$ReiniciarGrafo,
    [switch]$Mongo,
    [switch]$Etl
)

Set-Location -LiteralPath $PSScriptRoot

function Paso($t)  { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "   $t"   -ForegroundColor Green }
function Aviso($t) { Write-Host "   $t"   -ForegroundColor Yellow }
function Error1($t){ Write-Host "   $t"   -ForegroundColor Red }


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

foreach ($obligatoria in @("DB_USER", "DB_PASSWORD", "DB_NAME",
                          "MONGO_USER", "MONGO_PASSWORD", "MONGO_DB")) {
    if (-not $env_[$obligatoria] -or $env_[$obligatoria] -eq "cambiame") {
        Error1 "Falta llenar $obligatoria en el .env"
        exit 1
    }
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

    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
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
Write-Host ""
Write-Host "   PostgreSQL     localhost:5432   base $($env_['DB_NAME'])   usuario $($env_['DB_USER'])" -ForegroundColor White
Write-Host "   MongoDB        localhost:27018  base $($env_['MONGO_DB'])   usuario $($env_['MONGO_USER'])" -ForegroundColor White
Write-Host "   Redis          localhost:6379   con contrasena (requirepass)" -ForegroundColor White
Write-Host "   Neo4j          localhost:7687   bolt   usuario neo4j" -ForegroundColor White
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
