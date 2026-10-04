# etl/cargar_vectores.ps1
# Calcula el vector de contenido de cada producto y lo guarda en su documento
# del indice mesh_productos de Elasticsearch (campos vector, vector_hash,
# vector_grupo y vector_modelo, ver elastic/001_indice.json). Es lo que usa la
# recomendacion semantica: SimilaresService le pide a Elasticsearch los
# parecidos con kNN. Hasta el 2026-10-02 vivia en PostgreSQL, tabla
# producto_vector, que la migracion 036 retira.
#
#   .\etl\cargar_vectores.ps1            solo lo que falta o cambio
#   .\etl\cargar_vectores.ps1 -Todo      recalcula todo el catalogo
#
# De donde sale cada cosa
#   el texto     MongoDB, coleccion productos, nombre + categoria + descripcion
#   el vector    Ollama, modelo paraphrase-multilingual, 768 dimensiones. El de
#                la PC si lo tiene (localhost:11434) y si no el contenedor
#                mesh-ollama (localhost:11435). Ver el paso 1
#   el destino   Elasticsearch, el documento del producto en mesh_productos
#
# Solo recalcula un producto si su documento no tiene vector o si su texto
# cambio. Para saberlo el documento guarda el md5 del texto (vector_hash). El
# texto, el hash y el grupo se calculan IGUAL que en VectoresSyncService del
# backend, que mantiene al dia los productos que se editan; si cambian aqui,
# cambian alli.
#
# EL INDICE SE REHACE Y LOS VECTORES NO SE PIERDEN
# El ETL del buscador (Correr-EtlBusqueda en arrancar.ps1, o
# etl/cargar_busqueda.sh) tira mesh_productos entero y lo vuelve a crear, y con
# el se irian los 3105 vectores, unos 7 minutos de Ollama. Antes de tirarlo, el
# ETL copia los campos del vector al indice mesh_productos_vectores_previos.
# Este script mira ahi primero: si un producto tiene alli un vector con el
# mismo hash y el mismo modelo, se lo devuelve sin llamar a Ollama.
#
# Un producto que ya no esta en Mongo no hace falta borrarlo: su documento se
# fue con el indice. El "activo" tampoco se guarda aparte, es el estado del
# documento.
#
# Codigos de salida
#   0  todos los documentos del indice tienen vector
#   2  no se consiguio un Ollama con el modelo, ni el de la PC ni el de Docker.
#      Lo que se pudo devolver de mesh_productos_vectores_previos si se devolvio
#   1  cualquier otro fallo, tambien Elasticsearch caido o el indice sin crear
#
# Nada de tuberias hacia docker exec. PowerShell 5.1 les mete un BOM (ver
# arrancar.ps1, el ETL de Mongo). Lo que va a Mongo viaja con docker cp y lo
# que va a Elasticsearch como archivo con -InFile.

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
# Los mismos valores que arrancar.ps1 ($ES_URL, $ES_INDICE) y que ELASTIC_INDICE
# del backend.
$es = 'http://localhost:9200'
$indice = 'mesh_productos'
$previos = 'mesh_productos_vectores_previos'
$lote = 32
$sinBom = New-Object System.Text.UTF8Encoding($false)
$inv = [Globalization.CultureInfo]::InvariantCulture
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'mesh-vectores'
New-Item -ItemType Directory -Force $tmp | Out-Null

# Primero Elasticsearch, que es barato de mirar: sin el no hay donde guardar
# nada y no tiene sentido encender Ollama.
try {
    $total = [int](Invoke-RestMethod -Uri "$es/$indice/_count" -TimeoutSec 20).count
} catch {
    Write-Host "   Elasticsearch no responde o el indice $indice no existe. Corre antes el ETL del buscador" -ForegroundColor Red
    exit 1
}
$m = Invoke-RestMethod -Uri "$es/$indice/_mapping/field/vector" -TimeoutSec 20
$campo = @($m.PSObject.Properties)[0]
if ($null -eq $campo -or -not $campo.Value.mappings.vector -or $campo.Value.mappings.vector.mapping.vector.type -ne 'dense_vector') {
    # Un indice creado con el mapeo de antes del 2026-10-02. Sin el campo, el
    # primer update le pondria al vector un mapeo dinamico de floats sueltos.
    Write-Host "   El indice $indice no tiene el campo vector (dense_vector). Rehazlo con  .\arrancar.ps1 -Etl" -ForegroundColor Red
    exit 1
}


