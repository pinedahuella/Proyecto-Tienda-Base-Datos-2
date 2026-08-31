# demostracion_indices.ps1
# Corre mongo/demostracion_indices.js contra la base viva y arma una pagina
# HTML con lo medido.
#
#   .\mongo\demostracion_indices.ps1            mide y abre la pagina
#   .\mongo\demostracion_indices.ps1 -NoAbrir   mide y solo la escribe
#
# Sale con codigo 1 si alguna comprobacion falla, para que se pueda encadenar.
#
# Por que genera un HTML y no imprime en la terminal
# --------------------------------------------------
# Porque lo que hay que ensenar es una COMPARACION -- 7 documentos contra 102 --
# y una barra al lado del numero dice eso de un vistazo mientras que dos cifras
# en una linea de consola hay que leerlas. La pagina no lleva ni una cifra
# escrita a mano: todas salen de la corrida, asi que no puede quedar desfasada
# con la base como si quedaria una captura de pantalla pegada en el informe.
#
# La pagina es un archivo suelto, sin CSS ni JS de fuera: se abre con doble
# clic, sin servidor y sin internet.

param(
    [switch]$NoAbrir
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

function Paso($t)  { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "   $t"   -ForegroundColor Green }
function Error1($t){ Write-Host "   $t"   -ForegroundColor Red }

# ------------------------------------------------------------
# Las credenciales, del .env de la raiz
# ------------------------------------------------------------
# Mismo lector que arrancar.ps1: el .env no se sube al repositorio, asi que
# ninguna contrasena vive en un archivo versionado.
Paso "Leyendo el .env"

if (-not (Test-Path "$raiz\.env")) {
    Error1 "Falta el archivo .env en la raiz del proyecto."
    Error1 "Copialo de la plantilla:  copy .env.example .env"
    exit 1
}

$env_ = @{}
foreach ($linea in Get-Content "$raiz\.env") {
    $texto = $linea.Trim()
    if ($texto -eq "" -or $texto.StartsWith("#")) { continue }
    $partes = $texto.Split("=", 2)
    if ($partes.Count -eq 2) { $env_[$partes[0].Trim()] = $partes[1].Trim() }
}

foreach ($clave in @('MONGO_USER', 'MONGO_PASSWORD')) {
    if (-not $env_.ContainsKey($clave) -or $env_[$clave] -eq "") {
        Error1 "Falta $clave en el .env"
        exit 1
    }
}
Ok "Credenciales leidas"

# ------------------------------------------------------------
# Correr la medicion dentro del contenedor
# ------------------------------------------------------------
# Con `docker cp` y no por tuberia: PowerShell 5.1 le mete un BOM (EF BB BF) a
# lo que manda por una tuberia, y del otro lado mongosh se atraganta con la
# primera linea del script. Es el mismo motivo por el que el ETL de arrancar.ps1
# copia el archivo en vez de canalizarlo.
Paso "Midiendo contra MongoDB"

$corriendo = docker ps --filter "name=mesh-mongo" --filter "status=running" --format "{{.Names}}"
if (-not $corriendo) {
    Error1 "El contenedor mesh-mongo no esta corriendo."
    Error1 "Levantalo con:  .\arrancar.ps1"
    exit 1
}

docker cp "$PSScriptRoot\demostracion_indices.js" mesh-mongo:/tmp/demostracion_indices.js | Out-Null

$salida = docker exec `
    -e MU=$($env_['MONGO_USER']) `
    -e MP=$($env_['MONGO_PASSWORD']) `
    mesh-mongo sh -c 'mongosh --quiet -u "$MU" -p "$MP" --authenticationDatabase admin mesh /tmp/demostracion_indices.js'

$marcador = [array]::IndexOf($salida, '===DEMOSTRACION_JSON===')
if ($marcador -lt 0) {
    Error1 "mongosh no devolvio la medicion. Lo que contesto:"
    $salida | ForEach-Object { Error1 "   $_" }
    exit 1
}

$datos = $salida[$marcador + 1] | ConvertFrom-Json
Ok "$($datos.pasos.Count) pasos medidos sobre $($datos.totalProductos) productos"

# ------------------------------------------------------------
# Armar la pagina
# ------------------------------------------------------------
Paso "Escribiendo la pagina"

# Todo lo que venga de la base se escapa antes de entrar al HTML. Aqui los
# datos son nuestros, pero un nombre de producto con un `<` partiria la pagina
# en silencio y costaria mas encontrarlo que escribir esta funcion.
function Esc($t) {
    if ($null -eq $t) { return "" }
    return ([string]$t).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

$totalComprobaciones = 0
$totalOk = 0
foreach ($p in $datos.pasos) {
    foreach ($c in $p.comprobaciones) {
        $totalComprobaciones++
        if ($c.pasa) { $totalOk++ }
    }
}
$todoBien = ($totalOk -eq $totalComprobaciones)

$html = New-Object System.Text.StringBuilder
[void]$html.AppendLine(@"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Indices de MongoDB - Mesh</title>
<style>
  :root {
    --tinta: #1b1c26; --gris: #6b6d80; --linea: #e3e4ec; --panel: #f7f7fb;
    --indigo: #4b4ecd; --verde: #12794f; --verde-suave: #e6f4ee;
    --rojo: #b3261e; --rojo-suave: #fceceb; --blanco: #fff;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 2rem 1rem 4rem;
    font: 15px/1.55 "Segoe UI", system-ui, -apple-system, sans-serif;
    color: var(--tinta); background: var(--panel);
  }
  .hoja { max-width: 60rem; margin: 0 auto; }
  h1 { font-size: 1.6rem; margin: 0 0 .3rem; }
  h2 { font-size: 1.1rem; margin: 0; }
  .sub { color: var(--gris); margin: 0 0 1.5rem; }
  .tarjeta {
    background: var(--blanco); border: 1px solid var(--linea);
    border-radius: 10px; padding: 1.1rem 1.3rem; margin-bottom: 1rem;
  }
  .cabeza { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
  .num {
    display: inline-block; min-width: 1.6rem; height: 1.6rem; line-height: 1.6rem;
    text-align: center; border-radius: 50%; background: var(--indigo);
    color: #fff; font-size: .8rem; margin-right: .5rem;
  }
  .proposito { color: var(--gris); margin: .6rem 0 1rem; }
  pre {
    background: #14151c; color: #e6e6f0; padding: .8rem 1rem; border-radius: 8px;
    overflow-x: auto; font-size: .82rem; line-height: 1.45; margin: 0 0 1rem;
  }
  /* La comparacion. Es lo unico que hay que mirar si solo se mira una cosa. */
  .barras { display: grid; gap: .45rem; margin-bottom: 1rem; }
  .fila { display: grid; grid-template-columns: 9rem 1fr auto; align-items: center; gap: .7rem; }
  .fila .et { font-size: .82rem; color: var(--gris); }
  .pista { background: var(--panel); border-radius: 4px; height: 1.15rem; overflow: hidden; }
  .relleno { height: 100%; border-radius: 4px; }
  .relleno.con { background: var(--verde); }
  .relleno.sin { background: #c9cad6; }
  .cifra { font-variant-numeric: tabular-nums; font-size: .85rem; white-space: nowrap; }
  .ahorro { font-size: .85rem; color: var(--verde); font-weight: 600; }
  /* La tabla se desborda sola en una pantalla angosta (la columna del plan
     crece con el arbol de etapas). Que haga scroll ELLA y no la pagina: si
     la barra horizontal fuera del body, el texto de al lado se leeria movido. */
  .tabla-ancha { overflow-x: auto; margin-bottom: 1rem; }
  table { border-collapse: collapse; width: 100%; font-size: .85rem; }
  .tabla-ancha table { min-width: 34rem; }
  th, td { text-align: left; padding: .35rem .6rem; border-bottom: 1px solid var(--linea); }
  th { color: var(--gris); font-weight: 600; }
  td.n { font-variant-numeric: tabular-nums; }
  h6 { font-size: .82rem; color: var(--gris); margin: 0 0 .4rem; text-transform: uppercase; letter-spacing: .04em; }
  .nota-crudo { color: var(--gris); font-size: .82rem; margin: 0 0 .5rem; }
  details.explain { margin-bottom: .5rem; }
  details.explain summary {
    cursor: pointer; font-size: .84rem; color: var(--indigo);
    padding: .35rem .5rem; background: var(--panel); border-radius: 6px;
  }
  details.explain summary:hover { background: #eeeef6; }
  details.explain pre { margin-top: .5rem; }
  /* El volcado crudo puede ser largo (7 productos con sus variantes son cientos
     de lineas). Con tope de alto y scroll propio: se ve que esta ahi y se puede
     recorrer, sin que empuje las comprobaciones tres pantallas hacia abajo. */
  pre.crudo {
    max-height: 22rem; overflow: auto; margin-bottom: 1rem;
    background: #0f1017; font-size: .76rem;
  }
  ul.pruebas { list-style: none; margin: 0; padding: 0; }
  ul.pruebas li { padding: .5rem .7rem; border-radius: 6px; margin-bottom: .35rem; }
  li.ok { background: var(--verde-suave); }
  li.falla { background: var(--rojo-suave); }
  .marca { font-weight: 700; margin-right: .4rem; }
  li.ok .marca { color: var(--verde); }
  li.falla .marca { color: var(--rojo); }
  .detalle { display: block; color: var(--gris); font-size: .82rem; margin-top: .15rem; }
  .medido { display: block; font-size: .82rem; margin-top: .15rem; font-variant-numeric: tabular-nums; }
  .resumen { border-left: 4px solid; padding-left: 1rem; }
  .resumen.bien { border-color: var(--verde); }
  .resumen.mal { border-color: var(--rojo); }
  .pie { color: var(--gris); font-size: .82rem; margin-top: 2rem; }
  code { background: var(--panel); padding: .1rem .3rem; border-radius: 4px; font-size: .85em; }
</style>
</head>
<body>
<div class="hoja">
"@)

$estadoClase = if ($todoBien) { "bien" } else { "mal" }
$estadoTexto = if ($todoBien) {
    "Las $totalComprobaciones comprobaciones pasan."
} else {
    "$totalOk de $totalComprobaciones comprobaciones pasan. Las que fallan van en rojo."
}

[void]$html.AppendLine(@"
<h1>Los indices del catalogo, medidos</h1>
<p class="sub">
  Base <code>$(Esc $datos.base)</code> &middot; $($datos.totalProductos) productos &middot;
  medido el $(Esc $datos.generado)
</p>

<div class="tarjeta resumen $estadoClase">
  <h2>$estadoTexto</h2>
  <p class="proposito" style="margin-bottom:0">
    Cada paso se corre DOS veces: como la corre la aplicacion, y otra vez con
    <code>hint({`$natural:1})</code>, que obliga a MongoDB a no usar ningun indice.
    La diferencia entre los dos numeros es exactamente lo que aporta el indice.
    Ninguna cifra de esta pagina esta escrita a mano; todas salen de la corrida.
  </p>
