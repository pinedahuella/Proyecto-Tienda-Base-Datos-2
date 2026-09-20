# pais-enlace.ps1
# Los links de Mesh "vistos desde otro pais": https://mesh-singapur.ledkid.com, y sus hermanos.
# Lo usan demo-entrar-otro-pais.ps1, demo-fraude-pais.ps1 y mesh-publico.ps1
# (con ". .\pais-enlace.ps1").
#
# Que es: un programa pequeno (panel-comandos\pais-proxy.mjs) que reenvia todo lo que llega a
# ese nombre a https://mesh.ledkid.com SALIENDO POR EL TOR de ese pais. Quien abre el link,
# desde el navegador que sea, aparece para el backend en Singapur, y su login deja la IP de
# Singapur. Asi el viaje imposible se demuestra con un link normal, sin instalar nada.
#
# Pueden estar VARIOS paises abiertos a la vez: cada uno es un Tor (tor-demo.ps1) y una fila del
# registro paises-activos.json, que el proxy lee en cada peticion. Abrir o cerrar un pais es
# tocar ese registro y su Tor: no reinicia el proxy ni toca el tunel.
#
# Necesita, en este orden:
#   1. Tor con salida en el pais y su SOCKS publicado (tor-demo.ps1).
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
$OrdenPaises    = @('sg', 'de', 'jp', 'us', 'nl', 'fr', 'gb', 'ca')
$PuertoEnlacePais = 5299
$ConfigTunelMesh = Join-Path $env:USERPROFILE '.cloudflared\config-mesh.yml'
$CloudflaredExe = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$RegistroPaises = Join-Path $MeshDemoTmp 'paises-activos.json'

function Host-DePais([string]$p) { return "mesh-$($NombreHostPais[$p]).ledkid.com" }

# --- El registro de paises abiertos (lo lee el proxy en cada peticion) ---------------------
function Leer-Registro {
    if (Test-Path $RegistroPaises) {
        try { $r = Get-Content $RegistroPaises -Raw | ConvertFrom-Json; if ($r -and $r.paises) { return $r } } catch {}
    }
    return [pscustomobject]@{ paises = [pscustomobject]@{} }
}
function Guardar-Registro($r) {
    New-Item -ItemType Directory -Force (Split-Path $RegistroPaises) | Out-Null
    ($r | ConvertTo-Json -Depth 6) | Set-Content $RegistroPaises -Encoding ascii
}
# OJO: @($null) tiene UN elemento; con Properties.Name, sin paises devolvia [$null] y las cuentas salian mal
function Paises-Activos { return @((Leer-Registro).paises.PSObject.Properties | ForEach-Object { $_.Name }) }
function Pais-Activo([string]$p) { return ((Paises-Activos) -contains $p) }
function Registrar-PaisActivo([string]$p, [string]$ip, [string]$usuario = '') {
    $r = Leer-Registro
    $entrada = [pscustomobject]@{ nombre = $TituloPais[$p]; host = (Host-DePais $p); socks = $PuertosSocksTor[$p]; usuario = $usuario; ip = $ip; desde = (Get-Date -Format 's') }
    if ($r.paises.PSObject.Properties[$p]) { $r.paises.$p = $entrada } else { $r.paises | Add-Member -NotePropertyName $p -NotePropertyValue $entrada }
    Guardar-Registro $r
}
function Quitar-PaisActivo([string]$p) {
    $r = Leer-Registro
    if ($r.paises.PSObject.Properties[$p]) { [void]$r.paises.PSObject.Properties.Remove($p); Guardar-Registro $r }
}

# --- El proxy y el tunel ---------------------------------------------------------------------
function Proxy-DePais {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains('pais-proxy.mjs') }
}
function Cerrar-Proxy { foreach ($x in @(Proxy-DePais)) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue } }

function Tunel-MeshCorriendo {
    return @(Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains('config-mesh.yml') }).Count -gt 0
}

# La direccion publica de Mesh tiene que estar abierta: los links le hablan a ella.
function Asegurar-DireccionPublica {
    if (Tunel-MeshCorriendo) { return $true }
    Ok "La direccion publica estaba cerrada; se abre porque los links por pais dependen de ella"
    & (Join-Path $PSScriptRoot 'mesh-publico.ps1') -Accion encender *> $null
    return (Tunel-MeshCorriendo)
}

