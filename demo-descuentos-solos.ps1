# demo-descuentos-solos.ps1
# Descuentos que se activan y se apagan solos, en vivo y por el backend.
#
#   .\demo-descuentos-solos.ps1               las dos partes
#   .\demo-descuentos-solos.ps1 -Parte regla  solo la regla por ventas
#   .\demo-descuentos-solos.ps1 -Parte manual solo el descuento que vence
#   .\demo-descuentos-solos.ps1 -Duracion 30  el descuento manual dura 30 s (30 a 60)
#
# QUE ENSENA
# ==================================================
#   1. Regla automatica. Una oferta nueva con una regla "si vende 3 unidades en
#      2 minutos, 15 por ciento por 150 segundos". Un comprador nuevo hace tres
#      compras reales. Cada compra llega a ClickHouse (compra_producto) y el
#      worker de reglas (DisparadorReglasAutomaticoService, cada 60 s) cuenta
#      las unidades, cruza el umbral y aplica el descuento. La duracion (150 s)
#      es mayor que la ventana (2 min) para que no parpadee (ver
#      backend/cambio_propuestas/2026-09-25_0700-disparador-reglas-automatico.md).
#   2. Descuento manual con vencimiento. Otra oferta nueva recibe un 20 por
#      ciento por 45 segundos (POST /vendedor/ofertas/:id/descuento con
#      duracion_segundos). La llave mesh:oferta:<n>:descuento de Redis cuenta
#      hacia atras; cuando vence, el worker de vencidos (cada 60 s) quita el
#      descuento y precio_historial lo registra a nombre de tienda@mesh.com.
#
# Las dos ofertas son de una cuenta vendedora nueva de cada corrida, asi que
# nunca chocan con otro mecanismo de descuento (la exclusion entre regla,
# periodo y manual) ni con una oferta real.
#
# LIMPIEZA AL TERMINAR, aunque falle a la mitad
#   - la regla se pausa por la API y se borra de PostgreSQL (el backend no
#     tiene ruta para borrar una regla; igual que pruebas/reglas_descuento.sh)
#   - los descuentos se apagan solos; si alguno sigue puesto se quita por la API
#   - las dos ofertas quedan retiradas por la API
#   - las ventas y los carritos del comprador se borran de ClickHouse
# LO QUE NO SE PUEDE LIMPIAR: las dos cuentas, los pedidos, pagos y kardex de
# PostgreSQL y las filas de precio_historial. Igual que en las otras demos.
#
# Redis, ClickHouse y PostgreSQL solo se LEEN para ensenar (TTL, historial);
# todo lo que cambia algo pasa por el backend, salvo la limpieza de arriba.

param(
    [ValidateSet('todo', 'regla', 'manual')]
    [string]$Parte = 'todo',

    [ValidateRange(30, 60)]
    [int]$Duracion = 45,

    [string]$Backend = 'http://localhost:3000'
)

function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Av($t)   { Write-Host "   $t" -ForegroundColor Yellow }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

$CONTRASENA = 'Desarrollo123!'
$PRODUCTOS = @(
    @{ id = 83; variante = 166; nombre = 'Cartas al puerto seco' },
    @{ id = 76; variante = 158; nombre = 'Cuerda de salto Relampago' }
)
$UMBRAL = 3; $VENTANA_MIN = 2; $DURACION_REGLA = 150; $PCT_REGLA = 15; $PCT_MANUAL = 20
$prefijo = 'desc' + (Get-Date -Format 'MMddHHmmss')

$env_ = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
$RP = $env_['REDIS_PASSWORD']
$PGU = if ($env_['DB_USER']) { $env_['DB_USER'] } else { 'meme' }
$PGB = if ($env_['DB_NAME']) { $env_['DB_NAME'] } else { 'mesh' }
# --database SIEMPRE: sin ella clickhouse-client entra a `default`, que tiene
# tablas con el mismo nombre y no son las que lee el backend (etl/cargar_compras.sh).
$CHB = if ($env_['CLICKHOUSE_DB']) { $env_['CLICKHOUSE_DB'] } else { 'mesh_eventos' }

