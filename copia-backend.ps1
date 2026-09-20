# copia-backend.ps1
# Lo usan demo-fraude-pais.ps1 y tunel-celular.ps1 (con ". .\copia-backend.ps1").
# Arma una COPIA de backend/ fuera del repo, en %TEMP%\mesh-demo\backend, con una
# sola linea cambiada en src/main.ts:
#
#   new FastifyAdapter({ trustProxy: 'loopback' })
#
# Es la linea que se le pide a Jose David (docs/BACKEND-PENDIENTE.md). backend/
# no se toca: la copia deja probar hoy lo que el backend hara cuando la ponga.
#
# 'loopback' y no true: con true Fastify se queda con la IP de mas a la izquierda
# de X-Forwarded-For, que la escribe quien quiera; Cloudflare no la borra, le
# agrega la real al final. Con 'loopback' solo se cree lo que llega de esta
# maquina (el tunel y el proxy de vite), y la cadena se corta en la primera IP
# de fuera.

$MeshDemoTmp   = Join-Path $env:TEMP 'mesh-demo'
$MeshDemoCopia = Join-Path $MeshDemoTmp 'backend'

# Devuelve $true si la copia quedo lista (compilada y con trustProxy).
function Preparar-CopiaBackend([string]$repo) {
    $dist = Join-Path $MeshDemoCopia 'dist\main.js'
    # Se rehace si falta, si backend/ cambio despues de armarla (un pull de Jose
    # David) o si es de antes del 'loopback'; si no, se probaria un backend que
    # ya no es el del repo.
    $reciente = Get-ChildItem (Join-Path $repo 'backend') -Force |
        Where-Object { $_.Name -notin 'node_modules','dist' } |
        ForEach-Object { if ($_.PSIsContainer) { Get-ChildItem $_.FullName -Recurse -File -Force } else { $_ } } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    # Si backend/ ya trae su propio trustProxy, la copia lleva el suyo.
    $delRepo = Select-String -Path (Join-Path $repo 'backend\src\main.ts') -Pattern 'trustProxy' -Quiet
    $vigente = (Test-Path $dist) -and
        ($reciente.LastWriteTime -le (Get-Item $dist).LastWriteTime) -and
        ($delRepo -or (Select-String -Path $dist -Pattern "trustProxy: 'loopback'" -SimpleMatch -Quiet))
    if ($vigente) { return $true }

    # Remove-Item no sigue la junction de node_modules: borra el enlace, no el
    # node_modules del repo (medido en PS 5.1).
    Remove-Item $MeshDemoCopia -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $MeshDemoCopia | Out-Null
    Get-ChildItem (Join-Path $repo 'backend') -Force |
        Where-Object { $_.Name -notin 'node_modules','dist' } |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $MeshDemoCopia $_.Name) -Recurse -Force }
    New-Item -ItemType Junction -Path (Join-Path $MeshDemoCopia 'node_modules') `
        -Target (Join-Path $repo 'backend\node_modules') | Out-Null
    # El backend busca el script de Lua en ../redis
    Copy-Item (Join-Path $repo 'redis') (Join-Path $MeshDemoTmp 'redis') -Recurse -Force

    $main = Join-Path $MeshDemoCopia 'src\main.ts'
    $texto = (Get-Content $main -Raw).Replace('new FastifyAdapter(),', "new FastifyAdapter({ trustProxy: 'loopback' }),")
    # Si Jose David cambio esa linea sin poner trustProxy, el Replace no encuentra
    # nada y la copia saldria SIN el, con todo en 127.0.0.1 y sin un error. Se
    # corta aqui.
    if ($texto -notmatch 'trustProxy') {
        Write-Host "   backend/src/main.ts ya no tiene 'new FastifyAdapter(),' y no se donde poner trustProxy." -ForegroundColor Red
        return $false
    }
    Set-Content $main $texto -Encoding utf8

    # nest build busca tsconfig.json en el directorio actual: hay que estar dentro de la copia
    Push-Location $MeshDemoCopia
    & (Join-Path $MeshDemoCopia 'node_modules\.bin\nest.cmd') build *> (Join-Path $MeshDemoTmp 'build.log')
    Pop-Location
    return (Test-Path $dist)
}

# Para el backend normal (3000) y levanta la copia en 3100. Los dos a la vez
# duplicarian los @Interval (los workers de Elastic, del grafo, la venta
# relampago). Devuelve el proceso, o $null si no contesto.
function Arrancar-CopiaBackend {
    $lst = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
    if ($lst) { Stop-Process -Id $lst.OwningProcess -Force -ErrorAction SilentlyContinue }
    $lst = Get-NetTCPConnection -LocalPort 3100 -State Listen -ErrorAction SilentlyContinue
    if ($lst) { Stop-Process -Id $lst.OwningProcess -Force -ErrorAction SilentlyContinue }
    $env:PORT = '3100'
    $node = (Get-Command node.exe).Source
    $p = Start-Process $node -ArgumentList 'dist\main.js' -WorkingDirectory $MeshDemoCopia -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $MeshDemoTmp 'backend.log') `
        -RedirectStandardError (Join-Path $MeshDemoTmp 'backend.err') -PassThru
    Remove-Item Env:PORT
    for ($i=0; $i -lt 40; $i++) {
        Start-Sleep 3
        try { if ((Invoke-WebRequest 'http://localhost:3100/productos?limite=1' -UseBasicParsing -TimeoutSec 8).StatusCode -eq 200) { return $p } } catch {}
    }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    return $null
}

