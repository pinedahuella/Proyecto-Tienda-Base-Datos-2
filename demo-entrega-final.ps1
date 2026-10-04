# demo-entrega-final.ps1
# Lo de la Entrega final y el buscador, ensenado en vivo. Cada parte habla
# primero directo con su base, y al final pide lo mismo a la ruta del backend
# que usa la app (desde ced29f5 de Jose David, 2026-09-26). Si el backend no
# esta corriendo, ese ultimo paso solo avisa y lo de la base igual se ve.
#
#   .\demo-entrega-final.ps1 -Parte acceso                      los tres usuarios de Redis
#   .\demo-entrega-final.ps1 -Parte semantica -Producto laptop  los parecidos de un producto
#   .\demo-entrega-final.ps1 -Parte facetas -Texto laptop       filtros facetados y tolerancia
#   .\demo-entrega-final.ps1 -Parte vectores                    quien mantiene los vectores al dia
#   .\demo-entrega-final.ps1 -Parte rastro -Texto laptop        lo que ClickHouse guarda de una busqueda con filtros
#   .\demo-entrega-final.ps1 -Parte intencion -Texto "algo para salir a pedalear"   buscar por lo que se quiere
#   .\demo-entrega-final.ps1 -Parte clasificador                como leyo el clasificador cada resena
#   .\demo-entrega-final.ps1 -Parte hibrida -Texto "labtop gamer"   palabras y significado en una lista
#   .\demo-entrega-final.ps1 -Parte sugerencias -Texto "Laptop ligera para estudiantes"   al proponer un producto
#
# QUE ENSENA CADA PARTE
# ==================================================
#   acceso     Cada usuario de Redis intenta lo mismo y se ve que contesta Redis.
#              Lo destructivo (FLUSHALL, SHUTDOWN) no se ejecuta, se le pregunta
#              a Redis con ACL DRYRUN si lo dejaria pasar. Escribe una sola clave
#              bajo mesh:demo:acceso y la borra al final
#   semantica  Busca un producto por nombre y pide sus parecidos a
#              Elasticsearch con la misma consulta kNN que SimilaresService
#              (el vector vive en el documento de mesh_productos desde el
#              2026-10-02), con la similitud de cada uno, y la compara con la
#              busqueda exacta contra todos para ensenar lo que ahorra el HNSW
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
#
# Nada de tuberias hacia docker exec. PowerShell 5.1 les mete un BOM. Lo que
# va a Mongo o a PostgreSQL viaja como archivo con docker cp.

