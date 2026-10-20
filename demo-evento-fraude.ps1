# demo-evento-fraude.ps1
# Version RAPIDA y CONFIABLE de demo-fraude-login.ps1, para clase: sin
# ventanas que escriben solas (SendKeys), solo peticiones HTTP directas --
# no hay foco que perder ni aviso de Windows que la interrumpa a medio
# camino. Dispara UNA sola senal por corrida, la que elijas con -Tipo, y
# termina abriendo el panel para verla.
#
#   .\demo-evento-fraude.ps1 -Tipo fuerza_bruta_cuenta -Cuenta ventas.norte@mesh.com
#   .\demo-evento-fraude.ps1 -Tipo fuerza_bruta_ip     -Cuenta ventas.norte@mesh.com
#   .\demo-evento-fraude.ps1 -Tipo multi_cuenta_ip
#   .\demo-evento-fraude.ps1 -Tipo ip_rotacion_cuenta
#   .\demo-evento-fraude.ps1 -Tipo toma_cuenta
#   .\demo-evento-fraude.ps1 -Tipo viaje_imposible
#   .\demo-evento-fraude.ps1 -Tipo fuerza_bruta_cuenta_lenta
#   .\demo-evento-fraude.ps1 -Tipo multi_cuenta_ip_lenta
#   .\demo-evento-fraude.ps1 -Tipo ip_rotacion_cuenta_lenta
#   .\demo-evento-fraude.ps1 -Tipo granja_de_registros
#   .\demo-evento-fraude.ps1 -Tipo toma_cuenta -SinAbrir     sin abrir el panel al final
#
# CADA TIPO DISPARA SOLO ESE, A PROPOSITO -- asi el enunciado que ensenas en
# clase coincide exactamente con la alerta que aparece:
#
#   fuerza_bruta_cuenta   6 fallos contra LA MISMA cuenta (umbral 5, sin
#                         llegar al 8 de fuerza_bruta_ip)
#   fuerza_bruta_ip       8 fallos repartidos en 2 identificadores de 4 cada
#                         uno (llega a los 8 de la IP sin que ninguno de los
#                         dos cruce el 5 de fuerza_bruta_cuenta, y sin pasar
#                         de 4 identificadores distintos)
#   multi_cuenta_ip       4 CUENTAS REALES distintas, un fallo cada una
#                         (umbral 4, ninguna repite lo suficiente para
#                         fuerza_bruta_cuenta)
#
#   ip_rotacion_cuenta    4 fallos contra demo.rotacion@mesh.com (la crea
#                         si no esta), cada uno desde una IP distinta de
#                         Guatemala (umbral 4 IPs en 300s; 4 fallos no llegan
#                         al 5 de fuerza_bruta_cuenta). Una cuenta propia y
#                         siempre las mismas 4 IPs: una cuenta que ya entro
#                         desde otra IP hoy llega a las 5 de la lenta
#   toma_cuenta           la cuenta demo.toma@mesh.com (la crea si no esta)
#                         entra 3 veces desde "su casa" y despues desde una IP
#                         que nunca uso, tambien en Guatemala (pide 3 logins
#                         buenos antes; misma ciudad, asi que no es viaje)
#   viaje_imposible       la cuenta demo.viaje@mesh.com entra desde Guatemala
#                         y un momento despues desde Tokio (mas de 800 km/h)
#
# LAS IPS DE OTRO LADO. El backend lee la IP de la cabecera X-Forwarded-For
# cuando la peticion viene de esta misma maquina (trustProxy 'loopback' en
# backend/src/main.ts, es lo que usa el proxy de Vite y el tunel), asi que
# cada intento dice desde que IP viene y geoip-lite la ubica igual que una
# real. Son IPs publicas de verdad (de Guatemala, Tokio, Berlin, Sao Paulo);
# no se les manda nada, solo se escriben en la cabecera. demo-fraude-pais.ps1
# hace lo mismo con Tor, saliendo de verdad por otro pais.
#
# LAS LENTAS miran las ultimas 24 horas en Elasticsearch, con umbrales que a
# proposito no se cruzan en 5 minutos (15 fallos, 8 cuentas o 5 IPs). Para no
# esperar un dia, la demo escribe primero en Mongo el historial de las horas
# anteriores (eventos_autenticacion, repartidos en las ultimas 20 horas, con
# user_agent 'demo-evento-fraude (historial)' para reconocerlos), igual que
# los escribe el backend, y despues hace EN VIVO el intento que cruza el
# umbral; el backend lo revisa en el momento (evaluarInmediato):
#
#   fuerza_bruta_cuenta_lenta  13 fallos de hace horas contra -Cuenta desde
#                              una IP, y 2 en vivo (umbral 15; 2 no llegan al
#                              5 de la rapida)
#   multi_cuenta_ip_lenta      7 identificadores probados desde una IP de
#                              Sao Paulo hace horas, y el 8vo en vivo
#                              (umbral 8)
#   ip_rotacion_cuenta_lenta   4 IPs distintas contra compradora.norte hace
#                              horas, y la 5ta en vivo desde Tokio (umbral 5)
#   granja_de_registros        5 cuentas nuevas desde la misma IP en un
#                              minuto (umbral 5 en 60 minutos). Esta no se
#                              revisa al registrarse: la demo corre el
#                              detector una vez (pruebas/correr_detectores_fraude.cjs
#                              login), que es lo que haria el reloj de 15 min
#
# Para el espectaculo visual (ventanas que escriben solas, para una
# demostracion mas teatral) esta .\demo-fraude-login.ps1 -- pero esta version
# es la que hay que usar si el tiempo de clase es corto y no puede fallar.
#
# OJO SI CORRES VARIOS TIPOS SEGUIDOS: multi_cuenta_ip cuenta identificadores
# DISTINTOS probados desde la IP en los ultimos 5 minutos, en Redis, y ese
# contador no sabe que "demo" los mando -- se ACUMULAN. Medido: correr
# fuerza_bruta_ip (2 identificadores nuevos) menos de 5 minutos despues de
# multi_cuenta_ip (4 identificadores) hizo que multi_cuenta_ip volviera a
# dispararse solo, con los 6 identificadores juntos. No es un bug de este
# script -- es la senal funcionando como deberia -- pero si quieres que cada
# corrida se vea aislada en el panel, espera 5 minutos entre una y otra.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('fuerza_bruta_cuenta', 'fuerza_bruta_ip', 'multi_cuenta_ip',
                 'ip_rotacion_cuenta', 'toma_cuenta', 'viaje_imposible',
                 'fuerza_bruta_cuenta_lenta', 'multi_cuenta_ip_lenta', 'ip_rotacion_cuenta_lenta',
                 'granja_de_registros')]
    [string]$Tipo,

    # Para fuerza_bruta_cuenta y fuerza_bruta_ip: la cuenta objetivo.
    [string]$Cuenta = 'ventas.norte@mesh.com',

    # Para multi_cuenta_ip: 4 o mas cuentas REALES distintas -- reales para
    # que la alerta traiga cuentas_afectadas de verdad (un identificador que
    # no existe cuenta para el umbral pero no genera notificacion).
    [string[]]$Cuentas = @(
        'ventas.norte@mesh.com',
        'compradora.norte@mesh.com',
        'comprador.sur@mesh.com',
        'admin@mesh.com'
    ),

    [string]$Backend = 'http://localhost:3000',
    [string]$Frontend = 'http://localhost:5173',

    # No abre el panel al final (para correrla desde otra prueba).
    [switch]$SinAbrir
)

