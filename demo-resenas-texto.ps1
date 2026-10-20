# demo-resenas-texto.ps1
# Arma en vivo el fraude de resenas que NO sale del grafo, con cuentas nuevas y
# compras REALES, y confirma por la API del admin que cada senal quedo
# guardada: lo que se ve en el TEXTO de las resenas (el vector y la valoracion
# de cada una en vector_comentario de PostgreSQL, desde la migracion 040; antes
# en mesh_comentarios de Elasticsearch) y las resenas de compras que despues se
# cancelaron.
#
#   .\demo-resenas-texto.ps1                          los siete casos
#   .\demo-resenas-texto.ps1 -Caso copiadas           resenas copiadas
#   .\demo-resenas-texto.ps1 -Caso incoherentes       notas incoherentes
#   .\demo-resenas-texto.ps1 -Caso cancelada          resena buena y compra cancelada
#   .\demo-resenas-texto.ps1 -Caso negativas          resenas malas y compras canceladas
#   .\demo-resenas-texto.ps1 -Caso repetidas          una cuenta que repite su resena
#   .\demo-resenas-texto.ps1 -Caso parecidas_producto la misma resena en un producto
#   .\demo-resenas-texto.ps1 -Caso incoherentes_producto  estrellas contra el texto en un producto
#   .\demo-resenas-texto.ps1 -SinAbrir                no abre el panel al final
#
# QUE ARMA CADA CASO
# ==================================================
#   copiadas. Un vendedor nuevo y seis compradoras que le dejan casi la misma
#     resena, con un par de palabras cambiadas. Salen resenas_parecidas_vendedor
#     y anillo_de_texto (3 o mas cuentas con la misma plantilla).
#   incoherentes. Una cuenta compra cinco productos y les pone 5 estrellas con
#     textos que dicen que todo salio mal; el clasificador los lee como malos.
#     Salen notas_incoherentes_cuenta y notas_incoherentes_vendedor.
#   cancelada. Una cuenta compra, le pone 5 estrellas al vendedor y cancela el
#     pedido: se le devuelve el dinero y la resena buena se queda. Sale
#     resena_positiva_cancelada; una sola vez basta.
#   negativas. Cinco cuentas compran, le ponen 1 o 2 estrellas al mismo
#     vendedor y cancelan. Sale resenas_negativas_canceladas_vendedor, con el
#     vendedor como victima.
#   repetidas. Una cuenta deja la misma resena, con dos o tres palabras
#     cambiadas, en los cinco productos de un vendedor. Sale resenas_repetidas
#     (la de otras cuentas es parecidas; la de una sola, repetidas).
#   parecidas_producto. Seis cuentas dejan casi la misma resena sobre UN
#     producto, repartidas de a 2 entre tres vendedores nuevos (con 3 en un
#     vendedor ya seria un anillo de texto). Sale resenas_parecidas_producto.
#   incoherentes_producto. Seis cuentas le ponen 5 estrellas a UN producto con
#     textos distintos que dicen que salio malo, de a 2 por vendedor. Sale
#     notas_incoherentes_producto.
#   El producto de estos dos lo elige la demo en cada corrida: el del catalogo
#   con menos resenas en 180 dias que todavia no tenga esa senal (las dos piden
#   el 40 % de las resenas del producto, y una senal vieja daria un falso "salio").
#
# COMO SALE TAN RAPIDO
# Desde 1f1f480 el backend revisa al momento: al escribir una resena indexa,
# valora y evalua solo esa resena en las senales de texto, y al cancelar un
# pedido revisa la resena de esa compra. La demo espera a que cada senal salga
# sola y dice cuanto tardo. Si alguna no sale en 30 s, corre una vez los
# detectores con pruebas/correr_detectores_resenas.cjs, el mismo codigo del
# backend, y vuelve a mirar.
#
# Las resenas de texto pasan de 100 caracteres: las senales de texto no miran
# las mas cortas. Cada corrida usa un prefijo nuevo, asi que se puede repetir.
# Las senales quedan PENDIENTES en Fraude, Resenas en anillo.
#
# NO ES REVERSIBLE, igual que demo-patrones-resenas.ps1: deja cuentas,
# ofertas, pedidos, pagos y kardex reales.

