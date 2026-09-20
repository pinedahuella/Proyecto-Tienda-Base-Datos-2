# pais-enlace.ps1
# El link de Mesh "visto desde otro pais": https://mesh-singapur.ledkid.com, y sus hermanos.
# Lo usan demo-entrar-otro-pais.ps1, demo-fraude-pais.ps1 y mesh-publico.ps1
# (con ". .\pais-enlace.ps1").
#
# Que es: un programa pequeno (panel-comandos\pais-proxy.mjs) que reenvia todo lo que llega a
# ese nombre a https://mesh.ledkid.com SALIENDO POR TOR de ese pais. Quien abre el link, desde
# el navegador que sea, aparece para el backend en Singapur, y su login deja la IP de
# Singapur. Asi el viaje imposible se demuestra con un link normal, sin instalar nada.
#
# Necesita, en este orden:
#   1. Tor con salida en el pais y su SOCKS publicado (tor-demo.ps1: Levantar-Tor).
#   2. La direccion publica de Mesh abierta (mesh-publico.ps1), porque el proxy le habla a
#      https://mesh.ledkid.com.
#   3. Una vez por cuenta de Cloudflare: los nombres de cada pais en el DNS y en el tunel
#      'mesh' (mesh-publico.ps1 -Accion paises).
# Antes de incluirlo hay que haber incluido copia-backend.ps1 y tor-demo.ps1, y quien lo
# incluya define Ok y Mal.
#
# Los nombres son de UN solo nivel (mesh-singapur.ledkid.com y no singapur.mesh.ledkid.com)
# porque el certificado gratuito de Cloudflare cubre *.ledkid.com y no los de dos niveles.

$NombreHostPais = @{ sg = 'singapur'; de = 'alemania'; jp = 'japon'; us = 'eeuu'; nl = 'holanda'; fr = 'francia'; gb = 'reinounido'; ca = 'canada' }
$TituloPais     = @{ sg = 'Singapur'; de = 'Alemania'; jp = 'Japon'; us = 'EE. UU.'; nl = 'Holanda'; fr = 'Francia'; gb = 'Reino Unido'; ca = 'Canada' }
$PuertoEnlacePais = 5299
$ConfigTunelMesh = Join-Path $env:USERPROFILE '.cloudflared\config-mesh.yml'
$CloudflaredExe = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'

function Host-DePais([string]$p) { return "mesh-$($NombreHostPais[$p]).ledkid.com" }

function Proxy-DePais {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains('pais-proxy.mjs') }
}
function Cerrar-EnlacePais {
    foreach ($x in @(Proxy-DePais)) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Tunel-MeshCorriendo {
    return @(Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains('config-mesh.yml') }).Count -gt 0
}

# --- Una vez: los nombres de cada pais en el DNS y en el tunel 'mesh' ---------------------
# Idempotente. Agrega un CNAME por pais (solo registros nuevos: no toca ninguno existente),
# reescribe el ingress del tunel 'mesh' con esos nombres y lo reinicia si estaba corriendo.
# El tunel de LEDKID y su config no se tocan.
function Configurar-EnlacesPaises {
    if (-not (Test-Path $ConfigTunelMesh)) { Mal "Falta $ConfigTunelMesh (el tunel 'mesh', ver mesh-publico.ps1)."; return $false }
    $lineas = Get-Content $ConfigTunelMesh
    $lineaTunel = $lineas | Where-Object { $_ -match '^tunnel:' } | Select-Object -First 1
    $lineaCred  = $lineas | Where-Object { $_ -match '^credentials-file:' } | Select-Object -First 1
    if (-not $lineaTunel -or -not $lineaCred) { Mal "El config del tunel no trae tunnel: y credentials-file:."; return $false }

    $vacio = Join-Path $env:TEMP 'cf-vacio-mesh.yml'
    Set-Content $vacio '# vacio' -Encoding ascii
    foreach ($p in $NombreHostPais.Keys | Sort-Object) {
        $h = Host-DePais $p
        $salida = (& $CloudflaredExe tunnel --config $vacio route dns mesh $h 2>&1 | ForEach-Object { "$_" }) -join ' '
        if ($salida -match 'Added CNAME') { Ok "DNS nuevo: $h" }
        elseif ($salida -match 'already exists') { Ok "DNS ya estaba: $h" }
        else { Mal "$h : $($salida.Substring(0, [Math]::Min(160, $salida.Length)))" }
    }

    $reglas = foreach ($p in $NombreHostPais.Keys | Sort-Object) { "  - hostname: $(Host-DePais $p)`n    service: http://localhost:$PuertoEnlacePais" }
    $nuevo = @"
# Tunel nombrado 'mesh': publica Mesh en https://mesh.ledkid.com, y el link de cada pais
# (mesh-singapur.ledkid.com...) que lleva a pais-proxy.mjs. Es un tunel APARTE del de LEDKID
# (config.yml): no lo comparte ni lo toca. Lo escribe pais-enlace.ps1 (Configurar-EnlacesPaises)
# y lo lee mesh-publico.ps1. Este archivo NO va al repo: apunta a credenciales.
$lineaTunel
$lineaCred

ingress:
  - hostname: mesh.ledkid.com
    service: http://localhost:5173
$($reglas -join "`n")
  - service: http_status:404
"@
    $respaldo = "$ConfigTunelMesh.antes"
    Copy-Item $ConfigTunelMesh $respaldo -Force
    Set-Content $ConfigTunelMesh $nuevo -Encoding ascii
    $validacion = (& $CloudflaredExe tunnel --config $ConfigTunelMesh ingress validate 2>&1 | ForEach-Object { "$_" }) -join ' '
    if ($validacion -notmatch 'OK') {
        Mal "El ingress nuevo no valida ($validacion). Se deja el de antes."
        Copy-Item $respaldo $ConfigTunelMesh -Force
        return $false
    }
    Ok "Ingress del tunel mesh actualizado con los $($NombreHostPais.Count) paises"
    if (Tunel-MeshCorriendo) {
        Ok "Reiniciando el tunel mesh para que lea los nombres nuevos (mesh.ledkid.com parpadea unos segundos)"
        & (Join-Path $PSScriptRoot 'mesh-publico.ps1') -Accion apagar *> $null
        & (Join-Path $PSScriptRoot 'mesh-publico.ps1') -Accion encender *> $null
    }
    return $true
}

