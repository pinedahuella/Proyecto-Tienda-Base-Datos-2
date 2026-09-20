# demo-anillo-resenas.ps1
# Arma en vivo un anillo de resenas de 2, 3 o 4 cuentas que se califican
# entre si, con compras REALES por detras (la regla de POST /resenas exige
# haber comprado), y abre el panel de fraude para verlo.
#
#   .\demo-anillo-resenas.ps1
#   .\demo-anillo-resenas.ps1 -Cuentas 3
#   .\demo-anillo-resenas.ps1 -Cuentas 4 -Prefijo desarrollador
#
# QUE HACE, EN ORDEN
# ==================================================
#   1. Registra (o entra, si ya existen de una corrida anterior) N cuentas
#      "desarrollador1@mesh.com" .. "desarrolladorN@mesh.com". Se ven en
#      Mesh como cualquier otra cuenta -- es a proposito, para que quede
#      claro en el panel que el anillo es de cuentas de demostracion y no
#      de las cuentas reales del curso.
#   2. Como admin, las pasa a rol vendedor y les crea una direccion.
#   3. Cada una publica una oferta sobre un producto barato del catalogo
#      COMPARTIDO (nunca crea productos nuevos) y, como admin, la aprueba.
#      Con 2 cuentas las dos ofertan EL MISMO producto (para que salga el
#      par mutuo sobre el mismo articulo, A.2). Con 3 o 4, cada una vende
#      un producto distinto (para el ciclo, A.1).
#   4. Cada cuenta le compra a la siguiente del circulo (checkout real,
#      comprar_carrito()) y le escribe una resena de 5 estrellas.
#   5. Espera a que el worker de Neo4j (10s) y el chequeo inmediato de
#      anillos hagan su trabajo, y abre /panel?s=fraude como admin.
#
# NO ES REVERSIBLE. Igual que .\pruebas\falla_checkout.sh, esto compra de
# verdad: deja pedidos, pagos y kardex que no se deshacen. Las cuentas y sus
# ofertas se quedan en el catalogo para siempre, como ya se quedan
# anillo.uno/dos/tres de la semilla. Si no lo quieres, no lo corras.
#
# Se puede correr otra vez con el mismo -Prefijo: las cuentas y las ofertas
# ya existentes se reusan (login en vez de registro, la oferta ya aprobada
# no se vuelve a crear), y solo se repite la compra y la resena -- pero
# POST /resenas rechaza una segunda resena del mismo par sobre el mismo
# producto con 409, asi que una segunda corrida con el mismo prefijo no
# vuelve a cerrar el anillo. Usa otro -Prefijo para un anillo nuevo.

param(
    [ValidateSet(2, 3, 4)]
    [int]$Cuentas = 3,

    [string]$Prefijo = 'desarrollador',
    [string]$Backend = 'http://localhost:3000',
    [string]$Frontend = 'http://localhost:5173'
)

function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Av($t)   { Write-Host "   $t" -ForegroundColor Yellow }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

# Cuatro productos baratos del catalogo curado, con su variante mas barata.
# Los mismos que usa la semilla para anillo.uno/dos/tres (migrations/datos/
# 001_catalogo.sql), asi que ya se sabe que existen y que tienen precio bajo.
$PRODUCTOS = @(
    @{ id = 83; variante = 166; nombre = 'Cartas al puerto seco' },
    @{ id = 76; variante = 158; nombre = 'Cuerda de salto Relampago' },
    @{ id = 81; variante = 170; nombre = 'Antologia del ruido' },
    @{ id = 67; variante = 127; nombre = 'Espinilleras Muralla' }
)
$CONTRASENA = 'Desarrollo123!'

Paso "Revisando que Mesh este arriba"
docker ps *> $null
if ($LASTEXITCODE -ne 0) { Mal "Docker no responde. Corre .\arrancar.ps1"; exit 1 }
try { Invoke-RestMethod -Uri "$Backend/db" -TimeoutSec 5 -UseBasicParsing *> $null }
catch { Mal "El backend no contesta en $Backend. Corre: cd backend ; npm run start:dev"; exit 1 }
Ok "Docker y el backend estan arriba"

$env_ = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}

