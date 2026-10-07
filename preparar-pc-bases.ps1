# preparar-pc-bases.ps1
# Para la PC del amigo que presta su maquina para las bases de Mesh.
#
# Deja esta PC con las SEIS bases de Mesh corriendo y alcanzables por Tailscale,
# para que el backend corra en otra PC. Lo que hace, en orden:
#
#   1. instala Git y Docker Desktop si faltan (con winget)
#   2. instala Tailscale 1.102.4, la misma version que tiene Meme, y lo conecta
#   3. clona el repositorio en C:\Proyectos\Proyecto-Tienda-Base-Datos-2, o lo
#      actualiza si ya estaba
#   4. copia el .env que Meme te paso (tiene que estar al lado de este script)
#   5. abre en el firewall los puertos de las bases, SOLO para la red de Tailscale
#   6. corre arrancar.ps1, que levanta y llena las bases
#   7. te dice la IP que le tienes que mandar a Meme
#
# Como se usa
#   - Pon este archivo y el .env que te mando Meme en la misma carpeta.
#   - Clic derecho en este archivo, "Ejecutar con PowerShell". Pide permisos de
#     administrador, porque instala programas y toca el firewall.
#
#   .\preparar-pc-bases.ps1            prepara todo y levanta las bases
#   .\preparar-pc-bases.ps1 -Apagar    apaga las bases (no borra nada)
#
# Se puede correr las veces que quieras. Lo que ya esta hecho no se repite.

param([switch]$Apagar)

$ErrorActionPreference = 'Continue'

$VERSION_TAILSCALE = '1.102.4'
$REPO    = 'https://github.com/pinedahuella/Proyecto-Tienda-Base-Datos-2.git'
$DESTINO = 'C:\Proyectos\Proyecto-Tienda-Base-Datos-2'
# Postgres, Mongo, Redis, Neo4j (bolt), Elasticsearch y ClickHouse (HTTP).
# Son los que usa el backend. Las consolas web (pgAdmin, Kibana...) no se abren.
$PUERTOS = @(5432, 27018, 6379, 7687, 9200, 8123)
$REGLA   = 'Mesh, bases por Tailscale'
# Todas las IP de Tailscale caen en este rango.
$RED_TAILSCALE = '100.64.0.0/10'

function Paso($t)  { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "   $t" }
function Aviso($t) { Write-Host "   $t" -ForegroundColor Yellow }
function Falla($t) { Write-Host "`n   $t" -ForegroundColor Red; Read-Host "`nEnter para cerrar" | Out-Null; exit 1 }

# Recarga el PATH despues de instalar algo, sin cerrar la ventana.
function Refrescar-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

# ------------------------------------------------------------
# Administrador. Si no lo es, se vuelve a abrir pidiendo permiso.
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    $argumentos = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Apagar) { $argumentos += ' -Apagar' }
    Start-Process powershell -Verb RunAs -ArgumentList $argumentos
    exit
}

# ------------------------------------------------------------
if ($Apagar) {
    Paso "Apagando las bases de Mesh"
    if (-not (Test-Path $DESTINO)) { Falla "No encuentro $DESTINO" }
    Set-Location $DESTINO
    docker compose --profile ollama stop 2>&1 | Out-Null
    Ok "Apagadas. Los datos se quedan; la proxima vez corre este script sin -Apagar."
    Read-Host "`nEnter para cerrar" | Out-Null
    exit 0
}

# ------------------------------------------------------------
Paso "Revisando winget"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Falla "No hay winget. Instala 'Instalador de aplicacion' desde la Microsoft Store y vuelve a correr esto."
}
Ok "winget esta"

# ------------------------------------------------------------
Paso "Git"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Aviso "No esta, lo instalo"
    winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
    Refrescar-Path
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Falla "Git no quedo instalado." }
}
Ok (git --version)

# ------------------------------------------------------------
Paso "Docker Desktop"
$dockerExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
if (-not (Test-Path $dockerExe)) {
    Aviso "No esta, lo instalo (son unos 500 MB)"
    winget install --id Docker.DockerDesktop -e --silent --accept-package-agreements --accept-source-agreements
    if (-not (Test-Path $dockerExe)) { Falla "Docker Desktop no quedo instalado." }
    Write-Host ""
    Aviso "Docker Desktop recien instalado necesita REINICIAR la PC."
    Aviso "Reinicia, abre Docker Desktop una vez, acepta sus terminos y vuelve a correr este script."
    Read-Host "`nEnter para cerrar" | Out-Null
    exit 0
}
Ok "instalado"

