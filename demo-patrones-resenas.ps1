# demo-patrones-resenas.ps1
# Arma en vivo los patrones de resenas de la familia B que el backend revisa
# al instante, con cuentas nuevas y compras REALES, y confirma por la API del
# admin que cada caso quedo guardado con su tipo.
#
#   .\demo-patrones-resenas.ps1                       los tres patrones
#   .\demo-patrones-resenas.ps1 -Patron cadena        solo B.1
#   .\demo-patrones-resenas.ps1 -Patron favor         solo B.5
#   .\demo-patrones-resenas.ps1 -Patron coordinados   solo B.6
#   .\demo-patrones-resenas.ps1 -SinAbrir             no abre el panel al final
#
# QUE ARMA CADA PATRON
# ==================================================
#   cadena (B.1, tipo cadena_abierta). Tres cuentas A, B y C. A le compra a B
#     y la califica con 5, B le compra a C y la califica con 5. Nadie cierra
#     el circulo: es una cadena, no un ciclo (el ciclo es A.1).
#   favor (B.5, tipo favor_devuelto). Dos cuentas se compran una a la otra y
#     se ponen 5 en minutos. Ese mismo par tambien sale como mutuo (A.1): son
#     dos casos distintos a proposito.
#   coordinados (B.6, tipo coordinados). Un vendedor con tres productos y dos
#     compradoras que compran y califican los tres en el mismo rato. El caso
#     lleva a las dos compradoras y NO al vendedor, que es un tercero.
#
# Los tres los revisa el backend en cuanto llega cada resena
# (PatronesFraudeDetectorService.detectarInmediato), asi que salen en
# segundos. Los otros tres tipos de la familia B no se arman aqui:
#   satelites (B.2) y reputacion expres (B.7) los revisa el worker cada 15
#     minutos. B.7 sale solo con estas mismas cuentas: todas son nuevas, y a
#     los 15 minutos cada vendedor de la demo aparece con reputacion en minutos.
#   persistente (B.3) pide resenas repartidas en tres meses distintos; no se
#     puede armar en vivo.
#
# Cada corrida usa un prefijo nuevo (demo + mes, dia, hora, minuto y segundo),
# asi que se puede repetir sin chocar con la anterior. Los casos quedan
# PENDIENTES para verlos en Fraude > Resenas en anillo, filtrando por tipo.
#
# NO ES REVERSIBLE, igual que demo-anillo-resenas.ps1: deja cuentas, ofertas,
# pedidos, pagos y kardex reales. Hace un login por cuenta desde este equipo,
# asi que tambien puede sumar una alerta de varias cuentas desde la misma IP.

param(
    [ValidateSet('todos', 'cadena', 'favor', 'coordinados')]
    [string]$Patron = 'todos',

    [ValidatePattern('^[A-Za-z0-9]{0,20}$')]
    [string]$Prefijo = '',

    [int]$Espera = 60,
    [switch]$SinAbrir,
    [string]$Backend = 'http://localhost:3000',
    [string]$Frontend = 'http://localhost:5173'
)

function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Av($t)   { Write-Host "   $t" -ForegroundColor Yellow }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

# Los mismos productos baratos del catalogo curado que usan
# demo-anillo-resenas.ps1 y pruebas/anillos_familia_b.sh.
$PRODUCTOS = @(
    @{ id = 83; variante = 166; nombre = 'Cartas al puerto seco' },
    @{ id = 76; variante = 158; nombre = 'Cuerda de salto Relampago' },
    @{ id = 81; variante = 170; nombre = 'Antologia del ruido' }
)
$CONTRASENA = 'Desarrollo123!'
if ($Prefijo -eq '') { $Prefijo = 'demo' + (Get-Date -Format 'MMddHHmmss') }

function Cuerpo($obj) { $obj | ConvertTo-Json -Depth 6 -Compress }