function Cuerpo($obj) { $obj | ConvertTo-Json -Depth 6 -Compress }

# Cada llamada devuelve $null en vez de lanzar cuando el backend contesta un
# error esperado (ya existe, ya aprobada, ya resenada): esto se corre varias
# veces con el mismo prefijo y no tiene que detenerse por eso.
function Llamar([string]$Metodo, [string]$Ruta, $Cuerpo, $Sesion, [int[]]$OkExtra = @()) {
    try {
        $args = @{ Method = $Metodo; Uri = "$Backend$Ruta"; ContentType = 'application/json'; TimeoutSec = 15 }
        if ($Cuerpo) { $args.Body = Cuerpo $Cuerpo }
        if ($Sesion) { $args.WebSession = $Sesion } else { $args.SessionVariable = 'nueva' }
        $r = Invoke-RestMethod @args
        if (-not $Sesion -and $nueva) { Set-Variable -Scope 1 -Name UltimaSesion -Value $nueva }
        return $r
    } catch {
        $codigo = 0
        if ($_.Exception.Response) { $codigo = [int]$_.Exception.Response.StatusCode }
        if ($codigo -in $OkExtra) { return $null }
        $texto = $_.ErrorDetails.Message
        Mal "  $Metodo $Ruta -> $codigo $texto"
        throw
    }
}

