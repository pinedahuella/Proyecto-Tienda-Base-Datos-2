# remoto/activar.ps1 -- el modo remoto en una consola de PowerShell, para
# correr las demos (.ps1) con las bases de la otra PC. Se carga con un punto:
#
#   . .\remoto\activar.ps1                    la IP de siempre, 100.64.42.11
#   . .\remoto\activar.ps1 -Ip 100.64.42.11
#
# Igual que remoto/activar.sh: comprueba que la otra PC conteste, levanta
# remoto/tunel.cjs y pone remoto\bin al principio del PATH, asi "docker" pasa
# a ser el docker falso (remoto\bin\docker.ps1). Para salir:
#   . .\remoto\desactivar.ps1
param([string]$Ip = '100.64.42.11')

$remoto = $PSScriptRoot
if ($env:MESH_REMOTO) {
    Write-Host "Ya estas en el modo remoto ($env:MESH_REMOTO). Para salir: . .\remoto\desactivar.ps1"
    return
}
$c = New-Object Net.Sockets.TcpClient
if (-not $c.ConnectAsync($Ip, 5432).Wait(4000)) {
    Write-Host "La PC $Ip no contesta en el 5432. Prende Tailscale (y que la otra PC tenga las bases arriba)." -ForegroundColor Red
    return
}
$c.Close()

$registro = Join-Path $env:TEMP 'mesh-tunel.log'
Remove-Item $registro -ErrorAction SilentlyContinue
$p = Start-Process node -ArgumentList "`"$remoto\tunel.cjs`" $Ip" -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $registro -RedirectStandardError "$registro.err"
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 300
    if ((Test-Path $registro) -and (Select-String -Path $registro -Pattern 'tunel listo' -Quiet)) { break }
    if ($p.HasExited) { break }
}
if (-not ((Test-Path $registro) -and (Select-String -Path $registro -Pattern 'tunel listo' -Quiet))) {
    Get-Content "$registro.err" -ErrorAction SilentlyContinue | Write-Host -ForegroundColor Red
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Write-Host 'No se pudo levantar el tunel. Si dice ocupado: apaga el Docker local.' -ForegroundColor Red
    return
}
Set-Content -Path (Join-Path $remoto '.tunel.pid') -Value $p.Id
$env:MESH_REMOTO = $Ip
$env:MESH_REMOTO_PATH_ANTES = $env:PATH
$env:PATH = "$remoto\bin;$env:PATH"
# Las pruebas que tumban una base a proposito se saltan esa parte (activar.sh).
$env:SIN_CAIDA = '1'
Write-Host "Modo remoto: bases en $Ip, tunel en el pid $($p.Id), docker = remoto\bin\docker.ps1." -ForegroundColor Green
if (-not (Test-Path (Join-Path $remoto 'herramientas\bin\mongosh.exe'))) {
    Write-Host 'Falta mongosh para lo de Mongo: bash remoto/instalar.sh (una vez).' -ForegroundColor Yellow
}
Write-Host "El backend tiene que apuntar a la otra PC: .\usar-bases-remotas.ps1 -Ip $Ip"