function Llamar([string]$Metodo, [string]$Ruta, $Datos, $Sesion) {
    $args_ = @{ Method = $Metodo; Uri = "$Backend$Ruta"; ContentType = 'application/json'; TimeoutSec = 20; WebSession = $Sesion }
    if ($null -ne $Datos) { $args_.Body = Cuerpo $Datos }
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

# Registra una cuenta nueva, la pasa a vendedor si hace falta, entra con ella
# (DESPUES del cambio de rol, que viaja dentro del token) y le crea direccion.
function NuevaCuenta([string]$Usuario, [bool]$Vendedor) {
    $correo = "$Usuario@mesh.com"
    Invoke-RestMethod -Method Post -Uri "$Backend/usuario/registro" -ContentType 'application/json' `
        -Body (Cuerpo @{
            correo_electronico = $correo; usuario = $Usuario; nombre = 'Demo'
            apellido = 'Patrones'; contrasena = $CONTRASENA
        }) -TimeoutSec 20 | Out-Null
    $sesion = Entrar $correo $CONTRASENA
    $yo = Invoke-RestMethod -Uri "$Backend/usuario/yo" -WebSession $sesion -TimeoutSec 20
    if ($Vendedor) {
        Llamar PATCH "/admin/usuarios/$($yo.payload.id_usuario)" @{ id_rol_usuario = 2 } $script:admin | Out-Null
        $sesion = Entrar $correo $CONTRASENA
    }
    Llamar POST '/direccion-usuario' @{
        pais = 'Guatemala'; departamento = 'Guatemala'; ciudad = 'Guatemala'
        direccion_exacta = "Direccion de la demo de patrones, $Usuario"; codigo_postal = '01001'
    } $sesion | Out-Null
    $dirs = Invoke-RestMethod -Uri "$Backend/direccion-usuario" -WebSession $sesion -TimeoutSec 20
    Ok "$correo$(if ($Vendedor) { ', vendedor' } else { '' })"
    return [pscustomobject]@{
        Usuario = $Usuario; Correo = $correo; Sesion = $sesion
        Direccion = $dirs.payload[0].id_direccion; Ofertas = @{}
    }
}

function Publicar($Cuenta, $Producto) {
    $r = Llamar POST '/vendedor/ofertas' @{
        id_producto = $Producto.id; id_producto_variante = $Producto.variante
        precio = '15.00'; stock_inicial = 20
    } $Cuenta.Sesion
    Llamar PATCH "/vendedor/ofertas/$($r.payload.id_oferta)/revision" @{ decision = 'aprobar' } $script:admin | Out-Null
    $Cuenta.Ofertas[$Producto.id] = $r.payload.id_oferta
    Ok "$($Cuenta.Usuario) vende $($Producto.nombre)"
}

function ComprarYResenar($Comprador, $Vendedor, $Producto) {
    Llamar PUT "/carrito/lineas/$($Vendedor.Ofertas[$Producto.id])" @{ cantidad = 1 } $Comprador.Sesion | Out-Null
    $c = Llamar POST '/carrito/comprar' @{ id_direccion = $Comprador.Direccion; metodo_pago = 'efectivo contra entrega' } $Comprador.Sesion
    if (-not $c.payload.comprado) { throw "$($Comprador.Usuario) no pudo comprarle a $($Vendedor.Usuario)" }
    Llamar POST '/resenas' @{
        id_producto = $Producto.id; correo_vendedor = $Vendedor.Correo; calificacion = 5
        comentario = 'Todo llego perfecto y a tiempo. Muy recomendado.'
    } $Comprador.Sesion | Out-Null
    Ok "$($Comprador.Usuario) le compro $($Producto.nombre) a $($Vendedor.Usuario) y le puso 5"
}

# Busca por la API del admin un caso de ese tipo con EXACTAMENTE esas cuentas.
function EsperarCaso([string]$Tipo, [string[]]$Usuarios) {
    $quiero = ($Usuarios | Sort-Object) -join ','
    for ($i = 0; $i -lt $Espera; $i += 2) {
        try {
            $r = Invoke-RestMethod -Uri "$Backend/admin/fraude/alertas-resenas?tipo=$Tipo&pagina=1&limite=200" -WebSession $script:admin -TimeoutSec 20
            foreach ($a in $r.payload.anillos) {
                $tiene = (@($a.cuentas | ForEach-Object { $_.usuario }) | Sort-Object) -join ','
                if ($tiene -eq $quiero) { return $true }
            }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

$NOMBRES = @{
    cadena_abierta = 'Cadena de calificaciones'
    favor_devuelto = 'Se devuelven la nota en horas'
    coordinados    = 'Califican juntas lo mismo'
}
$resultado = @()
function Confirmar([string]$Tipo, [string[]]$Usuarios) {
    Paso "Esperando el caso en Fraude, hasta $Espera s"
    if (EsperarCaso $Tipo $Usuarios) {
        Ok "Guardado: $($NOMBRES[$Tipo]), con $($Usuarios -join ', ')"
        $script:resultado += [pscustomobject]@{ Tipo = $Tipo; Ok = $true }
    } else {
        Mal "No aparecio $($NOMBRES[$Tipo]) con $($Usuarios -join ', ')"
        $script:resultado += [pscustomobject]@{ Tipo = $Tipo; Ok = $false }
    }
}

Paso 'Revisando que Mesh este arriba'
try { Invoke-RestMethod -Uri "$Backend/db" -TimeoutSec 5 -UseBasicParsing *> $null }
catch { Mal "El backend no contesta en $Backend"; exit 1 }
$admin = Entrar 'admin@mesh.com' 'Admin123'
Ok 'Backend arriba, sesion de admin lista'

Write-Host ''
Write-Host '=============================================================='
Write-Host " Patrones de resenas, cuentas $Prefijo..." -ForegroundColor Yellow
Write-Host ' Hace compras y resenas REALES. No se deshace.' -ForegroundColor Yellow
Write-Host '=============================================================='

try {
    if ($Patron -in 'todos', 'cadena') {
        Paso 'Cadena de calificaciones (B.1): A califica a B, B califica a C'
        $a = NuevaCuenta "${Prefijo}c1" $false
        $b = NuevaCuenta "${Prefijo}c2" $true
        $c = NuevaCuenta "${Prefijo}c3" $true
        Publicar $b $PRODUCTOS[0]
        Publicar $c $PRODUCTOS[1]
        ComprarYResenar $a $b $PRODUCTOS[0]
        ComprarYResenar $b $c $PRODUCTOS[1]
        Confirmar 'cadena_abierta' @($a.Usuario, $b.Usuario, $c.Usuario)
    }

    if ($Patron -in 'todos', 'favor') {
        Paso 'Favor devuelto (B.5): dos cuentas se ponen 5 una a la otra'
        $x = NuevaCuenta "${Prefijo}f1" $true
        $y = NuevaCuenta "${Prefijo}f2" $true
        Publicar $x $PRODUCTOS[0]
        Publicar $y $PRODUCTOS[1]
        ComprarYResenar $x $y $PRODUCTOS[1]
        ComprarYResenar $y $x $PRODUCTOS[0]
        Confirmar 'favor_devuelto' @($x.Usuario, $y.Usuario)
    }

    if ($Patron -in 'todos', 'coordinados') {
        Paso 'Coordinados (B.6): dos compradoras califican lo mismo a la vez'
        $v = NuevaCuenta "${Prefijo}k1" $true
        $p = NuevaCuenta "${Prefijo}k2" $false
        $q = NuevaCuenta "${Prefijo}k3" $false
        foreach ($pr in $PRODUCTOS) { Publicar $v $pr }
        foreach ($pr in $PRODUCTOS) {
            ComprarYResenar $p $v $pr
            ComprarYResenar $q $v $pr
        }
        Confirmar 'coordinados' @($p.Usuario, $q.Usuario)
    }
} catch {
    Mal "La demo se detuvo: $($_.Exception.Message)"
    exit 1
}

$fallos = @($resultado | Where-Object { -not $_.Ok }).Count
Write-Host ''
Write-Host '=============================================================='
if ($fallos -eq 0) {
    Write-Host " Listo. $($resultado.Count) de $($resultado.Count) patrones guardados." -ForegroundColor Green
} else {
    Write-Host " $fallos de $($resultado.Count) patrones no aparecieron." -ForegroundColor Red
}
Write-Host ' Verlos: panel del admin, Fraude, Resenas en anillo, filtro por tipo.' -ForegroundColor Yellow
Write-Host ' En 15 minutos el worker suma Reputacion en minutos con estas cuentas.' -ForegroundColor Yellow
Write-Host '=============================================================='
if (-not $SinAbrir) { Start-Process "$Frontend/panel?s=fraude&t=resenas" }
if ($fallos -gt 0) { exit 1 }
exit 0
