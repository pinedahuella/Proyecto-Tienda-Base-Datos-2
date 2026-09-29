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
#   el vector    Ollama, modelo paraphrase-multilingual, 768 dimensiones. El de
#                la PC si lo tiene (localhost:11434) y si no el contenedor
#                mesh-ollama (localhost:11435). Ver el paso 1
#   el destino   PostgreSQL, producto_vector
#
# Solo recalcula un producto si no tiene vector o si su texto cambio. Para
# saberlo guarda el md5 del texto. Un producto que ya no esta en Mongo pierde
# su vector, y uno que dejo de estar activo queda marcado y no se recomienda.
#
# Codigos de salida
#   0  todo el catalogo tiene vector
#   2  no se consiguio un Ollama con el modelo, ni el de la PC ni el de Docker.
#      No se toco nada
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

# 1. Un Ollama con el modelo, antes de tocar nada
#
# Nadie tiene que instalar nada a mano. En este orden
#   a. OLLAMA_URL del .env, si alguien la puso. Manda y no se busca otro
#   b. el Ollama de esta PC, en localhost:11434. Si esta instalado pero
#      apagado, se enciende oculto con "ollama serve"
#   c. si la PC no tiene Ollama, el contenedor mesh-ollama del compose (perfil
#      ollama, puerto 11435). La primera vez baja la imagen
# En los tres casos, si falta el modelo se baja solo, una vez.
#
# Los docker de aqui van con $ErrorActionPreference en Continue. Con Stop,
# PowerShell 5.1 toma como error cualquier linea de stderr, y docker compose
# escribe ahi su progreso aunque todo salga bien.
function Responde($url) {
    try { Invoke-RestMethod -Uri "$url/api/tags" -TimeoutSec 5 | Out-Null; return $true } catch { return $false }
}
function Esperar($url, $segundos) {
    $hasta = (Get-Date).AddSeconds($segundos)
    while ((Get-Date) -lt $hasta) {
        if (Responde $url) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}
function OllamaDeLaPc {
    $c = Get-Command ollama -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($r in @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe", "$env:ProgramFiles\Ollama\ollama.exe")) {
        if (Test-Path $r) { return $r }
    }
    return $null
}

$exe = $null
$enDocker = $false
if ($env_['OLLAMA_URL']) {
    if (-not (Responde $ollama)) {
        Write-Host "   Ollama no responde en $ollama (OLLAMA_URL del .env)" -ForegroundColor Yellow
        exit 2
    }
    Write-Host "   Ollama de OLLAMA_URL, $ollama"
} else {
    $exe = OllamaDeLaPc
    if (Responde $ollama) {
        Write-Host "   Ollama de esta PC, $ollama"
    } elseif ($exe) {
        Write-Host "   Ollama esta instalado en esta PC pero apagado. Lo enciendo"
        Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden
        # 120 s y no 30: medido el 28-09, en reposo contesta a los 19 s, pero dentro
        # de arrancar, con Elastic, Neo4j y ClickHouse subiendo a la vez, paso de 30
        # y el paso de vectores se salto con Ollama ya casi arriba.
        if (-not (Esperar $ollama 120)) {
            Write-Host "   Ollama de esta PC no respondio en 120 s ($exe)" -ForegroundColor Yellow
            exit 2
        }
        Write-Host "   Ollama de esta PC, $ollama"
    } else {
        $ollama = 'http://localhost:11435'
        $enDocker = $true
        Write-Host "   Esta PC no tiene Ollama. Uso el contenedor mesh-ollama, $ollama"
        if (-not (Responde $ollama)) {
            Write-Host "   Levantando mesh-ollama. La primera vez baja la imagen y tarda unos minutos"
            $ErrorActionPreference = 'Continue'
            docker volume create mesh-ollama-modelos 2>&1 | Out-Null
            $salida = docker compose -f (Join-Path $raiz 'docker-compose.yml') --profile ollama up -d ollama 2>&1
            $codigo = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            if ($codigo -ne 0) {
                Write-Host "   No se pudo levantar mesh-ollama. $(($salida | Select-Object -Last 3) -join ' ')" -ForegroundColor Yellow
                exit 2
            }
            if (-not (Esperar $ollama 90)) {
                Write-Host "   mesh-ollama no respondio en 90 s. Ver  docker logs mesh-ollama" -ForegroundColor Yellow
                exit 2
            }
        }
    }
}

function TieneModelo {
    $t = Invoke-RestMethod -Uri "$ollama/api/tags" -TimeoutSec 10
    return [bool]($t.models | Where-Object { $_.name -like "$modelo*" })
}
if (-not (TieneModelo)) {
    Write-Host "   Bajando el modelo $modelo, unos 560 MB. Solo la primera vez"
    $ErrorActionPreference = 'Continue'
    if ($enDocker) {
        docker exec mesh-ollama ollama pull $modelo
    } elseif ($exe) {
        & $exe pull $modelo
    } else {
        # OLLAMA_URL apunta a otra maquina y aqui no hay ejecutable: por la API.
        try {
            Invoke-RestMethod -Uri "$ollama/api/pull" -Method Post -ContentType 'application/json' `
                -Body (@{ model = $modelo; stream = $false } | ConvertTo-Json -Compress) -TimeoutSec 3600 | Out-Null
        } catch { }
    }
    $ErrorActionPreference = 'Stop'
    if (-not (TieneModelo)) {
        Write-Host "   No se pudo bajar el modelo $modelo. Hace falta internet la primera vez" -ForegroundColor Yellow
        exit 2
    }
    Write-Host "   Modelo $modelo listo" -ForegroundColor Green
}

# El backend tambien habla con Ollama (VectoresSyncService recalcula los
# productos editados y /vectores revisa la conexion) y lee OLLAMA_URL de
# backend/.env, no de este. Si aqui se eligio mesh-ollama en el 11435 y el
# backend se queda con su 11434 por defecto, los similares siguen saliendo
# pero ningun producto editado vuelve a tener vector, sin error visible. Por
# eso se le deja escrito el mismo Ollama que se acaba de elegir. Surte efecto
# la proxima vez que arranque el backend.
$envBackend = Join-Path $raiz 'backend\.env'
if (Test-Path $envBackend) {
    $lineas = @(Get-Content $envBackend)
    $cambio = $false
    foreach ($par in @(@('OLLAMA_URL', $ollama), @('OLLAMA_MODELO_VECTORES', $modelo))) {
        $nombre = $par[0]; $valor = $par[1]
        $actual = $lineas | Where-Object { $_ -match "^\s*$nombre\s*=" } | Select-Object -First 1
        if ($actual -and $actual.Split('=', 2)[1].Trim() -eq $valor) { continue }
        $lineas = @($lineas | Where-Object { $_ -notmatch "^\s*$nombre\s*=" }) + "$nombre=$valor"
        $cambio = $true
    }
    if ($cambio) {
        [IO.File]::WriteAllLines($envBackend, $lineas, $sinBom)
        Write-Host "   backend\.env apunta ahora a $ollama con $modelo"
    }
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
    # El grupo deja fuera el nombre: las copias del generador cambian el sufijo
    # del nombre y repiten la descripcion, y no tienen que recomendarse entre si.
    $grupo = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($d.cat)|$($d.desc)".Trim())) | ForEach-Object { $_.ToString('x2') })
    $productos[[long]$d.id] = [pscustomobject]@{ id = [long]$d.id; texto = $texto; hash = $hash; grupo = $grupo; activo = [bool]$d.activo }
}
if ($productos.Count -eq 0) { Write-Host "   El catalogo de MongoDB esta vacio" -ForegroundColor Red; exit 1 }

# 3. Lo que ya hay en PostgreSQL
$hechos = @{}
foreach ($f in (Psql "SELECT id_producto || '|' || texto_hash || '|' || activo || '|' || COALESCE(grupo, '') FROM producto_vector;")) {
    $p = "$f".Split('|')
    # PostgreSQL pasa un booleano a texto como true o false, no como t o f.
    if ($p.Count -eq 4) { $hechos[[long]$p[0]] = [pscustomobject]@{ hash = $p[1]; activo = ($p[2] -in 't', 'true'); grupo = $p[3] } }
}

$pendientes = @($productos.Values | Where-Object { $Todo -or -not $hechos.ContainsKey($_.id) -or $hechos[$_.id].hash -ne $_.hash } | Sort-Object id)
$cambianEstado = @($productos.Values | Where-Object { $hechos.ContainsKey($_.id) -and $hechos[$_.id].hash -eq $_.hash -and ($hechos[$_.id].activo -ne $_.activo -or $hechos[$_.id].grupo -ne $_.grupo) })
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
        # Concatenado y no con -f. En PowerShell -f pesa mas que +, asi que se
        # aplicaba solo a la segunda mitad de la cadena y fallaba con FormatError.
        $activo = $pr.activo.ToString().ToLower()
        [void]$sql.AppendLine("INSERT INTO producto_vector (id_producto, modelo, texto_hash, grupo, activo, vector) VALUES (" +
            "$($pr.id), '$modelo', '$($pr.hash)', '$($pr.grupo)', $activo, '$lit') " +
            "ON CONFLICT (id_producto) DO UPDATE SET modelo = EXCLUDED.modelo, texto_hash = EXCLUDED.texto_hash, grupo = EXCLUDED.grupo, activo = EXCLUDED.activo, vector = EXCLUDED.vector, fecha_calculo = now();")
    }
    Write-Host ("   {0} de {1}" -f ([Math]::Min($i + $lote, $pendientes.Count)), $pendientes.Count)
}

foreach ($pr in $cambianEstado) {
    [void]$sql.AppendLine("UPDATE producto_vector SET activo = $($pr.activo.ToString().ToLower()), grupo = '$($pr.grupo)' WHERE id_producto = $($pr.id);")
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
Write-Host "   Vectores $conVector de $($productos.Count) productos, $($cambianEstado.Count) cambiaron de estado o de grupo, $($sobran.Count) quitados" -ForegroundColor Green
exit 0
