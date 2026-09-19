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
# NO CUBRE viaje_imposible, ip_rotacion_cuenta ni toma_cuenta: las tres
# necesitan que el intento venga de una IP distinta a la anterior (o, en
# toma_cuenta, una IP que la cuenta nunca uso), y desde esta maquina el
# origen es siempre el mismo. Para esas esta .\demo-fraude-pais.ps1, con Tor
# de verdad.
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
    [ValidateSet('fuerza_bruta_cuenta', 'fuerza_bruta_ip', 'multi_cuenta_ip')]
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
    [string]$Frontend = 'http://localhost:5173'
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
function Intentar-Login([string]$identificador, [string]$contrasena) {
    $cuerpo = @{ identificador = $identificador; contrasena = $contrasena } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
            -Body $cuerpo -TimeoutSec 10 | Out-Null
        return 200
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

# ------------------------------------------------------------
# La alerta recien creada, leida directo de PostgreSQL -- mas rapido y mas
# confiable que loguearse como admin solo para leer una tabla.
# ------------------------------------------------------------
function Ver-UltimaAlerta([string]$tipoAlerta, [string]$clave) {
    $sql = "SELECT contador, detalle::text, to_char(fecha_creacion, 'HH24:MI:SS') " +
           "FROM alerta_fraude af JOIN tipo_alerta_fraude t USING (id_tipo_alerta_fraude) " +
           "WHERE t.tipo_alerta_fraude_nombre = '$tipoAlerta' AND af.clave = '$clave' " +
           "ORDER BY af.fecha_actualizacion DESC LIMIT 1"
    (docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -tAc $sql 2>$null) -join ''
}

Write-Host ""
Write-Host "=============================================================="
Write-Host " Disparando $Tipo -- son puras peticiones HTTP, no toca nada" -ForegroundColor Yellow
Write-Host " tuyo. Puedes seguir trabajando mientras corre." -ForegroundColor Yellow
Write-Host "=============================================================="

switch ($Tipo) {
    'fuerza_bruta_cuenta' {
        Paso "6 fallos contra $Cuenta (umbral 5, en 60s)"
        for ($i = 1; $i -le 6; $i++) {
            $codigo = Intentar-Login $Cuenta "clave-mala-$i"
            Write-Host "   intento $i de 6: $codigo" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 1
        $vista = Ver-UltimaAlerta 'fuerza_bruta_cuenta' $Cuenta
        if ($vista) { Ok "Alerta confirmada en Postgres: $vista" } else { Mal "No aparecio la alerta -- revisa que $Cuenta exista." }
    }

    'fuerza_bruta_ip' {
        Paso "8 fallos repartidos en 2 identificadores (umbral 8, en 60s)"
        $identificadorB = 'demo.fuerza.ip@mesh.test'
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
        # IPv6, ::ffff:127.0.0.1, segun como Node vea el socket).
        $sql = "SELECT clave, contador, to_char(fecha_creacion, 'HH24:MI:SS') " +
               "FROM alerta_fraude af JOIN tipo_alerta_fraude t USING (id_tipo_alerta_fraude) " +
               "WHERE t.tipo_alerta_fraude_nombre = 'fuerza_bruta_ip' " +
               "ORDER BY af.fecha_actualizacion DESC LIMIT 1"
        $vista = (docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -tAc $sql 2>$null) -join ''
        if ($vista) { Ok "Alerta confirmada en Postgres: $vista" } else { Mal "No aparecio la alerta." }
    }

    'multi_cuenta_ip' {
        $unicas = $Cuentas | Select-Object -Unique
        if ($unicas.Count -lt 4) {
            Mal "multi_cuenta_ip pide 4 cuentas distintas y solo hay $($unicas.Count) en -Cuentas."
            exit 1
        }
        Paso "1 fallo cada una, con $($unicas.Count) cuentas distintas (umbral 4, en 300s)"
        foreach ($id in $unicas) {
            $codigo = Intentar-Login $id 'clave-mala'
            Write-Host "   probado: $id -- $codigo" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 1
        # La clave de multi_cuenta_ip es la IP, igual que fuerza_bruta_ip.
        $sql = "SELECT clave, detalle::text, to_char(fecha_creacion, 'HH24:MI:SS') " +
               "FROM alerta_fraude af JOIN tipo_alerta_fraude t USING (id_tipo_alerta_fraude) " +
               "WHERE t.tipo_alerta_fraude_nombre = 'multi_cuenta_ip' " +
               "ORDER BY af.fecha_actualizacion DESC LIMIT 1"
        $vista = (docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -tAc $sql 2>$null) -join ''
        if ($vista) { Ok "Alerta confirmada en Postgres: $vista" } else { Mal "No aparecio la alerta." }
    }
}

# ------------------------------------------------------------
# El resultado, en el navegador
# ------------------------------------------------------------
Paso "Abriendo el panel de fraude"
Start-Process "$Frontend/panel?s=fraude"

Write-Host ""
Write-Host "=============================================================="
Write-Host " LISTO. Entra como admin@mesh.com / Admin123 y mira 'Fraude'." -ForegroundColor Green
Write-Host "=============================================================="
