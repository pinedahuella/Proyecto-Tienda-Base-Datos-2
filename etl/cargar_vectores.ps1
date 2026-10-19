# etl/cargar_vectores.ps1
# Calcula el vector de contenido de cada producto y lo guarda en la tabla
# vector_producto de PostgreSQL (pgvector, migracion 040). Es lo que usan la
# recomendacion semantica (GET /productos/:id/similares), la busqueda por
# intencion, la hibrida y las sugerencias al proponer: todas le piden los
# vecinos a PostgreSQL con ORDER BY vector <=> $1.
#
# De donde vivio el vector, para quien lea el historial
#   hasta el 2026-10-02  tabla producto_vector (la retira la 036)
#   2026-10-02 al 10-16  campos vector* del indice mesh_productos
#   desde el 2026-10-16  tabla vector_producto (040, a pedido del profesor)
#
#   .\etl\cargar_vectores.ps1            solo lo que falta o cambio
#   .\etl\cargar_vectores.ps1 -Todo      recalcula todo el catalogo con Ollama
#
# De donde sale cada cosa
#   el texto     MongoDB, coleccion productos, nombre + categoria + descripcion
#   el vector    Ollama, modelo paraphrase-multilingual, 768 dimensiones. El de
#                la PC si lo tiene (localhost:11434) y si no el contenedor
#                mesh-ollama (localhost:11435). Ver el paso 1
#   el destino   PostgreSQL, vector_producto (una fila por producto)
#
# Solo recalcula un producto si no tiene fila, si su texto cambio (texto_hash)
# o si el modelo es otro. El texto, el hash, el grupo y `activo` se calculan
# IGUAL que en VectoresSyncService del backend, que mantiene al dia los
# productos que se editan; si cambian aqui, cambian alli.
#
# Solo entran los productos que ya estan en producto_catalogo: la FK de
# vector_producto lo exige. Los copia a PostgreSQL el paso 7e de arrancar,
# que corre antes que este. Un producto que se borra de producto_catalogo se
# lleva su vector por la cascada.
#
# UNA BASE QUE TENIA LOS VECTORES EN ELASTICSEARCH
# Si vector_producto todavia no tiene un producto y Elasticsearch si (el campo
# vector de mesh_productos, o la copia mesh_productos_vectores_previos que
# dejaba el ETL del buscador), se copia de ahi con el mismo hash y el mismo
# modelo, sin llamar a Ollama. Son los mismos numeros. Es lo que hace el
# vectores-pgvector-copiar.cjs de Jose David para los productos, pero dentro
# del arranque. Si Elasticsearch no responde, se calcula con Ollama y listo.
#
# Codigos de salida
#   0  todos los productos de producto_catalogo tienen vector al dia
#   2  no se consiguio un Ollama con el modelo, ni el de la PC ni el de Docker.
#      Lo que se pudo copiar de Elasticsearch si se copio
#   1  cualquier otro fallo, tambien PostgreSQL caido o la 040 sin correr
#
# Nada de tuberias hacia docker exec. PowerShell 5.1 les mete un BOM (ver
# arrancar.ps1, el ETL de Mongo). Lo que va a Mongo y a PostgreSQL viaja como
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
# Los mismos valores que arrancar.ps1 ($ES_URL, $ES_INDICE). Solo se leen, para
# la copia de una base que tenia los vectores alli.
$es = 'http://localhost:9200'
$indice = 'mesh_productos'
$previos = 'mesh_productos_vectores_previos'
$lote = 32
$sinBom = New-Object System.Text.UTF8Encoding($false)
$inv = [Globalization.CultureInfo]::InvariantCulture
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'mesh-vectores'
New-Item -ItemType Directory -Force $tmp | Out-Null

# Corre un archivo de SQL dentro de mesh-postgres y devuelve su salida. Va con
# docker cp y -f, nunca por tuberia (el BOM de PowerShell 5.1).
function Psql-Archivo($sql) {
    $archivo = Join-Path $tmp 'vectores.sql'
    [IO.File]::WriteAllText($archivo, $sql, $sinBom)
    docker cp $archivo mesh-postgres:/tmp/mesh_vectores.sql | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo copiar el SQL a mesh-postgres" }
    $salida = docker exec mesh-postgres psql -U $env_['DB_USER'] -d $env_['DB_NAME'] -qtAX -v ON_ERROR_STOP=1 -f /tmp/mesh_vectores.sql 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL rechazo el SQL de los vectores: $($salida.Trim())" }
    return $salida
}

