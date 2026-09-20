# demo-entrar-otro-pais.ps1
# Entrar a Mesh DESDE OTRO PAIS, con el frontend de verdad, y elegir cuales paises tener abiertos
# a la vez. Es la otra mitad de demo-fraude-pais.ps1: aquella manda intentos con curl y confirma
# en las bases, esta te da un LINK por pais para iniciar sesion tu mismo.
#
#   .\demo-entrar-otro-pais.ps1 -Pais sg              agrega Singapur, con su link y una ventana de Chrome
#   .\demo-entrar-otro-pais.ps1 -Paises sg,de,jp      abre EXACTAMENTE esos, a la vez (solo links)
#   .\demo-entrar-otro-pais.ps1 -Paises todos         abre los ocho
#   .\demo-entrar-otro-pais.ps1 -Estado               que paises estan abiertos y desde donde salen
#   .\demo-entrar-otro-pais.ps1 -Cerrar               CIERRA TODO: acaba el tour
#
# Cada pais es un Tor de Docker (mesh-tor-sg, mesh-tor-de...) y un link con su nombre
# (https://mesh-singapur.ledkid.com/entrar), que abres en CUALQUIER navegador, tambien en el
# celular. Quien lo abre aparece para el backend en ese pais, sin instalar nada. Un proxy reenvia
# cada link a https://mesh.ledkid.com saliendo por el Tor de su pais (panel-comandos/pais-proxy.mjs).
# Con -Pais, ademas, se abre una ventana de Chrome puesta en ese pais.
#
# Ojo con la memoria: cada pais es un Tor de casi 100 MB. Con los ocho a la vez (casi 100 MB cada uno) la maquina,
# que anda justa, puede ir lenta; para ensenar bastan dos o tres.
#
# Para la alerta de VIAJE IMPOSIBLE hacen falta DOS logins exitosos de la misma cuenta desde
# paises distintos y con poco tiempo en medio (mas de 800 km/h implicitos): abre dos paises, y
# entra con la misma cuenta por el link de uno y luego por el del otro. Un login desde tu casa no
# cuenta: 127.0.0.1 no tiene pais. Las alertas salen en /panel?s=fraude, con la cuenta del admin.
#
# Necesita la tienda (5173) y el backend (3000) arriba, y la direccion publica de Mesh abierta
# (si esta cerrada se abre sola). Para ver que es real:
#   docker ps --filter name=mesh-tor-
#   docker exec mesh-tor-sg curl -s --socks5-hostname 127.0.0.1:9050 https://api.ipify.org
#
# Variable de prueba: MESH_CHROME_EXTRA agrega argumentos a Chrome (se uso para abrirlo sin
# ventana al probar este script).

