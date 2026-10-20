# remoto/bin/docker.ps1 -- el docker falso para PowerShell (las demos .ps1),
# en el modo remoto: le pasa todo a remoto/bin/docker, que es de Git Bash.
# Con remoto/bin al principio del PATH, PowerShell encuentra este antes que el
# docker.exe de verdad (remoto/activar.ps1 lo pone ahi).
$bash = $null
foreach ($c in @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe")) {
    if (Test-Path $c) { $bash = $c; break }
}
if (-not $bash) { Write-Error 'docker falso: hace falta Git Bash (C:\Program Files\Git)'; exit 127 }
if ($MyInvocation.ExpectingInput) {
    $input | & $bash "$PSScriptRoot/docker" @args
} else {
    & $bash "$PSScriptRoot/docker" @args
}
exit $LASTEXITCODE
