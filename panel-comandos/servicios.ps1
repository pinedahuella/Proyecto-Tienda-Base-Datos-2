# servicios.ps1
# Levanta, para y mira el backend y el frontend de Mesh, sin abrir ventanas.
# Lo usa el panel de comandos, pero se puede correr solo:
#
#   .\panel-comandos\servicios.ps1 -Accion estado
#   .\panel-comandos\servicios.ps1 -Accion backend        (compila y reinicia)
#   .\panel-comandos\servicios.ps1 -Accion frontend       (compila y reinicia)
#   .\panel-comandos\servicios.ps1 -Accion todo           (arrancar.ps1 + backend + frontend)
#   .\panel-comandos\servicios.ps1 -Accion parar-backend
#   .\panel-comandos\servicios.ps1 -Accion parar-frontend
#   .\panel-comandos\servicios.ps1 -Accion publico        (abre https://mesh.ledkid.com)
#   .\panel-comandos\servicios.ps1 -Accion despublicar    (la cierra)
#
# Por que se sirve el build y no el modo watch (nest --watch, vite dev): el
# proyecto vive dentro de OneDrive, y cada toque de sincronizacion dispara una
# recarga. El backend queda reiniciandose sin parar y el login dice "el servidor
# se esta reiniciando". Con el build no hay vigilante. El precio es que despues
# de editar codigo hay que volver a correr backend o frontend.
#
# Solo toca los node.exe cuya linea de comando contiene la carpeta backend o
# frontend de ESTE repositorio. Los de otros proyectos no se tocan.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('estado', 'backend', 'frontend', 'todo', 'parar-backend', 'parar-frontend', 'publico', 'despublicar')]
    [string]$Accion
)

# Nada de ErrorActionPreference = 'Stop': npm escribe avisos por stderr y PowerShell 5.1
# los toma por error. Cada paso comprueba su propio resultado.
$raiz = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $env:TEMP 'mesh-logs'
New-Item -ItemType Directory -Force $logs | Out-Null

function Paso($t) { Write-Host "`n>> $t" }
function Ok($t)   { Write-Host "   $t" }
function Mal($t)  { Write-Host "   $t" }

function Procesos-De([string]$carpeta) {
    $ruta = Join-Path $raiz $carpeta
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ruta) }
}

function Parar([string]$carpeta) {
    $ps = @(Procesos-De $carpeta)
    if ($ps.Count -eq 0) { Ok "$carpeta no estaba corriendo"; return }
    foreach ($p in $ps) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
    if (@(Procesos-De $carpeta).Count -gt 0) { Mal "OJO: $carpeta sigue con procesos vivos"; return }
    Ok "$carpeta parado ($($ps.Count) procesos)"
}

function Esperar-Url([string]$url, [int]$segundos) {
    $fin = (Get-Date).AddSeconds($segundos)
    while ((Get-Date) -lt $fin) {
        try { Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3 | Out-Null; return $true }
        catch { if ($_.Exception.Response) { return $true } }
        Start-Sleep 2
    }
    return $false
}

