# usar-bases-remotas.ps1
# Para la PC de Meme: el backend corre aqui y las bases en la PC de un amigo,
# por Tailscale. La otra PC se prepara con preparar-pc-bases.ps1, que al final
# dice la IP que va aqui.
#
#   .\usar-bases-remotas.ps1 -Ip 100.x.y.z    el backend usa las bases de esa PC
#   .\usar-bases-remotas.ps1 -Local           el backend vuelve a las de esta PC
#
# Cambia los *_HOST de backend\.env y los usuarios y contrasenas con que el
# backend entra a cada base. Antes guarda una copia en backend\.env.antes-remotas.
# Despues hay que reiniciar el backend:
#   .\panel-comandos\servicios.ps1 -Accion backend
#
# LAS CREDENCIALES (desde el 2026-10-23, cuando cada base paso a tener su
# usuario mesh_backend, docs/SEGURIDAD.md). Cada PC genera las suyas al correr
# arrancar.ps1, asi que salen de dos lugares:
#   -Local   del .env de la raiz, el de esta PC
#   -Ip      de remoto\.env.remoto, con las de la otra PC (no se sube a git)
# Por cada base, si el archivo trae la contrasena del usuario del backend
# (PG_BACKEND_PASSWORD, MONGO_BACKEND_PASSWORD...) se usa ese usuario. Si no la
# trae, se usa el dueno de la base (DB_USER, MONGO_USER...), que es lo que hay
# en una PC que todavia no corrio arrancar.ps1 con esta version. Asi el backend
# arranca en los dos casos.

param(
    [string]$Ip = '',
    [switch]$Local
)

$raiz   = $PSScriptRoot
$envBack = Join-Path $raiz 'backend\.env'
$claves = @('DB_HOST', 'MONGO_HOST', 'REDIS_HOST', 'NEO4J_HOST', 'CLICKHOUSE_HOST', 'ELASTIC_HOST')
$puertos = [ordered]@{ PostgreSQL = 5432; MongoDB = 27018; Redis = 6379; Neo4j = 7687; Elasticsearch = 9200; ClickHouse = 8123 }

