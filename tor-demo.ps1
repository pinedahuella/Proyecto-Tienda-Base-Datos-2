# tor-demo.ps1
# Tor en contenedores de Docker, UNO POR PAIS (mesh-tor-sg, mesh-tor-de...), cada uno con
# salida en su pais. Lo usan demo-fraude-pais.ps1 y demo-entrar-otro-pais.ps1 (con
# ". .\tor-demo.ps1"). Pueden estar varios a la vez.
#
# Antes de incluirlo hay que haber incluido copia-backend.ps1 (define $MeshDemoTmp) y quien
# lo incluya tiene que definir las funciones Ok y Mal.
#
# Como se ve que es real:
#   docker ps --filter name=mesh-tor-                  los contenedores, uno por pais
#   docker exec mesh-tor-sg curl -s --socks5-hostname 127.0.0.1:9050 https://api.ipify.org
#                                                      la IP con la que sale, la de Singapur

# Imagen propia, para no instalar paquetes en vivo. Antes cada corrida arrancaba un
# alpine pelado y hacia `apk add tor curl` delante de todos. Se construye UNA vez.
$ImagenTor = 'mesh-tor-demo:local'

# Puerto del PC por el que un navegador puede usar el Tor de cada pais como proxy SOCKS5. Se
# publica solo en 127.0.0.1: nadie de la red lo ve. (No se usa el 9050 porque es el de Tor
# Browser y el de cualquier otro Tor que haya en la maquina.)
$PuertosSocksTor = @{ sg = 9061; de = 9062; jp = 9063; us = 9064; nl = 9065; fr = 9066; gb = 9067; ca = 9068 }

function Nombre-Tor([string]$Pais) { return "mesh-tor-$Pais" }

function Preparar-ImagenTor {
    if (docker images -q $ImagenTor) { return $true }
    $dir = Join-Path $MeshDemoTmp 'tor'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content (Join-Path $dir 'Dockerfile') "FROM alpine:3`nRUN apk add --no-cache tor curl" -Encoding ascii
    docker build -t $ImagenTor $dir *> (Join-Path $MeshDemoTmp 'tor-build.log')
    return ($LASTEXITCODE -eq 0)
}

# Esta el contenedor de ese pais publicando su SOCKS en el PC?
function Tor-PublicadoEnElPc([string]$Pais) {
    $n = Nombre-Tor $Pais
    return [bool]((docker port $n 9050/tcp 2>$null) -match "127\.0\.0\.1:$($PuertosSocksTor[$Pais])")
}

# Arranca el Tor de un pais SIN esperar a que arme circuitos, para poder lanzar varios en
# paralelo y esperarlos despues. Si ya hay uno vivo de ese pais con el puerto publicado, lo
# deja tal cual. Devuelve $true si hay (o habra) un contenedor, $false si no se pudo.
function Lanzar-Tor([string]$Pais) {
    $n = Nombre-Tor $Pais
    $puerto = $PuertosSocksTor[$Pais]
    # El unico contenedor de la version de un solo pais: se quita para que no estorbe
    docker rm -f mesh-tor-demo *> $null
    $vivo = docker ps -q --filter "name=^$n$" --filter "label=mesh.pais=$Pais"
    if ($vivo -and (Tor-PublicadoEnElPc $Pais)) { return $true }
    docker rm -f $n *> $null
    if (Get-NetTCPConnection -LocalPort $puerto -State Listen -ErrorAction SilentlyContinue) {
        Mal "El puerto $puerto del PC ya esta ocupado por otro programa. Cierralo y vuelve a intentar."
        return $false
    }
    $etiqueta = "mesh.pais=$Pais"
    $publicar = "127.0.0.1:${puerto}:9050"
    # SocksPort en 0.0.0.0 DENTRO del contenedor y una politica que acepta a quien llegue: sin
    # eso Tor solo acepta a 127.0.0.1 y el navegador del PC entra por la red de Docker y es
    # rechazado. Nada queda expuesto: el puerto solo se publica en 127.0.0.1 del PC.
    if (docker images -q $ImagenTor) {
        docker run -d --name $n --memory 192m --label $etiqueta -p $publicar $ImagenTor `
            tor --SocksPort 0.0.0.0:9050 --SocksPolicy 'accept 0.0.0.0/0' --ExitNodes "{$Pais}" --StrictNodes 1 --MaxCircuitDirtiness 3600 *> $null
    } else {
        docker run -d --name $n --memory 192m --label $etiqueta -p $publicar alpine:3 sh -c `
            "apk add --no-cache tor curl >/dev/null && exec tor --SocksPort 0.0.0.0:9050 --SocksPolicy 'accept 0.0.0.0/0' --ExitNodes '{$Pais}' --StrictNodes 1 --MaxCircuitDirtiness 3600" *> $null
    }
    return ($LASTEXITCODE -eq 0)
}