param(
    [ValidateSet('todos', 'copiadas', 'incoherentes', 'cancelada', 'negativas',
                 'repetidas', 'parecidas_producto', 'incoherentes_producto')]
    [string]$Caso = 'todos',

    [ValidatePattern('^[A-Za-z0-9]{0,20}$')]
    [string]$Prefijo = '',

    [int]$Espera = 120,
    [switch]$SinAbrir,
    [string]$Backend = 'http://localhost:3000',
    [string]$Frontend = 'http://localhost:5173'
)

# PostgreSQL solo se MIRA (las resenas ya tienen vector y valoracion?). Todo lo
# que se hace va por el backend.
$env_ = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
function Psql-Uno([string]$sql) {
    $r = docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -qtAX -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return "$r".Trim()
}

function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Av($t)   { Write-Host "   $t" -ForegroundColor Yellow }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

# Productos del catalogo curado, los mismos de las otras demos de resenas.
$PRODUCTOS = @(
    @{ id = 83; variante = 166; nombre = 'Cartas al puerto seco' },
    @{ id = 76; variante = 158; nombre = 'Cuerda de salto Relampago' },
    @{ id = 81; variante = 170; nombre = 'Antologia del ruido' },
    @{ id = 69; variante = 149; nombre = 'Candado plegable Cerrojo F8' },
    @{ id = 79; variante = 151; nombre = 'Tapete de yoga Raiz 6 mm' }
)
$CONTRASENA = 'Desarrollo123!'
if ($Prefijo -eq '') { $Prefijo = 'txt' + (Get-Date -Format 'MMddHHmmss') }

# La plantilla copiada: la misma resena con una o dos palabras distintas.
$COPIADAS = @(
    'Excelente compra, el producto llego rapidisimo y en perfecto estado. El vendedor es muy confiable y atento, lo recomiendo a todos sin dudarlo.',
    'Excelente compra, el producto llego rapidisimo y en perfecto estado. El vendedor es muy confiable y amable, lo recomiendo a todos sin dudarlo.',
    'Excelente compra, el producto llego rapido y en perfecto estado. El vendedor es muy confiable y atento, lo recomiendo a todos sin dudarlo.',
    'Excelente compra, el producto llego rapidisimo y en excelente estado. El vendedor es muy confiable y atento, lo recomiendo a todos sin dudarlo.',
    'Muy buena compra, el producto llego rapidisimo y en perfecto estado. El vendedor es muy confiable y atento, lo recomiendo a todos sin dudarlo.',
    'Excelente compra, el producto llego rapidisimo y en perfecto estado. El vendedor es muy confiable y atento, se lo recomiendo a todos sin dudarlo.'
)

# Textos claramente malos, cada uno distinto, que van con 5 estrellas.
$MALAS = @(
    'Llego roto y con piezas faltantes. Escribi tres veces al vendedor y nunca me contesto. Perdi mi dinero, no lo compren por nada del mundo.',
    'Pesima calidad, se desarmo a los dos dias de uso. Parece una copia barata y no se parece en nada a la foto. Una estafa total, me arrepiento.',
    'Nunca funciono bien desde que lo saque de la caja. Pedi la devolucion y me la negaron sin explicacion. La peor compra que he hecho este ano.',
    'El paquete llego abierto, sucio y con un mes de retraso. El producto estaba usado y rayado. Muy decepcionado, no vuelvo a comprar aqui jamas.',
    'Material malisimo, huele a quimico y se rompio la primera vez que lo use. El vendedor se burlo cuando reclame. No lo recomiendo para nada.'
)

# Una cuenta que se repite: la misma resena con dos o tres palabras cambiadas.
$REPETIDAS = @(
    'Todo perfecto con esta compra, llego en dos dias, bien envuelto y funcionando. El vendedor contesto rapido mis preguntas. Cinco estrellas sin duda.',
    'Todo perfecto con esta compra, llego en tres dias, bien envuelto y funcionando. El vendedor contesto rapido mis preguntas. Cinco estrellas sin duda.',
    'Todo perfecto con este pedido, llego en dos dias, bien envuelto y funcionando. El vendedor contesto rapido mis preguntas. Cinco estrellas sin duda.',
    'Todo perfecto con esta compra, llego en dos dias, bien empacado y funcionando. El vendedor contesto rapido mis dudas. Cinco estrellas sin duda.',
    'Todo excelente con esta compra, llego en dos dias, bien envuelto y funcionando. El vendedor contesto rapido mis preguntas. Cinco estrellas sin duda.'
)