function Redis { docker exec -e "REDISCLI_AUTH=$RP" mesh-redis redis-cli @args }
function Sql([string]$q) { (docker exec mesh-postgres psql -U $PGU -d $PGB -tAc $q 2>$null | Out-String).Trim() }
function Ch([string]$q) {
    docker exec mesh-clickhouse clickhouse-client --user $env_['CLICKHOUSE_USER'] --password $env_['CLICKHOUSE_PASSWORD'] --database $CHB -q $q 2>$null
}
function Cuerpo($obj) { $obj | ConvertTo-Json -Depth 6 -Compress }

function Llamar([string]$Metodo, [string]$Ruta, $Datos, $Sesion) {
    $a = @{ Method = $Metodo; Uri = "$Backend$Ruta"; ContentType = 'application/json'; TimeoutSec = 20; WebSession = $Sesion }
    if ($null -ne $Datos) { $a.Body = Cuerpo $Datos }
    try { return Invoke-RestMethod @a }
    catch {
        $c = 0; if ($_.Exception.Response) { $c = [int]$_.Exception.Response.StatusCode }
        throw "$Metodo $Ruta contesto $c $($_.ErrorDetails.Message)"
    }
}

function Entrar([string]$Correo, [string]$Clave) {
    $s = $null
    Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
        -Body (Cuerpo @{ identificador = $Correo; contrasena = $Clave }) -SessionVariable s -TimeoutSec 20 | Out-Null
    return $s
}

function NuevaCuenta([string]$Usuario, [bool]$Vendedor) {
    $correo = "$Usuario@mesh.com"
    Invoke-RestMethod -Method Post -Uri "$Backend/usuario/registro" -ContentType 'application/json' `
        -Body (Cuerpo @{ correo_electronico = $correo; usuario = $Usuario; nombre = 'Demo'; apellido = 'Descuentos'; contrasena = $CONTRASENA }) `
        -TimeoutSec 20 | Out-Null
    $s = Entrar $correo $CONTRASENA
    $yo = Invoke-RestMethod -Uri "$Backend/usuario/yo" -WebSession $s -TimeoutSec 20
    if ($Vendedor) {
        Llamar PATCH "/admin/usuarios/$($yo.payload.id_usuario)" @{ id_rol_usuario = 2 } $script:admin | Out-Null
        $s = Entrar $correo $CONTRASENA
    }
    return [pscustomobject]@{ Usuario = $Usuario; Correo = $correo; Sesion = $s; Id = $yo.payload.id_usuario }
}

function Oferta([int]$Id) {
    $r = Invoke-RestMethod -Uri "$Backend/vendedor/ofertas" -WebSession $script:vendedor.Sesion -TimeoutSec 20
    return $r.payload | Where-Object { [int]$_.id_oferta -eq $Id } | Select-Object -First 1
}

function Precio($o) {
    if ($o.porcentaje_descuento) { return "precio $($o.precio), con $([double]$o.porcentaje_descuento) por ciento queda en $($o.precio_final)" }
    return "precio $($o.precio), sin descuento"
}

# Espera hasta $Max segundos a que la oferta tenga (o deje de tener) descuento.
function EsperarDescuento([int]$Id, [bool]$Quiero, [int]$Max) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $Max) {
        $o = Oferta $Id
        if ([bool]$o.porcentaje_descuento -eq $Quiero) { return [int]((Get-Date) - $t0).TotalSeconds }
        Start-Sleep -Seconds 3
    }
    return -1
}

$ofertas = @(); $regla = $null; $fallos = 0

Paso 'Revisando que Mesh este arriba'
try { Invoke-RestMethod -Uri "$Backend/db" -TimeoutSec 5 -UseBasicParsing *> $null }
catch { Mal "El backend no contesta en $Backend"; exit 1 }
if (-not $RP) { Mal 'Falta REDIS_PASSWORD en el .env'; exit 1 }
$admin = Entrar 'admin@mesh.com' 'Admin123'
Ok 'Backend arriba, sesion de admin lista'

