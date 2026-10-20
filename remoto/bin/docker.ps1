# remoto/bin/docker.ps1 -- el docker falso para PowerShell (las demos .ps1),
# en el modo remoto: le pasa todo a remoto/bin/docker, que es de Git Bash.
# Con remoto/bin al principio del PATH, PowerShell encuentra este antes que el
# docker.exe de verdad (remoto/activar.ps1 lo pone ahi).
$bash = $null
foreach ($c in @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe")) {
    if (Test-Path $c) { $bash = $c; break }
}
if (-not $bash) { Write-Error 'docker falso: hace falta Git Bash (C:\Program Files\Git)'; exit 127 }

# Los argumentos viajan en base64 por el ambiente y no por la linea de comandos.
# Git Bash vuelve a partir la linea de comandos de Windows a su manera: se comia
# las comillas simples ('ip' llegaba como ip y el --eval de mongosh fallaba) y
# expandia las llaves como comodines ({sg} llegaba a Tor como sg). Asi cada
# argumento llega tal cual (2026-10-20). La "x" delante es para que un
# argumento vacio tambien viaje.
$codificados = foreach ($a in $args) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x' + [string]$a)) }
$env:MESH_DOCKER_ARGS_B64 = ($codificados -join ' ')
try {
    if ($MyInvocation.ExpectingInput) {
        $input | & $bash "$PSScriptRoot/docker"
    } else {
        & $bash "$PSScriptRoot/docker"
    }
    $codigo = $LASTEXITCODE
} finally {
    Remove-Item Env:\MESH_DOCKER_ARGS_B64 -ErrorAction SilentlyContinue
}
exit $codigo
