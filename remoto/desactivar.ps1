# remoto/desactivar.ps1 -- sale del modo remoto en esta consola de
# PowerShell: para el tunel y devuelve el PATH. Se carga con un punto:
#
#   . .\remoto\desactivar.ps1
# El tunel se busca por su linea de comando y no por el pid guardado: si lo
# levanto Git Bash, .tunel.pid tiene el pid de MSYS, que en Windows es otro
# proceso (2026-10-28).
# Solo se para si lo levanto esta consola (activar.ps1 lo anota en
# MESH_REMOTO_TUNEL_PROPIO). Uno que ya estaba, por ejemplo el que se prende
# antes de presentar, se queda: antes cada demo del panel lo apagaba y dejaba sin
# tunel a las carpetas 6 y 7 de Postman y a localhost:8123/play (2026-11-07).
if ($env:MESH_REMOTO_TUNEL_PROPIO -eq '1') {
    $tuneles = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -like '*remoto*tunel.cjs*' })
    foreach ($t in $tuneles) { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($tuneles.Count -gt 0) { Write-Host 'Tunel parado.' }
    Remove-Item (Join-Path $PSScriptRoot '.tunel.pid'), (Join-Path $PSScriptRoot '.tunel.ip') -ErrorAction SilentlyContinue
} else {
    Write-Host 'El tunel no lo levanto esta consola, se queda prendido. Para pararlo igual: $env:MESH_REMOTO_TUNEL_PROPIO = ''1'' antes de desactivar.'
}
Remove-Item Env:MESH_REMOTO_TUNEL_PROPIO -ErrorAction SilentlyContinue
if ($env:MESH_REMOTO_PATH_ANTES) { $env:PATH = $env:MESH_REMOTO_PATH_ANTES }
Remove-Item Env:MESH_REMOTO, Env:MESH_REMOTO_PATH_ANTES, Env:SIN_CAIDA -ErrorAction SilentlyContinue
Write-Host 'Fuera del modo remoto: docker es otra vez el de verdad.'