function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

# ------------------------------------------------------------
# Comprobaciones antes de tocar nada
# ------------------------------------------------------------
Paso "Revisando que Mesh este arriba"
docker ps *> $null
if ($LASTEXITCODE -ne 0) { Mal "Docker no responde. Abre Docker Desktop y corre .\arrancar.ps1"; exit 1 }
if (-not (docker ps --format '{{.Names}}' | Select-String -Quiet 'mesh-postgres')) {
    Mal "Los contenedores de Mesh no estan arriba. Corre primero: .\arrancar.ps1"; exit 1
}
try { Invoke-RestMethod -Uri "$Backend/db" -TimeoutSec 5 -UseBasicParsing *> $null }
catch { Mal "El backend no contesta en $Backend. Corre: cd backend ; npm run start:dev"; exit 1 }
Ok "Docker, los contenedores y el backend estan arriba"

# --- credenciales de PostgreSQL, del .env de la raiz (para verificar al final) ---
$env_ = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}

# ------------------------------------------------------------
# Un intento de login, sin lanzar: PowerShell 5.1 hace que
# Invoke-RestMethod LANCE en cualquier respuesta que no sea 2xx (aqui todos
# los intentos son fallidos a proposito, o sea 401 siempre), asi que el
# codigo de verdad sale de la excepcion, no del try.
# ------------------------------------------------------------
function Intentar-Login([string]$identificador, [string]$contrasena, [string]$ip = '') {
    $cuerpo = @{ identificador = $identificador; contrasena = $contrasena } | ConvertTo-Json
    # Con -ip, el intento dice venir de esa IP (ver LAS IPS DE OTRO LADO arriba).
    $cabeceras = @{}
    if ($ip) { $cabeceras['X-Forwarded-For'] = $ip }
    try {
        Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
            -Headers $cabeceras -Body $cuerpo -TimeoutSec 10 | Out-Null
        return 200
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

# Una cuenta nueva, registrada desde esa IP. 201 si nacio, 409 si ya estaba.
function Registrar-Cuenta([string]$correo, [string]$ip) {
    $usuario = ($correo.Split('@')[0]) -replace '[^A-Za-z0-9]', '_'
    $cuerpo = @{ correo_electronico = $correo; usuario = $usuario; nombre = 'Demo'; apellido = 'Fraude'; contrasena = 'Comprador123!' } | ConvertTo-Json
    $cabeceras = @{}
    if ($ip) { $cabeceras['X-Forwarded-For'] = $ip }
    try {
        Invoke-RestMethod -Method Post -Uri "$Backend/usuario/registro" -ContentType 'application/json' `
            -Headers $cabeceras -Body $cuerpo -TimeoutSec 10 | Out-Null
        return 201
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

# El historial de las horas anteriores, para las senales lentas: intentos
# fallidos escritos en Mongo como los escribe el backend (LogService), con
# pendiente_elastic para que el worker los pase a Elasticsearch. $intentos es
# una lista de @{ identificador; ip; idUsuario }; se reparten en las ultimas
# 20 horas, el mas viejo primero.
function Escribir-Historial($intentos) {
    $docs = @()
    $n = @($intentos).Count
    for ($i = 0; $i -lt $n; $i++) {
        $x = @($intentos)[$i]
        $horas = 20 - [math]::Floor(19 * $i / [math]::Max($n - 1, 1))
        $idUsuario = if ($x.idUsuario) { "'$($x.idUsuario)'" } else { 'null' }
        $motivo = if ($x.idUsuario) { 'credenciales_invalidas' } else { 'usuario_inexistente' }
        $docs += "{ tipo: 'login', resultado: 'fallo', motivo: '$motivo', id_usuario: $idUsuario, " +
                 "identificador_intentado: '$($x.identificador)', ip: '$($x.ip)', " +
                 "user_agent: 'demo-evento-fraude (historial)', huella_cliente: null, geo: null, " +
                 "fecha: new Date(Date.now() - $horas * 3600 * 1000 - $i * 60000), pendiente_elastic: true }"
    }
    $js = "const r = db.eventos_autenticacion.insertMany([`n" + ($docs -join ",`n") + "`n]);`nprint('historial: ' + Object.keys(r.insertedIds).length + ' eventos');`n"
    $archivo = Join-Path $env:TEMP 'demo-evento-fraude-historial.js'
    [System.IO.File]::WriteAllText($archivo, $js, (New-Object System.Text.UTF8Encoding($false)))
    docker cp "$archivo" "mesh-mongo:/tmp/demo-evento-fraude-historial.js" 2>&1 | Out-Null
    $salida = docker exec mesh-mongo sh -c 'mongosh --quiet -u $MONGO_INITDB_ROOT_USERNAME -p $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin $MONGO_INITDB_DATABASE /tmp/demo-evento-fraude-historial.js' 2>&1
    Remove-Item $archivo -ErrorAction SilentlyContinue
    Write-Host "   $(($salida | Out-String).Trim())" -ForegroundColor DarkGray
    # El worker los pasa a Elasticsearch cada 5 s; el intento en vivo tambien
    # sincroniza antes de revisar, pero se le da su tiempo.
    Start-Sleep -Seconds 6
}

# Las IPs de la demo. Ver LAS IPS DE OTRO LADO arriba.
$IpCasa      = '200.6.193.1'       # Guatemala, la de siempre de demo.toma
$IpGuatemala = '190.106.200.1'     # Guatemala, la primera de demo.viaje
$IpTokio     = '133.242.1.1'       # Tokio
$IpSaoPaulo  = '177.71.1.1'        # Brasil

# ------------------------------------------------------------
# La senal, leida directo de PostgreSQL -- mas rapido y mas confiable que
# loguearse como admin solo para leer una tabla.
#
# Desde el refactor de fraude (migraciones 031 a 033) el login ya no escribe
# en la tabla vieja de alertas: cada (tipo, clave) es UNA fila de senal_fraude,
# y cada vez que el detector la vuelve a ver suma 1 a total_detecciones.
# ultima_deteccion es el inicio de la ventana (truncada al minuto), asi que no
# sirve para saber si la senal salio de ESTA corrida. Lo que si sirve es el
# total: se cuenta antes de disparar y se compara despues.
# ------------------------------------------------------------
function Psql([string]$sql) {
    (docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -tAc $sql 2>$null) -join ''
}

function Filtro-Senal([string]$tipo, [string]$clave) {
    $f = "t.tipo_senal_fraude_nombre = '$tipo'"
    if ($clave) { $f += " AND s.clave = '$clave'" }
    $f
}

function Detecciones([string]$tipo, [string]$clave) {
    $n = Psql ("SELECT coalesce(sum(s.total_detecciones), 0) FROM senal_fraude s " +
               "JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude) WHERE " + (Filtro-Senal $tipo $clave))
    if ($n -match '^\d+$') { [int]$n } else { -1 }
}

# Si el total subio desde $antes, la senal con su clave, sus detecciones, sus
# cuentas y su detalle. Si no subio, vacio.
function Ver-Senal([string]$tipo, [string]$clave, [int]$antes) {
    $despues = Detecciones $tipo $clave
    if ($despues -le $antes) { return '' }
    Psql ("SELECT 'clave ' || s.clave || ', ' || s.total_detecciones || ' deteccion(es), ' || " +
          "(SELECT count(*) FROM senal_fraude_cuenta c WHERE c.id_senal_fraude = s.id_senal_fraude) || ' cuenta(s), ' || " +
          "s.detalle::text FROM senal_fraude s JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude) " +
          "WHERE " + (Filtro-Senal $tipo $clave) + " ORDER BY s.ultima_deteccion DESC, s.id_senal_fraude DESC LIMIT 1")
}

Write-Host ""
Write-Host "=============================================================="
if ($Tipo -like '*_lenta') {
    Write-Host " Disparando $Tipo -- escribe el historial en Mongo y despues" -ForegroundColor Yellow
    Write-Host " son peticiones HTTP. Puedes seguir trabajando mientras corre." -ForegroundColor Yellow
} else {
    Write-Host " Disparando $Tipo -- son puras peticiones HTTP, no toca nada" -ForegroundColor Yellow
    Write-Host " tuyo. Puedes seguir trabajando mientras corre." -ForegroundColor Yellow
}
Write-Host "=============================================================="

switch ($Tipo) {
    'fuerza_bruta_cuenta' {
        Paso "6 fallos contra $Cuenta (umbral 5, en 60s)"
        $antes = Detecciones 'fuerza_bruta_cuenta' $Cuenta
        for ($i = 1; $i -le 6; $i++) {
            $codigo = Intentar-Login $Cuenta "clave-mala-$i"
            Write-Host "   intento $i de 6: $codigo" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 1
        $vista = Ver-Senal 'fuerza_bruta_cuenta' $Cuenta $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal -- revisa que $Cuenta exista." }
    }

    'fuerza_bruta_ip' {
        Paso "8 fallos repartidos en 2 identificadores (umbral 8, en 60s)"
        $identificadorB = 'demo.fuerza.ip@mesh.test'
        $antes = Detecciones 'fuerza_bruta_ip' ''
        for ($i = 1; $i -le 4; $i++) {
            $codigo = Intentar-Login $Cuenta "clave-mala-a-$i"
            Write-Host "   $Cuenta -- intento $i de 4: $codigo" -ForegroundColor DarkGray
        }
        for ($i = 1; $i -le 4; $i++) {
            $codigo = Intentar-Login $identificadorB "clave-mala-b-$i"
            Write-Host "   $identificadorB -- intento $i de 4: $codigo" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 1
        # fuerza_bruta_ip no guarda el identificador como clave -- guarda la
        # IP de origen, que en esta maquina siempre es 127.0.0.1 (o su forma
        # IPv6, ::ffff:127.0.0.1, segun como Node vea el socket). Por eso se
        # cuenta sobre todas las senales del tipo.
        $vista = Ver-Senal 'fuerza_bruta_ip' '' $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal." }
    }

    'multi_cuenta_ip' {
        $unicas = $Cuentas | Select-Object -Unique
        if ($unicas.Count -lt 4) {
            Mal "multi_cuenta_ip pide 4 cuentas distintas y solo hay $($unicas.Count) en -Cuentas."
            exit 1
        }
        Paso "1 fallo cada una, con $($unicas.Count) cuentas distintas (umbral 4, en 300s)"
        $antes = Detecciones 'multi_cuenta_ip' ''
        foreach ($id in $unicas) {
            $codigo = Intentar-Login $id 'clave-mala'
            Write-Host "   probado: $id -- $codigo" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 1
        # La clave de multi_cuenta_ip es la IP, igual que fuerza_bruta_ip.
        $vista = Ver-Senal 'multi_cuenta_ip' '' $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal." }
    }

    'ip_rotacion_cuenta' {
        $correo = 'demo.rotacion@mesh.com'
        $ips = @('200.119.160.1', '181.174.100.1', '190.56.1.1', '190.56.80.10')
        $codigo = Registrar-Cuenta $correo $ips[0]
        if ($codigo -eq 201) { Ok "Cuenta $correo creada (Comprador123!)" }
        Paso "4 fallos contra $correo, cada uno desde una IP distinta (umbral 4 IPs, en 300s)"
        $antes = Detecciones 'ip_rotacion_cuenta' $correo
        foreach ($ip in $ips) {
            $codigo = Intentar-Login $correo 'clave-mala' $ip
            Write-Host "   desde $ip -- $codigo" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 1
        $vista = Ver-Senal 'ip_rotacion_cuenta' $correo $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal." }
    }

    'toma_cuenta' {
        $correo = 'demo.toma@mesh.com'
        Paso "La cuenta $correo entra 3 veces desde su casa ($IpCasa)"
        $codigo = Registrar-Cuenta $correo $IpCasa
        if ($codigo -eq 201) { Ok "Cuenta creada (Comprador123!)" }
        for ($i = 1; $i -le 3; $i++) {
            $codigo = Intentar-Login $correo 'Comprador123!' $IpCasa
            Write-Host "   login $i desde $IpCasa -- $codigo" -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
        }
        if ($codigo -ne 200) { Mal "La cuenta no pudo entrar ($codigo)."; exit 1 }
        Start-Sleep -Seconds 3
        # Una IP que nunca uso: la ultima cifra cambia en cada corrida.
        $ipNueva = "181.209.180.$(Get-Random -Minimum 2 -Maximum 250)"
        Paso "Y ahora entra desde una IP que nunca uso ($ipNueva, tambien en Guatemala)"
        $antes = Detecciones 'toma_cuenta' $correo
        $codigo = Intentar-Login $correo 'Comprador123!' $ipNueva
        Write-Host "   login desde $ipNueva -- $codigo" -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
        $vista = Ver-Senal 'toma_cuenta' $correo $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal." }
    }

    'viaje_imposible' {
        $correo = 'demo.viaje@mesh.com'
        Paso "La cuenta $correo entra desde Guatemala ($IpGuatemala)"
        $codigo = Registrar-Cuenta $correo $IpGuatemala
        if ($codigo -eq 201) { Ok "Cuenta creada (Comprador123!)" }
        $codigo = Intentar-Login $correo 'Comprador123!' $IpGuatemala
        Write-Host "   login desde $IpGuatemala -- $codigo" -ForegroundColor DarkGray
        if ($codigo -ne 200) { Mal "La cuenta no pudo entrar ($codigo)."; exit 1 }
        Start-Sleep -Seconds 4
        Paso "Y unos segundos despues, desde Tokio ($IpTokio): unos 13 000 km"
        $antes = Detecciones 'viaje_imposible' ''
        $codigo = Intentar-Login $correo 'Comprador123!' $IpTokio
        Write-Host "   login desde $IpTokio -- $codigo" -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
        $vista = Ver-Senal 'viaje_imposible' '' $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal." }
    }

    'fuerza_bruta_cuenta_lenta' {
        $ip = '190.56.80.10'
        $idUsuario = Psql "SELECT id_usuario FROM usuarios WHERE correo_electronico = '$Cuenta'"
        if (-not $idUsuario) { Mal "No existe la cuenta $Cuenta."; exit 1 }
        Paso "El historial: 13 fallos contra $Cuenta desde $ip, repartidos en las ultimas 20 horas"
        Escribir-Historial (1..13 | ForEach-Object { @{ identificador = $Cuenta; ip = $ip; idUsuario = $idUsuario } })
        Paso "Y 2 fallos mas, en vivo (umbral 15 en 24 horas)"
        $antes = Detecciones 'fuerza_bruta_cuenta_lenta' ''
        for ($i = 1; $i -le 2; $i++) {
            $codigo = Intentar-Login $Cuenta "clave-mala-$i" $ip
            Write-Host "   intento $i de 2: $codigo" -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
        }
        Start-Sleep -Seconds 4
        $vista = Ver-Senal 'fuerza_bruta_cuenta_lenta' '' $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal." }
    }

    'multi_cuenta_ip_lenta' {
        $sello = Get-Date -Format 'HHmmss'
        Paso "El historial: 7 identificadores probados desde $IpSaoPaulo en las ultimas 20 horas"
        Escribir-Historial (1..7 | ForEach-Object { @{ identificador = "cliente$_.$sello@correo.test"; ip = $IpSaoPaulo; idUsuario = $null } })
        Paso "Y el 8vo, en vivo (umbral 8 en 24 horas)"
        $antes = Detecciones 'multi_cuenta_ip_lenta' ''
        $codigo = Intentar-Login "cliente8.$sello@correo.test" 'clave-mala' $IpSaoPaulo
        Write-Host "   cliente8.$sello@correo.test desde $IpSaoPaulo -- $codigo" -ForegroundColor DarkGray
        Start-Sleep -Seconds 4
        $vista = Ver-Senal 'multi_cuenta_ip_lenta' '' $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal." }
    }

    'ip_rotacion_cuenta_lenta' {
        $victima = 'compradora.norte@mesh.com'
        $idUsuario = Psql "SELECT id_usuario FROM usuarios WHERE correo_electronico = '$victima'"
        if (-not $idUsuario) { Mal "No existe la cuenta $victima."; exit 1 }
        $ips = @('186.151.1.1', '8.8.8.8', '85.214.1.1', '41.208.1.1')
        Paso "El historial: $victima probada desde 4 IPs (Guatemala, Estados Unidos, Alemania, Sudafrica) en las ultimas 20 horas"
        Escribir-Historial ($ips | ForEach-Object { @{ identificador = $victima; ip = $_; idUsuario = $idUsuario } })
        Paso "Y la 5ta, en vivo desde Tokio ($IpTokio) (umbral 5 IPs en 24 horas)"
        $antes = Detecciones 'ip_rotacion_cuenta_lenta' ''
        $codigo = Intentar-Login $victima 'clave-mala' $IpTokio
        Write-Host "   desde $IpTokio -- $codigo" -ForegroundColor DarkGray
        Start-Sleep -Seconds 4
        $vista = Ver-Senal 'ip_rotacion_cuenta_lenta' '' $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal." }
    }

    'granja_de_registros' {
        $ip = '41.208.1.7'
        $sello = Get-Date -Format 'MMddHHmmss'
        Paso "5 cuentas nuevas desde la misma IP ($ip), una tras otra (umbral 5 en 60 minutos)"
        $antes = Detecciones 'granja_de_registros' ''
        for ($i = 1; $i -le 5; $i++) {
            $correo = "granja$i.$sello@mesh.com"
            $codigo = Registrar-Cuenta $correo $ip
            Write-Host "   $correo -- $codigo" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 6
        Paso "Corriendo el detector una vez (el reloj del backend es de 15 minutos)"
        node (Join-Path $PSScriptRoot 'pruebas\correr_detectores_fraude.cjs') login 2>&1 |
            Select-String -Pattern 'OK|FALLA' | ForEach-Object { Write-Host "   $($_.Line.Trim())" -ForegroundColor DarkGray }
        $vista = Ver-Senal 'granja_de_registros' '' $antes
        if ($vista) { Ok "Senal confirmada en Postgres: $vista" } else { Mal "No aparecio la senal." }
    }
}

# ------------------------------------------------------------
# El resultado, en el navegador
# ------------------------------------------------------------
if (-not $SinAbrir) {
    Paso "Abriendo el panel de fraude"
    Start-Process "$Frontend/panel?s=fraude"
}

Write-Host ""
Write-Host "=============================================================="
Write-Host " LISTO. Entra como admin@mesh.com / Admin123 y mira 'Fraude'." -ForegroundColor Green
Write-Host "=============================================================="
