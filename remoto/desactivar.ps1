# remoto/desactivar.ps1 -- sale del modo remoto en esta consola de
# PowerShell: para el tunel y devuelve el PATH. Se carga con un punto:
#
#   . .\remoto\desactivar.ps1
$pidArchivo = Join-Path $PSScriptRoot '.tunel.pid'
if (Test-Path $pidArchivo) {
    $id = [int](Get-Content $pidArchivo)
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    Remove-Item $pidArchivo
    Write-Host 'Tunel parado.'
}
if ($env:MESH_REMOTO_PATH_ANTES) { $env:PATH = $env:MESH_REMOTO_PATH_ANTES }
Remove-Item Env:MESH_REMOTO, Env:MESH_REMOTO_PATH_ANTES, Env:SIN_CAIDA -ErrorAction SilentlyContinue
Write-Host 'Fuera del modo remoto: docker es otra vez el de verdad.'
