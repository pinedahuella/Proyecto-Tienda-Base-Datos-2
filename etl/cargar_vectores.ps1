# etl/cargar_vectores.ps1
# Calcula el vector de contenido de cada producto y lo guarda en PostgreSQL
# (tabla producto_vector, migracion 024). Es lo que usa la recomendacion
# semantica de la Entrega final.
#
#   .\etl\cargar_vectores.ps1            solo lo que falta o cambio
#   .\etl\cargar_vectores.ps1 -Todo      recalcula todo el catalogo
#
# De donde sale cada cosa
#   el texto     MongoDB, coleccion productos, nombre + categoria + descripcion
#   el vector    Ollama en el anfitrion (OLLAMA_URL, por defecto localhost:11434),
#                modelo paraphrase-multilingual, 768 dimensiones
#   el destino   PostgreSQL, producto_vector
#
# Solo recalcula un producto si no tiene vector o si su texto cambio. Para
# saberlo guarda el md5 del texto. Un producto que ya no esta en Mongo pierde
# su vector, y uno que dejo de estar activo queda marcado y no se recomienda.
#
# Codigos de salida
#   0  todo el catalogo tiene vector
#   2  Ollama no responde o no tiene el modelo. No se toco nada
#   1  cualquier otro fallo
#
# Nada de tuberias hacia docker exec. PowerShell 5.1 les mete un BOM que rompe
# el SQL del otro lado (ver arrancar.ps1, el ETL de Mongo). Todo viaja como
# archivo con docker cp.

param([switch]$Todo)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$env_ = @{}
Get-Content (Join-Path $raiz '.env') | ForEach-Object {
    $l = $_.Trim()
    if ($l -and -not $l.StartsWith('#')) {
        $p = $l.Split('=', 2)
        if ($p.Count -eq 2) { $env_[$p[0].Trim()] = $p[1].Trim() }
    }
}

$ollama = if ($env_['OLLAMA_URL']) { $env_['OLLAMA_URL'] } else { 'http://localhost:11434' }
$modelo = if ($env_['OLLAMA_MODELO_VECTORES']) { $env_['OLLAMA_MODELO_VECTORES'] } else { 'paraphrase-multilingual' }
$lote = 32
$sinBom = New-Object System.Text.UTF8Encoding($false)
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'mesh-vectores'
New-Item -ItemType Directory -Force $tmp | Out-Null

function Psql($sql) {
    $salida = docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -qtAX -v ON_ERROR_STOP=1 -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql fallo: $salida" }
    return $salida
}

# 1. Ollama y el modelo, antes de tocar nada
try {
    $tags = Invoke-RestMethod -Uri "$ollama/api/tags" -TimeoutSec 5
} catch {
    Write-Host "   Ollama no responde en $ollama" -ForegroundColor Yellow
    exit 2
}
if (-not ($tags.models | Where-Object { $_.name -like "$modelo*" })) {
    Write-Host "   Ollama no tiene el modelo $modelo. Se instala con  ollama pull $modelo" -ForegroundColor Yellow
    exit 2
}

# 2. El catalogo, desde Mongo
$js = @'
db.productos.find({}, { nombre: 1, descripcion: 1, 'categoria.nombre': 1, estado: 1 }).forEach(function (d) {
  print(JSON.stringify({ id: d._id, nombre: d.nombre || '', cat: (d.categoria && d.categoria.nombre) || '',
                         desc: d.descripcion || '', activo: d.estado === 'activo' }));
});
'@
[IO.File]::WriteAllText((Join-Path $tmp 'extraer.js'), $js, $sinBom)
docker cp (Join-Path $tmp 'extraer.js') mesh-mongo:/tmp/extraer_vectores.js | Out-Null
$cmd = 'mongosh --quiet -u $MONGO_INITDB_ROOT_USERNAME -p $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin $MONGO_INITDB_DATABASE --file /tmp/extraer_vectores.js > /tmp/productos_vectores.jsonl'
docker exec mesh-mongo sh -c $cmd
if ($LASTEXITCODE -ne 0) { Write-Host "   No se pudo leer el catalogo de MongoDB" -ForegroundColor Red; exit 1 }
docker cp mesh-mongo:/tmp/productos_vectores.jsonl (Join-Path $tmp 'productos.jsonl') | Out-Null

$md5 = [Security.Cryptography.MD5]::Create()
$productos = @{}
foreach ($linea in [IO.File]::ReadAllLines((Join-Path $tmp 'productos.jsonl'), [Text.Encoding]::UTF8)) {
    if (-not $linea.Trim()) { continue }
    $d = $linea | ConvertFrom-Json
    $texto = "$($d.nombre). Categoria $($d.cat). $($d.desc)".Trim()
    $hash = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($texto)) | ForEach-Object { $_.ToString('x2') })
    $productos[[long]$d.id] = [pscustomobject]@{ id = [long]$d.id; texto = $texto; hash = $hash; activo = [bool]$d.activo }
}
if ($productos.Count -eq 0) { Write-Host "   El catalogo de MongoDB esta vacio" -ForegroundColor Red; exit 1 }

