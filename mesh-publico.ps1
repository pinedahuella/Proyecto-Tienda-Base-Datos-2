# mesh-publico.ps1
# Publica Mesh en https://mesh.ledkid.com para que cualquiera pueda entrar, y lo quita.
#
#   .\mesh-publico.ps1 -Accion encender     abre la direccion publica (sin ventana)
#   .\mesh-publico.ps1 -Accion apagar       la cierra
#   .\mesh-publico.ps1 -Accion estado       si esta abierta y si contesta
#
# Es un tunel de Cloudflare NOMBRADO y aparte: se llama 'mesh', es distinto del de LEDKID
# ('ledkid') y del de ENKID, y no comparte ni toca su config ni su servicio. Lleva al
# 5173 (la tienda), que le pasa /api al backend con la IP de quien llego; el backend la
# lee con trustProxy, asi que las visitas reales se registran con su IP publica y no
# con 127.0.0.1. Solo se publica la tienda: el panel de comandos (5199), pgAdmin, DbGate,
# RedisInsight y las bases siguen solo en esta maquina.
#
# Como se hizo la primera vez, ya hecho (una vez por cuenta de Cloudflare):
#   cloudflared tunnel create mesh
#   cloudflared tunnel route dns mesh mesh.ledkid.com
#   y ~\.cloudflared\config-mesh.yml con el id del tunel, sus credenciales y el ingress
#   hostname mesh.ledkid.com -> http://localhost:5173
# Ese config y las credenciales viven en la carpeta del usuario, NUNCA en el repo.
#
# Publica la tienda tal como esta, con sus cuentas de prueba: cualquiera que las conozca
# entra con ellas (admin incluido). Es para demostrar, y se cierra con -Accion apagar.
# Necesita la tienda (5173) y el backend (3000) arriba. En la red de la U el tunel
# necesita WARP; Asegurar-SalidaTunel lo conecta si el puerto 7844 esta cerrado.

param(
    [ValidateSet('encender', 'apagar', 'estado')]
    [string]$Accion = 'estado'
)

# Nada de ErrorActionPreference = 'Stop': cloudflared escribe avisos por stderr.
$repo = $PSScriptRoot
. (Join-Path $repo 'copia-backend.ps1')
$cf = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$cfg = Join-Path $env:USERPROFILE '.cloudflared\config-mesh.yml'
$direccion = 'https://mesh.ledkid.com'
$logs = Join-Path $env:TEMP 'mesh-logs'
$inicio = Get-Date
function Paso($t) { Write-Host ("`n>> $t  [+{0} s]" -f [int]((Get-Date) - $inicio).TotalSeconds) -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

# El cloudflared de ESTE tunel, y solo el: se reconoce por su config. No confundir con el
# servicio de LEDKID, que corre con otro --config.
function Proceso-Mesh {
    Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains('config-mesh.yml') }
}

function Publico-Responde {
    try { return ((Invoke-WebRequest "$direccion/api/productos?limite=1" -UseBasicParsing -TimeoutSec 20).StatusCode -eq 200) } catch { return $false }
}

if ($Accion -eq 'estado') {
    Paso "Direccion publica de Mesh"
    $p = @(Proceso-Mesh)
    if ($p.Count -eq 0) { Write-Host "   Cerrada. Para abrirla: .\mesh-publico.ps1 -Accion encender"; exit 0 }
    Ok "Tunel abierto (proceso $($p[0].ProcessId), desde $($p[0].CreationDate.ToString('HH:mm:ss')))"
    if (Publico-Responde) { Ok "$direccion contesta" } else { Mal "$direccion no contesta todavia (o la tienda esta apagada)" }
    exit 0
}

if ($Accion -eq 'apagar') {
    Paso "Cerrando la direccion publica"
    $p = @(Proceso-Mesh)
    if ($p.Count -eq 0) { Write-Host "   Ya estaba cerrada."; exit 0 }
    foreach ($x in $p) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
    Ok "Cerrada. ledkid.com y su tunel no se tocaron."
    exit 0
}

# --- encender ---
if (-not (Test-Path $cfg)) {
    Mal "Falta $cfg. Es el config del tunel 'mesh' (ver la cabecera de este archivo)."
    exit 1
}
if (@(Proceso-Mesh).Count -gt 0) {
    Paso "Direccion publica de Mesh"
    if (Publico-Responde) { Ok "Ya estaba abierta: $direccion"; exit 0 }
    Write-Host "   El tunel estaba corriendo pero no contesta; se reinicia." -ForegroundColor Yellow
    foreach ($x in @(Proceso-Mesh)) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
}

Paso "Revisando la tienda y el backend"
$tienda = try { (Invoke-WebRequest 'http://localhost:5173/api/productos?limite=1' -UseBasicParsing -TimeoutSec 20).StatusCode -eq 200 } catch { $false }
if (-not $tienda) { Mal "La tienda no contesta en el 5173 (o el backend en el 3000). Levantala primero (Levantar todo)."; exit 1 }
Ok "Tienda y backend arriba"

Paso "Comprobando que el tunel pueda salir"
if (-not (Asegurar-SalidaTunel)) { Write-Host "   Sigo, pero es probable que el tunel no levante." -ForegroundColor Yellow }

Paso "Abriendo $direccion"
New-Item -ItemType Directory -Force $logs | Out-Null
Start-Process -FilePath $cf -ArgumentList '--no-autoupdate', '--config', "`"$cfg`"", 'tunnel', 'run' -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $logs 'mesh-publico.log') -RedirectStandardError (Join-Path $logs 'mesh-publico.err') | Out-Null
$arriba = $false
for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep 2
    if (@(Proceso-Mesh).Count -eq 0) { break }
    if (Publico-Responde) { $arriba = $true; break }
}
if (-not $arriba) {
    Mal "No contesto $direccion. Mira $logs\mesh-publico.err"
    Mal "Si el DNS es nuevo puede tardar unos minutos; vuelve a probar con -Accion estado."
    exit 1
}
Ok "Abierta: $direccion"
Write-Host "`n=============================================================="
Write-Host " LISTO. Mesh esta en $direccion" -ForegroundColor Green
Write-Host " Cualquiera puede entrar y registrarse. Las visitas se registran con su IP real."
Write-Host " Cerrarla:  .\mesh-publico.ps1 -Accion apagar" -ForegroundColor Yellow
Write-Host "=============================================================="
