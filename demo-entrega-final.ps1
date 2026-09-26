# demo-entrega-final.ps1
# Lo de la Entrega final y el buscador, ensenado en vivo. Cada parte habla
# primero directo con su base, y al final pide lo mismo a la ruta del backend
# que usa la app (desde ced29f5 de Jose David, 2026-09-26). Si el backend no
# esta corriendo, ese ultimo paso solo avisa y lo de la base igual se ve.
#
#   .\demo-entrega-final.ps1 -Parte acceso                      los tres usuarios de Redis
#   .\demo-entrega-final.ps1 -Parte semantica -Producto laptop  los parecidos de un producto
#   .\demo-entrega-final.ps1 -Parte facetas -Texto laptop       filtros facetados y tolerancia
#
# QUE ENSENA CADA PARTE
# ==================================================
#   acceso     Cada usuario de Redis intenta lo mismo y se ve que contesta Redis.
#              Lo destructivo (FLUSHALL, SHUTDOWN) no se ejecuta, se le pregunta
#              a Redis con ACL DRYRUN si lo dejaria pasar. Escribe una sola clave
#              bajo mesh:demo:acceso y la borra al final
#   semantica  Busca un producto por nombre y pide sus parecidos a
#              productos_similares() de la migracion 024, con la similitud de
#              cada uno y el plan que prueba que se usa el indice HNSW
#   facetas    La consulta de elastic/pruebas/facetas.py contra el indice real.
#              Solo lee
#
# Nada de tuberias hacia docker exec. PowerShell 5.1 les mete un BOM. Lo que
# va a Mongo o a PostgreSQL viaja como archivo con docker cp.

param(
    [ValidateSet('acceso', 'semantica', 'facetas')]
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
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
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

function Mongo([string]$js) {
    [IO.File]::WriteAllText((Join-Path $tmp 'demo.js'), $js, $sinBom)
    docker cp (Join-Path $tmp 'demo.js') mesh-mongo:/tmp/demo_final.js | Out-Null
    $cmd = 'mongosh --quiet -u $MONGO_INITDB_ROOT_USERNAME -p $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin $MONGO_INITDB_DATABASE --file /tmp/demo_final.js'
    $salida = docker exec mesh-mongo sh -c $cmd 2>&1
    if ($LASTEXITCODE -ne 0) { Mal "MongoDB contesto con error. $salida"; exit 1 }
    return @($salida | ForEach-Object { "$_" } | Where-Object { $_.Trim().StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
}


# ============================================================
# acceso
# ============================================================
if ($Parte -eq 'acceso') {
    Contenedor 'mesh-redis'
    $pass = @{
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
    Write-Host "   $(Como operador $pass.operador ACL USERS)"
    Linea 'sin usuario' 'PING sin contrasena' ((docker exec mesh-redis redis-cli PING 2>&1) -join ' ')
    Linea 'inspeccion' 'entrar con la contrasena del backend' (Como inspeccion $pass.default PING)

    Paso "default, el que usa el backend. Trabaja con datos y no administra"
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
# semantica
# ============================================================
if ($Parte -eq 'semantica') {
    Contenedor 'mesh-postgres'
    Contenedor 'mesh-mongo'

    $conVector = (Psql "SELECT count(*) FROM producto_vector;")[0]
    if ([int]$conVector -eq 0) {
        Mal "No hay vectores. Corre .\arrancar.ps1, que los calcula en el paso 7d"
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
    $ids = ($candidatos | ForEach-Object { [long]$_.id }) -join ','
    $elegido = (Psql "SELECT id_producto FROM producto_vector WHERE activo AND id_producto IN ($ids) ORDER BY id_producto LIMIT 1;")
    if (-not $elegido) { Mal "Esos productos todavia no tienen vector. Corre .\etl\cargar_vectores.ps1"; exit 1 }
    $id = [long]$elegido[0]
    $base = $candidatos | Where-Object { [long]$_.id -eq $id } | Select-Object -First 1
    Ok "$($base.nombre), de $($base.cat) (id $id)"

    Paso "Los mas parecidos por su descripcion"
    $filas = Psql "SELECT id_producto || '|' || round((similitud * 100)::numeric, 1) FROM productos_similares($id, 6);"
    if (-not $filas) { Av "No salio ninguno parecido"; exit 0 }
    $sim = [ordered]@{}
    foreach ($f in $filas) { $p = $f.Split('|'); $sim[[long]$p[0]] = $p[1] }
    $nombres = @{}
    Mongo @"
db.productos.find({ _id: { `$in: [$(($sim.Keys) -join ',')] } }, { nombre: 1, 'categoria.nombre': 1 }).forEach(function (d) {
  print(JSON.stringify({ id: d._id, nombre: d.nombre, cat: (d.categoria && d.categoria.nombre) || '' }));
});
"@ | ForEach-Object { $nombres[[long]$_.id] = $_ }
    Write-Host ("   {0,-9} {1,-46} {2}" -f 'SIMILITUD', 'PRODUCTO', 'CATEGORIA') -ForegroundColor DarkGray
    foreach ($k in $sim.Keys) {
        $n = $nombres[$k]
        $nombre = if ($n) { $n.nombre } else { "(id $k, no esta en Mongo)" }
        if ($nombre.Length -gt 45) { $nombre = $nombre.Substring(0, 45) }
        $cat = if ($n) { $n.cat } else { '' }
        $color = if ($n -and $n.cat -eq $base.cat) { 'Green' } else { 'Gray' }
        Write-Host ("   {0,8}% {1,-46} {2}" -f $sim[$k], $nombre, $cat) -ForegroundColor $color
    }
    Write-Host "   En verde, los de la misma categoria. Nadie le dijo la categoria al modelo, solo leyo el texto" -ForegroundColor DarkGray

    Paso "Como lo resuelve PostgreSQL"
    $plan = Psql @"
SET hnsw.ef_search = 200;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT id_producto FROM producto_vector
 ORDER BY vector <=> (SELECT vector FROM producto_vector WHERE id_producto = $id)
 LIMIT 200;
"@
    $plan | Where-Object { $_ -match 'Index Scan|Execution Time' } | ForEach-Object { Write-Host "   $($_.Trim())" }
    Ok "$conVector productos con vector de 768 dimensiones, en la tabla producto_vector"
    Ok "El indice HNSW recorre un grafo de vecinos y no compara contra todos"

    Paso "Lo mismo por la app, GET /productos/$id/similares"
    $api = Api "/productos/$id/similares"
    if ($null -ne $api) {
        $idsApi = @($api | ForEach-Object { [long]$_.id_producto })
        $idsBase = @($sim.Keys)
        foreach ($f in $api) {
            $nombre = if ($f.producto) { $f.producto.nombre } else { "(id $($f.id_producto), no esta en Mongo)" }
            Write-Host ("   {0,8}% {1}" -f [math]::Round($f.similitud * 100, 1), $nombre)
        }
        if (($idsApi -join ',') -eq ($idsBase -join ',')) {
            Ok "La ruta devuelve los mismos $($idsApi.Count), en el mismo orden. Es el estante Parecidos a este de la ficha"
        } else {
            Mal "La ruta devolvio otros ids. Base $($idsBase -join ','), ruta $($idsApi -join ',')"
        }
    }
    exit 0
}


# ============================================================
# facetas
# ============================================================
if ($Parte -eq 'facetas') {
    Contenedor 'mesh-elastic'
    $env:PYTHONIOENCODING = 'utf-8'
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
