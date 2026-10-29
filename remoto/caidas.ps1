# remoto/caidas.ps1 -- apagar y prender una base para el backend, en vivo, sin
# tocar la maquina que la tiene. Sirve igual con las bases en la PC de Jose
# David (modo remoto) que con el Docker de aqui.
#
#   .\remoto\caidas.ps1 -Accion levantar             interruptor + backend apuntado a el
#   .\remoto\caidas.ps1 -Accion apagar   -Base redis como un docker stop
#   .\remoto\caidas.ps1 -Accion congelar -Base mongo como la red cortada: no contesta
#   .\remoto\caidas.ps1 -Accion prender  -Base redis vuelve
#   .\remoto\caidas.ps1 -Accion estado
#   .\remoto\caidas.ps1 -Accion quitar               backend normal otra vez
#
# -Base puede ser postgres, mongo, redis, neo4j, clickhouse, elastic o todas.
#
# Como funciona: remoto/interruptor.cjs reenvia un puerto de aqui a cada base
# (los de siempre mas 10000) y el backend se arranca con DB_HOST, MONGO_PORT,
# etc. apuntando a esos puertos. dotenv no pisa variables que ya estan puestas,
# asi que backend/.env no se toca. Apagar una base es dejar de reenviar su
# puerto: para el backend es exactamente una base caida.
#
# Todo queda oculto y con registro en %TEMP%\mesh-logs (interruptor.log,
# backend.out.log y backend.err.log). El backend es el compilado (backend\dist):
# si cambiaste codigo, compila antes (npm run build en backend).
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('levantar', 'apagar', 'congelar', 'prender', 'estado', 'quitar')]
    [string]$Accion,
    [ValidateSet('postgres', 'mongo', 'redis', 'neo4j', 'clickhouse', 'elastic', 'todas')]
    [string]$Base = ''
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $env:TEMP 'mesh-logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$control = 'http://127.0.0.1:5198'

$nombres = @{
    postgres = 'PostgreSQL'; mongo = 'MongoDB'; redis = 'Redis'
    neo4j = 'Neo4j'; clickhouse = 'ClickHouse'; elastic = 'Elasticsearch'; todas = 'todas las bases'
}

function Leer-Env([string]$clave) {
    $linea = Get-Content (Join-Path $raiz 'backend\.env') | Where-Object { $_ -match "^$clave=" } | Select-Object -First 1
    if (-not $linea) { return $null }
    return ($linea -split '=', 2)[1].Trim().Trim('"')
}

function Puerto-Abierto([int]$puerto) {
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync('127.0.0.1', $puerto).Wait(700) -and $c.Connected } catch { return $false } finally { $c.Close() }
}

function Lanzar-Oculto([string]$linea, [string]$carpeta) {
    # Win32_Process y no Start-Process: un proceso de Start-Process muere al
    # cerrarse la consola que lo lanzo (medido con el panel y con Claude Code).
    $si = New-CimInstance -CimClass (Get-CimClass Win32_ProcessStartup) -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    $r = Invoke-CimMethod Win32_Process -MethodName Create -Arguments @{ CommandLine = $linea; CurrentDirectory = $carpeta; ProcessStartupInformation = $si }
    if ($r.ReturnValue -ne 0) { throw "No se pudo lanzar: $linea" }
}

function Interruptor-Vivo {
    try { Invoke-RestMethod "$control/estado" -TimeoutSec 3 | Out-Null; return $true } catch { return $false }
}

function Parar-Backend {
    Get-CimInstance Win32_Process | Where-Object {
        ($_.Name -eq 'node.exe' -and $_.CommandLine -match 'backend\\dist\\main\.js') -or
        ($_.Name -eq 'cmd.exe' -and $_.CommandLine -match 'backend\\dist\\main\.js')
    } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
    for ($i = 0; $i -lt 30 -and (Puerto-Abierto 3000); $i++) { Start-Sleep -Milliseconds 500 }
}

