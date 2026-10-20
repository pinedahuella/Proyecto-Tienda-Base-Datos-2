# demo-compras-fraude.ps1
# Arma en vivo el fraude de compras y navegacion, el que se busca en
# ClickHouse (F1, F2, F3 y F5), con cuentas nuevas y compras REALES por el
# backend, y corre el detector para verlo en el panel sin esperar un dia.
#
#   .\demo-compras-fraude.ps1                                los cuatro casos
#   .\demo-compras-fraude.ps1 -Caso vistas_infladas          F1
#   .\demo-compras-fraude.ps1 -Caso compras_en_rafaga        F2
#   .\demo-compras-fraude.ps1 -Caso ip_multicuenta_compras   F3
#   .\demo-compras-fraude.ps1 -Caso devoluciones_seriales    F5
#   .\demo-compras-fraude.ps1 -SinAbrir                      no abre el panel al final
#
# QUE ARMA CADA CASO
# ==================================================
#   vistas_infladas         Una sola sesion abre la ficha de un mismo producto
#                           muchas veces (POST /eventos/vista, lo que manda la
#                           ficha). F1 pide 20 vistas por sesion o mas en ese
#                           producto, contando todas sus sesiones de los
#                           ultimos 30 dias: la demo elige el producto con menos
#                           sesiones y manda las que hagan falta.
#   compras_en_rafaga       Una cuenta nueva compra 5 veces en un par de
#                           minutos (F2 pide 5 pedidos en 15 minutos).
#   ip_multicuenta_compras  Cuatro cuentas nuevas compran desde la MISMA IP
#                           (F3 pide 4 cuentas). La IP va en X-Forwarded-For,
#                           que el backend lee cuando la peticion viene de esta
#                           maquina (trustProxy 'loopback'); desde localhost
#                           todas las compras traen 127.0.0.1, que F3 deja
#                           fuera a proposito.
#   devoluciones_seriales   Una cuenta nueva compra 4 veces y cancela 3 (F5
#                           pide 3 unidades devueltas y el 50 % de lo que
#                           compro).
#
# Cada compra pasa por el carrito y el checkout de verdad (PUT /carrito/lineas
# y POST /carrito/comprar), y el backend la escribe en ClickHouse en el
# momento (compra_producto, devolucion_producto, vista_producto, lote 'real').
#
# EL DETECTOR corre en el backend UNA vez al dia (HallazgosEventoFraudeDetectorService)
# y Nest no lo corre al arrancar: la demo lo corre una vez al final con
# node pruebas/correr_detectores_fraude.cjs compras, y confirma en PostgreSQL
# que cada senal subio. Necesita el backend compilado (npm run build).
#
# CADA CASO DISPARA SOLO ESE: la rafaga y las devoluciones compran desde
# localhost (F3 no las cuenta); las de una IP son una compra por cuenta (lejos
# de las 5 de F2) y no cancelan; las devoluciones son 4 compras (una menos que
# la rafaga). Las cuentas nacen desde localhost, asi que no son una granja de
# registros.
#
# NO ES REVERSIBLE: deja cuentas, pedidos, pagos, kardex y eventos reales,
# como demo-resenas-texto.ps1. Cada corrida usa un prefijo nuevo.

param(
    [ValidateSet('todos', 'vistas_infladas', 'compras_en_rafaga', 'ip_multicuenta_compras', 'devoluciones_seriales')]
    [string]$Caso = 'todos',

    [ValidatePattern('^[A-Za-z0-9]{0,20}$')]
    [string]$Prefijo = '',

    [switch]$SinAbrir,
    [string]$Backend = 'http://localhost:3000',
    [string]$Frontend = 'http://localhost:5173'
)