function EntrarOCrear([string]$Correo, [string]$Usuario, [string]$Nombre) {
    $sesion = $null
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
            -Body (Cuerpo @{ identificador = $Correo; contrasena = $CONTRASENA }) -SessionVariable sesion -TimeoutSec 15
        Ok "  $Correo ya existia, se entro con su cuenta"
        return $sesion
    } catch {
        # No existia: se registra.
    }
    Invoke-RestMethod -Method Post -Uri "$Backend/usuario/registro" -ContentType 'application/json' `
        -Body (Cuerpo @{
            correo_electronico = $Correo; usuario = $Usuario; nombre = $Nombre
            apellido = 'Demo'; contrasena = $CONTRASENA
        }) -TimeoutSec 15 | Out-Null
    $r = Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
        -Body (Cuerpo @{ identificador = $Correo; contrasena = $CONTRASENA }) -SessionVariable sesion -TimeoutSec 15
    Ok "  $Correo registrada"
    return $sesion
}

Write-Host ""
Write-Host "=============================================================="
Write-Host " Anillo de $Cuentas cuentas, prefijo '$Prefijo'" -ForegroundColor Yellow
Write-Host " Hace compras y resenas REALES. No se deshace." -ForegroundColor Yellow
Write-Host "=============================================================="

Paso "Entrando como admin"
$admin = $null
$r = Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
    -Body (Cuerpo @{ identificador = 'admin@mesh.com'; contrasena = 'Admin123' }) -SessionVariable admin -TimeoutSec 15
Ok "  admin@mesh.com"

Paso "Cuentas del anillo"
$miembros = @()
for ($i = 1; $i -le $Cuentas; $i++) {
    $correo = "$Prefijo$i@mesh.com"
    $sesion = EntrarOCrear -Correo $correo -Usuario "$Prefijo$i" -Nombre "Desarrollador $i"
    $yo = Invoke-RestMethod -Uri "$Backend/usuario/yo" -WebSession $sesion -TimeoutSec 15
    $producto = if ($Cuentas -eq 2) { $PRODUCTOS[0] } else { $PRODUCTOS[$i - 1] }
    $miembros += [pscustomobject]@{
        Correo = $correo; Sesion = $sesion; Id = $yo.payload.id_usuario; Producto = $producto
    }
}

Paso "Rol vendedor y direccion, para cada cuenta"
foreach ($m in $miembros) {
    Llamar PATCH "/admin/usuarios/$($m.Id)" @{ id_rol_usuario = 2 } $admin @(400) | Out-Null
    # El rol viaja DENTRO del JWT, firmado al momento de entrar -- cambiarlo
    # en la base no le hace nada a una cookie ya emitida. Sin volver a
    # entrar, la cuenta sigue viendose a si misma como compradora hasta que
    # el token de 2 horas venza solo, y POST /vendedor/ofertas le da 403.
    $r = Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
        -Body (Cuerpo @{ identificador = $m.Correo; contrasena = $CONTRASENA }) -SessionVariable sesionNueva -TimeoutSec 15
    $m.Sesion = $sesionNueva
    Llamar POST "/direccion-usuario" @{
        pais = 'Guatemala'; departamento = 'Guatemala'; ciudad = 'Guatemala'
        direccion_exacta = "Direccion de prueba del anillo, casa $($m.Correo)"
        codigo_postal = '01001'
    } $m.Sesion @(400) | Out-Null
    Ok "  $($m.Correo) -> vendedor, con direccion"
}

Paso "Cada cuenta publica su oferta, y el admin la aprueba"
foreach ($m in $miembros) {
    $ofertas = Invoke-RestMethod -Uri "$Backend/vendedor/ofertas" -WebSession $m.Sesion -TimeoutSec 15
    $mia = $ofertas.payload | Where-Object { $_.id_producto -eq $m.Producto.id -and $_.id_producto_variante -eq $m.Producto.variante } | Select-Object -First 1
    if ($mia) {
        $m | Add-Member IdOferta $mia.id_oferta -Force
        Ok "  $($m.Correo) ya tenia oferta de $($m.Producto.nombre) (id $($mia.id_oferta))"
    } else {
        $creada = Llamar POST "/vendedor/ofertas" @{
            id_producto = $m.Producto.id; id_producto_variante = $m.Producto.variante
            precio = '15.00'; stock_inicial = 20
        } $m.Sesion
        $m | Add-Member IdOferta $creada.payload.id_oferta -Force
        Ok "  $($m.Correo) publico $($m.Producto.nombre) (id $($m.IdOferta))"
    }
    Llamar PATCH "/vendedor/ofertas/$($m.IdOferta)/revision" @{ decision = 'aprobar' } $admin @(409) | Out-Null
}
Ok "  todas activas"

Paso "Cada cuenta le compra a la siguiente y la resena"
for ($i = 0; $i -lt $Cuentas; $i++) {
    $comprador = $miembros[$i]
    $vendedor = $miembros[($i + 1) % $Cuentas]

    $dirs = Invoke-RestMethod -Uri "$Backend/direccion-usuario" -WebSession $comprador.Sesion -TimeoutSec 15
    $idDireccion = $dirs.payload[0].id_direccion

    Llamar PUT "/carrito/lineas/$($vendedor.IdOferta)" @{ cantidad = 1 } $comprador.Sesion | Out-Null
    $compra = Llamar POST "/carrito/comprar" @{
        id_direccion = $idDireccion; metodo_pago = 'efectivo contra entrega'
    } $comprador.Sesion @(409)
    if ($compra -and $compra.payload.comprado -eq $false) {
        Av "  $($comprador.Correo) -> $($vendedor.Correo): el carrito ya no tenia nada que comprar (compra anterior)"
    } elseif ($compra) {
        Ok "  $($comprador.Correo) le compro $($vendedor.Producto.nombre) a $($vendedor.Correo)"
    } else {
        Av "  $($comprador.Correo) -> $($vendedor.Correo): ya le habia comprado antes"
    }

    $resena = Llamar POST "/resenas" @{
        id_producto = $vendedor.Producto.id
        correo_vendedor = $vendedor.Correo
        calificacion = 5
        comentario = 'Excelente vendedor, todo llego perfecto y en tiempo. Lo recomiendo.'
    } $comprador.Sesion @(400, 409)
    if ($resena) {
        Ok "  $($comprador.Correo) reseno a $($vendedor.Correo) (resena $($resena.payload.id_resena))"
    } else {
        Av "  $($comprador.Correo) ya habia resenado a $($vendedor.Correo) en una corrida anterior"
    }
}

Paso "Esperando a que se proyecte al grafo y se revise el anillo"
Start-Sleep -Seconds 8
Ok "  listo"

Write-Host ""
Write-Host "=============================================================="
Write-Host " Anillo armado: $($miembros.Correo -join ' -> ') -> $($miembros[0].Correo)" -ForegroundColor Yellow
Write-Host " Panel: $Frontend/panel?s=fraude&t=resenas" -ForegroundColor Yellow
Write-Host "=============================================================="
Start-Process "$Frontend/panel?s=fraude&t=resenas"
