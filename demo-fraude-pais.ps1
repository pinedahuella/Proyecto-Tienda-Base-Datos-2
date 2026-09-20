# demo-fraude-pais.ps1
# Demuestra el fraude del login de Mesh con una IP real de otro pais.
# Levanta Tor en ese pais, abre un tunel de Cloudflare al backend REAL (el 3000),
# manda intentos fallidos desde el pais elegido y comprueba en las bases que quedo
# la alerta. Al final deja el panel del admin listo con un link local.
#
# NO para el backend, ni ClickHouse, ni Neo4j: Mesh sigue en pie todo el tiempo.
# (Antes armaba una copia del backend con trustProxy y paraba el real cuatro
# minutos; ya no hace falta porque el backend trae trustProxy desde el 2026-09-18.
# La copia sigue disponible con -ConCopia.)
#
#   .\demo-fraude-pais.ps1 -Pais sg
#   .\demo-fraude-pais.ps1 -Limpiar      (borra lo que sembro la demo)
#   .\demo-fraude-pais.ps1 -Precalentar -Pais sg   (deja lista la parte lenta ANTES)
#   .\demo-fraude-pais.ps1 -Pais sg -ConCopia      (camino viejo: copia en el 3100)
#
# -Precalentar hace lo que tarda, sin tocar nada de lo que se ve: comprueba que el
# tunel pueda salir (en la U hace falta WARP), construye una vez la imagen de Tor
# (la demo ya no instala paquetes en vivo) y deja Tor corriendo con salida en el
# pais y comprobada. Con -ConCopia tambien compila la copia. Tor caliente pesa unos
# 50 MB; para soltarlo: docker rm -f mesh-tor-demo
#
# Paises probados: sg (Singapur), de (Alemania), jp (Japon), us (EE.UU.),
# nl (Holanda), fr (Francia), gb (Reino Unido), ca (Canada).
# Al terminar quita Tor y el tunel. La alerta se queda en el panel para
# ensenarla; -Limpiar la borra de Postgres, Mongo y Elastic.

