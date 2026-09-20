# demo-entrar-otro-pais.ps1
# Abre una ventana de Chrome que sale a internet por OTRO PAIS y entra a la tienda
# real, para que inicies sesion TU MISMO desde alla. Es la otra mitad de
# demo-fraude-pais.ps1: aquella manda intentos con curl y confirma en las bases, esta
# te deja usar el frontend de verdad.
#
#   .\demo-entrar-otro-pais.ps1 -Pais sg     abre la ventana (o cambia de pais)
#   .\demo-entrar-otro-pais.ps1 -Estado      desde donde sales y que sigue abierto
#   .\demo-entrar-otro-pais.ps1 -Cerrar      cierra la ventana, el tunel y Tor
#
# Como funciona
#   1. Tor en un contenedor de Docker con salida en el pais (mesh-tor-demo).
#   2. Un tunel de Cloudflare a la tienda (el 5173). El frontend le pasa /api al
#      backend con la IP de quien llego, y el backend la lee con trustProxy.
#   3. Chrome con un perfil aparte y limpio, usando ese Tor como proxy SOCKS5. Para
#      la tienda, esa ventana esta en otro pais; el resto de tus ventanas no cambian.
#
# Para la alerta de VIAJE IMPOSIBLE hacen falta DOS logins exitosos de la misma
# cuenta, desde paises distintos y con poco tiempo entre uno y otro (mas de 800 km/h
# implicitos). Un login desde tu casa no cuenta: 127.0.0.1 no tiene pais. Entonces:
#   .\demo-entrar-otro-pais.ps1 -Pais sg    y entra con la cuenta
#   .\demo-entrar-otro-pais.ps1 -Pais de    (cierra la ventana anterior) y entra con la MISMA
# Las alertas salen en /panel?s=fraude, con la cuenta del admin, en tu navegador normal.
#
# Necesita la tienda (5173) y el backend (3000) arriba. Para ver que es real:
#   docker ps --filter name=mesh-tor-demo
#   docker exec mesh-tor-demo curl -s --socks5-hostname 127.0.0.1:9050 https://api.ipify.org
#
# Variable de prueba: MESH_CHROME_EXTRA agrega argumentos a Chrome (se uso para
# abrirlo sin ventana al probar este script).

param(
    [ValidateSet('sg','de','jp','us','nl','fr','gb','ca')]
    [string]$Pais = 'sg',
    [switch]$Cerrar,
    [switch]$Estado,
    [switch]$SinNavegador
)

