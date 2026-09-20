# demo-fraude-pais.ps1
# Demuestra el fraude del login de Mesh con una IP real de otro pais.
# Levanta Tor en ese pais, expone una COPIA del backend (el repo no se toca)
# con trustProxy por un tunel, manda intentos fallidos desde el pais elegido,
# y al final deja el panel del admin listo con un link local.
#
#   .\demo-fraude-pais.ps1 -Pais sg
#   .\demo-fraude-pais.ps1 -Limpiar      (borra lo que sembro la demo)
#   .\demo-fraude-pais.ps1 -Precalentar -Pais sg   (deja lista la parte lenta ANTES)
#
# -Precalentar hace lo que tarda, sin tocar nada de lo que se ve: comprueba que el
# tunel pueda salir (en la U hace falta WARP), construye una vez la imagen de Tor
# (la demo ya no instala paquetes en vivo), compila la copia del backend, y deja
# Tor corriendo con salida en el pais y comprobada. Despues la demo solo manda los
# intentos. No para el backend ni pausa ClickHouse y Neo4j: eso sigue siendo de la
# demo. Tor caliente pesa unos 50 MB; para soltarlo: docker rm -f mesh-tor-demo
#
# Paises probados: sg (Singapur), de (Alemania), jp (Japon), us (EE.UU.),
# nl (Holanda), fr (Francia), gb (Reino Unido), ca (Canada).
# Al terminar quita Tor y el tunel y deja el backend normal. La alerta se queda
# en el panel para ensenarla; -Limpiar la borra de Postgres, Mongo y Elastic.

param(
    [ValidateSet('sg','de','jp','us','nl','fr','gb','ca')]
    [string]$Pais = 'sg',
    [switch]$Limpiar,
    [switch]$Precalentar
)