param(
    [ValidateSet('sg','de','jp','us','nl','fr','gb','ca')]
    [string]$Pais = 'sg',
    [string]$Paises = '',
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

$marcaPerfil = 'mesh-demo\chrome-pais'   # todos los perfiles de estas ventanas cuelgan de aqui

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

function Enlace-Responde([string]$url) {
    try { return ((Invoke-WebRequest "$url/api/productos?limite=1" -UseBasicParsing -TimeoutSec 30).StatusCode -eq 200) } catch { return $false }
}

# El pais de una IP, preguntado desde el PC (ipinfo contesta 403 a los nodos de Tor)
function Pais-De-Ip([string]$ip) {
    try { return (Invoke-RestMethod "https://ipinfo.io/$ip/country" -TimeoutSec 10).Trim() } catch {
        try { return (Invoke-RestMethod "http://ip-api.com/line/${ip}?fields=countryCode" -TimeoutSec 10).Trim() } catch { return '' } }
}

# --- -Cerrar: acaba el tour ---------------------------------------------------
if ($Cerrar) {
    Paso "Cerrando todos los paises (acabando el tour)"
    $abiertos = @(Paises-Activos)
    Cerrar-Ventanas
    Ok "Ventanas de Chrome cerradas"
    Cerrar-TodosLosPaises
    Remove-Item (Join-Path $MeshDemoTmp 'entrar-pais.json') -Force -ErrorAction SilentlyContinue
    if ($abiertos.Count -gt 0) { Ok "Paises cerrados: $((($abiertos | ForEach-Object { $TituloPais[$_] }) -join ', '))" } else { Ok "No habia ningun pais abierto" }
    Ok "Links por pais cerrados y Tor quitado (mesh-tor-*)"
    Write-Host "`n   Listo. mesh.ledkid.com, ledkid.com y tus ventanas normales no se tocaron."
    exit 0
}

# --- -Estado -------------------------------------------------------------------
if ($Estado) {
    $abiertos = @(Paises-Activos)
    Paso "Paises abiertos"
    if ($abiertos.Count -eq 0) {
        Write-Host "   Ninguno. Abre uno con: .\demo-entrar-otro-pais.ps1 -Pais sg   (o varios con -Paises sg,de)"
    } else {
        $reg = Leer-Registro
        foreach ($p in ($OrdenPaises | Where-Object { $abiertos -contains $_ })) {
            $n = Nombre-Tor $p
            $fila = docker ps --filter "name=^$n$" --format '{{.Status}}  {{.Ports}}'
            if (-not $fila) { Mal "$($TituloPais[$p]): no hay contenedor $n"; continue }
            $ip = (docker exec $n curl -s -m 30 --socks5-hostname 127.0.0.1:9050 https://api.ipify.org 2>$null)
            $salida = if ($ip -match '^[0-9a-fA-F:.]+$') { "sale por $ip ($(Pais-De-Ip $ip))" } else { 'no pude preguntar la IP de salida' }
            $link = "https://$(Host-DePais $p)"
            $vivo = if (Enlace-Responde $link) { 'contesta' } else { 'NO contesta' }
            Ok "$($TituloPais[$p]): $n $fila"
            Write-Host "       $salida | $link/entrar $vivo"
        }
    }
    Paso "El proxy, la direccion publica y las ventanas"
    if (@(Proxy-DePais).Count -gt 0) { Ok "Proxy de los links arriba" } else { Write-Host "   Proxy de los links apagado." }
    if (Tunel-MeshCorriendo) { Ok "Direccion publica abierta (mesh.ledkid.com)" } else { Write-Host "   Direccion publica cerrada." }
    Ok "Ventanas de Chrome abiertas por este script: $(@(Chrome-DeEstasVentanas).Count -gt 0)"
    Write-Host "`n   Para verlo tu mismo en la terminal:"
    Write-Host "     docker ps --filter name=mesh-tor-"
    Write-Host "     docker exec mesh-tor-sg curl -s --socks5-hostname 127.0.0.1:9050 https://api.ipify.org"
    exit 0
}

# --- abrir (uno o varios) ---------------------------------------------------------
# Que paises: -Paises manda; sin el, es solo -Pais.
$multi = $false
$lista = @($Pais)
if ($Paises.Trim() -ne '') {
    $multi = $true
    if ($Paises.Trim().ToLower() -eq 'todos') { $lista = @($OrdenPaises) }
    else {
        # Coma o espacio: sg,de sin comillas en PowerShell llega como una lista y se junta con espacio
        $lista = @($Paises.ToLower() -split '[,\s]+' | Where-Object { $_ } | Select-Object -Unique)
        $malos = @($lista | Where-Object { $OrdenPaises -notcontains $_ })
        if ($malos.Count -gt 0) { Mal "Pais desconocido: $($malos -join ', '). Los validos: $($OrdenPaises -join ', '), o 'todos'."; exit 1 }
    }
    if ($lista.Count -eq 0) { Mal "No elegiste ningun pais."; exit 1 }
}

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

# Con -Paises se abre EXACTAMENTE esa lista: los que estaban abiertos y no estan en ella se cierran.
# Con -Pais solo se agrega uno, sin tocar los demas.
if ($multi) {
    foreach ($p in @(Paises-Activos)) {
        if ($lista -notcontains $p) { Cerrar-EnlacePais $p; Ok "Se cierra $($TituloPais[$p]), que no estaba en la lista" }
    }
}

Paso "Tor de $($lista.Count) pais(es), a la vez"
if (-not (Preparar-ImagenTor)) { Mal "No se pudo construir la imagen de Tor. Mira $MeshDemoTmp\tor-build.log"; exit 1 }
# Se lanzan todos primero y se espera despues: asi arman sus circuitos en paralelo
$lanzados = @()
foreach ($p in $lista) { if (Lanzar-Tor $p) { $lanzados += $p } else { Mal "No se pudo arrancar el Tor de $($TituloPais[$p])." } }
if ($lanzados.Count -eq 0) { exit 1 }

$abiertos = @()
foreach ($p in $lanzados) {
    $titulo = $TituloPais[$p]
    if (-not (Esperar-Tor $p)) { Mal "El Tor de $titulo no arranco a tiempo."; Quitar-Tor $p; continue }
    $salida = Buscar-SalidaTor $p
    if (-not $salida) { Mal "No consegui una salida en $titulo. Prueba otro pais."; Quitar-Tor $p; continue }
    Ok "$titulo sale por la IP $($salida.Ip) ($($p.ToUpper()))"
    # Lo que el navegador va a usar es el puerto del PC, no el de dentro del contenedor: se comprueba
    # EL CAMINO REAL, para no descubrir en la ventana que no sale por Tor.
    $ipPc = (curl.exe -s -m 60 --socks5-hostname "127.0.0.1:$($PuertosSocksTor[$p])" https://api.ipify.org 2>$null)
    if ($ipPc -notmatch '^[0-9a-fA-F:.]+$') { Mal "El puerto $($PuertosSocksTor[$p]) del PC no deja salir por Tor ($titulo)."; Quitar-Tor $p; continue }
    $paisPc = Pais-De-Ip $ipPc
    if ($paisPc -ne $p.ToUpper()) { Write-Host "   OJO: el proxy del PC salio por $ipPc ($paisPc), no por $($p.ToUpper()). Tor cambia de circuito." -ForegroundColor Yellow }
    $abiertos += [pscustomobject]@{ Pais = $p; Ip = $salida.Ip; Usuario = $salida.Usuario }
}
if ($abiertos.Count -eq 0) { Mal "No quedo ningun pais abierto."; exit 1 }

Paso "Los links, para abrir desde cualquier navegador"
$links = @{}
foreach ($a in $abiertos) {
    $enlace = Abrir-EnlacePais $a.Pais $a.Ip $a.Usuario
    if ($enlace) { $links[$a.Pais] = $enlace; Ok "$($TituloPais[$a.Pais]): $enlace" }
    else { Write-Host "   $($TituloPais[$a.Pais]): sin link por pais." -ForegroundColor Yellow }
}

# La ventana de Chrome: solo cuando se pide UN pais (con varios no habria cual abrir)
if (-not $multi -and -not $SinNavegador) {
    Paso "Abriendo Chrome que sale por $($TituloPais[$Pais])"
    if (-not (Asegurar-DireccionPublica)) { Mal "La direccion publica de Mesh no abrio; Chrome no tiene a donde ir."; exit 1 }
    $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $chrome) { Mal "No encuentro Chrome. Abre el link con un navegador configurado con el proxy SOCKS5 127.0.0.1:$($PuertosSocksTor[$Pais])."; exit 1 }
    # Se cierra la ventana anterior y se parte de un perfil limpio: sin sesion
    Cerrar-Ventanas
    $perfil = Join-Path $MeshDemoTmp "chrome-pais-$Pais"
    # Chrome manda los nombres de host al proxy SOCKS5 (no los resuelve el PC), asi que el DNS
    # tambien sale por Tor. Las comillas van a mano: Start-Process no las pone.
    $argumentos = @("--user-data-dir=`"$perfil`"", "--proxy-server=socks5://127.0.0.1:$($PuertosSocksTor[$Pais])",
                    '--no-first-run', '--no-default-browser-check', '--new-window', '--window-size=1180,860', 'https://mesh.ledkid.com/entrar')
    if ($env:MESH_CHROME_EXTRA) { $argumentos += ($env:MESH_CHROME_EXTRA -split ' ' | Where-Object { $_ }) }
    Start-Process -FilePath $chrome -ArgumentList $argumentos | Out-Null
    Ok "Ventana abierta"
}

Write-Host "`n=============================================================="
Write-Host " LISTO. Paises abiertos: $($abiertos.Count)" -ForegroundColor Green
Write-Host " Abre el link de cada uno en CUALQUIER navegador (tambien el celular). Quien lo abra"
Write-Host " aparece en ese pais para la tienda, sin instalar nada. Va un poco mas lento: sale por Tor."
Write-Host ""
foreach ($a in $abiertos) {
    $t = "$($TituloPais[$a.Pais])".PadRight(12)
    if ($links.ContainsKey($a.Pais)) { Write-Host "   $t $($links[$a.Pais])/entrar" -ForegroundColor Yellow }
    else { Write-Host "   $t (sin link)" }
}
Write-Host ""
Write-Host " Para el viaje imposible: entra con la MISMA cuenta por el link de un pais y luego por el de otro."
Write-Host " Las alertas: http://localhost:5173/panel?s=fraude  (admin@mesh.com / Admin123)"
Write-Host " Ver cuales estan abiertos:  .\demo-entrar-otro-pais.ps1 -Estado" -ForegroundColor Yellow
Write-Host " Acabar el tour (cierra todo): .\demo-entrar-otro-pais.ps1 -Cerrar" -ForegroundColor Yellow
Write-Host "=============================================================="