# Nada de ErrorActionPreference = 'Stop': con docker, un stderr cortaria el script.
$repo = $PSScriptRoot
. (Join-Path $repo 'copia-backend.ps1')
. (Join-Path $repo 'tor-demo.ps1')
. (Join-Path $repo 'pais-enlace.ps1')
$inicio = Get-Date
function Paso($t) { Write-Host ("`n>> $t  [+{0} s]" -f [int]((Get-Date) - $inicio).TotalSeconds) -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

$sesion = Join-Path $MeshDemoTmp 'entrar-pais.json'
$marcaPerfil = 'mesh-demo\chrome-pais'   # todos los perfiles de estas ventanas cuelgan de aqui

function Leer-Sesion {
    if (-not (Test-Path $sesion)) { return $null }
    try { return (Get-Content $sesion -Raw | ConvertFrom-Json) } catch { return $null }
}

# Los chrome.exe de ESTAS ventanas, y solo ellos: se reconocen por su carpeta de perfil.
function Chrome-DeEstasVentanas {
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($marcaPerfil) }
}
function Cerrar-Ventanas {
    foreach ($p in @(Chrome-DeEstasVentanas)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 1
    Get-ChildItem $MeshDemoTmp -Directory -Filter 'chrome-pais-*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

function Tunel-Responde([string]$url) {
    try { return ((Invoke-WebRequest "$url/api/productos?limite=1" -UseBasicParsing -TimeoutSec 20).StatusCode -eq 200) } catch { return $false }
}

# El pais de una IP, preguntado desde el PC (ipinfo contesta 403 a los nodos de Tor)
function Pais-De-Ip([string]$ip) {
    try { return (Invoke-RestMethod "https://ipinfo.io/$ip/country" -TimeoutSec 10).Trim() } catch {
        try { return (Invoke-RestMethod "http://ip-api.com/line/${ip}?fields=countryCode" -TimeoutSec 10).Trim() } catch { return '' } }
}

# --- -Cerrar -----------------------------------------------------------------
if ($Cerrar) {
    Paso "Cerrando la ventana de otro pais"
    $s = Leer-Sesion
    Cerrar-Ventanas
    Ok "Ventanas de Chrome cerradas"
    if (@(Proxy-DePais).Count -gt 0) { Cerrar-EnlacePais; Ok "Link por pais cerrado" }
    if ($s -and $s.tunelPid) {
        $p = Get-Process -Id $s.tunelPid -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'cloudflared') { Stop-Process -Id $s.tunelPid -Force -ErrorAction SilentlyContinue; Ok "Tunel cerrado" }
    }
    docker rm -f mesh-tor-demo *> $null
    Ok "Tor quitado (mesh-tor-demo)"
    Remove-Item $sesion -Force -ErrorAction SilentlyContinue
    Write-Host "`n   Listo. Tus ventanas normales no se tocaron."
    exit 0
}

# --- -Estado -----------------------------------------------------------------
if ($Estado) {
    $s = Leer-Sesion
    Paso "Tor en Docker"
    $fila = docker ps --filter 'name=^mesh-tor-demo$' --format '{{.Names}}  {{.Status}}  {{.Ports}}'
    if ($fila) {
        Ok $fila
        $ip = (docker exec mesh-tor-demo curl -s -m 30 --socks5-hostname 127.0.0.1:9050 https://api.ipify.org 2>$null)
        if ($ip -match '^[0-9a-fA-F:.]+$') { Ok "Sale a internet con la IP $ip, del pais $(Pais-De-Ip $ip)" } else { Mal "No pude preguntar la IP de salida" }
    } else {
        Mal "No hay contenedor mesh-tor-demo. Abre una ventana con: .\demo-entrar-otro-pais.ps1 -Pais sg"
    }
    Paso "La ventana y el tunel"
    if ($s) {
        Ok "Sesion abierta desde $($s.pais.ToUpper()) desde las $($s.desde)"
        if ($s.enlace) {
            $vivo = try { (Invoke-WebRequest "$($s.enlace)/api/productos?limite=1" -UseBasicParsing -TimeoutSec 30).StatusCode -eq 200 } catch { $false }
            if ($vivo) { Ok "Link por pais arriba: $($s.enlace)/entrar" } else { Mal "El link por pais ya no contesta: $($s.enlace)" }
        }
        $abierta = @(Chrome-DeEstasVentanas).Count -gt 0
        if ($abierta) { Ok "La ventana de Chrome sigue abierta" } else { Mal "La ventana de Chrome ya no esta abierta" }
        if (Tunel-Responde $s.url) { Ok "Tunel arriba: $($s.url)" } else { Mal "El tunel no contesta" }
    } else {
        Write-Host "   No hay ninguna sesion abierta."
    }
    Write-Host "`n   Para verlo tu mismo en la terminal:"
    Write-Host "     docker ps --filter name=mesh-tor-demo"
    Write-Host "     docker exec mesh-tor-demo curl -s --socks5-hostname 127.0.0.1:9050 https://api.ipify.org"
    exit 0
}

# --- abrir -------------------------------------------------------------------
Paso "Revisando Docker, el backend y la tienda"
docker ps *> $null
if ($LASTEXITCODE -ne 0) { Mal "Docker no responde. Abre Docker Desktop y espera a que arranque."; exit 1 }
$backendOk = try { (Invoke-WebRequest 'http://localhost:3000/productos?limite=1' -UseBasicParsing -TimeoutSec 20).StatusCode -eq 200 } catch { $false }
if (-not $backendOk) { Mal "El backend no contesta en el 3000. Levantalo primero (Reiniciar el backend)."; exit 1 }
$tiendaOk = try { (Invoke-WebRequest 'http://localhost:5173/api/productos?limite=1' -UseBasicParsing -TimeoutSec 20).StatusCode -eq 200 } catch { $false }
if (-not $tiendaOk) { Mal "La tienda no contesta en el 5173. Levantala primero (Reiniciar el frontend)."; exit 1 }
Ok "Backend y tienda arriba"

Paso "Comprobando que el tunel pueda salir"
if (-not (Asegurar-SalidaTunel)) { Write-Host "   Sigo, pero es probable que el tunel no levante." -ForegroundColor Yellow }

Paso "Tor con salida en '$Pais'"
$previa = Leer-Sesion
if (-not (Preparar-ImagenTor)) { Mal "No se pudo construir la imagen de Tor. Mira $MeshDemoTmp\tor-build.log"; exit 1 }
if (-not (Levantar-Tor $Pais)) { Mal "Tor no arranco a tiempo."; docker rm -f mesh-tor-demo *> $null; exit 1 }
$salida = Buscar-SalidaTor $Pais
if (-not $salida) { Mal "No consegui una salida en '$Pais'. Prueba otro pais."; docker rm -f mesh-tor-demo *> $null; exit 1 }
Ok "Tor sale por la IP $($salida.Ip) ($($Pais.ToUpper()))"

# Lo que el navegador va a usar es el puerto del PC, no el de dentro del contenedor:
# se comprueba EL CAMINO REAL, para no descubrir en la ventana que no sale por Tor.
$ipPc = (curl.exe -s -m 60 --socks5-hostname "127.0.0.1:$PuertoSocksTor" https://api.ipify.org 2>$null)
if ($ipPc -notmatch '^[0-9a-fA-F:.]+$') {
    Mal "El puerto $PuertoSocksTor del PC no deja salir por Tor. Mira: docker logs mesh-tor-demo"
    docker rm -f mesh-tor-demo *> $null; exit 1
}
$paisPc = Pais-De-Ip $ipPc
if ($paisPc -ne $Pais.ToUpper()) { Write-Host "   OJO: el proxy del PC salio por $ipPc ($paisPc), no por $($Pais.ToUpper()). Tor cambia de circuito; si pasa en la ventana, cierrala y vuelve a abrirla." -ForegroundColor Yellow }
else { Ok "El proxy del PC sale por $ipPc ($paisPc)" }

# El link con el nombre del pais (mesh-singapur.ledkid.com), para abrirlo desde CUALQUIER navegador.
# Va antes del tunel: abrirlo deja abierta la direccion publica, y el paso siguiente la reutiliza.
Paso "El link de $($TituloPais[$Pais]), para abrir desde cualquier navegador"
$enlace = Abrir-EnlacePais $Pais
if ($enlace) { Ok "Listo: $enlace" } else { Write-Host "   Sin link por pais; queda la ventana de Chrome." -ForegroundColor Yellow }

Paso "Tunel a la tienda"
$url = $null; $tunelPid = $null
# Si la direccion publica de Mesh esta abierta (mesh-publico.ps1) se usa esa: es un https FIJO,
# no hace falta abrir otro tunel (ahorra unos 30 s) y el link es el mismo de siempre. Ese
# tunel NO es de este script: no se guarda su pid, asi que -Cerrar nunca lo apaga.
$direccionPublica = 'https://mesh.ledkid.com'
$meshAbierto = @(Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains('config-mesh.yml') }).Count -gt 0
if ($meshAbierto -and (Tunel-Responde $direccionPublica)) {
    $url = $direccionPublica
    Ok "Se usa la direccion publica fija: $url (no hace falta abrir otro tunel)"
    # Un tunel rapido de una sesion anterior ya sobra
    if ($previa -and $previa.tunelPid) {
        $viejo = Get-Process -Id $previa.tunelPid -ErrorAction SilentlyContinue
        if ($viejo -and $viejo.ProcessName -eq 'cloudflared') { Stop-Process -Id $previa.tunelPid -Force -ErrorAction SilentlyContinue }
    }
} elseif ($previa -and $previa.url -and $previa.tunelPid -and (Get-Process -Id $previa.tunelPid -ErrorAction SilentlyContinue) -and (Tunel-Responde $previa.url)) {
    $url = $previa.url; $tunelPid = $previa.tunelPid
    Ok "Se reutiliza el tunel de antes: $url"
} else {
    $tun = Abrir-Tunel 'http://localhost:5173' '/api/productos?limite=1' 'tunel-pais'
    if (-not $tun) { Mal "El tunel no levanto. Mira $MeshDemoTmp\tunel-pais.err"; docker rm -f mesh-tor-demo *> $null; exit 1 }
    $url = $tun.Url; $tunelPid = $tun.Proceso.Id
    Ok "Tunel arriba: $url"
}

if (-not $SinNavegador) {
    Paso "Abriendo Chrome que sale por $($Pais.ToUpper())"
    $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $chrome) { Mal "No encuentro Chrome. Abre $url/entrar con un navegador configurado con el proxy SOCKS5 127.0.0.1:$PuertoSocksTor."; exit 1 }
    # Se cierra la ventana anterior y se parte de un perfil limpio: sin sesion, y sin
    # que quede a medias la del pais de antes.
    Cerrar-Ventanas
    $perfil = Join-Path $MeshDemoTmp "chrome-pais-$Pais"
    # Chrome manda los nombres de host al proxy SOCKS5 (no los resuelve el PC), asi que
    # el DNS tambien sale por Tor. Las comillas van a mano: Start-Process no las pone.
    $argumentos = @("--user-data-dir=`"$perfil`"", "--proxy-server=socks5://127.0.0.1:$PuertoSocksTor",
                    '--no-first-run', '--no-default-browser-check', '--new-window', '--window-size=1180,860', "$url/entrar")
    if ($env:MESH_CHROME_EXTRA) { $argumentos += ($env:MESH_CHROME_EXTRA -split ' ' | Where-Object { $_ }) }
    Start-Process -FilePath $chrome -ArgumentList $argumentos | Out-Null
    Ok "Ventana abierta"
}

New-Item -ItemType Directory -Force $MeshDemoTmp | Out-Null
@{ pais = $Pais; url = $url; tunelPid = $tunelPid; ip = $salida.Ip; enlace = $enlace; desde = (Get-Date -Format 's') } |
    ConvertTo-Json | Set-Content $sesion -Encoding ascii

Write-Host "`n=============================================================="
Write-Host " LISTO. Esa ventana de Chrome esta en $($Pais.ToUpper()) para la tienda." -ForegroundColor Green
Write-Host " Inicia sesion en ella con tu cuenta (por ejemplo desarrollador1@mesh.com)."
Write-Host ""
if ($enlace) {
    Write-Host " Mesh desde $($TituloPais[$Pais]), abre este link en CUALQUIER navegador (tambien el celular):" -ForegroundColor Green
    Write-Host "   $enlace/entrar" -ForegroundColor Yellow
    Write-Host " Quien lo abra aparece en $($TituloPais[$Pais]) para la tienda, sin instalar nada. Va un poco mas lento: sale por Tor."
} else {
    Write-Host " La tienda, en la ventana de Chrome que se abrio:" -ForegroundColor Green
    Write-Host "   $url/entrar" -ForegroundColor Yellow
    Write-Host " OJO: solo esa ventana sale por $($Pais.ToUpper()). Si abres el link en tu navegador de siempre, la tienda te ve desde tu pais."
}
Write-Host ""
Write-Host " Para el viaje imposible: entra con la MISMA cuenta desde otro pais."
Write-Host "   .\demo-entrar-otro-pais.ps1 -Pais de     (cambia de pais y abre otra ventana)" -ForegroundColor Yellow
Write-Host " Las alertas: http://localhost:5173/panel?s=fraude  (admin@mesh.com / Admin123)"
Write-Host " Ver que es real:  .\demo-entrar-otro-pais.ps1 -Estado" -ForegroundColor Yellow
Write-Host " Cerrar todo:      .\demo-entrar-otro-pais.ps1 -Cerrar" -ForegroundColor Yellow
Write-Host "=============================================================="