if ($Local) { $destino = 'localhost' }
elseif ($Ip -match '^\d{1,3}(\.\d{1,3}){3}$') { $destino = $Ip }
else {
    Write-Host "Uso:  .\usar-bases-remotas.ps1 -Ip 100.x.y.z   o   .\usar-bases-remotas.ps1 -Local"
    exit 1
}
if (-not (Test-Path $envBack)) { Write-Host "No encuentro $envBack" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------
# Si es remoto, primero se mira que cada base conteste. Asi no se toca el .env
# para dejar un backend que no arranca.
if (-not $Local) {
    $ts = 'C:\Program Files\Tailscale\tailscale.exe'
    if ((Test-Path $ts) -and -not ((& $ts ip -4 2>$null) | Select-Object -First 1)) {
        Write-Host "Tailscale de esta PC esta apagado o sin sesion. Abrelo desde el menu inicio y entra." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "`n>> Probando las bases en $destino"
    $faltan = 0
    foreach ($b in $puertos.Keys) {
        $c = New-Object Net.Sockets.TcpClient
        $ok = $false
        try { $ok = $c.ConnectAsync($destino, $puertos[$b]).Wait(3000) -and $c.Connected } catch {}
        $c.Close()
        if ($ok) { Write-Host ("   {0,-14} {1}  contesta" -f $b, $puertos[$b]) }
        else     { Write-Host ("   {0,-14} {1}  NO contesta" -f $b, $puertos[$b]) -ForegroundColor Red; $faltan++ }
    }
    if ($faltan -gt 0) {
        Write-Host "`n   No cambie nada. Revisa que en la otra PC haya terminado preparar-pc-bases.ps1." -ForegroundColor Red
        exit 1
    }
}

# ------------------------------------------------------------
$copia = "$envBack.antes-remotas"
if (-not $Local) { Copy-Item $envBack $copia -Force }

$lineas = [Collections.Generic.List[string]](Get-Content $envBack)
foreach ($k in $claves) {
    $i = -1
    for ($n = 0; $n -lt $lineas.Count; $n++) { if ($lineas[$n] -match "^$k=") { $i = $n; break } }
    if ($i -ge 0) { $lineas[$i] = "$k=$destino" } else { $lineas.Add("$k=$destino") }
}
# ------------------------------------------------------------
# Las credenciales de cada base
function Leer-Env($ruta) {
    $d = @{}
    foreach ($l in Get-Content $ruta) {
        $t = $l.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $p = $t.Split('=', 2)
        if ($p.Count -eq 2) { $d[$p[0].Trim()] = $p[1].Trim() }
    }
    return $d
}
$fuente = if ($Local) { Join-Path $raiz '.env' } else { Join-Path $raiz 'remoto\.env.remoto' }
$credenciales = [ordered]@{}
if (Test-Path $fuente) {
    $f = Leer-Env $fuente
    # base -> usuario del backend, su contrasena, y el dueno con la suya
    $porBase = @(
        @('PostgreSQL',    'DB_USER',         'DB_PASSWORD',         'mesh_backend', 'PG_BACKEND_PASSWORD',         $f['DB_USER'],         $f['DB_PASSWORD']),
        @('MongoDB',       'MONGO_USER',      'MONGO_PASSWORD',      'mesh_backend', 'MONGO_BACKEND_PASSWORD',      $f['MONGO_USER'],      $f['MONGO_PASSWORD']),
        @('Redis',         'REDIS_USER',      'REDIS_PASSWORD',      'backend',      'REDIS_BACKEND_PASSWORD',      '',                    $f['REDIS_PASSWORD']),
        @('ClickHouse',    'CLICKHOUSE_USER', 'CLICKHOUSE_PASSWORD', 'mesh_backend', 'CLICKHOUSE_BACKEND_PASSWORD', $f['CLICKHOUSE_USER'],   $f['CLICKHOUSE_PASSWORD']),
        @('Elasticsearch', 'ELASTIC_USER',    'ELASTIC_PASSWORD',    'mesh_backend', 'ELASTIC_BACKEND_PASSWORD',    $(if ($f['ELASTIC_PASSWORD']) { 'elastic' } else { '' }), $f['ELASTIC_PASSWORD'])
    )
    Write-Host "`n>> Usuarios del backend, de $([IO.Path]::GetFileName($fuente))"
    foreach ($b in $porBase) {
        if ($f[$b[4]]) {
            $credenciales[$b[1]] = $b[3]; $credenciales[$b[2]] = $f[$b[4]]
            Write-Host ("   {0,-14} {1}" -f $b[0], $b[3])
        } else {
            # Sin usuario (Redis default, o Elasticsearch sin seguridad) la
            # linea queda vacia y el backend entra como antes.
            $credenciales[$b[1]] = $b[5]; $credenciales[$b[2]] = $b[6]
            $quien = if ($b[5]) { $b[5] } elseif ($b[0] -eq 'Redis') { 'default' } else { 'sin usuario' }
            Write-Host ("   {0,-14} {1}, el de antes (esa PC no tiene {2})" -f $b[0], $quien, $b[4]) -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "`n   No encontre $fuente, los usuarios y contrasenas de backend\.env quedan como estaban." -ForegroundColor Yellow
}
foreach ($k in $credenciales.Keys) {
    $i = -1
    for ($n = 0; $n -lt $lineas.Count; $n++) { if ($lineas[$n] -match "^$k=") { $i = $n; break } }
    if ($i -ge 0) { $lineas[$i] = "$k=$($credenciales[$k])" } else { $lineas.Add("$k=$($credenciales[$k])") }
}

# Sin BOM: dotenv lee el BOM como parte del primer nombre de variable.
[IO.File]::WriteAllLines($envBack, $lineas, (New-Object Text.UTF8Encoding($false)))

Write-Host "`n>> backend\.env apunta a $destino"
foreach ($k in $claves) { Write-Host "   $k=$destino" }
if (-not $Local) { Write-Host "   copia de antes en backend\.env.antes-remotas" }
Write-Host "`n   Ahora reinicia el backend:  .\panel-comandos\servicios.ps1 -Accion backend"