# ------------------------------------------------------------
Paso "Tailscale $VERSION_TAILSCALE"
$tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
$tsVersion = ''
if (Test-Path $tsExe) { $tsVersion = ((& $tsExe version) | Select-Object -First 1).Trim() }
if ($tsVersion -ne $VERSION_TAILSCALE) {
    if ($tsVersion) { Aviso "Tiene la $tsVersion, pongo la $VERSION_TAILSCALE" } else { Aviso "No esta, lo instalo" }
    $msi = Join-Path $env:TEMP "tailscale-setup-$VERSION_TAILSCALE-amd64.msi"
    $url = "https://pkgs.tailscale.com/stable/tailscale-setup-$VERSION_TAILSCALE-amd64.msi"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    } catch { Falla "No pude bajar $url" }
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { Falla "El instalador de Tailscale termino con codigo $($p.ExitCode)" }
}
Start-Service Tailscale -ErrorAction SilentlyContinue
Set-Service Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
Ok ((& $tsExe version) | Select-Object -First 1)

$ip = ((& $tsExe ip -4 2>$null) | Select-Object -First 1)
if (-not $ip) {
    Aviso "Tailscale no tiene sesion. Se abre el navegador para entrar."
    Aviso "Entra con la cuenta a la que Meme te invito."
    & $tsExe up --unattended
    $ip = ((& $tsExe ip -4 2>$null) | Select-Object -First 1)
    if (-not $ip) { Falla "Tailscale sigue sin sesion. Vuelve a correr el script cuando hayas entrado." }
}
$ip = $ip.Trim()
Ok "IP de Tailscale de esta PC: $ip"

# ------------------------------------------------------------
Paso "Repositorio"
if (Test-Path (Join-Path $DESTINO '.git')) {
    Set-Location $DESTINO
    git pull --ff-only
    if ($LASTEXITCODE -ne 0) { Aviso "git pull no pudo avanzar solo. Sigo con lo que hay." }
} else {
    New-Item -ItemType Directory -Force (Split-Path $DESTINO) | Out-Null
    Aviso "Clonando. El repositorio es privado: si se abre una ventana de GitHub, entra con tu cuenta."
    git clone $REPO $DESTINO
    if ($LASTEXITCODE -ne 0) { Falla "No se pudo clonar. Pide a Meme o a David que te agreguen al repositorio en GitHub." }
}
Set-Location $DESTINO
Ok $DESTINO

# ------------------------------------------------------------
Paso "Archivo .env"
$envRepo = Join-Path $DESTINO '.env'
$envJunto = Join-Path $PSScriptRoot '.env'
if ((Test-Path $envJunto) -and ($envJunto -ne $envRepo)) {
    Copy-Item $envJunto $envRepo -Force
    Ok "copiado el .env que estaba al lado del script"
} elseif (Test-Path $envRepo) {
    Ok "ya estaba"
} else {
    Falla "Falta el .env. Ponlo en la misma carpeta que este script (te lo pasa Meme) y vuelve a correrlo."
}

# ------------------------------------------------------------
Paso "Firewall"
Get-NetFirewallRule -DisplayName $REGLA -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $REGLA -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $PUERTOS -RemoteAddress $RED_TAILSCALE -Profile Any | Out-Null
Ok "puertos $($PUERTOS -join ', ') abiertos solo para $RED_TAILSCALE"

# ------------------------------------------------------------
Paso "Levantando las bases con arrancar.ps1 (la primera vez tarda, baja imagenes y el modelo de vectores)"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DESTINO 'arrancar.ps1')
if ($LASTEXITCODE -ne 0) { Falla "arrancar.ps1 termino con error ($LASTEXITCODE). Mandale a Meme lo que salio arriba." }

# ------------------------------------------------------------
Paso "Listo"
Write-Host ""
Write-Host "   Mandale esto a Meme:" -ForegroundColor Green
Write-Host "   .\usar-bases-remotas.ps1 -Ip $ip" -ForegroundColor Green
Write-Host ""
Ok "Para apagar las bases:  .\preparar-pc-bases.ps1 -Apagar"
Ok "No apagues la PC ni cierres Tailscale mientras Meme este probando."
Read-Host "`nEnter para cerrar" | Out-Null
