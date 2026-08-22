# arrancar.ps1
# Levanta todo el ambiente de Mesh de una sola vez.
#
#   .\arrancar.ps1                   levanta PostgreSQL, pgAdmin y MongoDB
#   .\arrancar.ps1 -Reiniciar        borra TODOS los datos y empieza de cero
#   .\arrancar.ps1 -ReiniciarMongo   rehace solo MongoDB, sin tocar PostgreSQL

param(
    [switch]$Reiniciar,
    [switch]$ReiniciarMongo
)

Set-Location -LiteralPath $PSScriptRoot

function Paso($t)  { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "   $t"   -ForegroundColor Green }
function Aviso($t) { Write-Host "   $t"   -ForegroundColor Yellow }
function Error1($t){ Write-Host "   $t"   -ForegroundColor Red }


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
    for ($i = 0; $i -lt 60; $i++) {
        $estado = docker inspect -f "{{.State.Health.Status}}" mesh-mongo 2>&1
        if ("$estado".Trim() -eq "healthy") { return $true }
        Start-Sleep -Seconds 2
    }

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

$listo = $false
for ($i = 0; $i -lt 60; $i++) {
    $estado = docker inspect -f "{{.State.Health.Status}}" mesh-postgres 2>&1
    if ("$estado".Trim() -eq "healthy") { $listo = $true; break }
    Start-Sleep -Seconds 2
}

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
Paso "Corriendo migraciones"

$scripts = @(Get-ChildItem -LiteralPath "$PSScriptRoot\migrations" -Filter "*.sql" -ErrorAction SilentlyContinue | Sort-Object Name)

if ($scripts.Count -eq 0) {
    Aviso "No hay archivos .sql en migrations/"
} else {
    foreach ($s in $scripts) {
        # ON_ERROR_STOP corta si algo falla, en vez de dejar la base a medias
        $salida = docker exec mesh-postgres psql -U $env_["DB_USER"] -d $env_["DB_NAME"] -v ON_ERROR_STOP=1 -q -f "/migrations/$($s.Name)" 2>&1 | Out-String

        if ($LASTEXITCODE -eq 0) {
            Ok "$($s.Name)"
        } elseif ($salida -match "already exists") {
            Aviso "$($s.Name) ya estaba aplicada"
        } else {
            Error1 "$($s.Name) FALLO"
            Write-Host $salida -ForegroundColor Red
            exit 1
        }
    }
}


# ------------------------------------------------------------
# 6. MongoDB
# ------------------------------------------------------------
# El contenedor ya subio con el "docker compose up -d" de arriba. Aqui se
# espera a que responda, se comprueba el acceso y se corren los scripts de
# mongo/ que crean las colecciones.

Paso "Esperando a MongoDB"

$listoMongo = $false
for ($i = 0; $i -lt 60; $i++) {
    $estado = docker inspect -f "{{.State.Health.Status}}" mesh-mongo 2>&1
    if ("$estado".Trim() -eq "healthy") { $listoMongo = $true; break }
    Start-Sleep -Seconds 2
}

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
# 7. Resumen
# ------------------------------------------------------------
Paso "Listo"
docker ps --format "   {{.Names}}  {{.Status}}"

Write-Host ""
Write-Host "   pgAdmin      http://localhost:5050" -ForegroundColor White
Write-Host "   PostgreSQL   localhost:5432   base $($env_['DB_NAME'])   usuario $($env_['DB_USER'])" -ForegroundColor White
Write-Host "   MongoDB      localhost:27017  base $($env_['MONGO_DB'])   usuario $($env_['MONGO_USER'])" -ForegroundColor White
Write-Host ""
Write-Host "   Falta arrancar a mano:" -ForegroundColor DarkGray
Write-Host "     cd backend  ; npm run start:dev" -ForegroundColor DarkGray
Write-Host "     cd frontend ; npm run dev" -ForegroundColor DarkGray
Write-Host ""
