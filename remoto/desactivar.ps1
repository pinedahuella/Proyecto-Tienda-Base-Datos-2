# remoto/desactivar.ps1 -- sale del modo remoto en esta consola de
# PowerShell: para el tunel y devuelve el PATH. Se carga con un punto:
#
#   . .\remoto\desactivar.ps1
# El tunel se busca por su linea de comando y no por el pid guardado: si lo
# levanto Git Bash, .tunel.pid tiene el pid de MSYS, que en Windows es otro
# proceso (2026-10-28).
$tuneles = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object { $_.CommandLine -like '*remoto*tunel.cjs*' })
foreach ($t in $tuneles) { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue }
if ($tuneles.Count -gt 0) { Write-Host 'Tunel parado.' }
Remove-Item (Join-Path $PSScriptRoot '.tunel.pid'), (Join-Path $PSScriptRoot '.tunel.ip') -ErrorAction SilentlyContinue
if ($env:MESH_REMOTO_PATH_ANTES) { $env:PATH = $env:MESH_REMOTO_PATH_ANTES }
Remove-Item Env:MESH_REMOTO, Env:MESH_REMOTO_PATH_ANTES, Env:SIN_CAIDA -ErrorAction SilentlyContinue
Write-Host 'Fuera del modo remoto: docker es otra vez el de verdad.'
