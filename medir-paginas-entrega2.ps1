# Mide con Word en que pagina cae cada seccion y cada subseccion del Reporte de
# Entrega 2, y deja paginas-entrega2.json, que es lo que el generador usa para
# escribir el indice.
#
#   .\medir-paginas-entrega2.ps1
#   python generar-reporte-entrega2.py
#
# EN ESE ORDEN Y SIEMPRE LAS DOS. python-docx no sabe cuantas paginas ocupa nada,
# porque paginar es cosa del programa que abre el archivo. Asi que la primera
# pasada deja el indice con guiones, este script abre el documento con Word de
# verdad y apunta las paginas, y la segunda pasada las escribe.
#
# Un indice escrito a ojo caduca en cuanto alguien agrega un parrafo, y es
# exactamente el defecto que tiene el indice del Reporte de Entrega 1: sus
# numeros estan casi todos vacios y los tres que hay no corresponden.
#
# SIN TILDES A PROPOSITO. PowerShell 5.1 lee un .ps1 sin BOM como ANSI y se lleva
# por delante cualquier caracter acentuado.

$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$f = Join-Path $aqui "Reporte Segunda Entrega - DABD2 - Mesh.docx"
if (-not (Test-Path $f)) {
    throw "No encuentro el documento: $f. Corre primero python generar-reporte-entrega2.py"
}

$w = $null
$doc = $null
try {
    $w = New-Object -ComObject Word.Application
} catch {
    Write-Host "  No se pudo abrir Word. Este paso necesita Word instalado." -ForegroundColor Yellow
    Write-Host "  Sin el, el indice se queda con guiones y hay que ponerlo a mano." -ForegroundColor Yellow
    exit 1
}

try {
    $w.Visible = $false
    # Se abre en solo lectura para no dejar el archivo bloqueado si esto muere a
    # la mitad. Un .docx bloqueado por un Word invisible es de las cosas mas
    # dificiles de diagnosticar que hay.
    $doc = $w.Documents.Open($f, $false, $true)
    $doc.Repaginate()

    $pares = @{}

    foreach ($p in $doc.Paragraphs) {
        $t = ($p.Range.Text -replace "[\r\n\a]", "").Trim()
        if ($t -eq "") { continue }
        # Las lineas del indice llevan tabulador y puntos suspensivos. Se saltan,
        # porque si no el indice se mediria a si mismo.
        if ($t -match "\t") { continue }
        if ($t.Length -gt 90) { continue }

        # Titulo de seccion: "3. OFERTA CON INVENTARIO LIMITADO..."
        if ($t -match '^([1-9])\.\s+[A-Z]') {
            $n = $matches[1]
            if (-not $pares.ContainsKey($n)) {
                $pares[$n] = $p.Range.Information(3)
                Write-Output ("  pagina " + $pares[$n] + "  seccion " + $n + "  " + $t)
            }
            continue
        }

        # Titulo de subseccion: "3.2. Por que un script Lua..."
        if ($t -match '^[1-9]\.[0-9]+\.?\s+\S') {
            if (-not $pares.ContainsKey($t)) {
                $pares[$t] = $p.Range.Information(3)
                Write-Output ("  pagina " + $pares[$t] + "     " + $t)
            }
        }
    }

    Write-Output ""
    Write-Output ("  Paginas totales : " + $doc.ComputeStatistics(2))
    Write-Output ("  Palabras        : " + $doc.ComputeStatistics(0))

    $doc.Close($false); $doc = $null
    $w.Quit(); $w = $null

    # Out-File con utf8 mete BOM en PowerShell 5.1, y el generador lo lee con
    # utf-8-sig justamente por eso. Se deja asi para no depender de la version.
    $pares | ConvertTo-Json | Out-File -Encoding utf8 (Join-Path $aqui "paginas-entrega2.json")
    Write-Output ""
    Write-Output "  paginas-entrega2.json actualizado."
    Write-Output "  Ahora corre:  python generar-reporte-entrega2.py"
} finally {
    # Sin esto, un fallo a mitad deja un Word invisible corriendo con el archivo
    # abierto, y el siguiente intento falla con un mensaje que no menciona a Word
    # por ningun lado.
    if ($doc -ne $null) { try { $doc.Close($false) } catch {} }
    if ($w -ne $null) { try { $w.Quit() } catch {} }
}