# Espera a que el Tor de ese pais arme circuitos.
function Esperar-Tor([string]$Pais) {
    $n = Nombre-Tor $Pais
    for ($i=0; $i -lt 40; $i++) {
        if ((docker logs $n 2>&1) -match 'Bootstrapped 100') { return $true }
        Start-Sleep 5
    }
    # Sin esto la falla salia muda ("Tor no arranco a tiempo") y no habia por donde empezar
    Mal "Ultimas lineas del Tor de ${Pais}:"
    docker logs --tail 5 $n 2>&1 | ForEach-Object { Write-Host "     $_" }
    return $false
}

# Lanzar y esperar, para quien solo necesita un pais.
function Levantar-Tor([string]$Pais) {
    if (-not (Lanzar-Tor $Pais)) { return $false }
    return (Esperar-Tor $Pais)
}

# El pais de una IP segun el BACKEND (su geoip-lite, panel-comandos/geo-pais.mjs). Es el que
# cuenta: es el que se guarda en el evento y dispara el viaje imposible. Tor, ipinfo y geoip-lite
# no coinciden en algunas salidas (46.250.243.29: Singapur, Australia y Reino Unido, medido el
# 2026-09-20), asi que una salida solo sirve si el backend la ubica en el pais pedido. Devuelve
# el codigo en mayusculas, '??' si la IP no esta en su base, o '' si no se pudo preguntar.
function Pais-SegunElBackend([string]$ip) {
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { return '' }
    $r = (& $node (Join-Path $PSScriptRoot 'panel-comandos\geo-pais.mjs') $ip 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $r) { return '' }
    return (("$r" -split '\s+')[1])
}

# Se piden circuitos (cada uno con su etiqueta c1, c2...) hasta que salga uno que el backend ubique
# en el pais. Si no se puede preguntarle al backend (falta geoip-lite) se cae a ipinfo, que se
# pregunta desde esta PC y no por Tor: contesta 403 a todo lo que sale de un nodo de Tor.
# Devuelve @{ Socks; Ip; Usuario } o $null. Usuario es la etiqueta del circuito: con ella el
# proxy de los links usa EXACTAMENTE ese circuito y no otro.
# Con -DesdePc la salida se prueba POR EL MISMO CAMINO que usa el proxy de los links: desde este
# PC, por el puerto publicado del Tor de ese pais, y con la etiqueta del circuito como usuario.
# Tor separa los circuitos por usuario Y por la direccion de quien se conecta, asi que probar
# dentro del contenedor (otra direccion) daba OTRO circuito distinto del que despues usaba el
# proxy, y el pais verificado no era el del link. Sin -DesdePc se prueba dentro del contenedor,
# que es de donde salen los intentos de demo-fraude-pais.ps1.
function Buscar-SalidaTor([string]$Pais, [switch]$DesdePc) {
    $n = Nombre-Tor $Pais
    for ($c=1; $c -le 15; $c++) {
        $s = "c${c}:x@127.0.0.1:9050"
        if ($DesdePc) {
            $ip = (curl.exe -s -m 40 --socks5-hostname "c${c}:x@127.0.0.1:$($PuertosSocksTor[$Pais])" https://api.ipify.org 2>$null)
        } else {
            $ip = (docker exec $n curl -s -m 40 --socks5-hostname $s https://api.ipify.org 2>$null)
        }
        if ($ip -notmatch '^[0-9a-fA-F:.]+$') { continue }
        $pais2 = Pais-SegunElBackend $ip
        if (-not $pais2) {
            $pais2 = try { (Invoke-RestMethod "https://ipinfo.io/$ip/country" -TimeoutSec 10).Trim() } catch {
                try { (Invoke-RestMethod "http://ip-api.com/line/${ip}?fields=countryCode" -TimeoutSec 10).Trim() } catch { '' } }
        }
        if ($pais2 -eq $Pais.ToUpper()) { return @{ Socks = $s; Ip = $ip; Usuario = "c$c" } }
    }
    return $null
}

function Quitar-Tor([string]$Pais) { docker rm -f (Nombre-Tor $Pais) *> $null }

# Todos los Tor de las demos, de cualquier pais (y el de la version de un solo pais).
function Quitar-TodosLosTor {
    $ids = @(docker ps -a -q --filter 'name=^mesh-tor-')
    if ($ids.Count -gt 0 -and $ids[0]) { docker rm -f $ids *> $null }
}