# 3. Lo que ya hay en PostgreSQL
$hechos = @{}
foreach ($f in (Psql "SELECT id_producto || '|' || texto_hash || '|' || activo FROM producto_vector;")) {
    $p = "$f".Split('|')
    if ($p.Count -eq 3) { $hechos[[long]$p[0]] = [pscustomobject]@{ hash = $p[1]; activo = ($p[2] -eq 't') } }
}

$pendientes = @($productos.Values | Where-Object { $Todo -or -not $hechos.ContainsKey($_.id) -or $hechos[$_.id].hash -ne $_.hash } | Sort-Object id)
$cambianEstado = @($productos.Values | Where-Object { $hechos.ContainsKey($_.id) -and $hechos[$_.id].hash -eq $_.hash -and $hechos[$_.id].activo -ne $_.activo })
$sobran = @($hechos.Keys | Where-Object { -not $productos.ContainsKey($_) })

Write-Host "   $($productos.Count) productos en MongoDB, $($hechos.Count) con vector, $($pendientes.Count) por calcular"

# 4. Los vectores, por lotes, y el SQL que los guarda
$inv = [Globalization.CultureInfo]::InvariantCulture
$sql = New-Object Text.StringBuilder
[void]$sql.AppendLine('BEGIN;')

for ($i = 0; $i -lt $pendientes.Count; $i += $lote) {
    $grupo = $pendientes[$i..([Math]::Min($i + $lote, $pendientes.Count) - 1)]
    $cuerpo = @{ model = $modelo; input = @($grupo | ForEach-Object { $_.texto }) } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Uri "$ollama/api/embed" -Method Post -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -TimeoutSec 300
    } catch {
        Write-Host "   Ollama fallo en el lote que empieza en $i. $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    for ($k = 0; $k -lt $grupo.Count; $k++) {
        $v = $r.embeddings[$k]
        if ($v.Count -ne 768) { Write-Host "   El modelo devolvio $($v.Count) dimensiones y la tabla espera 768" -ForegroundColor Red; exit 1 }
        $lit = '[' + (($v | ForEach-Object { ([double]$_).ToString('R', $inv) }) -join ',') + ']'
        $pr = $grupo[$k]
        [void]$sql.AppendLine(("INSERT INTO producto_vector (id_producto, modelo, texto_hash, activo, vector) VALUES ({0}, '{1}', '{2}', {3}, '{4}') " +
            "ON CONFLICT (id_producto) DO UPDATE SET modelo = EXCLUDED.modelo, texto_hash = EXCLUDED.texto_hash, activo = EXCLUDED.activo, vector = EXCLUDED.vector, fecha_calculo = now();") -f
            $pr.id, $modelo, $pr.hash, $pr.activo.ToString().ToLower(), $lit)
    }
    Write-Host ("   {0} de {1}" -f ([Math]::Min($i + $lote, $pendientes.Count)), $pendientes.Count)
}

foreach ($pr in $cambianEstado) {
    [void]$sql.AppendLine("UPDATE producto_vector SET activo = $($pr.activo.ToString().ToLower()) WHERE id_producto = $($pr.id);")
}
if ($sobran.Count) {
    [void]$sql.AppendLine("DELETE FROM producto_vector WHERE id_producto IN ($($sobran -join ','));")
}
[void]$sql.AppendLine('COMMIT;')

if ($pendientes.Count -or $cambianEstado.Count -or $sobran.Count) {
    [IO.File]::WriteAllText((Join-Path $tmp 'vectores.sql'), $sql.ToString(), $sinBom)
    docker cp (Join-Path $tmp 'vectores.sql') mesh-postgres:/tmp/vectores.sql | Out-Null
    $salida = docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -q -v ON_ERROR_STOP=1 -f /tmp/vectores.sql 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "   No se pudieron guardar los vectores. $salida" -ForegroundColor Red; exit 1 }
}

# 5. El resultado, contado y no supuesto
$conVector = [int]"$(Psql 'SELECT count(*) FROM producto_vector;')".Trim()
if ($conVector -ne $productos.Count) {
    Write-Host "   Vectores $conVector de $($productos.Count) productos" -ForegroundColor Red
    exit 1
}
Write-Host "   Vectores $conVector de $($productos.Count) productos, $($cambianEstado.Count) cambiaron de estado, $($sobran.Count) quitados" -ForegroundColor Green
exit 0