param(
    [ValidateSet('sg','de','jp','us','nl','fr','gb','ca')]
    [string]$Pais = 'sg',
    [switch]$Limpiar,
    [switch]$Precalentar,
    [switch]$ConCopia
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

# --- Tor: imagen propia, contenedor y busqueda de salida en el pais ---
# Viven en tor-demo.ps1, que comparte con demo-entrar-otro-pais.ps1.
. (Join-Path $repo 'tor-demo.ps1')
. (Join-Path $repo 'pais-enlace.ps1')

# Si hay una ventana abierta desde otro pais (demo-entrar-otro-pais.ps1), el Tor es de
# ella. Cambiarle el pais por debajo le rompe la sesion, asi que se pide cerrarla antes.
function Comprobar-SesionPais {
    $sesion = Join-Path $MeshDemoTmp 'entrar-pais.json'
    if (-not (Test-Path $sesion)) { return }
    $s = Get-Content $sesion -Raw | ConvertFrom-Json
    if ($s.pais -ne $Pais) {
        Mal "Hay una ventana abierta desde '$($s.pais)'. Cierrala primero (.\demo-entrar-otro-pais.ps1 -Cerrar) o usa -Pais $($s.pais)."
        exit 1
    }
}

# --- -Precalentar: lo lento, hecho antes y sin tocar lo que se ve ---
if ($Precalentar) {
    Paso "Precalentando la demo para '$($Pais.ToUpper())'"
    Paso "Salida del tunel"
    Asegurar-SalidaTunel | Out-Null
    Paso "Imagen de Tor"
    if (-not (Preparar-ImagenTor)) { Mal "No se pudo construir la imagen. Mira $MeshDemoTmp\tor-build.log"; exit 1 }
    Ok "Lista ($ImagenTor)"
    if ($ConCopia) {
        Paso "Copia del backend con trustProxy"
        if (-not (Preparar-CopiaBackend $repo)) { Mal "No compilo la copia. Mira $MeshDemoTmp\build.log"; exit 1 }
        Ok "Copia lista"
    }
    Paso "Tor con salida en '$Pais'"
    Comprobar-SesionPais
    if (-not (Levantar-Tor $Pais)) { Mal "Tor no arranco a tiempo."; docker rm -f mesh-tor-demo *> $null; exit 1 }
    $sal = Buscar-SalidaTor $Pais
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
# Antes de tocar nada: si esto falla no hay que deshacer nada. No se aborta, porque
# el tunel mismo dice si subio o no; se avisa para no esperar dos minutos a ciegas.
Paso "Comprobando que el tunel pueda salir"
$salidaTunel = Asegurar-SalidaTunel
if (-not $salidaTunel) { Write-Host "   Sigo, pero es probable que el tunel no levante." -ForegroundColor Yellow }

# --- lo que hay que deshacer al terminar, salga bien o mal ---
$pausadas = $false; $pCopia = $null; $tun = $null
function Limpiar-Demo {
    if ($tun)    { Stop-Process -Id $tun.Proceso.Id -Force -ErrorAction SilentlyContinue }
    if ($pCopia) { Stop-Process -Id $pCopia.Id -Force -ErrorAction SilentlyContinue; Arrancar-BackendNormal $repo | Out-Null }
    # Si hay una ventana abierta desde otro pais (demo-entrar-otro-pais.ps1), ese Tor es suyo
    if (-not (Test-Path (Join-Path $MeshDemoTmp 'entrar-pais.json'))) { docker rm -f mesh-tor-demo *> $null }
    if ($pausadas) { docker start mesh-clickhouse mesh-neo4j *> $null }
}
function Salir-Demo([int]$codigo) { Limpiar-Demo; exit $codigo }

# --- el backend ---
# Por defecto el tunel va al backend REAL, en el 3000, y la demo no para nada de Mesh.
#
# Antes la demo armaba una COPIA del backend con trustProxy, paraba el real, pausaba
# ClickHouse y Neo4j para que cupieran las dos, y al final lo devolvia todo. Eran
# unos cuatro minutos con Mesh caido ("el servidor se esta reiniciando"). Se hacia
# asi porque backend/ NO traia trustProxy, y sin el la IP siempre era 127.0.0.1.
# Jose David lo agrego a backend/src/main.ts el 2026-09-18 (`new FastifyAdapter({
# trustProxy: 'loopback' })`), asi que la copia dejo de hacer falta. Y los dos
# backends a la vez no se podian: duplicarian los @Interval (workers de Elastic, del
# grafo y de la venta relampago), por eso se paraba el real.
#
# -ConCopia deja el camino viejo, por si algun dia corre un backend sin trustProxy.
if ($ConCopia) {
    Paso "Liberando memoria (se paran ClickHouse y Neo4j un rato)"
    docker stop mesh-clickhouse mesh-neo4j *> $null
    $pausadas = $true
    Ok "ClickHouse y Neo4j pausados; se reactivan al terminar"
} else {
    Paso "Comprobando que el backend este arriba"
    $vivo = try { (Invoke-WebRequest 'http://localhost:3000/productos?limite=1' -UseBasicParsing -TimeoutSec 20).StatusCode -eq 200 } catch { $false }
    if (-not $vivo) {
        Mal "El backend no contesta en el 3000. Levantalo primero (en el panel de comandos, Reiniciar el backend)."
        Salir-Demo 1
    }
    Ok "Backend real arriba en el 3000. La demo no lo para ni toca las bases."
}

# --- Tor en el pais elegido, con un circuito que de verdad salga de ahi ---
Paso "Levantando Tor con salida en '$Pais'"
Comprobar-SesionPais
if (-not (Levantar-Tor $Pais)) { Mal "Tor no arranco a tiempo."; Salir-Demo 1 }
$salida = Buscar-SalidaTor $Pais
if (-not $salida) { Mal "No consegui una salida en '$Pais'. Prueba otro pais."; Salir-Demo 1 }
$socks = $salida.Socks; $ipSalida = $salida.Ip
Ok "IP de salida: $ipSalida ($($Pais.ToUpper()))"

# --- solo con -ConCopia: la copia con trustProxy en el 3100 ---
$destino = 'http://127.0.0.1:3000'
if ($ConCopia) {
    Paso "Preparando la copia del backend con trustProxy"
    if (-not (Preparar-CopiaBackend $repo)) { Mal "No compilo la copia. Mira $MeshDemoTmp\build.log"; Salir-Demo 1 }
    Ok "Copia lista"
    Paso "Arrancando la copia en el puerto 3100 (para el backend normal)"
    $pCopia = Arrancar-CopiaBackend
    if (-not $pCopia) { Mal "La copia no respondio. Mira $MeshDemoTmp\backend.err"; Arrancar-BackendNormal $repo | Out-Null; Salir-Demo 1 }
    Ok "Copia respondiendo en 3100"
    $destino = 'http://127.0.0.1:3100'
}

# --- tunel rapido al backend ---
Paso "Abriendo el tunel"
$tun = Abrir-Tunel $destino '/productos?limite=1' 'tunel'
if (-not $tun) { Mal "El tunel no levanto. Mira $MeshDemoTmp\tunel.err"; Salir-Demo 1 }
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

# Si el backend que corre es de antes del trustProxy, registra 127.0.0.1 para todo y
# la demo no demuestra nada. Se dice tal cual en vez de dar por buena una alerta
# de "127.0.0.1".
if ($ipsVistas | Where-Object { $_ -in @('127.0.0.1', '::1', '::ffff:127.0.0.1') }) {
    Mal "El backend registro la IP 127.0.0.1: el que esta corriendo es de antes del trustProxy."
    Mal "Reinicialo (panel de comandos, Reiniciar el backend) y vuelve a correr la demo, o usa -ConCopia."
    Salir-Demo 1
}

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
    Salir-Demo 1
}
$ipSalida = $ipsVistas -join ', '
Ok "8 intentos con 4 correos distintos (respuestas del backend: $(($codigos | Select-Object -Unique) -join ','))"
Ok "El backend los registro con la IP $ipSalida"
Ok "Alertas: $alertas"

# --- el link para entrar TU MISMO desde ese pais ---
# Tor sigue vivo (es el mismo de los intentos): se le pone el link con el nombre del pais
# (mesh-singapur.ledkid.com) y se deja abierto para que inicies sesion tu, desde el navegador
# que quieras. Se cierra con .\demo-entrar-otro-pais.ps1 -Cerrar o con su boton del panel.
# Con la sesion guardada, Limpiar-Demo ya no quita ese Tor.
$enlace = $null
if (-not $ConCopia) {
    Paso "El link de $($TituloPais[$Pais]), para entrar tu mismo"
    $enlace = Abrir-EnlacePais $Pais
    if ($enlace) {
        Ok "Listo: $enlace"
        New-Item -ItemType Directory -Force $MeshDemoTmp | Out-Null
        @{ pais = $Pais; url = $enlace; tunelPid = $null; ip = $ipSalida; enlace = $enlace; desde = (Get-Date -Format 's') } |
            ConvertTo-Json | Set-Content (Join-Path $MeshDemoTmp 'entrar-pais.json') -Encoding ascii
    } else {
        Write-Host "   Sin link por pais; la demo termina como siempre." -ForegroundColor Yellow
    }
}

# --- cerrar el tunel de los intentos ---
Paso "Cerrando el tunel de los intentos"
Limpiar-Demo
Ok $(if ($ConCopia) { "Backend normal arriba en 3000; ClickHouse y Neo4j reactivandose" } else { "Listo. El backend, ClickHouse y Neo4j no se tocaron" })

Write-Host "`n=============================================================="
Write-Host " LISTO. La alerta de $($Pais.ToUpper()) ($ipSalida) ya esta en el panel." -ForegroundColor Green
Write-Host " Abre este link y entra como admin@mesh.com / Admin123:"
Write-Host "   http://localhost:5173/panel?s=fraude" -ForegroundColor Yellow
Write-Host ""
if ($enlace) {
    Write-Host " Ahora entra TU MISMO desde $($TituloPais[$Pais]). Abre este link en CUALQUIER navegador (tambien el celular):" -ForegroundColor Green
    Write-Host "   $enlace/entrar" -ForegroundColor Yellow
    Write-Host " Quien lo abra aparece en $($TituloPais[$Pais]) para la tienda, y su login queda con esa IP. Va mas lento: sale por Tor."
    Write-Host " Para cerrar el link:   .\demo-entrar-otro-pais.ps1 -Cerrar" -ForegroundColor Yellow
    Write-Host ""
}
Write-Host " Para borrar la alerta de demostracion cuando termines:"
Write-Host "   .\demo-fraude-pais.ps1 -Limpiar" -ForegroundColor Yellow
Write-Host "=============================================================="
