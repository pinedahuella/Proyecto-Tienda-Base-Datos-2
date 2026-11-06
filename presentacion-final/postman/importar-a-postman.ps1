# Mete la coleccion de Mesh y su ambiente con claves en el Postman de quien lo
# corre, sin arrastrar archivos. Las claves salen del .env de la raiz del repo
# (el mismo que usan las bases), asi que nada con claves pasa por git.
#
#   powershell -ExecutionPolicy Bypass -File presentacion-final\postman\importar-a-postman.ps1
#
# Pide la llave de la API de Postman (en Postman, foto de perfil, Settings,
# API keys, Generate API Key). No se guarda en ningun lado.
# Si ya estaban importadas, las actualiza en vez de duplicarlas.
# Sin llave (-SinPostman) solo arma secrets\Mesh-con-claves.postman_environment.json
# para importarlo a mano junto a la coleccion.
param(
  [string]$ApiKey = $env:POSTMAN_API_KEY,
  [string]$Workspace = '',
  [switch]$SinPostman,
  [string]$Api = 'https://api.getpostman.com'
)
$ErrorActionPreference = 'Stop'
$aqui = $PSScriptRoot
$repo = Resolve-Path (Join-Path $aqui '..\..')
$archColeccion = Join-Path $aqui 'Mesh-ACL.postman_collection.json'
$archAmbiente = Join-Path $aqui 'Mesh.postman_environment.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)

# 1. Claves desde el .env
$archEnv = Join-Path $repo '.env'
if (-not (Test-Path $archEnv)) { throw "No encuentro $archEnv. Es el .env con las claves de las bases, el mismo que usa docker compose." }
$envVars = @{}
foreach ($l in [IO.File]::ReadAllLines($archEnv, $utf8)) {
  if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
    $envVars[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
  }
}
$mapa = [ordered]@{
  es_lectura_clave = 'ELASTIC_LECTURA_PASSWORD'
  es_backend_clave = 'ELASTIC_BACKEND_PASSWORD'
  ch_lectura_clave = 'CLICKHOUSE_LECTURA_PASSWORD'
  ch_backend_clave = 'CLICKHOUSE_BACKEND_PASSWORD'
}
$ambiente = Get-Content $archAmbiente -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($v in $ambiente.values) {
  $nombreEnv = $mapa[$v.key]
  if (-not $nombreEnv) { continue }
  if (-not $envVars[$nombreEnv]) { throw "Falta $nombreEnv en $archEnv" }
  $v.value = $envVars[$nombreEnv]
}
Write-Output "Claves leidas del .env: $($mapa.Count) de $($mapa.Count)"

# 2. Copia local del ambiente con claves (secrets esta en .gitignore)
$dirSecretos = Join-Path $aqui 'secrets'
New-Item -ItemType Directory -Force $dirSecretos | Out-Null
$archLleno = Join-Path $dirSecretos 'Mesh-con-claves.postman_environment.json'
[IO.File]::WriteAllText($archLleno, ($ambiente | ConvertTo-Json -Depth 10), $utf8)
Write-Output "Ambiente con claves guardado en $archLleno"
if ($SinPostman) {
  Write-Output 'Listo sin Postman. Arrastra a Postman la coleccion y ese archivo.'
  exit 0
}

# 3. Subirlas a Postman por su API
if (-not $ApiKey) {
  $seguro = Read-Host -AsSecureString 'Pega tu llave de la API de Postman (PMAK-...)'
  $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro))
}
if (-not $ApiKey) { throw 'Sin llave no puedo entrar a tu Postman. Usa -SinPostman para importarlo a mano.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cab = @{ 'X-Api-Key' = $ApiKey }
function Llamar($metodo, $ruta, $cuerpo) {
  $p = @{ Method = $metodo; Uri = "$Api$ruta"; Headers = $cab; UseBasicParsing = $true }
  if ($cuerpo) { $p.Body = $utf8.GetBytes($cuerpo); $p.ContentType = 'application/json; charset=utf-8' }
  # Postman a veces contesta 500 o 503 sin motivo. Se reintenta tres veces.
  for ($intento = 1; ; $intento++) {
    try { return Invoke-RestMethod @p }
    catch {
      $c = $_.Exception.Response.StatusCode.value__
      if ($c -eq 401) { throw 'Postman no acepto la llave (401). Genera otra en Settings, API keys.' }
      if ($c -ge 500 -and $intento -lt 3) { Write-Host "  Postman contesto $c, reintento en 3 s"; Start-Sleep -Seconds 3; continue }
      throw "Postman contesto $c en $metodo $ruta. $($_.ErrorDetails.Message)"
    }
  }
}

$yo = Llamar GET '/me'
Write-Output "Entre a Postman como $($yo.user.username)"
$espacios = (Llamar GET '/workspaces').workspaces
$esp = if ($Workspace) { $espacios | Where-Object { $_.name -eq $Workspace } | Select-Object -First 1 }
       else { $espacios | Where-Object { $_.type -eq 'personal' } | Select-Object -First 1 }
if (-not $esp) { $esp = $espacios | Select-Object -First 1 }
if (-not $esp) { throw 'Tu cuenta de Postman no tiene ningun workspace.' }
Write-Output "Workspace $($esp.name)"

# Lo que ya hay en el workspace, para actualizar en vez de duplicar. Si Postman
# no lo da, se crea igual.
$yaHay = $null
try { $yaHay = (Llamar GET "/workspaces/$($esp.id)").workspace }
catch { Write-Output "  No pude leer lo que ya tienes ($($_.Exception.Message)). Lo creo nuevo." }

# Coleccion, el texto tal cual para no deformar el JSON
$textoCol = [IO.File]::ReadAllText($archColeccion, $utf8)
$nombreCol = ($textoCol | ConvertFrom-Json).info.name
$cuerpoCol = '{"collection":' + $textoCol + '}'
$yaCol = $yaHay.collections | Where-Object { $_.name -eq $nombreCol } | Select-Object -First 1
if ($yaCol) { Llamar PUT "/collections/$($yaCol.uid)" $cuerpoCol | Out-Null; Write-Output "Coleccion actualizada  $nombreCol" }
else { Llamar POST "/collections?workspace=$($esp.id)" $cuerpoCol | Out-Null; Write-Output "Coleccion creada  $nombreCol" }

# Ambiente
$cuerpoAmb = @{ environment = @{ name = $ambiente.name; values = @($ambiente.values) } } | ConvertTo-Json -Depth 10
$yaAmb = $yaHay.environments | Where-Object { $_.name -eq $ambiente.name } | Select-Object -First 1
if ($yaAmb) { Llamar PUT "/environments/$($yaAmb.uid)" $cuerpoAmb | Out-Null; Write-Output "Ambiente actualizado  $($ambiente.name)" }
else { Llamar POST "/environments?workspace=$($esp.id)" $cuerpoAmb | Out-Null; Write-Output "Ambiente creado  $($ambiente.name)" }

Write-Output ''
Write-Output 'Listo. En Postman elige arriba a la derecha el ambiente de Mesh, abre la coleccion, Run y Start run.'