# Un solo proxy para todos los paises: si ya corre, se deja (la tabla se relee sola).
function Asegurar-Proxy {
    # Un proxy que arranco ANTES de la ultima version de pais-proxy.mjs corre codigo viejo (paso
    # al pasar de un solo pais a varios): se cierra y se vuelve a lanzar.
    $programa = Get-Item (Join-Path $PSScriptRoot 'panel-comandos\pais-proxy.mjs')
    foreach ($x in @(Proxy-DePais)) {
        if ($x.CreationDate -lt $programa.LastWriteTime) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue; Start-Sleep 1 }
    }
    if (@(Proxy-DePais).Count -gt 0) { return $true }
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { Mal "No encuentro Node."; return $false }
    $logs = Join-Path $env:TEMP 'mesh-logs'; New-Item -ItemType Directory -Force $logs | Out-Null
    $env:PAIS_TABLA = $RegistroPaises; $env:PAIS_PROXY_PUERTO = "$PuertoEnlacePais"
    Start-Process -FilePath $node -ArgumentList "`"$(Join-Path $PSScriptRoot 'panel-comandos\pais-proxy.mjs')`"" -WorkingDirectory $PSScriptRoot -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs 'pais-proxy.log') -RedirectStandardError (Join-Path $logs 'pais-proxy.err') | Out-Null
    Remove-Item Env:PAIS_TABLA, Env:PAIS_PROXY_PUERTO -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep 1
        try { if ((Invoke-WebRequest "http://127.0.0.1:$PuertoEnlacePais/__pais/estado" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) { return $true } } catch {}
    }
    Mal "El proxy de los links no arranco. Mira $logs\pais-proxy.err"
    return $false
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
    foreach ($p in $OrdenPaises) {
        $h = Host-DePais $p
        $salida = (& $CloudflaredExe tunnel --config $vacio route dns mesh $h 2>&1 | ForEach-Object { "$_" }) -join ' '
        if ($salida -match 'Added CNAME') { Ok "DNS nuevo: $h" }
        elseif ($salida -match 'already exists') { Ok "DNS ya estaba: $h" }
        else { Mal "$h : $($salida.Substring(0, [Math]::Min(160, $salida.Length)))" }
    }

    $reglas = foreach ($p in $OrdenPaises) { "  - hostname: $(Host-DePais $p)`n    service: http://localhost:$PuertoEnlacePais" }
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
    Ok "Ingress del tunel mesh actualizado con los $($OrdenPaises.Count) paises"
    if (Tunel-MeshCorriendo) {
        Ok "Reiniciando el tunel mesh para que lea los nombres nuevos (mesh.ledkid.com parpadea unos segundos)"
        & (Join-Path $PSScriptRoot 'mesh-publico.ps1') -Accion apagar *> $null
        & (Join-Path $PSScriptRoot 'mesh-publico.ps1') -Accion encender *> $null
    }
    return $true
}

# --- Abrir el link de un pais ------------------------------------------------------------------
# Supone que el Tor de ese pais ya esta arriba (Levantar-Tor / Esperar-Tor). Lo agrega al
# registro (sin tocar los demas paises abiertos), se asegura de que el proxy y la direccion
# publica esten, y comprueba que el link de verdad contesta. Devuelve la direccion
# (https://mesh-singapur.ledkid.com) o $null si algo falta.
function Abrir-EnlacePais([string]$Pais, [string]$Ip = '', [string]$Usuario = '') {
    $h = Host-DePais $Pais
    $titulo = $TituloPais[$Pais]
    if (-not (Test-Path $ConfigTunelMesh) -or -not (Select-String -Path $ConfigTunelMesh -Pattern ([regex]::Escape($h)) -Quiet)) {
        Mal "El link de $titulo todavia no esta preparado en Cloudflare. Una sola vez:  .\mesh-publico.ps1 -Accion paises"
        return $null
    }
    if (-not (Asegurar-DireccionPublica)) { Mal "No se pudo abrir la direccion publica (mesh-publico.ps1)."; return $null }
    # La salida que usara el proxy se verifica AQUI, por el mismo camino que el proxy (desde este PC,
    # con la etiqueta del circuito), y con el mismo geoip-lite que usa el backend. Los datos que
    # trae quien llama (`$Ip`, `$Usuario`) vienen de otra verificacion, hecha dentro del contenedor,
    # que puede haber caido en otro circuito: se ignoran.
    $verificada = Buscar-SalidaTor $Pais -DesdePc
    if (-not $verificada) { Mal "No hay una salida de Tor que el backend ubique en $titulo. Prueba otra vez o con otro pais."; return $null }
    Registrar-PaisActivo $Pais $verificada.Ip $verificada.Usuario
    if (-not (Asegurar-Proxy)) { return $null }

    # El link de verdad, por Cloudflare, sin pasar por Tor desde aqui: asi se ve lo que vera cualquiera
    $direccion = "https://$h"
    for ($i = 0; $i -lt 30; $i++) {
        try { if ((Invoke-WebRequest "$direccion/api/productos?limite=1" -UseBasicParsing -TimeoutSec 30).StatusCode -eq 200) { return $direccion } } catch {}
        Start-Sleep 3
    }
    Mal "$direccion no contesta todavia (el DNS nuevo puede tardar unos minutos)."
    return $null
}

# --- Cerrar ------------------------------------------------------------------------------------
# Un pais: sale del registro y se quita su Tor. Si era el ultimo, tambien el proxy.
function Cerrar-EnlacePais([string]$Pais) {
    Quitar-PaisActivo $Pais
    Quitar-Tor $Pais
    if ((Paises-Activos).Count -eq 0) { Cerrar-Proxy }
}

# Todos: el proxy, el registro y cada Tor. NO toca la direccion publica (mesh.ledkid.com) ni
# el tunel de LEDKID.
function Cerrar-TodosLosPaises {
    Cerrar-Proxy
    Remove-Item $RegistroPaises -Force -ErrorAction SilentlyContinue
    Quitar-TodosLosTor
}