function Iniciar-Backend {
    Paso 'Backend, parando el anterior'
    Parar 'backend'
    Paso 'Backend, compilando (un minuto)'
    Push-Location (Join-Path $raiz 'backend')
    cmd /c "npm run build 2>&1"
    $codigo = $LASTEXITCODE
    Pop-Location
    if ($codigo -ne 0) { Mal "La compilacion fallo, codigo $codigo"; exit 1 }
    Paso 'Backend, levantando'
    # La ruta va ENTERA y no como dist/main. Procesos-De reconoce el backend
    # buscando la carpeta del repo en la linea de comando, y con la ruta
    # relativa no aparecia: parar-backend decia "no estaba corriendo" con el
    # backend vivo, y reiniciar lo dejaba duplicado (2026-09-26).
    Start-Process -FilePath 'node' -ArgumentList '--enable-source-maps', "`"$(Join-Path $raiz 'backend\dist\main.js')`"" `
        -WorkingDirectory (Join-Path $raiz 'backend') -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs 'backend.out.log') `
        -RedirectStandardError (Join-Path $logs 'backend.err.log')
    # 180 y no 90: con la maquina cargada (ClickHouse y Neo4j recien arrancados) el
    # backend tardo mas de 90 s en contestar y se dio por muerto estando vivo.
    if (-not (Esperar-Url 'http://localhost:3000/' 180)) {
        Mal "El backend no contesto en el 3000. Mira $logs\backend.err.log"; exit 1
    }
    Ok 'Backend listo en http://localhost:3000'
}

function Iniciar-Frontend {
    Paso 'Frontend, parando el anterior'
    Parar 'frontend'
    Paso 'Frontend, compilando'
    Push-Location (Join-Path $raiz 'frontend')
    cmd /c "npm run build 2>&1"
    $codigo = $LASTEXITCODE
    Pop-Location
    if ($codigo -ne 0) { Mal "La compilacion fallo, codigo $codigo"; exit 1 }
    Paso 'Frontend, levantando'
    # El puerto tiene que ser el 5173: el CORS del backend solo acepta ese.
    $npx = (Get-Command npx.cmd).Source
    Start-Process -FilePath $npx -ArgumentList 'vite', 'preview', '--port', '5173', '--strictPort' `
        -WorkingDirectory (Join-Path $raiz 'frontend') -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs 'frontend.out.log') `
        -RedirectStandardError (Join-Path $logs 'frontend.err.log')
    # 150 y no 60: con la maquina cargada tardo mas de un minuto en contestar
    if (-not (Esperar-Url 'http://localhost:5173/' 150)) {
        Mal "El frontend no contesto en el 5173. Mira $logs\frontend.err.log"; exit 1
    }
    Ok 'Frontend listo en http://localhost:5173'
}

function Mostrar-Estado {
    Paso 'Servicios'
    foreach ($par in @(@(3000, 'backend'), @(5173, 'frontend'))) {
        $c = Get-NetTCPConnection -State Listen -LocalPort $par[0] -ErrorAction SilentlyContinue
        if ($c) {
            $p = Get-Process -Id $c[0].OwningProcess -ErrorAction SilentlyContinue
            Ok ("{0,-9} puerto {1}  ARRIBA  desde {2}" -f $par[1], $par[0], $p.StartTime)
        } else {
            Ok ("{0,-9} puerto {1}  apagado" -f $par[1], $par[0])
        }
    }
    Paso 'Contenedores'
    $d = docker ps --format '{{.Names}}  {{.Status}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $d) { Ok 'Docker no responde, o no hay contenedores' } else { $d | ForEach-Object { Ok $_ } }
    Paso 'Direccion publica (mesh.ledkid.com)'
    $mp = Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('config-mesh.yml') }
    if ($mp) { Ok 'ABIERTA, el tunel mesh esta corriendo' } else { Ok 'cerrada' }
    Paso 'Memoria'
    Ok ("libres {0} MB" -f [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024))
}

switch ($Accion) {
    'estado'         { Mostrar-Estado }
    'backend'        { Iniciar-Backend }
    'frontend'       { Iniciar-Frontend }
    'parar-backend'  { Parar 'backend' }
    'parar-frontend' { Parar 'frontend' }
    'publico'        { & (Join-Path $raiz 'mesh-publico.ps1') -Accion encender; exit $LASTEXITCODE }
    'despublicar'    { & (Join-Path $raiz 'mesh-publico.ps1') -Accion apagar; exit $LASTEXITCODE }
    'todo' {
        Paso 'Bases de datos, arrancar.ps1'
        & (Join-Path $raiz 'arrancar.ps1')
        if ($LASTEXITCODE -ne 0) { Mal "arrancar.ps1 fallo, codigo $LASTEXITCODE"; exit 1 }
        Iniciar-Backend
        Iniciar-Frontend
        # Si el tunel 'mesh' esta configurado (mesh-publico.ps1), tambien se abre la direccion
        # publica. Un fallo aqui no tumba lo demas: la tienda ya quedo arriba en local.
        if (Test-Path (Join-Path $env:USERPROFILE '.cloudflaredconfig-mesh.yml')) {
            Paso 'Direccion publica, mesh.ledkid.com'
            & (Join-Path $raiz 'mesh-publico.ps1') -Accion encender
            if ($LASTEXITCODE -ne 0) { Mal 'No se pudo abrir la direccion publica; la tienda sigue en local.' }
        }
        Paso 'Todo arriba'
        Ok 'Tienda en http://localhost:5173'
    }
}
exit 0