# Primero PostgreSQL, que es barato de mirar: sin la tabla no hay donde
# guardar nada y no tiene sentido encender Ollama.
try {
    $hayTabla = (Psql-Archivo "SELECT to_regclass('public.vector_producto') IS NOT NULL;").Trim()
} catch {
    Write-Host "   PostgreSQL no responde. $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($hayTabla -ne 't') {
    Write-Host "   Falta la tabla vector_producto. Corre antes las migraciones (la 040)" -ForegroundColor Red
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
db.productos.find({}, { nombre: 1, descripcion: 1, estado: 1, 'categoria.nombre': 1 }).forEach(function (d) {
  print(JSON.stringify({ id: d._id, nombre: d.nombre || '', cat: (d.categoria && d.categoria.nombre) || '',
                         desc: d.descripcion || '', estado: d.estado || '' }));
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
    $productos[[long]$d.id] = [pscustomobject]@{
        id = [long]$d.id; texto = $texto; hash = (Md5 $texto)
        grupo = (Md5 "$($d.cat)|$($d.desc)".Trim()); activo = ($d.estado -eq 'activo')
    }
}
if ($productos.Count -eq 0) { Write-Host "   El catalogo de MongoDB esta vacio" -ForegroundColor Red; exit 1 }


# 3. Lo que ya hay en PostgreSQL, sin traer los vectores
$enCatalogo = @{}
foreach ($l in ((Psql-Archivo 'SELECT id_producto_mongo FROM producto_catalogo;') -split "`n")) {
    if ($l.Trim()) { $enCatalogo[[long]$l.Trim()] = $true }
}
$guardados = @{}
$filas = Psql-Archivo "SELECT id_producto_mongo || '|' || texto_hash || '|' || grupo || '|' || activo || '|' || modelo FROM vector_producto;"
foreach ($l in ($filas -split "`n")) {
    $c = $l.Trim().Split('|')
    # Un boolean concatenado a texto sale 'true'/'false', no 't'/'f' como cuando
    # psql lo imprime solo. Comparando con 't' todos parecian inactivos y cada
    # arranque reescribia 3103 filas sin cambiar nada (medido el 2026-10-18).
    if ($c.Count -eq 5) { $guardados[[long]$c[0]] = [pscustomobject]@{ hash = $c[1]; grupo = $c[2]; activo = ($c[3] -eq 'true'); modelo = $c[4] } }
}

$sinCatalogo = @($productos.Keys | Where-Object { -not $enCatalogo.ContainsKey($_) })
$validos = @($productos.Values | Where-Object { $enCatalogo.ContainsKey($_.id) })
$pendientes = @($validos | Where-Object {
    $Todo -or -not $guardados.ContainsKey($_.id) -or $guardados[$_.id].hash -ne $_.hash -or $guardados[$_.id].modelo -ne $modelo
} | Sort-Object id)
$soloGrupo = @($validos | Where-Object {
    -not $Todo -and $guardados.ContainsKey($_.id) -and $guardados[$_.id].hash -eq $_.hash -and $guardados[$_.id].modelo -eq $modelo -and
    ($guardados[$_.id].grupo -ne $_.grupo -or $guardados[$_.id].activo -ne $_.activo)
})


# 4. Lo que se puede copiar de Elasticsearch (una base de antes del 2026-10-16)
#
# El vector viaja como TEXTO, sin pasar por ConvertFrom-Json: son 768 numeros
# por producto, y convertirlos a objetos de PowerShell y de vuelta costaria mas
# que pedirlos. Se recortan con expresiones regulares, que aqui son seguras
# porque el _source solo trae vector, vector_hash y vector_modelo: un arreglo de
# numeros y dos cadenas sin llaves dentro. Con scroll y no con un solo _search,
# que se corta en 10000 documentos.
function Leer-VectoresDe($nombreIndice) {
    $r = @{}
    $cuerpo = '{"size":500,"_source":["vector","vector_hash","vector_modelo"],"query":{"exists":{"field":"vector"}},"sort":["_doc"]}'
    try {
        $crudo = (Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$es/$nombreIndice/_search?scroll=1m" `
            -ContentType 'application/json' -Body $cuerpo -TimeoutSec 60).Content
    } catch { return $r }
    while ($true) {
        $n = 0
        foreach ($mt in [regex]::Matches($crudo, '"_id":"(\d+)"[^{}]*?"_source":(\{[^{}]*\})')) {
            $n++
            $f = $mt.Groups[2].Value
            $v = [regex]::Match($f, '"vector":(\[[^\]]*\])')
            $h = [regex]::Match($f, '"vector_hash":"([0-9a-f]{32})"')
            $m = [regex]::Match($f, '"vector_modelo":"([^"]*)"')
            if ($v.Success -and $h.Success -and $m.Success) {
                $r[[long]$mt.Groups[1].Value] = [pscustomobject]@{ vector = $v.Groups[1].Value; hash = $h.Groups[1].Value; modelo = $m.Groups[1].Value }
            }
        }
        $id = [regex]::Match($crudo, '"_scroll_id":"([^"]+)"').Groups[1].Value
        if ($n -eq 0 -or -not $id) { break }
        $crudo = (Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$es/_search/scroll" -ContentType 'application/json' `
            -Body ('{"scroll":"1m","scroll_id":"' + $id + '"}') -TimeoutSec 60).Content
    }
    if ($id) { try { Invoke-RestMethod -Method Delete -Uri "$es/_search/scroll/$id" -TimeoutSec 10 | Out-Null } catch { } }
    return $r
}

$deElastic = @{}
if ($pendientes.Count -and -not $Todo) {
    foreach ($nombre in @($previos, $indice)) {
        $leidos = Leer-VectoresDe $nombre
        foreach ($k in $leidos.Keys) { $deElastic[$k] = $leidos[$k] }
    }
}
# Solo con el MISMO texto y el MISMO modelo. -Todo no copia nada: pide recalcular.
$copiar = @($pendientes | Where-Object { $deElastic.ContainsKey($_.id) -and $deElastic[$_.id].hash -eq $_.hash -and $deElastic[$_.id].modelo -eq $modelo })
$idsCopiar = @{}
foreach ($pr in $copiar) { $idsCopiar[$pr.id] = $true }
$aOllama = @($pendientes | Where-Object { -not $idsCopiar.ContainsKey($_.id) })

$alDia = $validos.Count - $pendientes.Count
Write-Host "   $($productos.Count) productos en MongoDB, $($validos.Count) en producto_catalogo, $alDia con vector al dia en vector_producto"
Write-Host "   $($copiar.Count) se copian de Elasticsearch, $($aOllama.Count) por calcular con Ollama, $($soloGrupo.Count) cambian solo de grupo o de activo"
if ($sinCatalogo.Count) {
    Write-Host "   $($sinCatalogo.Count) productos de MongoDB no estan en producto_catalogo; los vectoriza el worker del backend cuando entren" -ForegroundColor Yellow
}


# 5. Escribir
#
# UPSERT por tandas, una sentencia por tanda. El vector va como literal de
# pgvector ('[0.1,0.2,...]'), igual que aVectorPg() del backend.
function Fila-Vector($pr, $vector) {
    "($($pr.id),'$vector'::vector,'$($pr.hash)','$($pr.grupo)',$(if ($pr.activo) { 'true' } else { 'false' }),'$modelo')"
}
function Guardar-Filas([string[]]$filas) {
    if (-not $filas.Count) { return }
    $sql = "INSERT INTO vector_producto (id_producto_mongo, vector, texto_hash, grupo, activo, modelo) VALUES`n" +
           ($filas -join ",`n") + "`n" +
           "ON CONFLICT (id_producto_mongo) DO UPDATE SET vector = EXCLUDED.vector, texto_hash = EXCLUDED.texto_hash, " +
           "grupo = EXCLUDED.grupo, activo = EXCLUDED.activo, modelo = EXCLUDED.modelo, fecha_calculo = now();"
    Psql-Archivo $sql | Out-Null
}

# 5a. Los que cambiaron solo de grupo o de activo
if ($soloGrupo.Count) {
    $sb = New-Object Text.StringBuilder
    foreach ($pr in $soloGrupo) {
        [void]$sb.Append("UPDATE vector_producto SET grupo = '$($pr.grupo)', activo = $(if ($pr.activo) { 'true' } else { 'false' }) WHERE id_producto_mongo = $($pr.id);`n")
    }
    Psql-Archivo $sb.ToString() | Out-Null
}

# 5b. Los copiados de Elasticsearch
for ($i = 0; $i -lt $copiar.Count; $i += 200) {
    $tanda = $copiar[$i..([Math]::Min($i + 200, $copiar.Count) - 1)]
    Guardar-Filas @($tanda | ForEach-Object { Fila-Vector $_ $deElastic[$_.id].vector })
}

# 5c. Los que calcula Ollama
if ($aOllama.Count -and -not $hayOllama) {
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
    $filas = @()
    for ($k = 0; $k -lt $grupo.Count; $k++) {
        $v = $r.embeddings[$k]
        if ($v.Count -ne 768) { Write-Host "   El modelo devolvio $($v.Count) dimensiones y la tabla espera 768" -ForegroundColor Red; exit 1 }
        # Con cultura invariante: con la de la PC un decimal puede salir con coma
        # y el literal queda roto.
        $lit = '[' + (($v | ForEach-Object { ([double]$_).ToString('R', $inv) }) -join ',') + ']'
        $filas += (Fila-Vector $grupo[$k] $lit)
    }
    Guardar-Filas $filas
    Write-Host ("   {0} de {1}" -f ([Math]::Min($i + $lote, $aOllama.Count)), $aOllama.Count)
}


# 6. El resultado, contado y no supuesto
$conVector = [int](Psql-Archivo @"
SELECT count(*) FROM vector_producto v
  JOIN producto_catalogo pc ON pc.id_producto_mongo = v.id_producto_mongo
 WHERE v.modelo = '$modelo';
"@).Trim()
if ($conVector -lt $validos.Count) {
    Write-Host "   Vectores en $conVector de $($validos.Count) productos de producto_catalogo" -ForegroundColor Red
    exit 1
}
Write-Host "   Vectores en $conVector de $($validos.Count) productos, $($copiar.Count) copiados de Elasticsearch, $($aOllama.Count) calculados, $($soloGrupo.Count) cambiaron de grupo o de activo" -ForegroundColor Green
exit 0