# --- La red de la U y el tunel -------------------------------------------------
# cloudflared sale SIEMPRE por el puerto 7844, y el firewall de la U lo bloquea
# por puerto (medido el 2026-08-06 y el 2026-08-25, el sintoma es "el tunel no
# levanto" o el error 1033). La salida es WARP, el cliente de Cloudflare, en modo
# MASQUE: mete ese trafico dentro de HTTPS. Es la misma solucion de LEDKID, ahi la
# hace arrancar-todo-cloudflare.ps1.
#
# Solo se toca WARP si el 7844 esta bloqueado de verdad. En casa, o en una red sin
# ese bloqueo, no se cambia nada. Devuelve $true si el tunel puede salir.

function Probar-Puerto([string]$servidor, [int]$puerto, [int]$segundos = 4) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $t = $c.ConnectAsync($servidor, $puerto)
        $abierto = $t.Wait($segundos * 1000) -and $c.Connected
        $c.Close()
        return $abierto
    } catch { return $false }
}

function Asegurar-SalidaTunel {
    $edge = 'region1.v2.argotunnel.com'
    if (Probar-Puerto $edge 7844) {
        Write-Host "   El puerto 7844 sale libre, no hace falta WARP" -ForegroundColor Green
        return $true
    }
    Write-Host "   El puerto 7844 esta bloqueado (red de la U); se usa WARP" -ForegroundColor Yellow
    if (-not (Get-Command warp-cli -ErrorAction SilentlyContinue)) {
        Write-Host "   No encuentro WARP (warp-cli). Instalalo o conectate a otra red; sin eso el tunel no va a subir." -ForegroundColor Red
        return $false
    }
    $estado = (warp-cli status 2>&1) -join ' '
    if ($estado -match 'Connected') {
        # Si ya esta conectado NO se desconecta: el tunel de LEDKID cuelga de el, y
        # LEDKID lo deja siempre en MASQUE. Solo se espera y se vuelve a probar.
        Write-Host "   WARP ya estaba conectado, no se toca" -ForegroundColor Yellow
    } else {
        # MASQUE en mayusculas: 'masque' lo rechaza.
        warp-cli tunnel protocol set MASQUE *> $null
        warp-cli connect *> $null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep 2
            if (((warp-cli status 2>&1) -join ' ') -match 'Connected') { break }
        }
    }
    # Se vuelve a probar el puerto: contar conexiones de cloudflared no sirve, sale en
    # QUIC (UDP) y ese contador solo mira TCP.
    for ($i = 0; $i -lt 10; $i++) {
        if (Probar-Puerto $edge 7844 3) {
            Write-Host "   WARP conectado, el 7844 ya sale" -ForegroundColor Green
            return $true
        }
        Start-Sleep 2
    }
    Write-Host "   WARP quedo conectado pero el 7844 sigue cerrado; el tunel puede fallar." -ForegroundColor Red
    return $false
}

# Vuelve a levantar el backend normal en 3000, sin ventana, y espera a que conteste.
function Arrancar-BackendNormal([string]$repo) {
    if (Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue) { return $true }
    $npm = (Get-Command npm.cmd).Source
    Start-Process $npm -ArgumentList 'run','start' -WorkingDirectory (Join-Path $repo 'backend') -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $MeshDemoTmp 'backend-normal.log') `
        -RedirectStandardError (Join-Path $MeshDemoTmp 'backend-normal.err') | Out-Null
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep 3
        try { if ((Invoke-WebRequest 'http://localhost:3000/productos?limite=1' -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200) { return $true } } catch {}
    }
    return $false
}

# Tunel rapido de Cloudflare a $destino. Devuelve @{ Proceso; Url } o $null.
# El --config vacio es para no heredar el ~/.cloudflared/config.yml de LEDKID,
# que impone su ingress y deja el tunel rapido en 404.
function Abrir-Tunel([string]$destino, [string]$prueba, [string]$nombre) {
    $cf = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
    New-Item -ItemType Directory -Force $MeshDemoTmp | Out-Null
    $cfg = Join-Path $MeshDemoTmp 'cf-vacio.yml'
    Set-Content $cfg "# vacio" -Encoding ascii
    $errT = Join-Path $MeshDemoTmp "$nombre.err"
    Set-Content $errT ''
    $p = Start-Process $cf -ArgumentList 'tunnel','--no-autoupdate','--config',"$cfg",'--url',$destino `
        -WindowStyle Hidden -RedirectStandardOutput (Join-Path $MeshDemoTmp "$nombre.log") -RedirectStandardError $errT -PassThru
    $url = $null
    for ($i=0; $i -lt 30 -and -not $url; $i++) {
        Start-Sleep 2
        $m = Select-String -Path $errT -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) { $url = $m.Matches[0].Value }
    }
    if ($url) {
        # El tunel tarda unos segundos en contestar despues de dar la direccion
        for ($i=0; $i -lt 12; $i++) {
            Start-Sleep 5
            try { if ((Invoke-WebRequest "$url$prueba" -UseBasicParsing -TimeoutSec 15).StatusCode -eq 200) { return @{ Proceso = $p; Url = $url } } } catch {}
        }
    }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    return $null
}