function Iniciar-Backend([hashtable]$variables) {
    Parar-Backend
    Remove-Item (Join-Path $logs 'backend.out.log'), (Join-Path $logs 'backend.err.log') -ErrorAction SilentlyContinue
    $prefijo = ''
    if ($variables) {
        # Win32_Process no hereda el ambiente de esta consola: las variables van
        # dentro del cmd.
        foreach ($k in $variables.Keys) { $prefijo += "set $k=$($variables[$k])&& " }
    }
    $main = Join-Path $raiz 'backend\dist\main.js'
    $linea = "cmd.exe /c $prefijo" + "node --enable-source-maps `"$main`" > `"$logs\backend.out.log`" 2> `"$logs\backend.err.log`""
    Lanzar-Oculto $linea (Join-Path $raiz 'backend')
    # 300 s y no 180: con las bases en la PC de Jose David el backend tardo 200 s
    # en abrir el puerto (2026-10-28).
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep 2
        if (Puerto-Abierto 3000) { return $true }
    }
    return $false
}

function Mostrar-Estado {
    $e = Invoke-RestMethod "$control/estado" -TimeoutSec 5
    Write-Host "Bases en $($e.destino), vistas por el backend:"
    foreach ($p in $e.bases.PSObject.Properties) {
        Write-Host ("  {0,-14} {1}" -f $nombres[$p.Name], $p.Value)
    }
}

switch ($Accion) {
    'levantar' {
        if (-not (Interruptor-Vivo)) {
            $destino = Leer-Env 'DB_HOST'
            if (-not $destino -or $destino -eq 'localhost') { $destino = '127.0.0.1' }
            $script = Join-Path $raiz 'remoto\interruptor.cjs'
            Lanzar-Oculto "cmd.exe /c node `"$script`" $destino > `"$logs\interruptor.log`" 2>&1" $raiz
            for ($i = 0; $i -lt 20 -and -not (Interruptor-Vivo); $i++) { Start-Sleep -Milliseconds 500 }
            if (-not (Interruptor-Vivo)) { Write-Host "El interruptor no arranco. Mira $logs\interruptor.log"; exit 1 }
            Write-Host "Interruptor arriba, hacia $destino"
        } else {
            Write-Host 'El interruptor ya estaba arriba'
        }
        $ambiente = Invoke-RestMethod "$control/ambiente" -TimeoutSec 5
        $variables = @{}
        foreach ($p in $ambiente.PSObject.Properties) { $variables[$p.Name] = $p.Value }
        Write-Host 'Reiniciando el backend apuntado al interruptor...'
        if (-not (Iniciar-Backend $variables)) { Write-Host "El backend no contesto en el 3000. Mira $logs\backend.err.log"; exit 1 }
        Write-Host 'Backend arriba en el 3000.'
        Mostrar-Estado
    }
    { $_ -in 'apagar', 'congelar', 'prender' } {
        if (-not $Base) { Write-Host 'Falta -Base (postgres, mongo, redis, neo4j, clickhouse, elastic o todas)'; exit 2 }
        if (-not (Interruptor-Vivo)) { Write-Host 'El interruptor no esta arriba: corre primero -Accion levantar'; exit 1 }
        $modo = @{ apagar = 'apagada'; congelar = 'congelada'; prender = 'arriba' }[$Accion]
        Invoke-RestMethod -Method Post "$control/$Base/$modo" -TimeoutSec 10 | Out-Null
        Write-Host "$($nombres[$Base]): $modo"
        Mostrar-Estado
    }
    'estado' {
        if (-not (Interruptor-Vivo)) { Write-Host 'El interruptor no esta arriba: el backend habla directo con las bases.'; exit 0 }
        Mostrar-Estado
    }
    'quitar' {
        Write-Host 'Backend directo a las bases otra vez...'
        if (-not (Iniciar-Backend $null)) { Write-Host "El backend no contesto en el 3000. Mira $logs\backend.err.log"; exit 1 }
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'interruptor\.cjs' } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
        Write-Host 'Interruptor quitado. Backend arriba en el 3000.'
    }
}
