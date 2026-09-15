# tunel-celular.ps1
# Abre Mesh a internet con un tunel rapido de Cloudflare, para entrar desde un
# celular (con VPN o sin ella) o desde otra red. Es UN solo tunel, al frontend:
# el navegador pide /api al mismo sitio y el proxy de vite se lo pasa al backend.
# Ver docs/ENTRAR-DESDE-EL-CELULAR.md.
#
#   .\tunel-celular.ps1              con el backend normal (3000)
#   .\tunel-celular.ps1 -ConCopia    con la copia del backend con trustProxy
#                                    (3100): el login sale con la IP del celular
#   .\tunel-celular.ps1 -Cerrar      cierra el tunel y el frontend y deja el
#                                    backend normal en 3000
#
# Todo corre sin ventana. El link cambia cada vez que se abre el tunel.

param(
    [switch]$ConCopia,
    [switch]$Cerrar
)

$repo = $PSScriptRoot
. (Join-Path $repo 'copia-backend.ps1')
$front = Join-Path $repo 'frontend'
$estado = Join-Path $MeshDemoTmp 'celular.json'
function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

function Cerrar-Puerto([int]$puerto) {
    $lst = Get-NetTCPConnection -LocalPort $puerto -State Listen -ErrorAction SilentlyContinue
    foreach ($l in @($lst)) { if ($l) { Stop-Process -Id $l.OwningProcess -Force -ErrorAction SilentlyContinue } }
}

# Cierra lo que abrio la corrida anterior de este script (tunel, frontend y copia).
function Cerrar-Anterior {
    if (-not (Test-Path $estado)) { return $false }
    $e = Get-Content $estado -Raw | ConvertFrom-Json
    foreach ($id in @($e.pids)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Remove-Item $estado -Force
    return [bool]$e.conCopia
}

if ($Cerrar) {
    Paso "Cerrando el tunel y el frontend"
    Cerrar-Anterior | Out-Null
    Cerrar-Puerto 5173
    Cerrar-Puerto 3100
    Ok "Tunel, frontend y copia cerrados"
    Paso "Dejando el backend normal en 3000"
    if (Arrancar-BackendNormal $repo) { Ok "Backend normal arriba en 3000" } else { Mal "El backend normal no contesto. Mira $MeshDemoTmp\backend-normal.err" }
    Write-Host "`n   El frontend queda apagado. Para trabajar en local: cd frontend ; npm run dev"
    exit 0
}

# --- Docker y las bases ---
Paso "Revisando Docker y las bases"
docker ps *> $null
if ($LASTEXITCODE -ne 0) { Mal "Docker no responde. Abre Docker Desktop y espera a que arranque."; exit 1 }
if (-not (docker ps --format '{{.Names}}' | Select-String -Quiet 'mesh-postgres')) {
    Mal "Los contenedores de Mesh no estan arriba. Corre primero: .\arrancar.ps1"; exit 1
}
Ok "Docker y los contenedores mesh-* estan arriba"
if (Cerrar-Anterior) { Cerrar-Puerto 3100 }

# --- el backend ---
$pids = @()
if ($ConCopia) {
    Paso "Preparando la copia del backend con trustProxy"
    if (-not (Preparar-CopiaBackend $repo)) { Mal "No compilo la copia. Mira $MeshDemoTmp\build.log"; exit 1 }
    $pCopia = Arrancar-CopiaBackend
    if (-not $pCopia) { Mal "La copia no respondio. Mira $MeshDemoTmp\backend.err"; Arrancar-BackendNormal $repo | Out-Null; exit 1 }
    $pids += $pCopia.Id
    $destino = 'http://127.0.0.1:3100'
    Ok "Copia respondiendo en 3100 (el backend normal quedo parado mientras tanto)"
} else {
    Paso "Revisando el backend normal"
    if (-not (Arrancar-BackendNormal $repo)) { Mal "El backend no contesta en 3000. Mira $MeshDemoTmp\backend-normal.err"; exit 1 }
    $destino = 'http://127.0.0.1:3000'
    Ok "Backend respondiendo en 3000"
}

# --- el frontend compilado, con el proxy a ese backend ---
# vite preview y no vite dev: OneDrive dispara el vigilante de vite y el dev
# server se recarga solo (docs/TRASPASO.md). El build no vigila nada.
Paso "Compilando el frontend"
Cerrar-Puerto 5173
New-Item -ItemType Directory -Force $MeshDemoTmp | Out-Null
Push-Location $front
& (Get-Command npm.cmd).Source run build *> (Join-Path $MeshDemoTmp 'front-build.log')
$compilo = $LASTEXITCODE -eq 0
Pop-Location
if (-not $compilo) { Mal "El frontend no compilo. Mira $MeshDemoTmp\front-build.log"; exit 1 }
Ok "Frontend compilado"

Paso "Sirviendo el frontend en 5173"
$env:MESH_BACKEND = $destino
$pFront = Start-Process (Get-Command node.exe).Source `
    -ArgumentList 'node_modules\vite\bin\vite.js','preview','--host','127.0.0.1','--port','5173','--strictPort' `
    -WorkingDirectory $front -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $MeshDemoTmp 'front.log') -RedirectStandardError (Join-Path $MeshDemoTmp 'front.err') -PassThru
Remove-Item Env:MESH_BACKEND
$pids += $pFront.Id
$arriba = $false
for ($i=0; $i -lt 30; $i++) {
    Start-Sleep 2
    try { if ((Invoke-WebRequest 'http://127.0.0.1:5173/api/productos?limite=1' -UseBasicParsing -TimeoutSec 8).StatusCode -eq 200) { $arriba = $true; break } } catch {}
}
if (-not $arriba) { Mal "El frontend no paso /api al backend. Mira $MeshDemoTmp\front.err"; $pids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }; exit 1 }
Ok "Frontend y proxy /api respondiendo"

# --- el tunel ---
Paso "Abriendo el tunel"
$tun = Abrir-Tunel 'http://127.0.0.1:5173' '/api/productos?limite=1' 'tunel-celular'
if (-not $tun) { Mal "El tunel no levanto. Mira $MeshDemoTmp\tunel-celular.err"; $pids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }; exit 1 }
$pids += $tun.Proceso.Id
@{ pids = $pids; conCopia = [bool]$ConCopia; url = $tun.Url } | ConvertTo-Json | Set-Content $estado -Encoding ascii
Ok "Tunel arriba"

Write-Host "`n=============================================================="
Write-Host " LISTO. Abre este link en el celular:" -ForegroundColor Green
Write-Host "   $($tun.Url)" -ForegroundColor Yellow
Write-Host ""
if ($ConCopia) {
    Write-Host " Los logins que entren por ahi salen con la IP del celular en el"
    Write-Host " panel del admin (pestana Fraude)."
} else {
    Write-Host " OJO: con el backend normal todo login por el tunel sale como"
    Write-Host " 127.0.0.1 hasta que Jose David ponga trustProxy. Para ver la IP"
    Write-Host " del celular hoy: .\tunel-celular.ps1 -ConCopia"
}
Write-Host ""
Write-Host " En esta PC sigue en http://localhost:5173"
Write-Host " Para cerrar todo:  .\tunel-celular.ps1 -Cerrar" -ForegroundColor Yellow
Write-Host "=============================================================="
