# demo-entrega-final.ps1
# Lo de la Entrega final y el buscador, ensenado en vivo. Cada parte habla
# primero directo con su base, y al final pide lo mismo a la ruta del backend
# que usa la app (desde ced29f5 de Jose David, 2026-09-26). Si el backend no
# esta corriendo, ese ultimo paso solo avisa y lo de la base igual se ve.
#
#   .\demo-entrega-final.ps1 -Parte acceso                      los usuarios de Redis
#   .\demo-entrega-final.ps1 -Parte bases                       el control de acceso de las seis bases
#   .\demo-entrega-final.ps1 -Parte semantica -Producto laptop  los parecidos de un producto
#   .\demo-entrega-final.ps1 -Parte facetas -Texto laptop       filtros facetados y tolerancia
#   .\demo-entrega-final.ps1 -Parte vectores                    quien mantiene los vectores al dia
#   .\demo-entrega-final.ps1 -Parte rastro -Texto laptop        lo que ClickHouse guarda de una busqueda con filtros
#   .\demo-entrega-final.ps1 -Parte intencion -Texto "algo para salir a pedalear"   buscar por lo que se quiere
#   .\demo-entrega-final.ps1 -Parte clasificador                como leyo el clasificador cada resena
#   .\demo-entrega-final.ps1 -Parte hibrida -Texto "labtop gamer"   palabras y significado en una lista
#   .\demo-entrega-final.ps1 -Parte sugerencias -Texto "Laptop ligera para estudiantes"   al proponer un producto
#   .\demo-entrega-final.ps1 -Parte compartir                   el ACL de la aplicacion, por oferta
#   .\demo-entrega-final.ps1 -Parte categorias -Producto laptop  tambien compraron, primero la misma categoria
#
# QUE ENSENA CADA PARTE
# ==================================================
#   acceso     Cada usuario de Redis intenta lo mismo y se ve que contesta Redis.
#              Lo destructivo (FLUSHALL, SHUTDOWN) no se ejecuta, se le pregunta
#              a Redis con ACL DRYRUN si lo dejaria pasar. Escribe una sola clave
#              bajo mesh:demo:acceso y la borra al final
#   bases      Corre bash seguridad/prueba_acceso.sh: en PostgreSQL, MongoDB,
#              ClickHouse y Elasticsearch, que mesh_backend hace lo suyo y no
#              puede crear ni borrar tablas, colecciones, indices o usuarios, y
#              que mesh_lectura solo mira. En Neo4j, que no tiene roles. Al final
#              la de Redis. No cambia nada de la tienda
#   semantica  Busca un producto por nombre y pide sus parecidos a
#              PostgreSQL con la misma consulta que SimilaresService (pgvector,
#              tabla vector_producto desde la migracion 040), con la similitud
#              de cada uno, y la compara con la busqueda exacta contra todos
#              para ensenar lo que ahorra el indice HNSW
#   facetas    La consulta de elastic/pruebas/facetas.py contra el indice real.
#              Solo lee
#   vectores   Cuantos productos y cuantas resenas tienen vector, cuantos
#              esperan a los workers del backend y si el backend llega a
#              Ollama con el modelo. Solo lee
#   intencion  Pide la frase a GET /buscador/productos/intencion y ensena cada
#              producto con la resena que lo explica, y al lado lo que da la
#              busqueda por nombre con la misma frase. Solo lee
#   clasificador  Cuantas resenas leyo el clasificador como malas, buenas,
#              dudosas o cortas, algunas cuyas estrellas contradicen el texto, y
#              cuantas senales de notas incoherentes hay. Solo lee
#   hibrida    GET /buscador/productos/hibrida: cada producto con su lugar en la
#              busqueda por palabras y en la de significado, y la misma frase
#              solo por palabras al lado. Solo lee
#   sugerencias  POST /vendedor/productos/sugerencias con la sesion del admin: en
#              que categoria suele ir y que parecidos ya hay. No crea nada
#   rastro     Hace UNA busqueda con filtros por el backend, ensena la fila que
#              quedo en ClickHouse con sus facetas y la borra al final, para
#              que no cuente en las tendencias
#   compartir  El ACL de la aplicacion (migracion 049). ventas.norte le da a
#              ventas.sur ver y editar sobre una oferta suya, ventas.sur ve,
#              edita y no puede poner descuento, ventas.norte le quita editar y
#              deja de poder al instante, y al final el registro. Deja la
#              oferta como estaba (sin permisos, la misma existencia) y las
#              filas del registro, que son historia
#   categorias Tambien compraron de un producto, directo en Neo4j con el grupo
#              de cada uno (0 la misma categoria, 1 el resto) y por la ruta de
#              la ficha. Solo lee
#   permisos   El ACL de funcionalidades (migracion 050). La matriz de
#              permisos_por_rol en PostgreSQL, cada rol llamando DIRECTO a las
#              mismas rutas (401 sin sesion, 403 sin el permiso), y en vivo: una
#              linea de SQL le quita ofertas.publicar al vendedor, el vendedor
#              recibe 403 con el permiso que falta, el intento queda en
#              auditoria_permiso, y otra linea se lo devuelve. Deja la matriz como
#              estaba y las filas del registro, que son historia
#
# Nada de tuberias hacia docker exec. PowerShell 5.1 les mete un BOM. Lo que
# va a Mongo o a PostgreSQL viaja como archivo con docker cp.

param(
    [ValidateSet('acceso', 'bases', 'semantica', 'facetas', 'vectores', 'rastro', 'intencion', 'clasificador', 'hibrida', 'sugerencias', 'compartir', 'categorias', 'permisos')]
    [string]$Parte = 'acceso',
    [string]$Producto = 'laptop',
    [string]$Texto = 'laptop',
    [string]$Backend = 'http://localhost:3000'
)

function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Av($t)   { Write-Host "   $t" -ForegroundColor Yellow }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

$env_ = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.+)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
$sinBom = New-Object System.Text.UTF8Encoding($false)
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'mesh-demo-final'
New-Item -ItemType Directory -Force $tmp | Out-Null

function Contenedor($nombre) {
    docker ps *> $null
    if ($LASTEXITCODE -ne 0) { Mal "Docker no responde. Corre .\arrancar.ps1"; exit 1 }
    if (-not (docker ps --filter "name=^$nombre$" --format "{{.Names}}")) {
        Mal "El contenedor $nombre no esta corriendo. Corre .\arrancar.ps1"
        exit 1
    }
}