# Seis cuentas, casi la misma resena sobre un producto.
$PARECIDAS_PRODUCTO = @(
    'Lo compre por las fotos y es justo lo que se ve. Buen material, buen acabado y llego antes de lo prometido. De lo mejor que he comprado en linea.',
    'Lo compre por las fotos y es justo lo que se ve. Buen material, buen acabado y llego antes de lo esperado. De lo mejor que he comprado en linea.',
    'Lo pedi por las fotos y es justo lo que se ve. Buen material, buen acabado y llego antes de lo prometido. De lo mejor que he comprado en linea.',
    'Lo compre por las fotos y es exactamente lo que se ve. Buen material, buen acabado y llego antes de lo prometido. De lo mejor que he comprado en linea.',
    'Lo compre por las fotos y es justo lo que se ve. Buen material, muy buen acabado y llego antes de lo prometido. De lo mejor que he comprado en linea.',
    'Lo compre por las fotos y es justo lo que se ve. Buen material, buen acabado y llego antes de lo prometido. Lo mejor que he comprado en linea.'
)

# Seis textos malos, distintos entre si (y de $MALAS), que van con 5 estrellas
# sobre un mismo producto.
$MALAS_PRODUCTO = @(
    'Se rompio la primera semana y la pieza que fallo no tiene repuesto. El vendedor dejo de contestar cuando reclame. Dinero tirado a la basura.',
    'Llego con un golpe enorme y ademas le faltaban partes. Nada que ver con lo que mostraban. Una decepcion de principio a fin, no lo recomiendo.',
    'La calidad es pesima, se nota barato apenas lo tocas y se desarmo al usarlo. Me arrepiento de haberlo comprado, no sirve para nada.',
    'Nunca funciono como decia la descripcion y el olor a plastico quemado no se va. Pedi que me lo cambiaran y me ignoraron por completo.',
    'Tardo un mes en llegar y vino usado, sucio y con rayones. El empaque estaba roto. Pesima experiencia, no vuelvo a comprar esto.',
    'Es una copia de mala calidad, nada de lo que prometen es cierto. Se descompuso a los pocos dias y nadie se hace responsable.'
)

# Las negativas de compras canceladas: cortas y distintas entre si, para que no
# se mezclen con las senales de texto.
$NEGATIVAS = @(
    'No me gusto nada, la calidad es muy baja para el precio que tiene.',
    'Tardo demasiado y el vendedor nunca respondio mis mensajes.',
    'Vino incompleto y la caja estaba golpeada, mala experiencia.',
    'No era lo que mostraban las fotos, me senti enganado con esto.',
    'Se rompio enseguida, no lo volveria a comprar a este vendedor.'
)

function Cuerpo($obj) { $obj | ConvertTo-Json -Depth 6 -Compress }