param(
    [ValidateSet('acceso', 'semantica', 'facetas', 'vectores', 'rastro', 'intencion', 'clasificador', 'hibrida', 'sugerencias')]
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

function ClickHouse([string]$sql) {
    $salida = docker exec mesh-clickhouse clickhouse-client `
        --user $env_['CLICKHOUSE_USER'] --password $env_['CLICKHOUSE_PASSWORD'] `
        --database $env_['CLICKHOUSE_DB'] --query $sql 2>&1
    if ($LASTEXITCODE -ne 0) { Mal "ClickHouse contesto con error. $salida"; exit 1 }
    return @($salida | ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
}

$ES_URL = 'http://localhost:9200'
$ES_INDICE = 'mesh_productos'
$ES_INDICE_COMENTARIOS = 'mesh_comentarios'

# Un POST a Elasticsearch leido como UTF-8. Invoke-RestMethod de PowerShell 5.1
# no siempre respeta el charset de la respuesta y las tildes del texto de una
# resena salian rotas ("venA-a" por "venia").
function Es-Post([string]$ruta, [string]$cuerpo) {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$ES_URL$ruta" -ContentType 'application/json' -Body $cuerpo -TimeoutSec 30
    $bytes = $r.RawContentStream.ToArray()
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

function Contar-ConVector {
    try {
        return [int](Invoke-RestMethod -Method Post -Uri "$ES_URL/$ES_INDICE/_count" -ContentType 'application/json' `
            -Body '{"query":{"exists":{"field":"vector"}}}' -TimeoutSec 20).count
    } catch {
        Mal "Elasticsearch no contesto o no existe el indice $ES_INDICE. Corre .rrancar.ps1"
        exit 1
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
    Contenedor 'mesh-elastic'
    Contenedor 'mesh-mongo'

    $conVector = Contar-ConVector
    if ($conVector -eq 0) {
        Mal "No hay vectores en $ES_INDICE. Corre .\arrancar.ps1, que los calcula en el paso 7d"
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
    $base = $null
    $doc = $null
    foreach ($c in $candidatos) {
        try {
            $d = Invoke-RestMethod -Uri "$ES_URL/$ES_INDICE/_doc/$($c.id)?_source_includes=vector,vector_grupo" -TimeoutSec 20
            if ($d.found -and $d._source.vector) { $base = $c; $doc = $d; break }
        } catch { }
    }
    if (-not $base) { Mal "Esos productos todavia no tienen vector. Corre .\etl\cargar_vectores.ps1"; exit 1 }
    $id = [long]$base.id
    Ok "$($base.nombre), de $($base.cat) (id $id)"

    # La misma consulta que SimilaresService del backend: kNN sobre `vector`
    # con 200 candidatos, solo activos, sin el propio ni su grupo, y despues
    # uno por grupo. Elasticsearch puntua (1 + coseno) / 2; se vuelve al coseno.
    $filtro = @{ bool = @{ filter = @(@{ term = @{ estado = 'activo' } }); must_not = @(@{ ids = @{ values = @("$id") } }) } }
    if ($doc._source.vector_grupo) { $filtro.bool.must_not += @{ term = @{ vector_grupo = $doc._source.vector_grupo } } }
    $knn = @{
        size = 200; _source = @('vector_grupo')
        knn = @{ field = 'vector'; query_vector = $doc._source.vector; k = 200; num_candidates = 400; filter = $filtro }
    } | ConvertTo-Json -Depth 10 -Compress
    # Exacto, comparando contra TODOS: script_score con cosineSimilarity. Es lo
    # que el indice HNSW se ahorra.
    $exacto = @{
        size = 200; _source = @('vector_grupo')
        query = @{ script_score = @{ query = $filtro; script = @{ source = "cosineSimilarity(params.v, 'vector') + 1.0"; params = @{ v = $doc._source.vector } } } }
    } | ConvertTo-Json -Depth 10 -Compress

    function Uno-PorGrupo($hits) {
        $vistos = @{}
        $r = [ordered]@{}
        foreach ($h in $hits) {
            $clave = if ($h._source.vector_grupo) { $h._source.vector_grupo } else { "id:$($h._id)" }
            if ($vistos.ContainsKey($clave)) { continue }
            $vistos[$clave] = $true
            $r[[long]$h._id] = $h._score
            if ($r.Count -eq 6) { break }
        }
        return $r
    }

    Paso "Los mas parecidos por su descripcion"
    # Dos veces cada una: la primera paga la carga del indice en memoria.
    $null = Invoke-RestMethod -Method Post -Uri "$ES_URL/$ES_INDICE/_search" -ContentType 'application/json' -Body $knn -TimeoutSec 60
    $rKnn = Invoke-RestMethod -Method Post -Uri "$ES_URL/$ES_INDICE/_search" -ContentType 'application/json' -Body $knn -TimeoutSec 60
    $sim = Uno-PorGrupo $rKnn.hits.hits
    if ($sim.Count -eq 0) { Av "No salio ninguno parecido"; exit 0 }
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
        $coseno = [math]::Round((2 * [double]$sim[$k] - 1) * 100, 1)
        Write-Host ("   {0,8}% {1,-46} {2}" -f $coseno, $nombre, $cat) -ForegroundColor $color
    }
    Write-Host "   En verde, los de la misma categoria. Nadie le dijo la categoria al modelo, solo leyo el texto" -ForegroundColor DarkGray

    Paso "Como lo resuelve Elasticsearch, con el indice HNSW o comparando contra todos"
    $null = Invoke-RestMethod -Method Post -Uri "$ES_URL/$ES_INDICE/_search" -ContentType 'application/json' -Body $exacto -TimeoutSec 60
    $rExacto = Invoke-RestMethod -Method Post -Uri "$ES_URL/$ES_INDICE/_search" -ContentType 'application/json' -Body $exacto -TimeoutSec 60
    $simExacto = Uno-PorGrupo $rExacto.hits.hits
    Ok "kNN con el indice HNSW, $($rKnn.took) ms. Comparando contra los $conVector, $($rExacto.took) ms"
    if ((@($sim.Keys) -join ',') -eq (@($simExacto.Keys) -join ',')) {
        Ok "Los dos dan los mismos $($sim.Count), en el mismo orden"
    } else {
        Av "El indice dio otros que la busqueda exacta: HNSW es aproximado. Exacto $(@($simExacto.Keys) -join ','), indice $(@($sim.Keys) -join ',')"
    }
    Ok "$conVector productos con vector de 768 dimensiones, dentro de su documento de $ES_INDICE"
    Write-Host "   El indice HNSW recorre un grafo de vecinos y no compara contra todos. El vector vive en el" -ForegroundColor DarkGray
    Write-Host "   mismo documento que el texto y los filtros, asi que una sola consulta los combina" -ForegroundColor DarkGray

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
            Mal "La ruta devolvio otros ids. Aqui $($idsBase -join ','), ruta $($idsApi -join ',')"
        }
    }
    exit 0
}


# ============================================================
# vectores
# ============================================================
if ($Parte -eq 'vectores') {
    Contenedor 'mesh-elastic'
    Contenedor 'mesh-mongo'

    Paso "Los vectores que hay en Elasticsearch"
    $total = [int](Invoke-RestMethod -Uri "$ES_URL/$ES_INDICE/_count" -TimeoutSec 20).count
    $conVector = Contar-ConVector
    $agg = @{
        size = 0; query = @{ exists = @{ field = 'vector' } }
        aggs = @{
            activos = @{ filter = @{ term = @{ estado = 'activo' } } }
            grupos = @{ cardinality = @{ field = 'vector_grupo' } }
            modelos = @{ terms = @{ field = 'vector_modelo'; size = 5 } }
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $a = (Invoke-RestMethod -Method Post -Uri "$ES_URL/$ES_INDICE/_search" -ContentType 'application/json' -Body $agg -TimeoutSec 30).aggregations
    Ok "$conVector de $total documentos de $ES_INDICE con vector, $($a.activos.doc_count) activos, en $($a.grupos.value) grupos distintos"
    Ok "Modelo $((@($a.modelos.buckets) | ForEach-Object { $_.key }) -join ', ')"

    Paso "Los vectores de las resenas, en $ES_INDICE_COMENTARIOS"
    try {
        $c = [int](Invoke-RestMethod -Uri "$ES_URL/$ES_INDICE_COMENTARIOS/_count" -TimeoutSec 20).count
        $cv = [int](Invoke-RestMethod -Method Post -Uri "$ES_URL/$ES_INDICE_COMENTARIOS/_count" -ContentType 'application/json' `
            -Body '{"query":{"exists":{"field":"vector"}}}' -TimeoutSec 20).count
        Ok "$c comentarios indexados, $cv con vector (las respuestas de menos de 15 letras van sin vector)"
    } catch {
        Av "El indice $ES_INDICE_COMENTARIOS no existe. Lo crea .\arrancar.ps1 en el paso Indice de comentarios"
    }
    if (docker ps --filter "name=^mesh-postgres$" --format "{{.Names}}") {
        $cola = @(Psql "SELECT count(*) FILTER (WHERE procesado_en IS NULL) || '|' || count(*) FILTER (WHERE procesado_en IS NULL AND intentos > 0) FROM evento_comentario;")[0].Split('|')
        Ok "$($cola[0]) comentarios esperan al worker en evento_comentario, $($cola[1]) con algun fallo"
    }

    Paso "Los productos que esperan al worker del backend"
    $m = Mongo @"
print(JSON.stringify({
  total: db.productos.countDocuments({}),
  pendientes: db.productos.countDocuments({ pendiente_vector: true })
}));
"@
    Ok "$($m[0].total) productos en MongoDB, $($m[0].pendientes) marcados con pendiente_vector"
    Write-Host "   Crear o editar un producto lo marca. VectoresSyncService lo recalcula cada 3 horas" -ForegroundColor DarkGray
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
    Contenedor 'mesh-elastic'

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
    Write-Host '   (mesh_comentarios) y de cada producto (mesh_productos). En /buscar sale arriba.' -ForegroundColor DarkGray
    exit 0
}


# ============================================================
# clasificador
# ============================================================
if ($Parte -eq 'clasificador') {
    Contenedor 'mesh-elastic'

    Paso 'Como leyo el clasificador cada resena de mesh_comentarios'
    $agg = @{
        size = 0; query = @{ term = @{ es_respuesta = $false } }
        aggs = @{ v = @{ terms = @{ field = 'valoracion_texto'; size = 10 } } }
    } | ConvertTo-Json -Depth 10 -Compress
    $a = Es-Post "/$ES_INDICE_COMENTARIOS/_search" $agg
    foreach ($b in $a.aggregations.v.buckets) {
        $que = switch ($b.key) { 'mala' { 'el texto es malo' } 'buena' { 'el texto es bueno' } 'dudosa' { 'no esta seguro' } 'corta' { 'menos de 100 letras, no se lee' } default { '' } }
        Ok ("{0,4} {1,-7} {2}" -f $b.doc_count, $b.key, $que)
    }

    Paso 'Resenas cuyas estrellas contradicen el texto'
    $q = @{
        size = 8; _source = @('comentario', 'calificacion', 'prob_mala')
        query = @{ bool = @{ should = @(
            @{ bool = @{ filter = @(@{ term = @{ valoracion_texto = 'mala' } }, @{ range = @{ calificacion = @{ gte = 4 } } }) } },
            @{ bool = @{ filter = @(@{ term = @{ valoracion_texto = 'buena' } }, @{ range = @{ calificacion = @{ lte = 2 } } }) } }
        ); minimum_should_match = 1 } }
    } | ConvertTo-Json -Depth 12 -Compress
    $r = Es-Post "/$ES_INDICE_COMENTARIOS/_search" $q
    Ok "$($r.hits.total.value) en total. Algunas:"
    foreach ($h in $r.hits.hits) {
        $t = $h._source.comentario
        if ($t.Length -gt 100) { $t = $t.Substring(0, 100) + '...' }
        Write-Host ("   {0} estrellas, probabilidad de mala {1:N2}" -f $h._source.calificacion, [double]$h._source.prob_mala) -ForegroundColor White
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