function Psql([string]$sql) {
    [IO.File]::WriteAllText((Join-Path $tmp 'demo.sql'), $sql, $sinBom)
    docker cp (Join-Path $tmp 'demo.sql') mesh-postgres:/tmp/demo_final.sql | Out-Null
    $salida = docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -qtAX -v ON_ERROR_STOP=1 -f /tmp/demo_final.sql 2>&1
    if ($LASTEXITCODE -ne 0) { Mal "PostgreSQL contesto con error. $salida"; exit 1 }
    return @($salida | ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
}

# GET a la ruta del backend. Devuelve el payload, o $null si no contesta.
function Api([string]$ruta) {
    try {
        $r = Invoke-RestMethod -Uri "$Backend$ruta" -TimeoutSec 20
        return ,$r.payload
    } catch {
        Av "El backend no contesto en $Backend$ruta. $($_.Exception.Message)"
        return $null
    }
}

function ClickHouse([string]$sql) {
    $salida = docker exec mesh-clickhouse clickhouse-client `
        --user $env_['CLICKHOUSE_USER'] --password $env_['CLICKHOUSE_PASSWORD'] `
        --database $env_['CLICKHOUSE_DB'] --query $sql 2>&1
    if ($LASTEXITCODE -ne 0) { Mal "ClickHouse contesto con error. $salida"; exit 1 }
    return @($salida | ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
}

$ES_URL = 'http://localhost:9200'
# Con la seguridad de Elasticsearch encendida (2026-10-23), como elastic.
$ES_CABECERA = @{ Authorization = 'Basic ' + [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("elastic:$($env_['ELASTIC_PASSWORD'])")) }
$ES_INDICE = 'mesh_productos'

# Un POST a Elasticsearch leido como UTF-8. Invoke-RestMethod de PowerShell 5.1
# no siempre respeta el charset de la respuesta y las tildes del texto de una
# resena salian rotas ("venA-a" por "venia").
function Es-Post([string]$ruta, [string]$cuerpo) {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Headers $ES_CABECERA -Uri "$ES_URL$ruta" -ContentType 'application/json' -Body $cuerpo -TimeoutSec 30
    $bytes = $r.RawContentStream.ToArray()
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

# Los vectores viven en PostgreSQL desde la migracion 040 (2026-10-16): la
# tabla vector_producto, con un indice HNSW de pgvector.
function Contar-ConVector {
    return [int](@(Psql "SELECT count(*) FROM vector_producto;")[0])
}

function Mongo([string]$js) {
    [IO.File]::WriteAllText((Join-Path $tmp 'demo.js'), $js, $sinBom)
    docker cp (Join-Path $tmp 'demo.js') mesh-mongo:/tmp/demo_final.js | Out-Null
    $cmd = 'mongosh --quiet -u $MONGO_INITDB_ROOT_USERNAME -p $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin $MONGO_INITDB_DATABASE --file /tmp/demo_final.js'
    $salida = docker exec mesh-mongo sh -c $cmd 2>&1
    if ($LASTEXITCODE -ne 0) { Mal "MongoDB contesto con error. $salida"; exit 1 }
    return @($salida | ForEach-Object { "$_" } | Where-Object { $_.Trim().StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
}


# ============================================================
# compartir y categorias (2026-10-26)
# ============================================================

# Una sesion del backend por cuenta. Devuelve la sesion web o sale.
function Entrar([string]$correo, [string]$clave) {
    $cuerpo = @{ identificador = $correo; contrasena = $clave } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "$Backend/usuario/login" -Method Post -ContentType 'application/json' -Body $cuerpo -SessionVariable s -TimeoutSec 20 | Out-Null
        return $s
    } catch {
        Mal "No se pudo entrar como $correo. $($_.Exception.Message)"
        exit 1
    }
}

# Una peticion con sesion. Devuelve @{ codigo; datos } sin lanzar en un 4xx;
# en un 4xx datos es el cuerpo del error ({ ok, mensaje }), si lo hay.
# Content-Type solo con cuerpo: Fastify rechaza un DELETE que dice traer JSON
# y no trae nada. Sin sesion ($null) va sin cookie.
function Llamar($sesion, [string]$metodo, [string]$ruta, $cuerpo = $null) {
    $p = @{ Uri = "$Backend$ruta"; Method = $metodo; TimeoutSec = 20; UseBasicParsing = $true }
    if ($null -ne $sesion) { $p.WebSession = $sesion }
    if ($null -ne $cuerpo) { $p.ContentType = 'application/json'; $p.Body = ($cuerpo | ConvertTo-Json -Compress) }
    try {
        $r = Invoke-WebRequest @p
        $texto = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return @{ codigo = [int]$r.StatusCode; datos = ($texto | ConvertFrom-Json) }
    } catch {
        $codigo = 0
        $datos = $null
        if ($_.Exception.Response) {
            $codigo = [int]$_.Exception.Response.StatusCode
            # PowerShell 5.1 ya leyo el cuerpo del error y lo deja en ErrorDetails.
            try { $datos = $_.ErrorDetails.Message | ConvertFrom-Json } catch { $datos = $null }
        }
        return @{ codigo = $codigo; datos = $datos }
    }
}

function Esperado([int]$codigo, [int]$debe, [string]$que) {
    if ($codigo -eq $debe) { Ok "$que ($codigo)" } else { Mal "$que dio $codigo, se esperaba $debe" }
}

if ($Parte -eq 'compartir') {
    Contenedor 'mesh-postgres'
    Paso 'El ACL de la aplicacion, por oferta (migracion 049, ADR-24)'
    Write-Host '   ventas.norte es la duena, ventas.sur recibe permisos. Todo pasa por el backend.' -ForegroundColor DarkGray
    $norte = Entrar 'ventas.norte@mesh.com' 'Vendedor123'
    $sur = Entrar 'ventas.sur@mesh.com' 'Vendedor123'

    # Una oferta de ventas.norte activa, sin descuento, sin venta relampago y
    # sin nadie con permisos.
    $fila = @(Psql @"
SELECT o.id_oferta || '|' || coalesce(pc.nombre, 'Producto ' || o.id_producto_mongo) || '|' || o.stock
  FROM oferta o
  JOIN usuarios u USING (id_usuario)
  JOIN estado_oferta e USING (id_estado_oferta)
  LEFT JOIN producto_catalogo pc ON pc.id_producto_mongo = o.id_producto_mongo
 WHERE u.correo_electronico = 'ventas.norte@mesh.com' AND e.estado_oferta_nombre = 'activa'
   AND o.porcentaje_descuento IS NULL AND NOT o.es_inventario_limitado
   AND NOT EXISTS (SELECT 1 FROM permiso_oferta p WHERE p.id_oferta = o.id_oferta)
 ORDER BY o.id_oferta LIMIT 1;
"@)[0]
    if (-not $fila) { Mal 'No hay una oferta de ventas.norte para la demo.'; exit 1 }
    $of, $nombre, $stock = $fila -split '\|'
    Ok "Oferta $of, $nombre, $stock unidades"

    Paso '1. Sin entrada en la lista, ventas.sur no ve nada'
    Esperado (Llamar $sur 'GET' "/compartidas/ofertas/$of").codigo 404 'ventas.sur pide la oferta'
    Write-Host '   El mismo 404 de una oferta ajena. No se le confirma que existe. Con alguna entrada, lo que le falte es 403.' -ForegroundColor DarkGray

    Paso '2. ventas.norte le da ver y editar por diez minutos'
    $vence = (Get-Date).ToUniversalTime().AddMinutes(10).ToString('yyyy-MM-ddTHH:mm:ssZ')
    Esperado (Llamar $norte 'POST' "/vendedor/ofertas/$of/permisos" @{ correo = 'ventas.sur@mesh.com'; permisos = @('ver', 'editar'); fecha_vencimiento = $vence }).codigo 201 'permisos dados'
    $lista = @(Psql "SELECT t.tipo_permiso_oferta_nombre || ' hasta ' || to_char(p.fecha_vencimiento AT TIME ZONE 'America/Guatemala', 'HH24:MI') FROM permiso_oferta p JOIN tipo_permiso_oferta t USING (id_tipo_permiso_oferta) JOIN usuarios u ON u.id_usuario = p.id_usuario WHERE p.id_oferta = $of AND u.correo_electronico = 'ventas.sur@mesh.com' ORDER BY 1;")
    Write-Host "   En permiso_oferta: $($lista -join ', ')" -ForegroundColor DarkGray

    Paso '3. Cada permiso por separado'
    $r = Llamar $sur 'GET' "/compartidas/ofertas/$of"
    Esperado $r.codigo 200 "ventas.sur ve la oferta, de $($r.datos.payload.dueno.usuario)"
    $r = Llamar $sur 'POST' "/compartidas/ofertas/$of/descuento" @{ porcentaje_descuento = 10 }
    Esperado $r.codigo 403 "pero no le puede poner descuento. $($r.datos.mensaje)"
    $r = Llamar $sur 'PATCH' "/compartidas/ofertas/$of" @{ ajuste_stock = 1 }
    Esperado $r.codigo 200 "edita la existencia, ahora $($r.datos.payload.stock)"
    Esperado (Llamar $sur 'PATCH' "/compartidas/ofertas/$of" @{ estado = 'pausada' }).codigo 400 'el estado no, eso sigue siendo de la duena'
    Esperado (Llamar $sur 'PATCH' "/vendedor/ofertas/$of" @{ ajuste_stock = 1 }).codigo 404 'y la ruta propia de ventas.norte sigue cerrada para ventas.sur'
    $r = Llamar $sur 'PATCH' "/compartidas/ofertas/$of" @{ ajuste_stock = -1 }
    Esperado $r.codigo 200 "devuelve la existencia, otra vez $($r.datos.payload.stock)"

    Paso '4. ventas.norte le quita editar, y vale al instante'
    $ent = (Llamar $norte 'GET' "/vendedor/ofertas/$of/permisos").datos.payload.permisos | Where-Object { $_.permiso -eq 'editar' }
    Esperado (Llamar $norte 'DELETE' "/vendedor/ofertas/$of/permisos/$($ent.id_permiso_oferta)").codigo 200 'editar quitado'
    $r = Llamar $sur 'PATCH' "/compartidas/ofertas/$of" @{ ajuste_stock = 1 }
    Esperado $r.codigo 403 "ventas.sur intenta editar otra vez. $($r.datos.mensaje)"
    Esperado (Llamar $sur 'GET' "/compartidas/ofertas/$of").codigo 200 'ver le sigue'

    Paso '5. El registro de la oferta, lo que ve la duena'
    $reg = @((Llamar $norte 'GET' "/vendedor/ofertas/$of/permisos").datos.payload.registro | Select-Object -First 8)
    [array]::Reverse($reg)
    foreach ($x in $reg) {
        $quien = if ($x.receptor) { " a $($x.receptor)" } else { '' }
        $color = if ($x.accion -eq 'negado') { 'Red' } else { 'White' }
        Write-Host ("   {0,-16} {1,-10} {2}{3}" -f $x.accion, $x.permiso, $x.actor, $quien) -ForegroundColor $color
    }

    Paso 'Limpieza'
    foreach ($e in @((Llamar $norte 'GET' "/vendedor/ofertas/$of/permisos").datos.payload.permisos)) {
        Llamar $norte 'DELETE' "/vendedor/ofertas/$of/permisos/$($e.id_permiso_oferta)" | Out-Null
    }
    $quedan = @(Psql "SELECT count(p.id_permiso_oferta) || ' permisos, ' || stock || ' unidades' FROM oferta o LEFT JOIN permiso_oferta p USING (id_oferta) WHERE o.id_oferta = $of GROUP BY stock;")[0]
    Ok "La oferta $of queda con $quedan, como estaba. El registro se queda, es historia."
    exit 0
}

if ($Parte -eq 'permisos') {
    Contenedor 'mesh-postgres'
    Paso 'El ACL de funcionalidades, por rol (migracion 050, ADR-26)'
    Write-Host '   Cada ruta privada pide un permiso y rol_permiso dice que rol lo tiene. Todo se llama DIRECTO al backend, sin la pagina.' -ForegroundColor DarkGray
    $admin = Entrar 'admin@mesh.com' 'Admin123'
    $vendedor = Entrar 'ventas.sur@mesh.com' 'Vendedor123'
    $comprador = Entrar 'compradora.norte@mesh.com' 'Comprador123'

    Paso '1. La lista vive en PostgreSQL (vista permisos_por_rol)'
    $filas = @(Psql @"
SELECT rpad(permiso, 26) || rpad(CASE WHEN comprador THEN 'si' ELSE '-' END, 11)
       || rpad(CASE WHEN vendedor THEN 'si' ELSE '-' END, 10) || CASE WHEN admin THEN 'si' ELSE '-' END
  FROM permisos_por_rol
 WHERE permiso IN ('carrito.comprar', 'ofertas.publicar', 'ofertas.compartir', 'usuarios.editar', 'fraude.resolver', 'permisos.administrar');
"@)
    Write-Host ('   {0,-26}{1,-11}{2,-10}{3}' -f 'permiso', 'comprador', 'vendedor', 'admin') -ForegroundColor DarkGray
    foreach ($f in $filas) { Write-Host "   $f" }
    $total = @(Psql "SELECT (SELECT count(*) FROM permiso) || ' permisos en ' || (SELECT count(*) FROM modulo_permiso) || ' modulos, ' || (SELECT count(*) FROM rol_permiso) || ' entradas en rol_permiso';")[0]
    Write-Host "   $total" -ForegroundColor DarkGray

    Paso '2. Sin sesion, nadie pasa'
    Esperado (Llamar $null 'GET' '/admin/usuarios').codigo 401 'GET /admin/usuarios sin cookie'
    Esperado (Llamar $null 'POST' '/vendedor/ofertas' @{}).codigo 401 'POST /vendedor/ofertas sin cookie'

    Paso '3. Cada rol llama directo a las mismas rutas'
    $r = Llamar $comprador 'POST' '/vendedor/ofertas' @{}
    Esperado $r.codigo 403 "la compradora intenta publicar una oferta. $($r.datos.mensaje)"
    Esperado (Llamar $vendedor 'POST' '/vendedor/ofertas' @{}).codigo 400 'el vendedor pasa el guard (el 400 es del cuerpo vacio, no del permiso)'
    $r = Llamar $vendedor 'GET' '/admin/usuarios'
    Esperado $r.codigo 403 "el vendedor pide las cuentas del admin. $($r.datos.mensaje)"
    Esperado (Llamar $admin 'GET' '/admin/usuarios').codigo 200 'el admin si las ve'

    $sqlId = "SELECT p.id_permiso FROM permiso p JOIN modulo_permiso m USING (id_modulo_permiso) WHERE m.modulo_permiso_nombre = 'ofertas' AND p.permiso_nombre = 'publicar'"
    $inicio = @(Psql "SELECT coalesce(max(id_auditoria_permiso), 0) FROM auditoria_permiso;")[0]
    try {
        Paso '4. Una linea de SQL le quita ofertas.publicar al vendedor'
        Write-Host '   DELETE FROM rol_permiso WHERE id_rol_usuario = 2 AND id_permiso = (ofertas.publicar)' -ForegroundColor DarkGray
        Psql "DELETE FROM rol_permiso WHERE id_rol_usuario = 2 AND id_permiso = ($sqlId);" | Out-Null
        $r = Llamar $vendedor 'POST' '/vendedor/ofertas' @{}
        Esperado $r.codigo 403 "el mismo vendedor, la peticion siguiente, sin reiniciar nada. $($r.datos.mensaje)"
        Esperado (Llamar $vendedor 'GET' '/vendedor/ofertas').codigo 200 'ver sus ofertas le sigue, es otro permiso'

        Paso '5. Otra linea se lo devuelve'
        Write-Host '   INSERT INTO rol_permiso (id_rol_usuario, id_permiso) VALUES (2, (ofertas.publicar))' -ForegroundColor DarkGray
        Psql "INSERT INTO rol_permiso (id_rol_usuario, id_permiso) SELECT 2, ($sqlId) ON CONFLICT DO NOTHING;" | Out-Null
        Esperado (Llamar $vendedor 'POST' '/vendedor/ofertas' @{}).codigo 400 'el vendedor vuelve a pasar el guard'
    } finally {
        Psql "INSERT INTO rol_permiso (id_rol_usuario, id_permiso) SELECT 2, ($sqlId) ON CONFLICT DO NOTHING;" | Out-Null
    }

    Paso '6. El registro, en auditoria_permiso'
    $reg = @(Psql @"
SELECT to_char(a.fecha AT TIME ZONE 'America/Guatemala', 'HH24:MI:SS') || '  ' || rpad(a.accion, 8) || rpad(coalesce(u.usuario, a.id_usuario_actor::text), 18)
       || rpad(r.rol_usuario_nombre, 11) || rpad(m.modulo_permiso_nombre || '.' || p.permiso_nombre, 20) || coalesce(a.metodo || ' ' || a.ruta, '')
  FROM auditoria_permiso a
  JOIN rol_usuario r USING (id_rol_usuario)
  JOIN permiso p USING (id_permiso)
  JOIN modulo_permiso m USING (id_modulo_permiso)
  LEFT JOIN usuarios u ON u.id_usuario = a.id_usuario_actor
 WHERE a.id_auditoria_permiso > $inicio
 ORDER BY a.id_auditoria_permiso;
"@)
    foreach ($x in $reg) { Write-Host "   $x" -ForegroundColor $(if ($x -match 'negado') { 'Red' } else { 'White' }) }
    $quedan = @(Psql "SELECT count(*) FROM rol_permiso;")[0]
    Ok "La matriz queda como estaba ($quedan entradas). El registro se queda, es historia."
    exit 0
}

if ($Parte -eq 'categorias') {
    Contenedor 'mesh-postgres'
    Contenedor 'mesh-neo4j'
    $patron = $Producto -replace "'", ''
    $fila = @(Psql @"
SELECT pc.id_producto_mongo || '|' || pc.nombre || '|' || c.nombre
  FROM producto_catalogo pc JOIN categorias c USING (id_categoria)
 WHERE pc.nombre ILIKE '%$patron%' AND pc.estado = 'activo'
   AND EXISTS (SELECT 1 FROM pedido_producto pp WHERE pp.id_producto_mongo = pc.id_producto_mongo)
 ORDER BY pc.id_producto_mongo LIMIT 1;
"@)[0]
    if (-not $fila) { Mal "Ningun producto comprado con '$Producto' en el nombre."; exit 1 }
    $id, $nombre, $categoria = $fila -split '\|'

    Paso "Quienes compraron $nombre ($categoria) tambien llevaron, en Neo4j (ADR-25)"
    $cypher = "MATCH (base:Producto {id: $id})<-[:DE]-(:Compra)<-[:HIZO]-(cuenta:Usuario) MATCH (cuenta)-[:HIZO]->(:Compra)-[:DE]->(rec:Producto) WHERE rec <> base WITH base, rec, count(DISTINCT cuenta) AS compradores WITH rec, compradores, CASE WHEN base.id_categoria IS NOT NULL AND rec.id_categoria = base.id_categoria THEN 0 ELSE 1 END AS grupo RETURN grupo, compradores, rec.categoria, rec.nombre ORDER BY grupo, compradores DESC, rec.id LIMIT 10;"
    $salida = docker exec mesh-neo4j cypher-shell -u neo4j -p $env_['NEO4J_PASSWORD'] --format plain $cypher 2>&1
    if ($LASTEXITCODE -ne 0) { Mal "Neo4j contesto con error. $salida"; exit 1 }
    Write-Host '   grupo  compradores  categoria / producto' -ForegroundColor DarkGray
    foreach ($l in @($salida | Select-Object -Skip 1)) {
        $g, $n, $cat, $prod = ("$l" -replace '"', '') -split ', ', 4
        $color = if ($g -eq '0') { 'Green' } else { 'White' }
        Write-Host ("   {0,5}  {1,11}  {2} / {3}" -f $g, $n, $cat, $prod) -ForegroundColor $color
    }
    Write-Host '   Grupo 0 es la misma categoria, va siempre primero aunque tenga menos compradores.' -ForegroundColor DarkGray
    Write-Host '   La categoria vive en cada :Producto (id_categoria), la pone al dia GrafoCategoriasSyncService.' -ForegroundColor DarkGray

    Paso "Lo mismo por la ruta de la ficha, GET /productos/$id/tambien-compraron"
    $lista = Api "/productos/$id/tambien-compraron"
    if ($null -ne $lista) {
        foreach ($x in @($lista)) {
            $marca = if ($x.misma_categoria) { 'misma categoria' } else { 'otra' }
            Write-Host ("   {0,-16} {1,3} compradores  {2}" -f $marca, $x.compradores, $x.producto.nombre) -ForegroundColor $(if ($x.misma_categoria) { 'Green' } else { 'White' })
        }
    }
    exit 0
}


# ============================================================
# acceso
# ============================================================
if ($Parte -eq 'acceso') {
    Contenedor 'mesh-redis'
    $pass = @{
        backend    = $env_['REDIS_BACKEND_PASSWORD']
        default    = $env_['REDIS_PASSWORD']
        inspeccion = $env_['REDIS_INSPECCION_PASSWORD']
        operador   = $env_['REDIS_OPERADOR_PASSWORD']
    }
    foreach ($u in $pass.Keys) {
        if (-not $pass[$u]) { Mal "Falta la contrasena de $u en el .env. Corre .\arrancar.ps1, que la agrega"; exit 1 }
    }

    function Como($u, $p) {
        $r = docker exec mesh-redis redis-cli --no-auth-warning --user $u --pass $p @args 2>&1
        return (@($r | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -First 2) -join ' '
    }
    function Linea($u, $que, $respuesta) {
        $negado = $respuesta -match 'NOPERM|WRONGPASS|NOAUTH|no permissions'
        $color = if ($negado) { 'Red' } else { 'Green' }
        $marca = if ($negado) { 'NEGADO ' } else { 'PERMITE' }
        if ($respuesta.Length -gt 60) { $respuesta = $respuesta.Substring(0, 60) + '...' }
        Write-Host ("   {0,-11} {1,-44} " -f $u, $que) -NoNewline
        Write-Host ("{0}  {1}" -f $marca, $respuesta) -ForegroundColor $color
    }
    # Pregunta sin ejecutar. Sirve para lo que no se puede intentar de verdad.
    function Dryrun($u) { return Como operador $pass.operador ACL DRYRUN $u @args }

    $clave = 'mesh:demo:acceso'

    Paso "Quien existe"
    # Sin Como, que corta en dos lineas: son cuatro usuarios.
    Write-Host "   $((docker exec mesh-redis redis-cli --no-auth-warning --user operador --pass $pass.operador ACL USERS 2>&1) -join ' ')"
    Linea 'sin usuario' 'PING sin contrasena' ((docker exec mesh-redis redis-cli PING 2>&1) -join ' ')
    Linea 'inspeccion' 'entrar con la contrasena del backend' (Como inspeccion $pass.default PING)

    Paso "backend, el del backend. Solo las claves de la tienda, mesh:*"
    Linea 'backend' "SET $clave" (Como backend $pass.backend SET $clave hola EX 300)
    Linea 'backend' 'EVAL, el Lua de la venta relampago' (Como backend $pass.backend EVAL "return redis.call('GET', KEYS[1])" 1 $clave)
    Linea 'backend' 'GET otra:clave, fuera de mesh:' (Como backend $pass.backend GET 'otra:clave')
    Linea 'backend' 'CONFIG GET maxmemory' (Como backend $pass.backend CONFIG GET maxmemory)
    Linea 'backend' 'FLUSHALL, preguntado con DRYRUN' (Dryrun backend FLUSHALL)

    Paso "default, el de los scripts. Trabaja con datos y no administra"
    Linea 'default' "SET $clave" (Como default $pass.default SET $clave hola EX 300)
    Linea 'default' "GET $clave" (Como default $pass.default GET $clave)
    Linea 'default' 'EVAL, el Lua de la venta relampago' (Como default $pass.default EVAL "return redis.call('GET', KEYS[1])" 1 $clave)
    Linea 'default' 'CONFIG GET maxmemory' (Como default $pass.default CONFIG GET maxmemory)
    Linea 'default' 'KEYS *' (Como default $pass.default KEYS '*')
    Linea 'default' 'FLUSHALL, preguntado con DRYRUN' (Dryrun default FLUSHALL)
    Linea 'default' 'SHUTDOWN, preguntado con DRYRUN' (Dryrun default SHUTDOWN)

    Paso "inspeccion, el de RedisInsight. Solo mira"
    Linea 'inspeccion' "GET $clave" (Como inspeccion $pass.inspeccion GET $clave)
    Linea 'inspeccion' "TTL $clave" (Como inspeccion $pass.inspeccion TTL $clave)
    Linea 'inspeccion' "SET $clave otra" (Como inspeccion $pass.inspeccion SET $clave otra)
    Linea 'inspeccion' "PERSIST $clave" (Como inspeccion $pass.inspeccion PERSIST $clave)
    Linea 'inspeccion' 'EVAL return 1' (Como inspeccion $pass.inspeccion EVAL 'return 1' 0)
    Linea 'inspeccion' "DEL $clave, preguntado con DRYRUN" (Dryrun inspeccion DEL $clave)
    Linea 'default' 'control, la clave sigue igual' (Como default $pass.default GET $clave)

    Paso "operador, mantenimiento a mano. Puede lo que a los otros se les niega"
    Linea 'operador' 'CONFIG GET maxmemory' (Como operador $pass.operador CONFIG GET maxmemory)
    Linea 'operador' 'ACL GETUSER inspeccion' (Como operador $pass.operador ACL GETUSER inspeccion)
    Linea 'operador' "DEL $clave" (Como operador $pass.operador DEL $clave)

    Paso "Las reglas completas, como las ve Redis"
    docker exec mesh-redis redis-cli --no-auth-warning --user operador --pass $pass.operador ACL LIST 2>&1 |
        ForEach-Object { "   " + ("$_" -replace '#[0-9a-f]{64}', '#<hash>') }

    Write-Host ""
    Ok "Los usuarios estan en docker-compose.yml y la prueba completa es  bash redis/prueba_acceso.sh"
    exit 0
}


# ============================================================
# bases
# ============================================================
if ($Parte -eq 'bases') {
    $bash = $null
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if ($git) { $c = Join-Path (Split-Path (Split-Path $git)) 'bin\bash.exe'; if (Test-Path $c) { $bash = $c } }
    if (-not $bash -and (Test-Path 'C:\Program Files\Git\bin\bash.exe')) { $bash = 'C:\Program Files\Git\bin\bash.exe' }
    if (-not $bash) { Mal "No encontre bash (viene con Git para Windows)"; exit 1 }

    Paso "Cada base con su usuario, seguridad/prueba_acceso.sh"
    $global:LASTEXITCODE = 0
    & $bash (Join-Path $PSScriptRoot 'seguridad/prueba_acceso.sh') 2>&1 | ForEach-Object {
        $l = "$_"
        if ($l -match '^\s*OK\b') { Write-Host $l -ForegroundColor Green }
        elseif ($l -match 'FALLA') { Write-Host $l -ForegroundColor Red }
        elseif ($l -match '^\d+\.|RESULTADO') { Write-Host $l -ForegroundColor Cyan }
        else { Write-Host $l }
    }
    Write-Host ""
    Ok "Los usuarios y el porque de cada uno estan en docs/SEGURIDAD.md"
    exit $LASTEXITCODE
}


# ============================================================
# semantica
# ============================================================
if ($Parte -eq 'semantica') {
    Contenedor 'mesh-postgres'
    Contenedor 'mesh-mongo'

    $conVector = Contar-ConVector
    if ($conVector -eq 0) {
        Mal "No hay vectores en vector_producto. Corre .\arrancar.ps1, que los calcula en el paso 7d"
        exit 1
    }

    Paso "Buscando un producto que diga '$Producto'"
    # Como literal JSON, asi una comilla o una barra en lo que se busca no rompe el JS.
    $patron = [Text.RegularExpressions.Regex]::Escape($Producto) | ConvertTo-Json
    $candidatos = Mongo @"
db.productos.find({ nombre: { `$regex: $patron, `$options: 'i' }, estado: 'activo' }, { nombre: 1, 'categoria.nombre': 1 })
  .sort({ _id: 1 }).limit(50).forEach(function (d) {
    print(JSON.stringify({ id: d._id, nombre: d.nombre, cat: (d.categoria && d.categoria.nombre) || '' }));
  });
"@
    if ($candidatos.Count -eq 0) { Mal "Ningun producto activo dice '$Producto'. Prueba con otra palabra"; exit 1 }
    $conFila = @{}
    Psql "SELECT id_producto_mongo FROM vector_producto WHERE id_producto_mongo IN ($(($candidatos | ForEach-Object { [long]$_.id }) -join ','));" |
        ForEach-Object { $conFila[[long]$_] = $true }
    $base = $candidatos | Where-Object { $conFila.ContainsKey([long]$_.id) } | Select-Object -First 1
    if (-not $base) { Mal "Esos productos todavia no tienen vector. Corre .\etl\cargar_vectores.ps1"; exit 1 }
    $id = [long]$base.id
    Ok "$($base.nombre), de $($base.cat) (id $id)"

    # Las mismas dos consultas que SimilaresService del backend, con los mismos
    # ajustes que buscarCercanos(): ef_search 400 e iterative_scan. El bloque 1
    # son los de su misma categoria (producto_catalogo.id_categoria), el bloque
    # 2 los 200 mas cercanos de todo el catalogo, con el vector como constante
    # (asi el ORDER BY puede usar el indice HNSW). Cada fila lleva su bloque y
    # su categoria. Despues, uno por grupo y por bloques, aqui abajo.
    $consulta = @"
SELECT v.vector::text AS v, v.grupo AS g, coalesce(pc.id_categoria, -1) AS c
  FROM vector_producto v LEFT JOIN producto_catalogo pc USING (id_producto_mongo)
 WHERE v.id_producto_mongo = $id \gset
BEGIN;
SELECT set_config('hnsw.ef_search', '400', true) AS ef, set_config('hnsw.iterative_scan', 'strict_order', true) AS it \gset
SELECT '1|' || v.id_producto_mongo || '|' || v.grupo || '|' || (1 - (v.vector <=> :'v'::vector)) || '|' || pc.id_categoria
  FROM vector_producto v JOIN producto_catalogo pc USING (id_producto_mongo)
 WHERE v.activo AND v.id_producto_mongo <> $id AND v.grupo <> :'g' AND pc.id_categoria = :c
 ORDER BY v.vector <=> :'v'::vector
 LIMIT 200;
SELECT '2|' || id_producto_mongo || '|' || grupo || '|' || (1 - (vector <=> :'v'::vector)) || '|' ||
       coalesce((SELECT pc.id_categoria FROM producto_catalogo pc WHERE pc.id_producto_mongo = vector_producto.id_producto_mongo), -1)
  FROM vector_producto
 WHERE activo AND id_producto_mongo <> $id AND grupo <> :'g'
 ORDER BY vector <=> :'v'::vector
 LIMIT 200;
SELECT '0|' || :c;
COMMIT;
"@
    # Primero el bloque 1 entero, despues el 2 sin los grupos ya vistos ni los
    # de su categoria (esos ya estaban en el 1). Seis en total, como la ficha.
    function Por-Bloques($filas) {
        $cat = (@($filas | Where-Object { $_ -like '0|*' })[0]).Split('|')[1]
        $vistos = @{}
        $r = [ordered]@{}
        foreach ($bloque in '1', '2') {
            foreach ($f in $filas) {
                $c = $f.Split('|')
                if ($c.Count -ne 5 -or $c[0] -ne $bloque) { continue }
                if ($r.Count -eq 6) { break }
                if ($vistos.ContainsKey($c[2])) { continue }
                if ($bloque -eq '2' -and $c[4] -eq $cat) { continue }
                $vistos[$c[2]] = $true
                $r[[long]$c[1]] = [pscustomobject]@{
                    s = [double]::Parse($c[3], [Globalization.CultureInfo]::InvariantCulture)
                    misma = ($bloque -eq '1')
                }
            }
        }
        return $r
    }
    function Uno-PorGrupo($filas) {
        $vistos = @{}
        $r = [ordered]@{}
        foreach ($f in $filas) {
            $c = $f.Split('|')
            if ($c.Count -ne 3 -or $vistos.ContainsKey($c[1])) { continue }
            $vistos[$c[1]] = $true
            $r[[long]$c[0]] = [double]::Parse($c[2], [Globalization.CultureInfo]::InvariantCulture)
            if ($r.Count -eq 6) { break }
        }
        return $r
    }

    Paso "Los mas parecidos por su descripcion, primero los de su categoria y despues el resto"
    $sim = Por-Bloques (Psql $consulta)
    if ($sim.Count -eq 0) { Av "No salio ninguno parecido"; exit 0 }
    $nombres = @{}
    Mongo @"
db.productos.find({ _id: { `$in: [$(($sim.Keys) -join ',')] } }, { nombre: 1, 'categoria.nombre': 1 }).forEach(function (d) {
  print(JSON.stringify({ id: d._id, nombre: d.nombre, cat: (d.categoria && d.categoria.nombre) || '' }));
});
"@ | ForEach-Object { $nombres[[long]$_.id] = $_ }
    Write-Host ("   {0,-9} {1,-46} {2}" -f 'SIMILITUD', 'PRODUCTO', 'CATEGORIA') -ForegroundColor DarkGray
    $titulo = ''
    foreach ($k in $sim.Keys) {
        $bloque = if ($sim[$k].misma) { "   Bloque 1, de su misma categoria, $($base.cat)" } else { '   Bloque 2, el resto del catalogo' }
        if ($bloque -ne $titulo) { Write-Host $bloque -ForegroundColor DarkGray; $titulo = $bloque }
        $n = $nombres[$k]
        $nombre = if ($n) { $n.nombre } else { "(id $k, no esta en Mongo)" }
        if ($nombre.Length -gt 45) { $nombre = $nombre.Substring(0, 45) }
        $cat = if ($n) { $n.cat } else { '' }
        $color = if ($sim[$k].misma) { 'Green' } else { 'Gray' }
        $coseno = [math]::Round($sim[$k].s * 100, 1)
        Write-Host ("   {0,8}% {1,-46} {2}" -f $coseno, $nombre, $cat) -ForegroundColor $color
    }
    Write-Host "   Igual que Quienes lo compraron tambien llevaron, los de su categoria van siempre primero" -ForegroundColor DarkGray

    Paso "Como lo resuelve PostgreSQL, con el indice HNSW o comparando contra todos"
    # EXPLAIN ANALYZE de la misma consulta dos veces: una obligando al indice
    # (enable_seqscan off) y otra sin el (enable_indexscan off), que es el
    # recorrido exacto. Cada una corre dos veces y se queda la segunda, que ya
    # no paga la carga en memoria.
    function Medir([string]$ajuste) {
        $sql = @"
SELECT vector::text AS v, grupo AS g FROM vector_producto WHERE id_producto_mongo = $id \gset
BEGIN;
SET LOCAL $ajuste = off;
SELECT set_config('hnsw.ef_search', '400', true) AS ef, set_config('hnsw.iterative_scan', 'strict_order', true) AS it \gset
EXPLAIN (ANALYZE, COSTS OFF)
SELECT id_producto_mongo FROM vector_producto
 WHERE activo AND id_producto_mongo <> $id AND grupo <> :'g'
 ORDER BY vector <=> :'v'::vector LIMIT 200;
EXPLAIN (ANALYZE, COSTS OFF)
SELECT id_producto_mongo FROM vector_producto
 WHERE activo AND id_producto_mongo <> $id AND grupo <> :'g'
 ORDER BY vector <=> :'v'::vector LIMIT 200;
SELECT string_agg(x || '|' || g || '|' || s, ',') FROM (
  SELECT id_producto_mongo AS x, grupo AS g, (1 - (vector <=> :'v'::vector)) AS s FROM vector_producto
   WHERE activo AND id_producto_mongo <> $id AND grupo <> :'g'
   ORDER BY vector <=> :'v'::vector LIMIT 200) t;
COMMIT;
"@
        $salida = Psql $sql
        $tiempos = @($salida | Where-Object { $_ -match 'Execution Time: ([\d.]+) ms' } | ForEach-Object { [double]::Parse(($_ -replace '.*Execution Time: ([\d.]+) ms.*', '$1'), [Globalization.CultureInfo]::InvariantCulture) })
        $usaIndice = [bool]($salida | Where-Object { $_ -match 'idx_vector_producto_hnsw' })
        $ids = Uno-PorGrupo ((@($salida)[-1]) -split ',')
        return [pscustomobject]@{ ms = $tiempos[-1]; indice = $usaIndice; ids = @($ids.Keys) }
    }
    $conIndice = Medir 'enable_seqscan'
    $exacto = Medir 'enable_indexscan'
    $queUsa = if ($conIndice.indice) { 'con el indice HNSW' } else { 'sin indice (la tabla es chica y PostgreSQL prefirio recorrerla)' }
    Ok "$queUsa, $([math]::Round($conIndice.ms, 1)) ms. Comparando contra los $conVector, $([math]::Round($exacto.ms, 1)) ms"
    if (($conIndice.ids -join ',') -eq ($exacto.ids -join ',')) {
        Ok "Los dos dan los mismos $($conIndice.ids.Count), en el mismo orden"
    } else {
        Av "El indice dio otros que la busqueda exacta: HNSW es aproximado. Exacto $($exacto.ids -join ','), indice $($conIndice.ids -join ',')"
    }
    Ok "$conVector productos con vector de 768 dimensiones, en la tabla vector_producto"
    Write-Host "   El indice HNSW recorre un grafo de vecinos y no compara contra todos. ef_search dice cuantos" -ForegroundColor DarkGray
    Write-Host "   candidatos mira, e iterative_scan sigue buscando si el filtro (activo, grupo) descarta" -ForegroundColor DarkGray

    Paso "Lo mismo por la app, GET /productos/$id/similares"
    $api = Api "/productos/$id/similares"
    if ($null -ne $api) {
        $idsApi = @($api | ForEach-Object { [long]$_.id_producto })
        $idsBase = @($sim.Keys)
        foreach ($f in $api) {
            $nombre = if ($f.producto) { $f.producto.nombre } else { "(id $($f.id_producto), no esta en Mongo)" }
            Write-Host ("   {0,8}% {1,-46} misma_categoria {2}" -f [math]::Round($f.similitud * 100, 1), $nombre, "$($f.misma_categoria)".ToLower())
        }
        $bloquesApi = @($api | ForEach-Object { [bool]$_.misma_categoria }) -join ','
        $bloquesBase = @($sim.Values | ForEach-Object { $_.misma }) -join ','
        if (($idsApi -join ',') -eq ($idsBase -join ',') -and $bloquesApi -eq $bloquesBase) {
            Ok "La ruta devuelve los mismos $($idsApi.Count), en el mismo orden y con los mismos bloques. Es el estante Parecidos a este de la ficha"
        } else {
            Mal "La ruta devolvio otros ids. Aqui $($idsBase -join ','), ruta $($idsApi -join ',')"
        }
    }
    exit 0
}


# ============================================================
# vectores
# ============================================================
if ($Parte -eq 'vectores') {
    Contenedor 'mesh-postgres'
    Contenedor 'mesh-mongo'

    Paso "Los vectores de los productos, en vector_producto (PostgreSQL)"
    $f = @(Psql @"
SELECT (SELECT count(*) FROM producto_catalogo) || '|' || count(*) || '|' || count(*) FILTER (WHERE activo) || '|' ||
       count(DISTINCT grupo) || '|' || coalesce(string_agg(DISTINCT modelo, ', '), '')
  FROM vector_producto;
"@)[0].Split('|')
    Ok "$($f[1]) de $($f[0]) productos de producto_catalogo con vector, $($f[2]) activos, en $($f[3]) grupos distintos"
    Ok "Modelo $($f[4])"

    Paso "Los vectores de las resenas, en vector_comentario (PostgreSQL)"
    $c = @(Psql @"
SELECT (SELECT count(*) FROM comentario) || '|' || count(*) || '|' || count(*) FILTER (WHERE valoracion_texto IS NOT NULL)
  FROM vector_comentario;
"@)[0].Split('|')
    Ok "$($c[1]) de $($c[0]) comentarios con vector (las respuestas de menos de 15 letras van sin vector), $($c[2]) valorados"
    $cola = @(Psql "SELECT count(*) FILTER (WHERE procesado_en IS NULL) || '|' || count(*) FILTER (WHERE procesado_en IS NULL AND intentos > 0) FROM evento_comentario;")[0].Split('|')
    Ok "$($cola[0]) comentarios esperan al worker en evento_comentario, $($cola[1]) con algun fallo"

    Paso "Los productos que esperan al worker del backend"
    $m = Mongo @"
print(JSON.stringify({
  total: db.productos.countDocuments({}),
  pendientes: db.productos.countDocuments({ pendiente_vector: true })
}));
"@
    Ok "$($m[0].total) productos en MongoDB, $($m[0].pendientes) marcados con pendiente_vector"
    Write-Host "   Crear o editar un producto lo marca. VectoresSyncService lo mira cada 10 segundos" -ForegroundColor DarkGray
    Write-Host "   y solo le pide el vector a Ollama si cambio el nombre, la categoria o la descripcion" -ForegroundColor DarkGray
    Write-Host "   Al arrancar, etl\cargar_vectores.ps1 pone al dia todo el catalogo con el mismo md5" -ForegroundColor DarkGray

    Paso "El backend y Ollama, GET /vectores"
    $api = Api "/vectores"
    if ($null -ne $api) {
        if ($api.modelo_descargado) {
            Ok "El backend llega a Ollama en $($api.url) y el modelo $($api.modelo) esta descargado"
        } else {
            Av "El backend llega a Ollama en $($api.url), pero no tiene $($api.modelo). Lo baja etl\cargar_vectores.ps1"
        }
    }
    exit 0
}


# ============================================================
# intencion
# ============================================================
if ($Parte -eq 'intencion') {
    Contenedor 'mesh-postgres'

    Paso "Lo que la persona quiere, con sus palabras: '$Texto'"
    try {
        $r = Invoke-RestMethod -Uri "$Backend/buscador/productos/intencion?q=$([uri]::EscapeDataString($Texto))&limite=12" -TimeoutSec 30
    } catch {
        Mal "El backend no contesto la busqueda por intencion. $($_.Exception.Message)"
        exit 1
    }
    $lista = @($r.payload)
    if ($lista.Count -eq 0) { Av 'No salio nada parecido. Prueba con una frase mas concreta'; exit 0 }
    $conResena = @($lista | Where-Object { $_.motivo })
    Ok "$($lista.Count) productos; $($conResena.Count) salen por una resena que habla de eso"
    foreach ($f in ($lista | Select-Object -First 6)) {
        Write-Host ("   {0,5}%  {1}" -f [math]::Round($f.puntaje * 100), $f.nombre) -ForegroundColor White
        if ($f.motivo) {
            $cita = $f.motivo.comentario
            if ($cita.Length -gt 110) { $cita = $cita.Substring(0, 110) + '...' }
            Write-Host "          Resena de $($f.motivo.calificacion) de 5: $cita" -ForegroundColor DarkGray
        } else {
            Write-Host '          Por su descripcion' -ForegroundColor DarkGray
        }
    }

    Paso 'Lo mismo por nombre, la busqueda de siempre'
    $n = Api "/buscador/productos?nombre=$([uri]::EscapeDataString($Texto))&limite=5"
    $porNombre = if ($n -is [array]) { @($n) } else { @($n.resultados) }
    Ok "Por nombre salen $($porNombre.Count), y casi nunca son lo que se busca:"
    foreach ($f in $porNombre) { Write-Host "          $($f.nombre)" -ForegroundColor DarkGray }
    Write-Host '   La frase se vuelve vector con Ollama y se compara contra el vector de cada resena' -ForegroundColor DarkGray
    Write-Host '   (vector_comentario) y de cada producto (vector_producto), en PostgreSQL. En /buscar sale arriba.' -ForegroundColor DarkGray
    exit 0
}


# ============================================================
# clasificador
# ============================================================
if ($Parte -eq 'clasificador') {
    Contenedor 'mesh-postgres'

    Paso 'Como leyo el clasificador cada resena, en vector_comentario'
    # Solo las raices de una resena se valoran (las respuestas no).
    $filas = Psql @"
SELECT v.valoracion_texto || '|' || count(*)
  FROM resena r JOIN vector_comentario v ON v.id_comentario = r.id_comentario
 WHERE v.valoracion_texto IS NOT NULL
 GROUP BY v.valoracion_texto ORDER BY count(*) DESC;
"@
    foreach ($l in $filas) {
        $b = $l.Split('|')
        $que = switch ($b[0]) { 'mala' { 'el texto es malo' } 'buena' { 'el texto es bueno' } 'dudosa' { 'no esta seguro' } 'corta' { 'menos de 100 letras, no se lee' } default { '' } }
        Ok ("{0,4} {1,-7} {2}" -f $b[1], $b[0], $que)
    }

    Paso 'Resenas cuyas estrellas contradicen el texto'
    # La misma regla que NotasIncoherentesDetectorService: texto malo con 4 o 5
    # estrellas, o bueno con 1 o 2. El texto viaja en base64 para que las tildes
    # y los saltos de linea no rompan la fila. Sin los saltos que mete encode():
    # parte el base64 cada 76 letras, y cada pedazo salia como otra fila
    # ("IHZleiBx... estrellas") con la resena cortada (2026-11-02).
    $contra = "((v.valoracion_texto = 'mala' AND r.calificacion >= 4) OR (v.valoracion_texto = 'buena' AND r.calificacion <= 2))"
    $total = @(Psql "SELECT count(*) FROM resena r JOIN vector_comentario v ON v.id_comentario = r.id_comentario WHERE $contra;")[0]
    $algunas = Psql @"
SELECT r.calificacion || '|' || coalesce(v.prob_mala::text, '') || '|' || replace(encode(convert_to(c.comentario, 'UTF8'), 'base64'), E'\n', '')
  FROM resena r
  JOIN vector_comentario v ON v.id_comentario = r.id_comentario
  JOIN comentario c ON c.id_comentario = r.id_comentario
 WHERE $contra
 ORDER BY r.id_resena DESC LIMIT 8;
"@
    Ok "$total en total. Algunas:"
    foreach ($l in $algunas) {
        $b = $l.Split('|', 3)
        $t = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($b[2] -replace '\s', '')))
        if ($t.Length -gt 100) { $t = $t.Substring(0, 100) + '...' }
        $prob = if ($b[1]) { [double]::Parse($b[1], [Globalization.CultureInfo]::InvariantCulture) } else { 0 }
        Write-Host ("   {0} estrellas, probabilidad de mala {1:N2}" -f $b[0], $prob) -ForegroundColor White
        Write-Host "          $t" -ForegroundColor DarkGray
    }
    Write-Host '   El modelo es una regresion logistica entrenada a mano con 400 resenas escritas para esto.' -ForegroundColor DarkGray
    Write-Host '   En 80 casos dificiles que nunca vio acierta el 90 %. No entiende el sarcasmo: por eso' -ForegroundColor DarkGray
    Write-Host '   la senal va al admin y nunca bloquea sola. Ver clasificador-resenas\modelo\reporte.txt' -ForegroundColor DarkGray

    Paso 'Las senales de notas incoherentes, por la API del admin'
    try {
        $s = Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
            -Body '{"identificador":"admin@mesh.com","contrasena":"Admin123"}' -SessionVariable sesion -TimeoutSec 20
        foreach ($tipo in 'notas_incoherentes_cuenta', 'notas_incoherentes_vendedor', 'notas_incoherentes_producto') {
            $x = Invoke-RestMethod -Uri "$Backend/admin/fraude/alertas-resenas?tipo=$tipo&pagina=1&limite=1" -WebSession $sesion -TimeoutSec 20
            Ok ("{0,-28} {1}" -f $tipo, $x.payload.total_anillos)
        }
        Write-Host '   Hace falta 5 o mas contradictorias y una parte de las suyas. Para ver una salir en vivo,' -ForegroundColor DarkGray
        Write-Host '   la demo Resenas copiadas y notas incoherentes las arma con cuentas nuevas.' -ForegroundColor DarkGray
    } catch {
        Av "El backend no contesto. $($_.Exception.Message)"
    }
    exit 0
}


# ============================================================
# hibrida
# ============================================================
if ($Parte -eq 'hibrida') {
    Contenedor 'mesh-elastic'

    Paso "Busqueda hibrida, palabras y significado juntos: '$Texto'"
    try {
        $r = Invoke-RestMethod -Uri "$Backend/buscador/productos/hibrida?q=$([uri]::EscapeDataString($Texto))&limite=10" -TimeoutSec 30
    } catch {
        Mal "El backend no contesto la busqueda hibrida. $($_.Exception.Message)"
        exit 1
    }
    $p = $r.payload
    if ($p.modo -eq 'solo_texto') { Av 'Ollama no contesto: salio solo por las palabras' } else { Ok "Modo $($p.modo)" }
    Write-Host ("   {0,-7} {1,-9} {2,-11} {3}" -f 'PUNTAJE', 'PALABRAS', 'SIGNIFICADO', 'PRODUCTO') -ForegroundColor DarkGray
    foreach ($f in @($p.resultados) | Select-Object -First 8) {
        $pt = if ($null -ne $f.posicion_texto) { "#$($f.posicion_texto)" } else { '-' }
        $ps = if ($null -ne $f.posicion_significado) { "#$($f.posicion_significado)" } else { '-' }
        $color = if (@($f.origen).Count -eq 2) { 'Green' } else { 'Gray' }
        Write-Host ("   {0,-7} {1,-9} {2,-11} {3}" -f ([math]::Round($f.puntaje, 3)), $pt, $ps, $f.nombre) -ForegroundColor $color
    }
    Write-Host '   En verde, los que salieron por las dos. Se combinan por posicion (RRF), no por puntaje:' -ForegroundColor DarkGray
    Write-Host '   la relevancia de las palabras y el coseno estan en escalas distintas. Es la lista de /buscar.' -ForegroundColor DarkGray

    Paso 'La misma busqueda solo por palabras'
    $n = Api "/buscador/productos?nombre=$([uri]::EscapeDataString($Texto))&limite=5"
    $porNombre = if ($n -is [array]) { @($n) } else { @($n.resultados) }
    Ok "Por palabras salen $($porNombre.Count)"
    foreach ($f in $porNombre) { Write-Host "          $($f.nombre)" -ForegroundColor DarkGray }
    if ($n -and $n.quisiste_decir) { Ok "Y dice: tal vez quisiste decir $($n.quisiste_decir)" }
    exit 0
}


# ============================================================
# sugerencias
# ============================================================
if ($Parte -eq 'sugerencias') {
    Contenedor 'mesh-elastic'

    Paso "Un vendedor va a proponer '$Texto'"
    try {
        Invoke-RestMethod -Method Post -Uri "$Backend/usuario/login" -ContentType 'application/json' `
            -Body '{"identificador":"admin@mesh.com","contrasena":"Admin123"}' -SessionVariable sesion -TimeoutSec 20 | Out-Null
        $cuerpo = [Text.Encoding]::UTF8.GetBytes((@{ nombre = $Texto } | ConvertTo-Json -Compress))
        $r = Invoke-RestMethod -Method Post -Uri "$Backend/vendedor/productos/sugerencias" -ContentType 'application/json; charset=utf-8' `
            -Body $cuerpo -WebSession $sesion -TimeoutSec 30
    } catch {
        Mal "El backend no contesto las sugerencias. $($_.Exception.Message)"
        exit 1
    }
    $cats = @($r.payload.categorias)
    $sim = @($r.payload.productos_similares)
    if ($cats.Count -eq 0) { Av 'Nada del catalogo se le parece: no hay categoria que sugerir'; exit 0 }
    Ok 'Suele ir en'
    foreach ($c in $cats) {
        Write-Host ("          {0,-18} {1,3}% de los parecidos, el mas cercano {2:N2}" -f $c.nombre, [math]::Round($c.puntaje * 100), [double]$c.mejor_similitud) -ForegroundColor White
    }
    Ok 'Ya hay parecidos en la tienda'
    foreach ($s in $sim) {
        $marca = if ($s.posible_duplicado) { '  PUEDE QUE YA EXISTA' } else { '' }
        Write-Host ("          {0:N2}  {1} ({2}){3}" -f [double]$s.similitud, $s.nombre, $s.categoria, $marca) -ForegroundColor $(if ($s.posible_duplicado) { 'Yellow' } else { 'Gray' })
    }
    Write-Host '   Es lo que sale en el formulario de proponer un producto al terminar de escribir el nombre.' -ForegroundColor DarkGray
    Write-Host '   La primera categoria se elige sola si no habias elegido ninguna. No crea nada.' -ForegroundColor DarkGray
    exit 0
}


# ============================================================
# rastro
# ============================================================
if ($Parte -eq 'rastro') {
    Contenedor 'mesh-clickhouse'
    Contenedor 'mesh-elastic'
    $sesion = "demo-rastro-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $q = [uri]::EscapeDataString($Texto)

    Paso "Una busqueda de '$Texto' sin filtros, para ver que categorias salen"
    $api = Api "/buscador/productos/facetado?nombre=$q&limite=1"
    if ($null -eq $api) { Mal "Sin backend no hay rastro. Arrancalo y vuelve a intentar"; exit 1 }
    $cat = $api.facetas.categoria | Sort-Object cantidad -Descending | Select-Object -First 1
    if (-not $cat) { Mal "La busqueda de '$Texto' no trajo ninguna categoria. Prueba otra palabra"; exit 1 }
    Ok "La categoria con mas resultados es $($cat.nombre) (id $($cat.id), $($cat.cantidad) productos)"

    # El precio se elige DESPUES de fijar la categoria, porque el conteo de cada
    # faceta ya viene recortado por las demas. Antes, un rango con 57 productos
    # en toda la busqueda podia quedarse en 0 dentro de la categoria.
    $conCat = Api "/buscador/productos/facetado?nombre=$q&categoria=$($cat.id)&limite=1"
    $precio = if ($conCat) { $conCat.facetas.precio | Where-Object { $_.cantidad -gt 0 } | Sort-Object cantidad -Descending | Select-Object -First 1 }
    $filtro = "categoria=$($cat.id)&disponible=si"
    if ($precio) { $filtro += "&precio=$($precio.clave)" }
    Paso "La misma busqueda con filtros, como la hace /buscar ($filtro)"
    $api = Api "/buscador/productos/facetado?nombre=$q&$filtro&limite=5&sesion=$sesion"
    if ($null -eq $api) { exit 1 }
    Ok "$($api.total) resultados"

    Paso "La fila que quedo en ClickHouse, tabla busqueda_realizada"
    # El backend la escribe sin esperar a que termine, asi que puede tardar un momento.
    $fila = @()
    for ($i = 0; $i -lt 10 -and $fila.Count -eq 0; $i++) {
        Start-Sleep -Milliseconds 500
        $fila = @(ClickHouse "SELECT termino, resultados, facetada, toString(categorias), toString(precios), toString(calificaciones), disponible FROM busqueda_realizada WHERE sesion = '$sesion' FORMAT TSVRaw")
    }
    if ($fila.Count -eq 0) {
        Mal "No llego ninguna fila. Mira que clickhouse\001_esquema.sql tenga las columnas de facetas y el log del backend"
        exit 1
    }
    $c = $fila[0].Split("`t")
    Write-Host ("   {0,-15} {1}" -f 'termino', $c[0])
    Write-Host ("   {0,-15} {1}" -f 'resultados', $c[1])
    Write-Host ("   {0,-15} {1}" -f 'facetada', $c[2])
    Write-Host ("   {0,-15} {1}" -f 'categorias', $c[3])
    Write-Host ("   {0,-15} {1}" -f 'precios', $c[4])
    Write-Host ("   {0,-15} {1}" -f 'calificaciones', $c[5])
    Write-Host ("   {0,-15} {1}" -f 'disponible', $c[6])
    Ok "Se guarda lo que eligio la persona, tal como viajo en la direccion"

    Paso "De ahi sale el ranking Categorias filtradas de Tendencias"
    $rank = ClickHouse "SELECT toString(valor), count(DISTINCT sesion) FROM busqueda_realizada ARRAY JOIN categorias AS valor WHERE fecha >= now() - INTERVAL 30 DAY AND lote = 'real' GROUP BY valor ORDER BY 2 DESC LIMIT 5 FORMAT TSV"
    foreach ($r in $rank) { $p = $r.Split("`t"); Write-Host ("   categoria {0,-6} {1} sesiones" -f $p[0], $p[1]) }
    Write-Host "   ARRAY JOIN abre el arreglo, asi una busqueda con dos categorias cuenta para las dos" -ForegroundColor DarkGray

    Paso "Borrando la fila de la demo"
    ClickHouse "ALTER TABLE busqueda_realizada DELETE WHERE sesion = '$sesion' SETTINGS mutations_sync = 1" | Out-Null
    Ok "Listo, las tendencias quedan como estaban"
    exit 0
}


# ============================================================
# facetas
# ============================================================
if ($Parte -eq 'facetas') {
    Contenedor 'mesh-elastic'
    $env:PYTHONIOENCODING = 'utf-8'
    # Sin esto Python guarda su salida hasta el final cuando no escribe en una
    # consola, y en el panel de comandos lo del backend salia antes que lo de la base.
    $env:PYTHONUNBUFFERED = '1'
    & python (Join-Path $PSScriptRoot 'elastic\pruebas\demo_facetas.py') $Texto
    $codigo = $LASTEXITCODE

    Paso "Lo mismo por la app, GET /buscador/productos/facetado?nombre=$Texto"
    $api = Api "/buscador/productos/facetado?nombre=$([uri]::EscapeDataString($Texto))&limite=5"
    if ($null -ne $api) {
        Ok "$($api.total) resultados. Los primeros"
        foreach ($r in $api.resultados) { Write-Host "   $($r.nombre)" }
        Write-Host "   Categorias" -ForegroundColor DarkGray
        foreach ($c in ($api.facetas.categoria | Select-Object -First 6)) { Write-Host ("   {0,6}  {1}" -f $c.cantidad, $c.nombre) }
        Write-Host "   Precio" -ForegroundColor DarkGray
        foreach ($c in $api.facetas.precio) { Write-Host ("   {0,6}  {1}" -f $c.cantidad, $c.clave) }
        Ok "Con existencias, $($api.facetas.disponible). Es el panel de /buscar"
    }

    $prefijo = $Texto.Substring(0, [Math]::Min(3, $Texto.Length))
    Paso "Autocompletado, GET /buscador/productos/sugerencias?prefijo=$prefijo"
    $api = Api "/buscador/productos/sugerencias?prefijo=$([uri]::EscapeDataString($prefijo))&limite=6"
    if ($null -ne $api) {
        foreach ($s in $api) { Write-Host "   $($s.nombre)" }
        Ok "Solo nombres que empiezan por '$prefijo', con bool_prefix sobre nombre.escribiendo"
    }
    exit $codigo
}