# --- El link de un pais: arranca el proxy y comprueba que el link de verdad contesta ------
# Devuelve la direccion (https://mesh-singapur.ledkid.com) o $null si algo falta.
function Abrir-EnlacePais([string]$Pais) {
    $h = Host-DePais $Pais
    $titulo = $TituloPais[$Pais]
    if (-not (Test-Path $ConfigTunelMesh) -or -not (Select-String -Path $ConfigTunelMesh -Pattern ([regex]::Escape($h)) -Quiet)) {
        Mal "El link de $titulo todavia no esta preparado en Cloudflare. Una sola vez:  .\mesh-publico.ps1 -Accion paises"
        return $null
    }
    # El proxy le habla a https://mesh.ledkid.com: esa direccion tiene que estar abierta
    if (-not (Tunel-MeshCorriendo)) {
        Ok "La direccion publica estaba cerrada; se abre porque el link de $titulo depende de ella"
        & (Join-Path $PSScriptRoot 'mesh-publico.ps1') -Accion encender *> $null
        if (-not (Tunel-MeshCorriendo)) { Mal "No se pudo abrir la direccion publica (mesh-publico.ps1)."; return $null }
    }
    Cerrar-EnlacePais
    Start-Sleep 1
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { Mal "No encuentro Node."; return $null }
    $logs = Join-Path $env:TEMP 'mesh-logs'; New-Item -ItemType Directory -Force $logs | Out-Null
    $env:PAIS_HOST = $h; $env:PAIS_NOMBRE = $titulo; $env:TOR_SOCKS_PUERTO = "$PuertoSocksTor"; $env:PAIS_PROXY_PUERTO = "$PuertoEnlacePais"
    Start-Process -FilePath $node -ArgumentList "`"$(Join-Path $PSScriptRoot 'panel-comandos\pais-proxy.mjs')`"" -WorkingDirectory $PSScriptRoot -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs 'pais-proxy.log') -RedirectStandardError (Join-Path $logs 'pais-proxy.err') | Out-Null
    Remove-Item Env:PAIS_HOST, Env:PAIS_NOMBRE, Env:TOR_SOCKS_PUERTO, Env:PAIS_PROXY_PUERTO -ErrorAction SilentlyContinue

    $local = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep 1
        try { if ((Invoke-WebRequest "http://127.0.0.1:$PuertoEnlacePais/__pais/estado" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) { $local = $true; break } } catch {}
    }
    if (-not $local) { Mal "El proxy del link no arranco. Mira $logs\pais-proxy.err"; return $null }

    # El link de verdad, por Cloudflare, sin pasar por Tor desde aqui: asi se ve lo que vera cualquiera
    $direccion = "https://$h"
    $contesta = $false
    for ($i = 0; $i -lt 30; $i++) {
        try { if ((Invoke-WebRequest "$direccion/api/productos?limite=1" -UseBasicParsing -TimeoutSec 30).StatusCode -eq 200) { $contesta = $true; break } } catch {}
        Start-Sleep 3
    }
    if (-not $contesta) { Mal "$direccion no contesta todavia (el DNS nuevo puede tardar unos minutos)."; return $null }
    return $direccion
}