# 1. Un Ollama con el modelo
#
# Nadie tiene que instalar nada a mano. En este orden
#   a. OLLAMA_URL del .env, si alguien la puso. Manda y no se busca otro
#   b. el Ollama de esta PC, en localhost:11434. Si esta instalado pero
#      apagado, se enciende oculto con "ollama serve"
#   c. si la PC no tiene Ollama, el contenedor mesh-ollama del compose (perfil
#      ollama, puerto 11435). La primera vez baja la imagen
# En los tres casos, si falta el modelo se baja solo, una vez.
#
# Se enciende aunque no haya ningun producto por calcular: el backend tambien
# lo usa (los vectores de las resenas, la busqueda por intencion y los
# productos editados), y es el que se le deja escrito en backend\.env.
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
function TieneModelo {
    $t = Invoke-RestMethod -Uri "$ollama/api/tags" -TimeoutSec 10
    return [bool]($t.models | Where-Object { $_.name -like "$modelo*" })
}

# Devuelve $true con $script:ollama apuntando a un Ollama que tiene el modelo.
function Preparar-Ollama {
    $exe = $null
    $enDocker = $false
    if ($env_['OLLAMA_URL']) {
        if (-not (Responde $script:ollama)) {
            Write-Host "   Ollama no responde en $($script:ollama) (OLLAMA_URL del .env)" -ForegroundColor Yellow
            return $false
        }
        Write-Host "   Ollama de OLLAMA_URL, $($script:ollama)"
    } else {
        $exe = OllamaDeLaPc
        if (Responde $script:ollama) {
            Write-Host "   Ollama de esta PC, $($script:ollama)"
        } elseif ($exe) {
            Write-Host "   Ollama esta instalado en esta PC pero apagado. Lo enciendo"
            Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden
            # 120 s y no 30: medido el 28-09, en reposo contesta a los 19 s, pero dentro
            # de arrancar, con Elastic, Neo4j y ClickHouse subiendo a la vez, paso de 30
            # y el paso de vectores se salto con Ollama ya casi arriba.
            if (-not (Esperar $script:ollama 120)) {
                Write-Host "   Ollama de esta PC no respondio en 120 s ($exe)" -ForegroundColor Yellow
                return $false
            }
            Write-Host "   Ollama de esta PC, $($script:ollama)"
        } else {
            $script:ollama = 'http://localhost:11435'
            $enDocker = $true
            Write-Host "   Esta PC no tiene Ollama. Uso el contenedor mesh-ollama, $($script:ollama)"
            if (-not (Responde $script:ollama)) {
                Write-Host "   Levantando mesh-ollama. La primera vez baja la imagen y tarda unos minutos"
                $ErrorActionPreference = 'Continue'
                docker volume create mesh-ollama-modelos 2>&1 | Out-Null
                $salida = docker compose -f (Join-Path $raiz 'docker-compose.yml') --profile ollama up -d ollama 2>&1
                $codigo = $LASTEXITCODE
                $ErrorActionPreference = 'Stop'
                if ($codigo -ne 0) {
                    Write-Host "   No se pudo levantar mesh-ollama. $(($salida | Select-Object -Last 3) -join ' ')" -ForegroundColor Yellow
                    return $false
                }
                if (-not (Esperar $script:ollama 90)) {
                    Write-Host "   mesh-ollama no respondio en 90 s. Ver  docker logs mesh-ollama" -ForegroundColor Yellow
                    return $false
                }
            }
        }
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
                Invoke-RestMethod -Uri "$($script:ollama)/api/pull" -Method Post -ContentType 'application/json' `
                    -Body (@{ model = $modelo; stream = $false } | ConvertTo-Json -Compress) -TimeoutSec 3600 | Out-Null
            } catch { }
        }
        $ErrorActionPreference = 'Stop'
        if (-not (TieneModelo)) {
            Write-Host "   No se pudo bajar el modelo $modelo. Hace falta internet la primera vez" -ForegroundColor Yellow
            return $false
        }
        Write-Host "   Modelo $modelo listo" -ForegroundColor Green
    }
    return $true
}

$hayOllama = Preparar-Ollama

# El backend tambien habla con Ollama (VectoresSyncService recalcula los
# productos editados, EventoComentarioSyncService vectoriza las resenas y
# /buscador/productos/intencion la frase de quien busca) y lee OLLAMA_URL de
# backend/.env, no de este. Si aqui se eligio mesh-ollama en el 11435 y el
# backend se queda con su 11434 por defecto, todo eso se queda sin vector sin
# error visible. Por eso se le deja escrito el mismo Ollama que se acaba de
# elegir. Surte efecto la proxima vez que arranque el backend.
$envBackend = Join-Path $raiz 'backend\.env'
if ($hayOllama -and (Test-Path $envBackend)) {
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
db.productos.find({}, { nombre: 1, descripcion: 1, 'categoria.nombre': 1 }).forEach(function (d) {
  print(JSON.stringify({ id: d._id, nombre: d.nombre || '', cat: (d.categoria && d.categoria.nombre) || '',
                         desc: d.descripcion || '' }));
});
'@
[IO.File]::WriteAllText((Join-Path $tmp 'extraer.js'), $js, $sinBom)
docker cp (Join-Path $tmp 'extraer.js') mesh-mongo:/tmp/extraer_vectores.js | Out-Null
$cmd = 'mongosh --quiet -u $MONGO_INITDB_ROOT_USERNAME -p $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin $MONGO_INITDB_DATABASE --file /tmp/extraer_vectores.js > /tmp/productos_vectores.jsonl'
docker exec mesh-mongo sh -c $cmd
if ($LASTEXITCODE -ne 0) { Write-Host "   No se pudo leer el catalogo de MongoDB" -ForegroundColor Red; exit 1 }
docker cp mesh-mongo:/tmp/productos_vectores.jsonl (Join-Path $tmp 'productos.jsonl') | Out-Null

$md5 = [Security.Cryptography.MD5]::Create()
function Md5($texto) { -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($texto)) | ForEach-Object { $_.ToString('x2') }) }
$productos = @{}
foreach ($linea in [IO.File]::ReadAllLines((Join-Path $tmp 'productos.jsonl'), [Text.Encoding]::UTF8)) {
    if (-not $linea.Trim()) { continue }
    $d = $linea | ConvertFrom-Json
    $texto = "$($d.nombre). Categoria $($d.cat). $($d.desc)".Trim()
    # El grupo deja fuera el nombre: las copias del generador cambian el sufijo
    # del nombre y repiten la descripcion, y no tienen que recomendarse entre si.
    $productos[[long]$d.id] = [pscustomobject]@{ id = [long]$d.id; texto = $texto; hash = (Md5 $texto); grupo = (Md5 "$($d.cat)|$($d.desc)".Trim()) }
}
if ($productos.Count -eq 0) { Write-Host "   El catalogo de MongoDB esta vacio" -ForegroundColor Red; exit 1 }


# 3. Lo que ya hay en Elasticsearch, sin traer los vectores
#
# Con scroll y no con un solo _search: un _search se corta en 10000 documentos
# (index.max_result_window), y el generador de arrancar puede pasar de ahi.
function Leer-Campos($nombreIndice, [string[]]$campos) {
    $r = @{}
    $cuerpo = @{ size = 1000; _source = $campos; sort = @('_doc') } | ConvertTo-Json -Compress
    $p = Invoke-RestMethod -Method Post -Uri "$es/$nombreIndice/_search?scroll=1m" -ContentType 'application/json' -Body $cuerpo -TimeoutSec 60
    while ($p.hits.hits.Count -gt 0) {
        foreach ($h in $p.hits.hits) { $r[[long]$h._id] = $h._source }
        $siguiente = @{ scroll = '1m'; scroll_id = $p._scroll_id } | ConvertTo-Json -Compress
        $p = Invoke-RestMethod -Method Post -Uri "$es/_search/scroll" -ContentType 'application/json' -Body $siguiente -TimeoutSec 60
    }
    try { Invoke-RestMethod -Method Delete -Uri "$es/_search/scroll/$($p._scroll_id)" -TimeoutSec 10 | Out-Null } catch { }
    return $r
}

$enIndice = Leer-Campos $indice @('vector_hash', 'vector_grupo')
$guardados = @{}
try { $guardados = Leer-Campos $previos @('vector_hash', 'vector_modelo') } catch { }

# Solo los productos que tienen documento. Uno que esta en Mongo y no en el
# indice no tiene donde guardar su vector; lo agrega BuscadorSyncService y lo
# vectoriza VectoresSyncService del backend.
$sinDocumento = @($productos.Keys | Where-Object { -not $enIndice.ContainsKey($_) })
$enAmbos = @($productos.Values | Where-Object { $enIndice.ContainsKey($_.id) })
$pendientes = @($enAmbos | Where-Object { $Todo -or $enIndice[$_.id].vector_hash -ne $_.hash } | Sort-Object id)
$soloGrupo = @($enAmbos | Where-Object { -not $Todo -and $enIndice[$_.id].vector_hash -eq $_.hash -and $enIndice[$_.id].vector_grupo -ne $_.grupo })
# De los pendientes, los que el ETL del buscador guardo antes de tirar el
# indice con el MISMO texto y el MISMO modelo vuelven tal cual. -Todo no
# devuelve nada: pide recalcular.
$devolver = @($pendientes | Where-Object { -not $Todo -and $guardados.ContainsKey($_.id) -and $guardados[$_.id].vector_hash -eq $_.hash -and $guardados[$_.id].vector_modelo -eq $modelo })
$idsDevolver = @{}
foreach ($pr in $devolver) { $idsDevolver[$pr.id] = $true }
$aOllama = @($pendientes | Where-Object { -not $idsDevolver.ContainsKey($_.id) })

$conVectorAntes = $enAmbos.Count - $pendientes.Count
Write-Host "   $($productos.Count) productos en MongoDB, $total documentos en $indice, $conVectorAntes con vector al dia"
Write-Host "   $($devolver.Count) se devuelven de $previos, $($aOllama.Count) por calcular con Ollama, $($soloGrupo.Count) cambian solo de grupo"
if ($sinDocumento.Count) {
    Write-Host "   $($sinDocumento.Count) productos de MongoDB no estan en el indice; los agrega el worker del buscador" -ForegroundColor Yellow
}


# 4. Escribir, por tandas de _bulk con actualizaciones parciales
#
# _bulk contesta 200 aunque documentos sueltos fallen. El unico sitio donde
# eso se ve es `errors`, y se mira en cada tanda.
function Mandar-Bulk($texto) {
    if (-not $texto) { return }
    $archivo = Join-Path $tmp 'vectores.ndjson'
    [IO.File]::WriteAllText($archivo, $texto, $sinBom)
    $r = Invoke-RestMethod -Method Post -Uri "$es/_bulk" -ContentType 'application/x-ndjson' -InFile $archivo -TimeoutSec 300
    if ($r.errors) {
        $malo = @($r.items | ForEach-Object { $_.update } | Where-Object { $_.error } | Select-Object -First 1)
        Write-Host "   Elasticsearch rechazo un documento: $($malo[0]._id) $($malo[0].error.type) $($malo[0].error.reason)" -ForegroundColor Red
        exit 1
    }
}
function Linea-Accion($id) { '{"update":{"_index":"' + $indice + '","_id":"' + $id + '"}}' }

# 4a. Los que cambiaron solo de grupo
$sb = New-Object Text.StringBuilder
foreach ($pr in $soloGrupo) {
    [void]$sb.Append((Linea-Accion $pr.id)).Append("`n")
    [void]$sb.Append('{"doc":{"vector_grupo":"' + $pr.grupo + '"}}').Append("`n")
}
Mandar-Bulk $sb.ToString()

# 4b. Los devueltos de mesh_productos_vectores_previos
#
# El vector viaja como TEXTO, sin pasar por ConvertFrom-Json: son 768 numeros
# por producto, y convertirlos a objetos de PowerShell y de vuelta a JSON
# costaria mas que pedirlos. El _source de _mget se recorta con una expresion
# regular, que aqui es segura porque solo pide vector, vector_hash y
# vector_modelo: un arreglo de numeros y dos cadenas de hex y de letras, sin
# llaves dentro. El grupo se le suma al final, el de ahora.
for ($i = 0; $i -lt $devolver.Count; $i += 200) {
    $tanda = $devolver[$i..([Math]::Min($i + 200, $devolver.Count) - 1)]
    $cuerpo = '{"ids":[' + (($tanda | ForEach-Object { '"' + $_.id + '"' }) -join ',') + ']}'
    $crudo = (Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$es/$previos/_mget?_source=vector,vector_hash,vector_modelo" `
        -ContentType 'application/json' -Body $cuerpo -TimeoutSec 120).Content
    $porId = @{}
    foreach ($mt in [regex]::Matches($crudo, '"_id":"(\d+)"[^{}]*?"found":true,"_source":(\{[^{}]*\})')) {
        $porId[[long]$mt.Groups[1].Value] = $mt.Groups[2].Value
    }
    $sb = New-Object Text.StringBuilder
    foreach ($pr in $tanda) {
        $fuente = $porId[$pr.id]
        if (-not $fuente) { $aOllama += $pr; continue }
        [void]$sb.Append((Linea-Accion $pr.id)).Append("`n")
        [void]$sb.Append('{"doc":' + $fuente.Substring(0, $fuente.Length - 1) + ',"vector_grupo":"' + $pr.grupo + '"}}').Append("`n")
    }
    Mandar-Bulk $sb.ToString()
}

# 4c. Los que calcula Ollama
if ($aOllama.Count -and -not $hayOllama) {
    Invoke-RestMethod -Method Post -Uri "$es/$indice/_refresh" -TimeoutSec 60 | Out-Null
    Write-Host "   Sin Ollama quedan $($aOllama.Count) productos sin vector" -ForegroundColor Yellow
    exit 2
}
for ($i = 0; $i -lt $aOllama.Count; $i += $lote) {
    $grupo = $aOllama[$i..([Math]::Min($i + $lote, $aOllama.Count) - 1)]
    $cuerpo = @{ model = $modelo; input = @($grupo | ForEach-Object { $_.texto }) } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Uri "$ollama/api/embed" -Method Post -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -TimeoutSec 300
    } catch {
        Write-Host "   Ollama fallo en el lote que empieza en $i. $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    $sb = New-Object Text.StringBuilder
    for ($k = 0; $k -lt $grupo.Count; $k++) {
        $v = $r.embeddings[$k]
        if ($v.Count -ne 768) { Write-Host "   El modelo devolvio $($v.Count) dimensiones y el indice espera 768" -ForegroundColor Red; exit 1 }
        # Con cultura invariante: con la de la PC un decimal puede salir con coma
        # y el JSON queda roto.
        $lit = '[' + (($v | ForEach-Object { ([double]$_).ToString('R', $inv) }) -join ',') + ']'
        $pr = $grupo[$k]
        [void]$sb.Append((Linea-Accion $pr.id)).Append("`n")
        [void]$sb.Append('{"doc":{"vector":' + $lit + ',"vector_hash":"' + $pr.hash + '","vector_grupo":"' + $pr.grupo + '","vector_modelo":"' + $modelo + '"}}').Append("`n")
    }
    Mandar-Bulk $sb.ToString()
    Write-Host ("   {0} de {1}" -f ([Math]::Min($i + $lote, $aOllama.Count)), $aOllama.Count)
}


# 5. El resultado, contado y no supuesto
Invoke-RestMethod -Method Post -Uri "$es/$indice/_refresh" -TimeoutSec 60 | Out-Null
$total = [int](Invoke-RestMethod -Uri "$es/$indice/_count" -TimeoutSec 20).count
$cuerpo = '{"query":{"exists":{"field":"vector"}}}'
$conVector = [int](Invoke-RestMethod -Method Post -Uri "$es/$indice/_count" -ContentType 'application/json' -Body $cuerpo -TimeoutSec 20).count
if ($conVector -ne $total) {
    Write-Host "   Vectores en $conVector de $total documentos" -ForegroundColor Red
    exit 1
}
Write-Host "   Vectores en $conVector de $total documentos, $($devolver.Count) devueltos, $($aOllama.Count) calculados, $($soloGrupo.Count) cambiaron de grupo" -ForegroundColor Green
exit 0