</div>
"@)

foreach ($p in $datos.pasos) {
    [void]$html.AppendLine('<div class="tarjeta">')
    [void]$html.AppendLine("<div class=""cabeza""><h2><span class=""num"">$($p.numero)</span>$(Esc $p.titulo)</h2></div>")
    [void]$html.AppendLine("<p class=""proposito"">$(Esc $p.proposito)</p>")
    [void]$html.AppendLine("<pre>$(Esc $p.consulta)</pre>")

    if ($p.medidas) {
        $con = $p.medidas.conIndice
        $sin = $p.medidas.sinIndice
        # Las dos barras se miden contra el MISMO maximo. Escalar cada una a su
        # propio ancho haria que 7 y 102 se vieran iguales, que es justo lo
        # contrario de lo que la pagina viene a ensenar.
        $tope = [Math]::Max([int]$con.documentosExaminados, [int]$sin.documentosExaminados)
        if ($tope -le 0) { $tope = 1 }
        $anchoCon = [Math]::Max(1, [int](100 * $con.documentosExaminados / $tope))
        $anchoSin = [Math]::Max(1, [int](100 * $sin.documentosExaminados / $tope))

        [void]$html.AppendLine('<div class="barras">')
        [void]$html.AppendLine("<div class=""fila""><span class=""et"">Con el indice</span><div class=""pista""><div class=""relleno con"" style=""width:$anchoCon%""></div></div><span class=""cifra"">$($con.documentosExaminados) docs</span></div>")
        [void]$html.AppendLine("<div class=""fila""><span class=""et"">Sin ningun indice</span><div class=""pista""><div class=""relleno sin"" style=""width:$anchoSin%""></div></div><span class=""cifra"">$($sin.documentosExaminados) docs</span></div>")
        if ([int]$con.documentosExaminados -gt 0) {
            $veces = [Math]::Round([double]$sin.documentosExaminados / [double]$con.documentosExaminados, 1)
            [void]$html.AppendLine("<div class=""fila""><span class=""et""></span><span class=""ahorro"">$veces veces menos documentos abiertos</span><span></span></div>")
        }
        [void]$html.AppendLine('</div>')

        # Las etapas se escapan UNA A UNA y se unen despues con la entidad. Al
        # reves -- unir con `&rsaquo;` y escapar el resultado entero -- el `&`
        # de la entidad se convierte en `&amp;` y la tabla ensena el texto
        # "&rsaquo;" en vez de la flecha.
        $planCon = ($con.etapas | ForEach-Object { Esc $_ }) -join ' &rsaquo; '
        $planSin = ($sin.etapas | ForEach-Object { Esc $_ }) -join ' &rsaquo; '

        [void]$html.AppendLine(@"
<div class="tabla-ancha">
<table>
  <tr><th></th><th>Devueltos</th><th>Claves leidas</th><th>Documentos abiertos</th><th>Indice</th><th>Plan</th></tr>
  <tr>
    <td>Con indice</td>
    <td class="n">$($con.devueltos)</td><td class="n">$($con.clavesExaminadas)</td><td class="n">$($con.documentosExaminados)</td>
    <td><code>$(Esc $con.indice)</code></td><td>$planCon</td>
  </tr>
  <tr>
    <td>Sin indice</td>
    <td class="n">$($sin.devueltos)</td><td class="n">$($sin.clavesExaminadas)</td><td class="n">$($sin.documentosExaminados)</td>
    <td><code>$(Esc $sin.indice)</code></td><td>$planSin</td>
  </tr>
</table>
</div>
"@)
    }

    # LO QUE DEVOLVIO la consulta, en crudo. Va antes de las comprobaciones a
    # proposito: es la respuesta a la pregunta que se hizo, y todo lo demas
    # (el plan, los documentos abiertos) habla de lo que costo conseguirla.
    #
    # Se pintan los documentos ENTEROS, sin elegir campos: es la salida de la
    # misma consulta sin `.explain()`, la misma que sale pegandola en mongosh.
    # Cualquier recorte que hiciera este script dejaria de ser el resultado de
    # la consulta y pasaria a ser un resumen mio, que es justo lo que no sirve
    # para demostrar nada.
    if ($p.resultados) {
        $n = $p.resultados.cuantos
        $cuantos = "$n $(if ($n -eq 1) { 'documento' } else { 'documentos' })"
        # El JSON ya viene formateado desde mongosh (ver resultadosDe en el .js):
        # aqui solo se escapa y se pinta.
        $json = $p.resultados.texto
        [void]$html.AppendLine("<h6>Lo que devolvio la consulta &mdash; $cuantos</h6>")
        [void]$html.AppendLine("<p class=""nota-crudo"">Los documentos completos, tal como los devuelve <code>$(Esc $p.consultaCruda)</code>. Sin recortar ni renombrar nada.</p>")
        [void]$html.AppendLine("<pre class=""crudo"">$(Esc $json)</pre>")
    }

    # EL EXPLAIN ENTERO, sin tocar. Es la salida de la consulta original -- la
    # que se pego en el grupo -- y es lo que hay que poder revisar: los cinco
    # numeros de las barras y de las comprobaciones son una lectura MIA de
    # esto, y quien revisa tiene derecho a comprobar que dice lo que digo.
    #
    # Plegado en <details> porque son cientos de lineas por consulta y abiertos
    # los seis sepultarian todo lo demas. El de arriba (con indice) es el que
    # se abre en la demostracion; el de $natural esta al lado para comparar.
    if ($p.medidas -and $p.medidas.explicacionConIndice) {
        [void]$html.AppendLine('<h6>El explain completo</h6>')
        [void]$html.AppendLine("<details class=""explain""><summary>Salida de <code>$(Esc $p.consultaCruda).explain(&quot;executionStats&quot;)</code></summary><pre class=""crudo"">$(Esc $p.medidas.explicacionConIndice)</pre></details>")
        [void]$html.AppendLine("<details class=""explain""><summary>La misma, forzada con <code>.hint({`$natural:1})</code> &mdash; sin ningun indice</summary><pre class=""crudo"">$(Esc $p.medidas.explicacionSinIndice)</pre></details>")
    }

    [void]$html.AppendLine('<ul class="pruebas">')
    foreach ($c in $p.comprobaciones) {
        $clase = if ($c.pasa) { "ok" } else { "falla" }
        $marca = if ($c.pasa) { "PASA" } else { "FALLA" }
        [void]$html.AppendLine("<li class=""$clase""><span class=""marca"">$marca</span>$(Esc $c.nombre)<span class=""detalle"">$(Esc $c.detalle)</span><span class=""medido"">Medido: $(Esc $c.medido)</span></li>")
    }
    [void]$html.AppendLine('</ul>')
    [void]$html.AppendLine('</div>')
}

# Los indices que existen ahora mismo, para que se vea que la pagina habla de
# esta base y no de una de hace tres semanas.
[void]$html.AppendLine('<div class="tarjeta"><h2>Los indices que tiene <code>productos</code> ahora</h2><table><tr><th>Nombre</th><th>Llave</th></tr>')
foreach ($i in $datos.indices) {
    [void]$html.AppendLine("<tr><td><code>$(Esc $i.nombre)</code></td><td><code>$(Esc $i.llave)</code></td></tr>")
}
[void]$html.AppendLine('</table></div>')

[void]$html.AppendLine(@"
<p class="pie">
  Generado por <code>mongo\demostracion_indices.ps1</code>, que corre
  <code>mongo\demostracion_indices.js</code> contra la base viva. Para volver a
  medirlo, se corre otra vez. Los indices y el porque de cada uno estan
  comentados en <code>mongo\001_productos.js</code>.
</p>
</div>
</body>
</html>
"@)

# En la RAIZ del proyecto, no junto al script: es el entregable que se abre
# delante del profesor, y ahi se encuentra sin entrar a ninguna carpeta. El
# script y su .js se quedan en mongo\ porque son la herramienta, no el
# resultado.
$destino = Join-Path $raiz 'demostracion_indices.html'
# WriteAllText con UTF8 sin BOM: `>` y Out-File dejan un BOM que algunos
# navegadores pintan como un caracter raro al principio del <!doctype>.
[System.IO.File]::WriteAllText($destino, $html.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Ok "Escrita en $destino"

if ($todoBien) {
    Ok "$totalOk de $totalComprobaciones comprobaciones pasan"
} else {
    Error1 "$totalOk de $totalComprobaciones comprobaciones pasan"
}

if (-not $NoAbrir) { Start-Process $destino }

if ($todoBien) { exit 0 } else { exit 1 }
