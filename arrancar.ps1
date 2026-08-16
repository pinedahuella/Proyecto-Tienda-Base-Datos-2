# arrancar.ps1
# Levanta todo el ambiente de Mesh de una sola vez.
#
#   .\arrancar.ps1              levanta PostgreSQL y pgAdmin
#   .\arrancar.ps1 -Reiniciar   borra los datos y empieza de cero

param(
    [switch]$Reiniciar
)

Set-Location -LiteralPath $PSScriptRoot

function Paso($t)  { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "   $t"   -ForegroundColor Green }
function Aviso($t) { Write-Host "   $t"   -ForegroundColor Yellow }
function Error1($t){ Write-Host "   $t"   -ForegroundColor Red }


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

foreach ($obligatoria in @("DB_USER", "DB_PASSWORD", "DB_NAME")) {
    if (-not $env_[$obligatoria] -or $env_[$obligatoria] -eq "cambiame") {
        Error1 "Falta llenar $obligatoria en el .env"
        exit 1
    }
}
Ok "Credenciales leidas"

# pgAdmin necesita estos dos archivos para conectarse solo. Se generan aqui a
# partir del .env para que las contrasenas no queden en el repositorio.
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
$servidores | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath "$carpetaPgadmin\servers.json" -Encoding utf8 -NoNewline

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
# 4. Migraciones
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
# 5. Resumen
# ------------------------------------------------------------
Paso "Listo"
docker ps --format "   {{.Names}}  {{.Status}}"

Write-Host ""
Write-Host "   pgAdmin      http://localhost:5050" -ForegroundColor White
Write-Host "   PostgreSQL   localhost:5432   base $($env_['DB_NAME'])   usuario $($env_['DB_USER'])" -ForegroundColor White
Write-Host ""
Write-Host "   Falta arrancar a mano:" -ForegroundColor DarkGray
Write-Host "     cd backend  ; npm run start:dev" -ForegroundColor DarkGray
Write-Host "     cd frontend ; npm run dev" -ForegroundColor DarkGray
Write-Host ""