function Llamar([string]$Metodo, [string]$Ruta, $Datos, $Sesion) {
    $args_ = @{ Method = $Metodo; Uri = "$Backend$Ruta"; ContentType = 'application/json; charset=utf-8'; TimeoutSec = 20; WebSession = $Sesion }
    if ($null -ne $Datos) { $args_.Body = [Text.Encoding]::UTF8.GetBytes((Cuerpo $Datos)) }
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

# Igual que en demo-patrones-resenas.ps1: registra, pasa a vendedor si hace
# falta, entra DESPUES del cambio de rol y le crea direccion.
function NuevaCuenta([string]$Usuario, [bool]$Vendedor) {
    $correo = "$Usuario@mesh.com"
    Invoke-RestMethod -Method Post -Uri "$Backend/usuario/registro" -ContentType 'application/json' `
        -Body (Cuerpo @{
            correo_electronico = $correo; usuario = $Usuario; nombre = 'Demo'
            apellido = 'Texto'; contrasena = $CONTRASENA
        }) -TimeoutSec 20 | Out-Null
    $sesion = Entrar $correo $CONTRASENA
    $yo = Invoke-RestMethod -Uri "$Backend/usuario/yo" -WebSession $sesion -TimeoutSec 20
    if ($Vendedor) {
        Llamar PATCH "/admin/usuarios/$($yo.payload.id_usuario)" @{ id_rol_usuario = 2 } $script:admin | Out-Null
        $sesion = Entrar $correo $CONTRASENA
    }
    Llamar POST '/direccion-usuario' @{
        pais = 'Guatemala'; departamento = 'Guatemala'; ciudad = 'Guatemala'
        direccion_exacta = "Direccion de la demo de resenas, $Usuario"; codigo_postal = '01001'
    } $sesion | Out-Null
    $dirs = Invoke-RestMethod -Uri "$Backend/direccion-usuario" -WebSession $sesion -TimeoutSec 20
    Ok "$correo$(if ($Vendedor) { ', vendedor' } else { '' })"
    return [pscustomobject]@{
        Usuario = $Usuario; Correo = $correo; Sesion = $sesion; Id = [long]$yo.payload.id_usuario
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
}

# Compra, resena y devuelve el id del pedido.
function ComprarYResenar($Comprador, $Vendedor, $Producto, [int]$Nota, [string]$Texto) {
    Llamar PUT "/carrito/lineas/$($Vendedor.Ofertas[$Producto.id])" @{ cantidad = 1 } $Comprador.Sesion | Out-Null
    $c = Llamar POST '/carrito/comprar' @{ id_direccion = $Comprador.Direccion; metodo_pago = 'efectivo contra entrega' } $Comprador.Sesion
    if (-not $c.payload.comprado) { throw "$($Comprador.Usuario) no pudo comprarle a $($Vendedor.Usuario)" }
    Llamar POST '/resenas' @{
        id_producto = $Producto.id; correo_vendedor = $Vendedor.Correo; calificacion = $Nota; comentario = $Texto
    } $Comprador.Sesion | Out-Null
    Ok "$($Comprador.Usuario) le compro $($Producto.nombre) a $($Vendedor.Usuario) y le puso $Nota"
    return $c.payload.id_pedido
}

# Los cinco productos en UN pedido de cinco lineas, y despues una resena por
# producto. Cinco pedidos seguidos de la misma cuenta ya son una compra en
# rafaga (F2, 5 en 15 minutos): la cuenta de incoherentes y la de repetidas
# compran asi para que salga solo su senal de texto.
function ComprarTodoYResenar($Comprador, $Vendedor, $Productos, [int]$Nota, [string[]]$Textos) {
    foreach ($p in $Productos) {
        Llamar PUT "/carrito/lineas/$($Vendedor.Ofertas[$p.id])" @{ cantidad = 1 } $Comprador.Sesion | Out-Null
    }
    $c = Llamar POST '/carrito/comprar' @{ id_direccion = $Comprador.Direccion; metodo_pago = 'efectivo contra entrega' } $Comprador.Sesion
    if (-not $c.payload.comprado) { throw "$($Comprador.Usuario) no pudo comprarle a $($Vendedor.Usuario)" }
    for ($k = 0; $k -lt $Productos.Count; $k++) {
        Llamar POST '/resenas' @{
            id_producto = $Productos[$k].id; correo_vendedor = $Vendedor.Correo; calificacion = $Nota; comentario = $Textos[$k]
        } $Comprador.Sesion | Out-Null
    }
    Ok "$($Comprador.Usuario) le compro $($Productos.Count) productos en un pedido a $($Vendedor.Usuario) y les puso $Nota a todos"
}

function Cancelar($Comprador, $IdPedido) {
    Llamar POST "/comprador/pedidos/$IdPedido/cancelar" @{} $Comprador.Sesion | Out-Null
    Ok "$($Comprador.Usuario) cancelo el pedido $IdPedido y se le devolvio el dinero"
}

# Espera a que las resenas de esas cuentas tengan su vector y la valoracion del
# clasificador en vector_comentario. Los pone el backend (EventoComentarioSyncService
# y ValoracionComentariosService); aqui solo se cuentan.
function EsperarValoradas([long[]]$Ids, [int]$Cuantas) {
    $sql = "SELECT count(*) FROM resena r JOIN vector_comentario v ON v.id_comentario = r.id_comentario " +
           "WHERE r.id_usuario IN ($($Ids -join ',')) AND v.valoracion_texto IS NOT NULL;"
    for ($i = 0; $i -lt $Espera; $i += 3) {
        $n = Psql-Uno $sql
        if ($n -match '^\d+$' -and [int]$n -ge $Cuantas) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

# El producto del catalogo con menos resenas en 180 dias que todavia no tiene
# esa senal (ni el otro de esta corrida). Devuelve id, variante y nombre.
function ProductoSinSenal([string]$Tipo, [long]$Excepto = 0) {
    $fila = Psql-Uno ("SELECT p.id_producto || '|' || min(pv.id_producto_variante) || '|' || p.nombre " +
        "FROM productos p JOIN productos_variantes pv ON pv.id_producto = p.id_producto " +
        "WHERE p.nombre !~ ' [A-Z][0-9]+-[0-9]+$' AND p.id_producto <> $Excepto " +
        "AND NOT EXISTS (SELECT 1 FROM senal_fraude s JOIN tipo_senal_fraude t USING (id_tipo_senal_fraude) " +
        "WHERE t.tipo_senal_fraude_nombre = '$Tipo' AND s.clave = 'p' || p.id_producto) " +
        "GROUP BY p.id_producto, p.nombre ORDER BY (SELECT count(*) FROM resena r JOIN comentario c USING (id_comentario) " +
        "WHERE r.id_producto_mongo = p.id_producto AND c.fecha_publicacion > now() - interval '180 days'), p.id_producto LIMIT 1;")
    if (-not $fila) { throw "No hay un producto sin la senal $Tipo" }
    $c = $fila -split '\|', 3
    return @{ id = [long]$c[0]; variante = [long]$c[1]; nombre = $c[2] }
}

# Seis cuentas, cada una con su texto, sobre un producto, repartidas de a 2
# entre tres vendedores nuevos. Devuelve el producto.
function SeisSobreUnProducto([string]$Letra, $Producto, [string[]]$Textos, [int]$Nota) {
    $vendedores = @()
    for ($k = 1; $k -le 3; $k++) {
        $v = NuevaCuenta "${Prefijo}${Letra}v$k" $true
        Publicar $v $Producto
        $vendedores += $v
    }
    for ($k = 0; $k -lt 6; $k++) {
        $c = NuevaCuenta "${Prefijo}${Letra}$($k + 1)" $false
        ComprarYResenar $c ($vendedores[$k % 3]) $Producto $Nota ($Textos[$k]) | Out-Null
        $script:idsTexto += $c.Id
        $script:totalTexto++
    }
}

function HaySenal([string]$Tipo, [string]$Clave) {
    try {
        $r = Invoke-RestMethod -Uri "$Backend/admin/fraude/alertas-resenas?tipo=$Tipo&pagina=1&limite=200" -WebSession $script:admin -TimeoutSec 20
        foreach ($a in $r.payload.anillos) { if ("$($a.clave)" -eq $Clave) { return $true } }
    } catch { }
    return $false
}

$esperadas = @()

Paso 'Revisando que Mesh este arriba'
try { Invoke-RestMethod -Uri "$Backend/db" -TimeoutSec 5 -UseBasicParsing *> $null }
catch { Mal "El backend no contesta en $Backend"; exit 1 }
if ((Psql-Uno "SELECT to_regclass('public.vector_comentario') IS NOT NULL;") -ne 't') {
    Mal "No esta la tabla vector_comentario (migracion 040). Corre .\arrancar.ps1"; exit 1
}
$admin = Entrar 'admin@mesh.com' 'Admin123'
Ok 'Backend y PostgreSQL arriba, sesion de admin lista'

Write-Host ''
Write-Host '=============================================================='
Write-Host " Fraude de resenas fuera del grafo, cuentas $Prefijo..." -ForegroundColor Yellow
Write-Host ' Hace compras y resenas REALES. No se deshace.' -ForegroundColor Yellow
Write-Host '=============================================================='

$idsTexto = @()
$totalTexto = 0
$inicio = Get-Date
try {
    if ($Caso -in 'todos', 'copiadas') {
        Paso 'Resenas copiadas: seis cuentas, la misma resena, el mismo vendedor'
        $v = NuevaCuenta "${Prefijo}v1" $true
        Publicar $v $PRODUCTOS[0]
        $compradoras = @()
        for ($k = 0; $k -lt $COPIADAS.Count; $k++) {
            $c = NuevaCuenta "${Prefijo}c$($k + 1)" $false
            ComprarYResenar $c $v $PRODUCTOS[0] 5 $COPIADAS[$k] | Out-Null
            $compradoras += $c
            $idsTexto += $c.Id
            $totalTexto++
        }
        $esperadas += [pscustomobject]@{ Tipo = 'resenas_parecidas_vendedor'; Clave = "$($v.Id)"; Que = "el vendedor $($v.Usuario)" }
        $claveAnillo = (@($compradoras | ForEach-Object { $_.Id }) | Sort-Object) -join '-'
        $esperadas += [pscustomobject]@{ Tipo = 'anillo_de_texto'; Clave = $claveAnillo; Que = 'las seis compradoras' }
    }

    if ($Caso -in 'todos', 'incoherentes') {
        Paso 'Notas incoherentes: cinco estrellas con textos que dicen que todo salio mal'
        $w = NuevaCuenta "${Prefijo}v2" $true
        foreach ($p in $PRODUCTOS) { Publicar $w $p }
        $b = NuevaCuenta "${Prefijo}m1" $false
        ComprarTodoYResenar $b $w $PRODUCTOS 5 $MALAS
        $totalTexto += $PRODUCTOS.Count
        $idsTexto += $b.Id
        $esperadas += [pscustomobject]@{ Tipo = 'notas_incoherentes_cuenta'; Clave = "$($b.Id)"; Que = "la cuenta $($b.Usuario)" }
        $esperadas += [pscustomobject]@{ Tipo = 'notas_incoherentes_vendedor'; Clave = "$($w.Id)"; Que = "el vendedor $($w.Usuario)" }
    }

    if ($Caso -in 'todos', 'cancelada') {
        Paso 'Resena buena y compra cancelada: cinco estrellas y despues devuelve'
        $x = NuevaCuenta "${Prefijo}v3" $true
        Publicar $x $PRODUCTOS[1]
        $r = NuevaCuenta "${Prefijo}r1" $false
        $pedido = ComprarYResenar $r $x $PRODUCTOS[1] 5 'Muy buen producto y el vendedor atendio rapido, lo recomiendo.'
        Cancelar $r $pedido
        $esperadas += [pscustomobject]@{ Tipo = 'resena_positiva_cancelada'; Clave = "$($r.Id)"; Que = "la cuenta $($r.Usuario)" }
    }

    if ($Caso -in 'todos', 'negativas') {
        Paso 'Resenas malas y compras canceladas: cinco cuentas contra el mismo vendedor'
        $y = NuevaCuenta "${Prefijo}v4" $true
        Publicar $y $PRODUCTOS[2]
        for ($k = 0; $k -lt $NEGATIVAS.Count; $k++) {
            $n = NuevaCuenta "${Prefijo}n$($k + 1)" $false
            $pedido = ComprarYResenar $n $y $PRODUCTOS[2] (1 + ($k % 2)) $NEGATIVAS[$k]
            Cancelar $n $pedido
        }
        $esperadas += [pscustomobject]@{ Tipo = 'resenas_negativas_canceladas_vendedor'; Clave = "$($y.Id)"; Que = "el vendedor $($y.Usuario), como victima" }
    }

    if ($Caso -in 'todos', 'repetidas') {
        Paso 'Resenas repetidas: una cuenta deja la misma resena en cinco productos'
        $z = NuevaCuenta "${Prefijo}v5" $true
        foreach ($p in $PRODUCTOS) { Publicar $z $p }
        $u = NuevaCuenta "${Prefijo}u1" $false
        ComprarTodoYResenar $u $z $PRODUCTOS 5 $REPETIDAS
        $totalTexto += $PRODUCTOS.Count
        $idsTexto += $u.Id
        $esperadas += [pscustomobject]@{ Tipo = 'resenas_repetidas'; Clave = "$($u.Id)"; Que = "la cuenta $($u.Usuario)" }
    }

    $productoParecidas = $null
    if ($Caso -in 'todos', 'parecidas_producto') {
        $productoParecidas = ProductoSinSenal 'resenas_parecidas_producto'
        Paso "Resenas parecidas en un producto: seis cuentas, casi la misma resena, sobre $($productoParecidas.nombre)"
        SeisSobreUnProducto 'p' $productoParecidas $PARECIDAS_PRODUCTO 5
        $esperadas += [pscustomobject]@{ Tipo = 'resenas_parecidas_producto'; Clave = "p$($productoParecidas.id)"; Que = "el producto $($productoParecidas.nombre)" }
    }

    if ($Caso -in 'todos', 'incoherentes_producto') {
        $excepto = if ($productoParecidas) { $productoParecidas.id } else { 0 }
        $productoIncoherente = ProductoSinSenal 'notas_incoherentes_producto' $excepto
        Paso "Notas incoherentes en un producto: seis cuentas, 5 estrellas y textos malos, sobre $($productoIncoherente.nombre)"
        SeisSobreUnProducto 'i' $productoIncoherente $MALAS_PRODUCTO 5
        $esperadas += [pscustomobject]@{ Tipo = 'notas_incoherentes_producto'; Clave = "p$($productoIncoherente.id)"; Que = "el producto $($productoIncoherente.nombre)" }
    }
} catch {
    Mal "La demo se detuvo: $($_.Exception.Message)"
    exit 1
}

if ($totalTexto -gt 0) {
    Paso "Esperando que las $totalTexto resenas de texto tengan su vector y su valoracion, hasta $Espera s"
    if (EsperarValoradas $idsTexto $totalTexto) {
        Ok "Las $totalTexto estan en vector_comentario con su vector y su valoracion"
    } else {
        Mal 'No llegaron todas. Mira que el backend este corriendo y que Ollama conteste (GET /vectores)'
        exit 1
    }
}

Paso 'Esperando que cada senal salga sola, hasta 30 s'
$faltan = @($esperadas)
for ($i = 0; $i -lt 30 -and $faltan.Count -gt 0; $i += 2) {
    $siguen = @()
    foreach ($e in $faltan) {
        if (HaySenal $e.Tipo $e.Clave) {
            Ok ("{0}, {1}, a los {2:N0} s de empezar" -f $e.Tipo, $e.Que, ((Get-Date) - $inicio).TotalSeconds)
        } else {
            $siguen += $e
        }
    }
    $faltan = $siguen
    if ($faltan.Count -gt 0) { Start-Sleep -Seconds 2 }
}

if ($faltan.Count -gt 0) {
    Av "$($faltan.Count) no salieron solas. Corro los detectores una vez, sin esperar los 15 minutos"
    & node (Join-Path $PSScriptRoot 'pruebas\correr_detectores_resenas.cjs')
}

$fallos = 0
foreach ($e in $faltan) {
    if (HaySenal $e.Tipo $e.Clave) {
        Ok "$($e.Tipo), $($e.Que), con los detectores"
    } else {
        Mal "No aparecio $($e.Tipo) para $($e.Que)"
        $fallos++
    }
}

Write-Host ''
Write-Host '=============================================================='
if ($fallos -eq 0) {
    Write-Host " Listo. $($esperadas.Count) de $($esperadas.Count) senales guardadas." -ForegroundColor Green
} else {
    Write-Host " $fallos de $($esperadas.Count) senales no aparecieron." -ForegroundColor Red
}
Write-Host ' Verlas: panel del admin, Fraude, Resenas en anillo, filtro por tipo.' -ForegroundColor Yellow
Write-Host '=============================================================='
if (-not $SinAbrir) { Start-Process "$Frontend/panel?s=fraude&t=resenas" }
if ($fallos -gt 0) { exit 1 }
exit 0
