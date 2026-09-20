# tor-demo.ps1
# Tor en un contenedor de Docker (`mesh-tor-demo`) con salida en un pais. Lo usan
# demo-fraude-pais.ps1 y demo-entrar-otro-pais.ps1 (con ". .\tor-demo.ps1").
#
# Antes de incluirlo hay que haber incluido copia-backend.ps1 (define $MeshDemoTmp) y
# quien lo incluya tiene que definir las funciones Ok y Mal.
#
# Como se ve que es real:
#   docker ps --filter name=mesh-tor-demo            el contenedor, con su etiqueta de pais
#   docker exec mesh-tor-demo curl -s --socks5-hostname 127.0.0.1:9050 https://api.ipify.org
#                                                    la IP con la que sale, la de ese pais

# Imagen propia, para no instalar paquetes en vivo. Antes cada corrida arrancaba un
# alpine pelado y hacia `apk add tor curl` delante de todos. Se construye UNA vez.
$ImagenTor = 'mesh-tor-demo:local'

# Puerto del PC por el que un navegador puede usar este Tor como proxy SOCKS5. Se
# publica solo en 127.0.0.1: nadie de la red lo ve. (No se usa el 9050 porque es el
# de Tor Browser y el de cualquier otro Tor que haya en la maquina.)
$PuertoSocksTor = 9051

function Preparar-ImagenTor {
    if (docker images -q $ImagenTor) { return $true }
    $dir = Join-Path $MeshDemoTmp 'tor'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content (Join-Path $dir 'Dockerfile') "FROM alpine:3`nRUN apk add --no-cache tor curl" -Encoding ascii
    docker build -t $ImagenTor $dir *> (Join-Path $MeshDemoTmp 'tor-build.log')
    return ($LASTEXITCODE -eq 0)
}

# Esta el contenedor publicando su SOCKS en el PC? Los precalentados de antes de
# poder entrar con el navegador no lo publicaban y hay que rehacerlos.
function Tor-PublicadoEnElPc {
    return [bool]((docker port mesh-tor-demo 9050/tcp 2>$null) -match "127\.0\.0\.1:$PuertoSocksTor")
}

# Levanta Tor con salida en el pais y espera a que arme circuitos. Si ya hay uno
# para ESTE pais (lo marca la etiqueta mesh.pais) y con el puerto publicado, lo
# reutiliza. Devuelve $true o $false.
function Levantar-Tor([string]$Pais) {
    $caliente = docker ps -q --filter 'name=^mesh-tor-demo$' --filter "label=mesh.pais=$Pais"
    if ($caliente -and (Tor-PublicadoEnElPc)) {
        Ok "Tor ya estaba caliente para '$Pais'"
    } else {
        if ($caliente) { Ok "El Tor de antes no publicaba el puerto para el navegador; se rehace" }
        docker rm -f mesh-tor-demo *> $null
        if (Get-NetTCPConnection -LocalPort $PuertoSocksTor -State Listen -ErrorAction SilentlyContinue) {
            Mal "El puerto $PuertoSocksTor del PC ya esta ocupado por otro programa. Cierralo y vuelve a intentar."
            return $false
        }
        $etiqueta = "mesh.pais=$Pais"
        $publicar = "127.0.0.1:${PuertoSocksTor}:9050"
        # SocksPort en 0.0.0.0 DENTRO del contenedor y una politica que acepta a quien
        # llegue: sin eso Tor solo acepta a 127.0.0.1 y el navegador del PC entra por
        # la red de Docker y es rechazado. Nada queda expuesto: el puerto solo se
        # publica en 127.0.0.1 del PC (ver $publicar).
        if (docker images -q $ImagenTor) {
            docker run -d --name mesh-tor-demo --memory 96m --label $etiqueta -p $publicar $ImagenTor `
                tor --SocksPort 0.0.0.0:9050 --SocksPolicy 'accept 0.0.0.0/0' --ExitNodes "{$Pais}" --StrictNodes 1 *> $null
        } else {
            docker run -d --name mesh-tor-demo --memory 96m --label $etiqueta -p $publicar alpine:3 sh -c `
                "apk add --no-cache tor curl >/dev/null && exec tor --SocksPort 0.0.0.0:9050 --SocksPolicy 'accept 0.0.0.0/0' --ExitNodes '{$Pais}' --StrictNodes 1" *> $null
        }
    }
    for ($i=0; $i -lt 40; $i++) {
        if ((docker logs mesh-tor-demo 2>&1) -match 'Bootstrapped 100') { return $true }
        Start-Sleep 5
    }
    # Sin esto la falla salia muda ("Tor no arranco a tiempo") y no habia por donde
    # empezar: paso una vez en frio y no se pudo reproducir.
    Mal "Ultimas lineas de Tor:"
    docker logs --tail 5 mesh-tor-demo 2>&1 | ForEach-Object { Write-Host "     $_" }
    return $false
}

# ipinfo a veces ubica el nodo en otro pais; se piden circuitos hasta que cuadre.
# El pais se pregunta desde esta PC y no por Tor: ipinfo contesta 403 a todo lo
# que sale de un nodo de Tor (medido el 2026-09-15), y la demo no encontraba
# salida en ningun pais. Devuelve @{ Socks; Ip } o $null.
function Buscar-SalidaTor([string]$Pais) {
    for ($c=1; $c -le 15; $c++) {
        $s = "c${c}:x@127.0.0.1:9050"
        $ip = (docker exec mesh-tor-demo curl -s -m 40 --socks5-hostname $s https://api.ipify.org 2>$null)
        if ($ip -notmatch '^[0-9a-fA-F:.]+$') { continue }
        $pais2 = try { (Invoke-RestMethod "https://ipinfo.io/$ip/country" -TimeoutSec 10).Trim() } catch {
            try { (Invoke-RestMethod "http://ip-api.com/line/${ip}?fields=countryCode" -TimeoutSec 10).Trim() } catch { '' } }
        if ($pais2 -eq $Pais.ToUpper()) { return @{ Socks = $s; Ip = $ip } }
    }
    return $null
}