# Nada de ErrorActionPreference = 'Stop': con los comandos de docker, un stderr
# (por ejemplo "docker rm" de un contenedor que no existe) cortaria el script.
# Cada paso comprueba su propio resultado y sale con exit 1 si algo va mal.
$repo = $PSScriptRoot
. (Join-Path $repo 'copia-backend.ps1')
$marca = 'mesh-demo-pais'
$inicioDemo = Get-Date
# Cada paso dice a los cuantos segundos empezo, para ver donde se va el tiempo.
function Paso($t) { Write-Host ("`n>> $t  [+{0} s]" -f [int]((Get-Date) - $inicioDemo).TotalSeconds) -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

# --- credenciales, del .env de la raiz ---
$env_ = @{}
Get-Content (Join-Path $repo '.env') | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
$RP = $env_['REDIS_PASSWORD']; $MU = $env_['MONGO_USER']; $MP = $env_['MONGO_PASSWORD']; $MD = $env_['MONGO_DB']

# --- Docker vivo ---
Paso "Revisando Docker y las bases"
docker ps *> $null
if ($LASTEXITCODE -ne 0) { Mal "Docker no responde. Abre Docker Desktop y espera a que arranque."; exit 1 }
if (-not (docker ps --format '{{.Names}}' | Select-String -Quiet 'mesh-postgres')) {
    Mal "Los contenedores de Mesh no estan arriba. Corre primero: .\arrancar.ps1"; exit 1
}
Ok "Docker y los contenedores mesh-* estan arriba"

# --- -Limpiar: borrar lo sembrado por la demo, marcado con su user-agent ---
# Primero se leen las IPs de Mongo (las alertas por IP llevan la IP como clave),
# despues se borra en Postgres, Mongo y Elastic. Sin comillas dobles en el
# JavaScript: PowerShell 5.1 las rompe al pasarlas a docker.
if ($Limpiar) {
    Paso "Borrando los datos de la demo"
    $js = "db.eventos_autenticacion.distinct('ip',{user_agent:'$marca'}).join(',')"
    $ips = (docker exec mesh-mongo mongosh --quiet -u $MU -p $MP --authenticationDatabase admin $MD --eval $js 2>$null) -join ''
    $claves = @($ips.Split(',') | Where-Object { $_ -match '^[0-9a-fA-F:.]+$' } | ForEach-Object { "'$_'" })
    $enIps = if ($claves.Count) { "clave IN ($($claves -join ',')) OR " } else { '' }
    $sql = "WITH d AS (DELETE FROM alerta_fraude WHERE $enIps clave LIKE 'demo.%@mesh.test' RETURNING 1) SELECT count(*) FROM d"
    $nPg = docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -tAc $sql 2>$null
    $js = "print(db.eventos_autenticacion.deleteMany({user_agent:'$marca'}).deletedCount)"
    $nMongo = docker exec mesh-mongo mongosh --quiet -u $MU -p $MP --authenticationDatabase admin $MD --eval $js 2>$null
    $nEs = '?'
    try {
        $r = Invoke-RestMethod -Method Post -ContentType 'application/json' `
            -Uri 'http://localhost:9200/mesh_eventos_autenticacion/_delete_by_query?refresh=true&conflicts=proceed' `
            -Body "{`"query`":{`"term`":{`"user_agent`":`"$marca`"}}}"
        $nEs = $r.deleted
    } catch {}
    Ok "IPs de la demo: $(if ($ips) { $ips } else { 'ninguna' })"
    Ok "Postgres: $nPg alerta(s); Mongo: $nMongo evento(s); Elastic: $nEs documento(s)"
    exit 0
}

# --- Tor: imagen propia, para no instalar paquetes en vivo ---
# Antes cada corrida arrancaba un alpine pelado y hacia `apk add tor curl` delante
# de todos. La imagen se construye UNA vez (con -Precalentar, o sola la primera
# vez que hace falta) y despues Tor arranca en segundos.
$ImagenTor = 'mesh-tor-demo:local'

function Preparar-ImagenTor {
    if (docker images -q $ImagenTor) { return $true }
    $dir = Join-Path $MeshDemoTmp 'tor'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content (Join-Path $dir 'Dockerfile') "FROM alpine:3`nRUN apk add --no-cache tor curl" -Encoding ascii
    docker build -t $ImagenTor $dir *> (Join-Path $MeshDemoTmp 'tor-build.log')
    return ($LASTEXITCODE -eq 0)
}

# Levanta Tor con salida en el pais y espera a que arme circuitos. Si ya hay uno
# precalentado para ESTE pais (lo marca la etiqueta mesh.pais) lo reutiliza.
function Levantar-Tor {
    $caliente = docker ps -q --filter 'name=^mesh-tor-demo$' --filter "label=mesh.pais=$Pais"
    if ($caliente) {
        Ok "Tor ya estaba caliente para '$Pais'"
    } else {
        docker rm -f mesh-tor-demo *> $null
        $etiqueta = "mesh.pais=$Pais"
        if (docker images -q $ImagenTor) {
            docker run -d --name mesh-tor-demo --memory 96m --label $etiqueta $ImagenTor `
                tor --SocksPort 127.0.0.1:9050 --ExitNodes "{$Pais}" --StrictNodes 1 *> $null
        } else {
            docker run -d --name mesh-tor-demo --memory 96m --label $etiqueta alpine:3 sh -c `
                "apk add --no-cache tor curl >/dev/null && exec tor --SocksPort 127.0.0.1:9050 --ExitNodes '{$Pais}' --StrictNodes 1" *> $null
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
function Buscar-SalidaTor {
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

# --- -Precalentar: lo lento, hecho antes y sin tocar lo que se ve ---
if ($Precalentar) {
    Paso "Precalentando la demo para '$($Pais.ToUpper())'"
    Paso "Salida del tunel"
    Asegurar-SalidaTunel | Out-Null
    Paso "Imagen de Tor"
    if (-not (Preparar-ImagenTor)) { Mal "No se pudo construir la imagen. Mira $MeshDemoTmp\tor-build.log"; exit 1 }
    Ok "Lista ($ImagenTor)"
    Paso "Copia del backend con trustProxy"
    if (-not (Preparar-CopiaBackend $repo)) { Mal "No compilo la copia. Mira $MeshDemoTmp\build.log"; exit 1 }
    Ok "Copia lista"
    Paso "Tor con salida en '$Pais'"
    if (-not (Levantar-Tor)) { Mal "Tor no arranco a tiempo."; docker rm -f mesh-tor-demo *> $null; exit 1 }
    $sal = Buscar-SalidaTor
    if (-not $sal) { Mal "No consegui una salida en '$Pais'. Prueba otro pais."; docker rm -f mesh-tor-demo *> $null; exit 1 }
    Ok "Salida comprobada, IP $($sal.Ip) ($($Pais.ToUpper()))"
    Write-Host "`n=============================================================="
    Write-Host " LISTO. Todo lo lento ya esta hecho para $($Pais.ToUpper())." -ForegroundColor Green
    Write-Host " Cuando quieras la demo:   .\demo-fraude-pais.ps1 -Pais $Pais" -ForegroundColor Yellow
    Write-Host " Tor queda corriendo (unos 50 MB). Para soltarlo:"
    Write-Host "   docker rm -f mesh-tor-demo"
    Write-Host "=============================================================="
    exit 0
}

# --- que el tunel pueda salir (en la U hace falta WARP) ---
# Antes de parar nada: si esto falla no hay que deshacer nada. No se aborta, porque
# el tunel mismo dice si subio o no; se avisa para no esperar dos minutos a ciegas.
Paso "Comprobando que el tunel pueda salir"
$salidaTunel = Asegurar-SalidaTunel
if (-not $salidaTunel) { Write-Host "   Sigo, pero es probable que el tunel no levante." -ForegroundColor Yellow }

# --- hacer sitio en RAM: la demo del login no usa ClickHouse ni Neo4j ---
# Esta maquina se queda sin memoria con todo arriba. Se paran las dos bases
# que esta demo no toca (el login usa Postgres, Mongo, Redis y Elastic) y se
# vuelven a arrancar al final. Neo4j solo alimenta los anillos de resenas del
# panel, que no es lo que se ensena aqui.
Paso "Liberando memoria (se paran ClickHouse y Neo4j un rato)"
docker stop mesh-clickhouse mesh-neo4j *> $null
Ok "ClickHouse y Neo4j pausados; se reactivan al terminar"

# --- Tor en el pais elegido, con un circuito que de verdad salga de ahi ---
Paso "Levantando Tor con salida en '$Pais'"
if (-not (Levantar-Tor)) { Mal "Tor no arranco a tiempo."; docker rm -f mesh-tor-demo *> $null; docker start mesh-clickhouse mesh-neo4j *> $null; exit 1 }

$salida = Buscar-SalidaTor
if (-not $salida) { Mal "No consegui una salida en '$Pais'. Prueba otro pais."; docker rm -f mesh-tor-demo *> $null; docker start mesh-clickhouse mesh-neo4j *> $null; exit 1 }
$socks = $salida.Socks; $ipSalida = $salida.Ip
Ok "IP de salida: $ipSalida ($($Pais.ToUpper()))"

# --- copia del backend con trustProxy (el repo NO se toca) ---
Paso "Preparando la copia del backend con trustProxy"
if (-not (Preparar-CopiaBackend $repo)) { Mal "No compilo la copia. Mira $MeshDemoTmp\build.log"; docker rm -f mesh-tor-demo *> $null; docker start mesh-clickhouse mesh-neo4j *> $null; exit 1 }
Ok "Copia lista"

# --- parar el backend normal y correr la copia en 3100 ---
Paso "Arrancando la copia en el puerto 3100"
$pCopia = Arrancar-CopiaBackend
if (-not $pCopia) { Mal "La copia no respondio. Mira $MeshDemoTmp\backend.err"; Arrancar-BackendNormal $repo | Out-Null; docker rm -f mesh-tor-demo *> $null; docker start mesh-clickhouse mesh-neo4j *> $null; exit 1 }
Ok "Copia respondiendo en 3100"

# --- tunel rapido a la copia ---
Paso "Abriendo el tunel"
$tun = Abrir-Tunel 'http://127.0.0.1:3100' '/productos?limite=1' 'tunel'
if (-not $tun) { Mal "El tunel no levanto."; Stop-Process -Id $pCopia.Id -Force -ErrorAction SilentlyContinue; Arrancar-BackendNormal $repo | Out-Null; docker rm -f mesh-tor-demo *> $null; docker start mesh-clickhouse mesh-neo4j *> $null; exit 1 }
$url = $tun.Url
Ok "Tunel arriba"

# --- mandar los intentos desde el pais ---
Paso "Enviando intentos de entrada fallidos desde $($Pais.ToUpper())"
# El cuerpo viaja en base64. PowerShell 5.1 le quita las comillas dobles a los
# argumentos de un exe: el JSON llegaba como {identificador:demo.sg1@mesh.test},
# el backend contestaba 400 por JSON invalido y NINGUN intento contaba, con la
# demo diciendo que si. Medido el 2026-09-15.
$codigos = @()
$desde = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
1..2 | ForEach-Object {
    1..4 | ForEach-Object {
        $json = '{"identificador":"demo.' + $Pais + $_ + '@mesh.test","contrasena":"mala"}'
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $codigos += (docker exec mesh-tor-demo sh -c "echo $b64 | base64 -d | curl -s -m 40 --socks5-hostname $socks -o /dev/null -w '%{http_code}' -A $marca -H 'Content-Type: application/json' --data-binary @- $url/usuario/login" 2>$null)
    }
}
Start-Sleep 7

# Se comprueba en las bases, no en lo que se mando. La IP se lee de lo que el
# backend registro y no de la que dio ipify: un nodo de Tor puede salir con
# varias IPs, y el 2026-09-15 ipify vio 203.55.81.1 y Cloudflare 203.55.81.2.
$js = "db.eventos_autenticacion.distinct('ip',{user_agent:'$marca',fecha:{`$gte:new Date('$desde')}}).join(',')"
$ipsVistas = @(((docker exec mesh-mongo mongosh --quiet -u $MU -p $MP --authenticationDatabase admin $MD --eval $js 2>$null) -join '').Split(',') |
    Where-Object { $_ -match '^[0-9a-fA-F:.]+$' })
$alertas = ''; $consultaOk = $true
if ($ipsVistas.Count) {
    $enIps = ($ipsVistas | ForEach-Object { "'$_'" }) -join ','
    $sql = "SELECT string_agg(t.tipo_alerta_fraude_nombre || ' (' || a.clave || ')', ', ') FROM alerta_fraude a JOIN tipo_alerta_fraude t USING (id_tipo_alerta_fraude) WHERE a.clave IN ($enIps)"
    $alertas = ((docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -v ON_ERROR_STOP=1 -tAc $sql 2>&1) -join ' ').Trim()
    $consultaOk = $LASTEXITCODE -eq 0
}
if (-not $consultaOk -or -not $alertas) {
    # Si la consulta misma fallo, se ensena su error: un verificador que no
    # distingue "no hay alerta" de "no pude preguntar" miente (paso aqui mismo,
    # con una columna mal escrita).
    if (-not $ipsVistas.Count) { Mal "El backend no registro ningun intento de esta corrida." }
    elseif ($consultaOk) { Mal "No quedo ninguna alerta con la IP $($ipsVistas -join ', ')." }
    else { Mal "No pude consultar alerta_fraude: $alertas" }
    Mal "Respuestas del backend: $($codigos -join ' ')"
    Stop-Process -Id $tun.Proceso.Id,$pCopia.Id -Force -ErrorAction SilentlyContinue
    Arrancar-BackendNormal $repo | Out-Null
    docker rm -f mesh-tor-demo *> $null; docker start mesh-clickhouse mesh-neo4j *> $null
    exit 1
}
$ipSalida = $ipsVistas -join ', '
Ok "8 intentos con 4 correos distintos (respuestas del backend: $(($codigos | Select-Object -Unique) -join ','))"
Ok "El backend los registro con la IP $ipSalida"
Ok "Alertas: $alertas"

# --- cerrar el tunel y la copia, volver al backend normal ---
Paso "Cerrando el tunel y devolviendo el backend normal"
Stop-Process -Id $tun.Proceso.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $pCopia.Id -Force -ErrorAction SilentlyContinue
Arrancar-BackendNormal $repo | Out-Null
docker rm -f mesh-tor-demo *> $null
docker start mesh-clickhouse mesh-neo4j *> $null
Ok "Backend normal arriba en 3000; ClickHouse y Neo4j reactivandose"

Write-Host "`n=============================================================="
Write-Host " LISTO. La alerta de $($Pais.ToUpper()) ($ipSalida) ya esta en el panel." -ForegroundColor Green
Write-Host " Abre este link y entra como admin@mesh.com / Admin123:"
Write-Host "   http://localhost:5173/panel?s=fraude" -ForegroundColor Yellow
Write-Host ""
Write-Host " Para borrar la alerta de demostracion cuando termines:"
Write-Host "   .\demo-fraude-pais.ps1 -Limpiar" -ForegroundColor Yellow
Write-Host "=============================================================="