try {
    Paso 'Cuentas y ofertas nuevas para la demo'
    $vendedor = NuevaCuenta "${prefijo}v" $true
    Ok "vendedor $($vendedor.Correo)"
    $n = if ($Parte -eq 'todo') { 2 } else { 1 }
    for ($i = 0; $i -lt $n; $i++) {
        $p = $PRODUCTOS[$i]
        $r = Llamar POST '/vendedor/ofertas' @{ id_producto = $p.id; id_producto_variante = $p.variante; precio = '15.00'; stock_inicial = 20 } $vendedor.Sesion
        Llamar PATCH "/vendedor/ofertas/$($r.payload.id_oferta)/revision" @{ decision = 'aprobar' } $admin | Out-Null
        $ofertas += [pscustomobject]@{ Id = [int]$r.payload.id_oferta; Nombre = $p.nombre }
        Ok "oferta de $($p.nombre) publicada y aprobada, sin descuento"
    }

    # ------------------------------------------------------------------
    if ($Parte -in 'todo', 'regla') {
        $of = $ofertas[0]
        Paso "Parte 1. Regla automatica sobre $($of.Nombre)"
        $r = Llamar POST '/vendedor/reglas-descuento' @{
            id_oferta = $of.Id; umbral_unidades = $UMBRAL; ventana_minutos = $VENTANA_MIN
            es_venta_relampago = $false; duracion_segundos = $DURACION_REGLA; porcentaje_descuento = $PCT_REGLA
        } $vendedor.Sesion
        $regla = $r.payload.id_regla_descuento_automatico
        Ok "regla creada: $UMBRAL unidades en $VENTANA_MIN minutos dan $PCT_REGLA por ciento por $DURACION_REGLA s"

        $comprador = NuevaCuenta "${prefijo}c" $false
        Llamar POST '/direccion-usuario' @{ pais = 'Guatemala'; departamento = 'Guatemala'; ciudad = 'Guatemala'; direccion_exacta = 'Direccion de la demo de descuentos'; codigo_postal = '01001' } $comprador.Sesion | Out-Null
        $dir = (Invoke-RestMethod -Uri "$Backend/direccion-usuario" -WebSession $comprador.Sesion -TimeoutSec 20).payload[0].id_direccion
        for ($k = 1; $k -le $UMBRAL; $k++) {
            Llamar PUT "/carrito/lineas/$($of.Id)" @{ cantidad = 1 } $comprador.Sesion | Out-Null
            $c = Llamar POST '/carrito/comprar' @{ id_direccion = $dir; metodo_pago = 'efectivo contra entrega' } $comprador.Sesion
            if (-not $c.payload.comprado) { throw 'una compra no se completo' }
            Ok "compra $k de $UMBRAL hecha"
        }
        $vendidas = (Ch "SELECT sum(cantidad) FROM compra_producto WHERE id_oferta = $($of.Id) AND lote = 'real'" | Out-String).Trim()
        Ok "ClickHouse ya cuenta $vendidas unidades vendidas de esta oferta"

        Write-Host "   esperando al worker de reglas, corre cada 60 s..." -ForegroundColor DarkGray
        $s = EsperarDescuento $of.Id $true 90
        if ($s -ge 0) {
            Ok "descuento aplicado solo, a los $s s. $(Precio (Oferta $of.Id))"
        } else {
            Mal 'el worker no aplico el descuento en 90 s'; $fallos++
        }
        # Pausar no apaga el efecto ya puesto (el TTL manda), pero evita que
        # vuelva a dispararse mientras corre la demo.
        Llamar PATCH "/vendedor/reglas-descuento/$regla" @{ activa = $false } $vendedor.Sesion | Out-Null
        Ok "regla pausada. El descuento sigue hasta que venzan sus $DURACION_REGLA s"
    }

    # ------------------------------------------------------------------
    if ($Parte -in 'todo', 'manual') {
        $of = $ofertas[$ofertas.Count - 1]
        Paso "Parte 2. Descuento manual de $Duracion s sobre $($of.Nombre)"
        Llamar POST "/vendedor/ofertas/$($of.Id)/descuento" @{ porcentaje_descuento = $PCT_MANUAL; duracion_segundos = $Duracion } $vendedor.Sesion | Out-Null
        Ok "descuento puesto. $(Precio (Oferta $of.Id))"
        $llave = "mesh:oferta:$($of.Id):descuento"
        Ok "en Redis: $llave (buscala asi en RedisInsight, localhost:5540)"
        while ($true) {
            $ttl = [int]((Redis ttl $llave | Out-String).Trim())
            if ($ttl -lt 0) { Ok 'la llave vencio y Redis la borro'; break }
            Write-Host "   TTL $ttl s" -ForegroundColor Yellow
            Start-Sleep -Seconds ([Math]::Min(10, [Math]::Max(1, $ttl)))
        }
        Write-Host '   esperando al worker de vencidos, corre cada 60 s...' -ForegroundColor DarkGray
        $s = EsperarDescuento $of.Id $false 90
        if ($s -ge 0) {
            Ok "el worker quito el descuento a los $s s. $(Precio (Oferta $of.Id))"
            $quien = Sql "SELECT u.correo_electronico FROM precio_historial h JOIN usuarios u ON u.id_usuario = h.id_usuario_modifico WHERE h.id_oferta = $($of.Id) ORDER BY h.id_precio_historial DESC LIMIT 1"
            if ($quien -eq 'tienda@mesh.com') { Ok "precio_historial registra el cambio a nombre de $quien" }
            else { Mal "precio_historial registra el cambio a nombre de $quien"; $fallos++ }
        } else {
            Mal 'el worker no quito el descuento en 90 s'; $fallos++
        }
    }
} catch {
    Mal "La demo se detuvo: $_"
    $fallos++
} finally {
    Paso 'Limpiando'
    if ($regla) {
        try { Llamar PATCH "/vendedor/reglas-descuento/$regla" @{ activa = $false } $vendedor.Sesion | Out-Null } catch { }
        if (($Parte -in 'todo', 'regla') -and $ofertas.Count -gt 0) {
            Write-Host "   esperando a que el descuento de la regla venza solo, hasta $($DURACION_REGLA + 70) s..." -ForegroundColor DarkGray
            $s = EsperarDescuento $ofertas[0].Id $false ($DURACION_REGLA + 70)
            if ($s -ge 0) { Ok 'el descuento de la regla tambien se apago solo' }
        }
        Sql "DELETE FROM regla_descuento_automatico WHERE id_regla_descuento_automatico = $regla" | Out-Null
        Ok 'regla borrada'
    }
    foreach ($of in $ofertas) {
        $o = Oferta $of.Id
        if ($o -and $o.porcentaje_descuento) {
            try { Llamar DELETE "/vendedor/ofertas/$($of.Id)/descuento" $null $vendedor.Sesion | Out-Null; Av "descuento de $($of.Nombre) quitado a mano" } catch { Mal "$_" }
        }
        try { Llamar PATCH "/vendedor/ofertas/$($of.Id)" @{ estado = 'retirada' } $vendedor.Sesion | Out-Null } catch { Mal "$_" }
        $resto = @(Redis --scan --pattern "mesh:oferta:$($of.Id)*" | Where-Object { $_ -and $_.Trim() }).Count
        if ($resto -gt 0) { Mal "quedaron $resto llaves de Redis de $($of.Nombre)" }
    }
    if ($ofertas.Count -gt 0) { Ok "ofertas retiradas, sin llaves en Redis" }
    if ($comprador) {
        Ch "ALTER TABLE compra_producto DELETE WHERE id_usuario = $($comprador.Id)" | Out-Null
        Ch "ALTER TABLE carrito_producto DELETE WHERE id_usuario = $($comprador.Id)" | Out-Null
        Ok 'ventas y carritos de prueba borrados de ClickHouse'
    }
    Av 'Quedan las cuentas y los pedidos en PostgreSQL, no se deshacen.'
}

Write-Host ''
Write-Host '=============================================================='
if ($fallos -eq 0) { Write-Host ' Listo. Los descuentos se activaron y se apagaron solos.' -ForegroundColor Green }
else { Write-Host " Algo fallo, $fallos paso(s). Revisa arriba." -ForegroundColor Red }
Write-Host '=============================================================='
if ($fallos -gt 0) { exit 1 }
exit 0
