# panel-comandos.ps1
# Abre el panel de comandos de Mesh en el navegador, con botones para arrancar
# las bases, el backend y el frontend, cargar productos con semilla y lanzar
# las demos de fraude. No hace falta que nada de Mesh este corriendo.
#
#   .\panel-comandos.ps1              arranca el panel (oculto) y abre la pagina
#   .\panel-comandos.ps1 -Parar       apaga el panel (se niega si hay un comando corriendo)
#   .\panel-comandos.ps1 -Parar -Forzar   lo apaga aunque haya uno corriendo
#   .\panel-comandos.ps1 -SinNavegador   lo arranca pero no abre la pagina
#
# Queda corriendo sin ventana en http://127.0.0.1:5199, solo visible desde esta
# maquina. La salida va a %TEMP%\mesh-logs\panel-comandos.log.
# Hace falta Node 18 o mas, el mismo que ya usa el proyecto.

param(
    [switch]$Parar,
    [switch]$Forzar,
    [switch]$SinNavegador
)

$raiz = $PSScriptRoot
$puerto = 5199
$url = "http://127.0.0.1:$puerto"
$servidor = Join-Path $raiz 'panel-comandos\servidor.mjs'

function Panel-Procesos {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($servidor) }
}

if ($Parar) {
    $ps = @(Panel-Procesos)
    if ($ps.Count -eq 0) { Write-Host 'El panel no estaba corriendo.'; exit 0 }
    # Apagar el panel con un comando corriendo lo mata a medias, y comandos como la
    # demo de otro pais dejan las bases paradas. El panel deja una marca mientras
    # corre uno; si el proceso de la marca sigue vivo, no se apaga.
    $marca = Join-Path $env:TEMP 'mesh-logs\panel-trabajo.json'
    if ((Test-Path $marca) -and -not $Forzar) {
        try {
            $m = Get-Content $marca -Raw | ConvertFrom-Json
            if (Get-Process -Id $m.pid -ErrorAction SilentlyContinue) {
                Write-Host "El panel esta ejecutando '$($m.titulo)'. Si lo apagas ahora, ese comando se corta y puede dejar las bases a medias." -ForegroundColor Red
                Write-Host 'Espera a que termine, o usa  .\panel-comandos.ps1 -Parar -Forzar' -ForegroundColor Yellow
                exit 1
            }
        } catch {}
    }
    $ps | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Write-Host 'Panel apagado.'
    exit 0
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host 'No encuentro Node. Instalalo desde nodejs.org y vuelve a correr esto.' -ForegroundColor Red
    exit 1
}

if (@(Panel-Procesos).Count -eq 0) {
    $logs = Join-Path $env:TEMP 'mesh-logs'
    New-Item -ItemType Directory -Force $logs | Out-Null
    Start-Process -FilePath 'node' -ArgumentList "`"$servidor`"" -WorkingDirectory $raiz -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs 'panel-comandos.log') `
        -RedirectStandardError (Join-Path $logs 'panel-comandos.err.log')
    $listo = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep 1
        try { Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 | Out-Null; $listo = $true; break } catch {}
    }
    if (-not $listo) {
        Write-Host "El panel no contesto. Mira $logs\panel-comandos.err.log" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Panel de comandos en $url"
if (-not $SinNavegador) { Start-Process $url }