$env_ = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
function Psql-Uno([string]$sql) {
    $r = docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -qtAX -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return "$r".Trim()
}
function ClickHouse([string]$sql) {
    $salida = docker exec mesh-clickhouse clickhouse-client `
        --user $env_['CLICKHOUSE_USER'] --password $env_['CLICKHOUSE_PASSWORD'] `
        --database $env_['CLICKHOUSE_DB'] --query $sql 2>&1
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($salida | ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
}

function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Av($t)   { Write-Host "   $t" -ForegroundColor Yellow }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

$CONTRASENA = 'Desarrollo123!'
if ($Prefijo -eq '') { $Prefijo = 'cmp' + (Get-Date -Format 'MMddHHmmss') }
# La IP de las cuatro cuentas de F3: una de Guatemala (Ciudad de Guatemala).
$IP_COMPARTIDA = '200.6.193.' + (Get-Random -Minimum 20 -Maximum 250)

function Cuerpo($obj) { $obj | ConvertTo-Json -Depth 6 -Compress }

function Llamar([string]$Metodo, [string]$Ruta, $Datos, $Sesion, [string]$Ip = '') {
    $args_ = @{ Method = $Metodo; Uri = "$Backend$Ruta"; ContentType = 'application/json; charset=utf-8'; TimeoutSec = 20; WebSession = $Sesion }
    if ($null -ne $Datos) { $args_.Body = [Text.Encoding]::UTF8.GetBytes((Cuerpo $Datos)) }
    if ($Ip) { $args_.Headers = @{ 'X-Forwarded-For' = $Ip } }
    try {
        return Invoke-RestMethod @args_
    } catch {
        $codigo = 0
        if ($_.Exception.Response) { $codigo = [int]$_.Exception.Response.StatusCode }
        Mal "$Metodo $Ruta contesto $codigo $($_.ErrorDetails.Message)"
        throw
    }
}

function Entrar([string]$Correo, [string]$Clave) {
    $s = $null
    Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
        -Body (Cuerpo @{ identificador = $Correo; contrasena = $Clave }) -SessionVariable s -TimeoutSec 20 | Out-Null
    return $s
}

# Una compradora nueva con su direccion, igual que en demo-resenas-texto.ps1.
function NuevaCuenta([string]$Usuario) {
    $correo = "$Usuario@mesh.com"
    Invoke-RestMethod -Method Post -Uri "$Backend/usuario/registro" -ContentType 'application/json' `
        -Body (Cuerpo @{
            correo_electronico = $correo; usuario = $Usuario; nombre = 'Demo'
            apellido = 'Compras'; contrasena = $CONTRASENA
        }) -TimeoutSec 20 | Out-Null
    $sesion = Entrar $correo $CONTRASENA
    $yo = Invoke-RestMethod -Uri "$Backend/usuario/yo" -WebSession $sesion -TimeoutSec 20
    Llamar POST '/direccion-usuario' @{
        pais = 'Guatemala'; departamento = 'Guatemala'; ciudad = 'Guatemala'
        direccion_exacta = "Direccion de la demo de compras, $Usuario"; codigo_postal = '01001'
    } $sesion | Out-Null
    $dirs = Invoke-RestMethod -Uri "$Backend/direccion-usuario" -WebSession $sesion -TimeoutSec 20
    Ok "$correo"
    return [pscustomobject]@{
        Usuario = $Usuario; Correo = $correo; Sesion = $sesion; Id = [long]$yo.payload.id_usuario
        Direccion = $dirs.payload[0].id_direccion
    }
}

# Una compra de una unidad por el carrito. Devuelve el id del pedido.
function Comprar($Cuenta, [long]$IdOferta, [string]$Ip = '') {
    Llamar PUT "/carrito/lineas/$IdOferta" @{ cantidad = 1 } $Cuenta.Sesion $Ip | Out-Null
    $c = Llamar POST '/carrito/comprar' @{ id_direccion = $Cuenta.Direccion; metodo_pago = 'efectivo contra entrega' } $Cuenta.Sesion $Ip
    if (-not $c.payload.comprado) { throw "$($Cuenta.Usuario) no pudo comprar la oferta $IdOferta" }
    return $c.payload.id_pedido
}

# Cuantas veces se ha detectado ya ese tipo, sumando todas sus senales: se
# mira antes y despues de correr el detector.
function Detecciones([string]$tipo) {
    $n = Psql-Uno ("SELECT coalesce(sum(s.total_detecciones), 0) FROM senal_fraude s " +
                   "JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude) WHERE t.tipo_senal_fraude_nombre = '$tipo'")
    if ($n -match '^\d+$') { [int]$n } else { -1 }
}

# La senal de ese tipo cuya clave es esa (una cuenta, un producto o una IP).
function Ver-Senal([string]$tipo, [string]$clave) {
    Psql-Uno ("SELECT 'clave ' || s.clave || ', ' || s.total_detecciones || ' deteccion(es), ' || s.detalle::text " +
              "FROM senal_fraude s JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude) " +
              "WHERE t.tipo_senal_fraude_nombre = '$tipo' AND s.clave = '$clave' LIMIT 1")
}

Paso 'Revisando que Mesh este arriba'
try { Invoke-RestMethod -Uri "$Backend/db" -TimeoutSec 5 -UseBasicParsing *> $null }
catch { Mal "El backend no contesta en $Backend. Corre: cd backend ; npm run start:dev"; exit 1 }
if (-not (Test-Path (Join-Path $PSScriptRoot 'backend\dist\main.js'))) {
    Mal 'Falta compilar el backend (cd backend ; npm run build): el detector se corre desde backend\dist'; exit 1
}
if ((ClickHouse 'SELECT 1') -notcontains '1') { Mal 'ClickHouse no contesta. Corre .\arrancar.ps1'; exit 1 }

# Ofertas baratas, activas, aprobadas, con stock y sin inventario limitado, de
# los vendedores del catalogo (no de la semilla de fraude).
$ofertas = @((Psql-Uno ("SELECT string_agg(id_oferta::text, ',' ORDER BY precio, id_oferta) FROM (" +
    "SELECT o.id_oferta, o.precio FROM oferta o JOIN estado_oferta eo USING (id_estado_oferta) " +
    "JOIN usuarios u ON u.id_usuario = o.id_usuario " +
    "WHERE eo.estado_oferta_nombre = 'activa' AND o.fecha_aprobacion IS NOT NULL AND NOT o.es_inventario_limitado " +
    "AND o.stock >= 10 AND u.correo_electronico NOT LIKE 'fraude.%' ORDER BY o.precio, o.id_oferta LIMIT 8) x")) -split ',')
if ($ofertas.Count -lt 5) { Mal "Hacen falta 5 ofertas con stock y hay $($ofertas.Count)."; exit 1 }
Ok "Backend, PostgreSQL y ClickHouse arriba; $($ofertas.Count) ofertas baratas para comprar"

Write-Host ''
Write-Host '=============================================================='
Write-Host " Fraude de compras y navegacion, cuentas $Prefijo..." -ForegroundColor Yellow
Write-Host ' Hace compras REALES. No se deshace.' -ForegroundColor Yellow
Write-Host '=============================================================='

$tipos = @()
$claves = @{}
try {
    if ($Caso -in 'todos', 'vistas_infladas') {
        Paso 'Vistas infladas: una sola sesion abre la misma ficha una y otra vez'
        # El producto con menos sesiones reales en 30 dias, de los del catalogo.
        $ids = @((Psql-Uno "SELECT string_agg(id_producto::text, ',' ORDER BY id_producto) FROM productos WHERE nombre !~ ' [A-Z][0-9]+-[0-9]+$'") -split ',')
        $vistos = @{}
        foreach ($fila in (ClickHouse ("SELECT id_producto, count(), uniqExact(sesion) FROM vista_producto " +
                                       "WHERE lote = 'real' AND fecha >= now() - INTERVAL 30 DAY GROUP BY id_producto FORMAT TabSeparated"))) {
            $c = $fila -split "`t"
            $vistos[$c[0]] = @([int]$c[1], [int]$c[2])
        }
        $elegido = $null; $menos = [int]::MaxValue
        foreach ($id in $ids) {
            $s = if ($vistos.ContainsKey($id)) { $vistos[$id][1] } else { 0 }
            if ($s -lt $menos) { $menos = $s; $elegido = $id }
        }
        $v = if ($vistos.ContainsKey($elegido)) { $vistos[$elegido][0] } else { 0 }
        $nombre = Psql-Uno "SELECT nombre FROM productos WHERE id_producto = $elegido"
        # 20 vistas por sesion contando la nueva: (v + n) / (s + 1) >= 20.
        $n = [Math]::Max(25, 20 * ($menos + 1) - $v + 5)
        $sesion = "demo-vistas-$Prefijo"
        Ok "$nombre (producto $elegido): $v vistas en $menos sesiones en 30 dias; van $n vistas de una sola sesion"
        for ($i = 1; $i -le $n; $i++) {
            Invoke-RestMethod -Method Post -Uri "$Backend/eventos/vista" -ContentType 'application/json' `
                -Body (Cuerpo @{ id_producto = [int]$elegido; sesion = $sesion; origen = 'enlace_directo' }) -TimeoutSec 10 | Out-Null
        }
        Ok "$n vistas mandadas desde la sesion $sesion"
        $tipos += 'vistas_infladas'; $claves['vistas_infladas'] = "$elegido"
    }

    if ($Caso -in 'todos', 'compras_en_rafaga') {
        Paso 'Compras en rafaga: una cuenta compra 5 veces en un par de minutos'
        $c = NuevaCuenta "${Prefijo}rafaga"
        for ($i = 0; $i -lt 5; $i++) {
            $pedido = Comprar $c ([long]$ofertas[$i])
            Ok "pedido $pedido"
        }
        $tipos += 'compras_en_rafaga'; $claves['compras_en_rafaga'] = "$($c.Id)"
    }

    if ($Caso -in 'todos', 'ip_multicuenta_compras') {
        Paso "Una IP, cuatro cuentas: las cuatro compran desde $IP_COMPARTIDA"
        for ($k = 1; $k -le 4; $k++) {
            $c = NuevaCuenta "${Prefijo}ip$k"
            $pedido = Comprar $c ([long]$ofertas[$k]) $IP_COMPARTIDA
            Ok "$($c.Usuario) compro desde $IP_COMPARTIDA (pedido $pedido)"
        }
        # ClickHouse guarda la IP como IPv6: una IPv4 sale como ::ffff:a.b.c.d.
        $tipos += 'ip_multicuenta_compras'; $claves['ip_multicuenta_compras'] = "::ffff:$IP_COMPARTIDA"
    }

    if ($Caso -in 'todos', 'devoluciones_seriales') {
        Paso 'Devoluciones seriales: una cuenta compra 4 veces y cancela 3'
        $c = NuevaCuenta "${Prefijo}devuelve"
        $pedidos = @()
        for ($i = 0; $i -lt 4; $i++) { $pedidos += Comprar $c ([long]$ofertas[$i + 1]) }
        for ($i = 0; $i -lt 3; $i++) {
            Llamar POST "/comprador/pedidos/$($pedidos[$i])/cancelar" @{} $c.Sesion | Out-Null
            Ok "cancelo el pedido $($pedidos[$i]) y se le devolvio el dinero"
        }
        Ok "se quedo con el pedido $($pedidos[3])"
        $tipos += 'devoluciones_seriales'; $claves['devoluciones_seriales'] = "$($c.Id)"
    }
} catch {
    Mal "La demo se corto: $($_.Exception.Message)"
    exit 1
}

# El backend escribe en ClickHouse sin esperar la respuesta: se le da un
# momento antes de buscar.
Start-Sleep -Seconds 3
$antes = @{}
foreach ($t in $tipos) { $antes[$t] = Detecciones $t }

Paso 'Corriendo el detector de compras una vez (en el backend corre una vez al dia)'
node (Join-Path $PSScriptRoot 'pruebas\correr_detectores_fraude.cjs') compras casos 2>&1 |
    Select-String -Pattern 'OK |FALLA|hallazgo' | ForEach-Object { Write-Host "   $($_.Line.Trim())" -ForegroundColor DarkGray }

$faltan = 0
Paso 'Lo que quedo en PostgreSQL'
foreach ($t in $tipos) {
    $vista = Ver-Senal $t $claves[$t]
    if ((Detecciones $t) -gt $antes[$t] -and $vista) { Ok "$t -- $vista" }
    else { Mal "$t no aparecio con la clave $($claves[$t])"; $faltan++ }
}

if (-not $SinAbrir) {
    Paso 'Abriendo el panel de fraude'
    Start-Process "$Frontend/panel?s=fraude"
}

Write-Host ''
Write-Host '=============================================================='
if ($faltan -eq 0) {
    Write-Host " LISTO. Entra como admin@mesh.com / Admin123, Fraude, Compras y navegacion." -ForegroundColor Green
} else {
    Write-Host " Faltaron $faltan senal(es). Mira el log del backend." -ForegroundColor Red
}
Write-Host '=============================================================='
if ($faltan -gt 0) { exit 1 }
