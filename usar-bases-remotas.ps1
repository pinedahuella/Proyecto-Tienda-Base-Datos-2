# usar-bases-remotas.ps1
# Para la PC de Meme: el backend corre aqui y las bases en la PC de un amigo,
# por Tailscale. La otra PC se prepara con preparar-pc-bases.ps1, que al final
# dice la IP que va aqui.
#
#   .\usar-bases-remotas.ps1 -Ip 100.x.y.z    el backend usa las bases de esa PC
#   .\usar-bases-remotas.ps1 -Local           el backend vuelve a las de esta PC
#
# Solo cambia los *_HOST de backend\.env. Antes guarda una copia en
# backend\.env.antes-remotas. Despues hay que reiniciar el backend:
#   .\panel-comandos\servicios.ps1 -Accion backend
#
# Las contrasenas tienen que ser las mismas en las dos PC. Por eso el amigo
# usa el .env de Meme.

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
# Sin BOM: dotenv lee el BOM como parte del primer nombre de variable.
[IO.File]::WriteAllLines($envBack, $lineas, (New-Object Text.UTF8Encoding($false)))

Write-Host "`n>> backend\.env apunta a $destino"
foreach ($k in $claves) { Write-Host "   $k=$destino" }
if (-not $Local) { Write-Host "   copia de antes en backend\.env.antes-remotas" }
Write-Host "`n   Ahora reinicia el backend:  .\panel-comandos\servicios.ps1 -Accion backend"
