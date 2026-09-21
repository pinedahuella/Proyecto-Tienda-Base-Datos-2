# demo-redis-sin-ttl.ps1
# Deja en Redis un par de llaves SIN TTL, para explicarselas al profesor, y una
# llave CON TTL al lado para que se vea la diferencia.
#
#   .\demo-redis-sin-ttl.ps1                  crea las llaves y las muestra
#   .\demo-redis-sin-ttl.ps1 -Accion ver      lista todas las llaves de Mesh con su TTL
#   .\demo-redis-sin-ttl.ps1 -Accion borrar   quita las llaves de la demo
#
# QUE DEJA
# ==================================================
#   mesh:demo:sin_ttl:contador          STRING, no vence nunca
#   mesh:demo:sin_ttl:configuracion     HASH, no vence nunca
#   mesh:demo:con_ttl:carrito_de_prueba HASH, vence en 10 minutos y cuenta hacia atras
#
# Todas viven bajo mesh:demo y no tocan nada real: el carrito, los contadores
# de fraude y las ofertas de Mesh tienen otras claves. -Accion borrar solo quita
# las que empiezan con mesh:demo.
#
# COMO SE VE
# ==================================================
# En RedisInsight (http://localhost:5540) buscar mesh:demo:* y pulsar refrescar.
# Una llave sin TTL sale con "No limit" en la columna del tiempo de vida. La que
# vence muestra los segundos que le quedan, y desaparece sola a los 10 minutos.
# En redis-cli el TTL de una llave que no vence se lee como -1.

param(
    [ValidateSet('crear', 'ver', 'borrar')]
    [string]$Accion = 'crear'
)

function Paso($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   $t" -ForegroundColor Green }
function Av($t)   { Write-Host "   $t" -ForegroundColor Yellow }
function Mal($t)  { Write-Host "   $t" -ForegroundColor Red }

$TTL_CORTO = 600

# La contrasena de Redis sale del .env de la raiz, nunca escrita aqui.
$env_ = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $env_[$Matches[1]] = $Matches[2].Trim() }
}
$RP = $env_['REDIS_PASSWORD']
if (-not $RP) { Mal "Falta REDIS_PASSWORD en el .env"; exit 1 }

Paso "Revisando que Redis este arriba"
docker ps *> $null
if ($LASTEXITCODE -ne 0) { Mal "Docker no responde. Corre .\arrancar.ps1"; exit 1 }
if (-not (docker ps --filter "name=mesh-redis" --format "{{.Names}}")) {
    Mal "El contenedor mesh-redis no esta corriendo. Corre .\arrancar.ps1"
    exit 1
}
Ok "mesh-redis esta arriba"

# La contrasena viaja por la variable de entorno del contenedor y no en la linea
# de comandos, asi no sale en la lista de procesos ni avisa redis-cli.
function Redis {
    docker exec -e "REDISCLI_AUTH=$RP" mesh-redis redis-cli @args
}

function Llaves([string]$patron) {
    $ls = @(Redis --scan --pattern $patron | Where-Object { $_ -and $_.Trim() -ne '' } | Sort-Object)
    return $ls
}

function Mostrar([string]$patron) {
    $ls = Llaves $patron
    if ($ls.Count -eq 0) { Av "No hay llaves que empiecen con $($patron.TrimEnd('*'))"; return }
    Write-Host ("   {0,-40} {1,-7} {2}" -f 'LLAVE', 'TIPO', 'TTL') -ForegroundColor DarkGray
    foreach ($k in $ls) {
        $tipo = (Redis type $k)
        $ttl = [int](Redis ttl $k)
        if ($ttl -eq -1) {
            Write-Host ("   {0,-40} {1,-7} {2}" -f $k, $tipo, 'sin TTL, no vence nunca (-1, No limit en RedisInsight)') -ForegroundColor Yellow
        } elseif ($ttl -ge 0) {
            Write-Host ("   {0,-40} {1,-7} {2}" -f $k, $tipo, "vence en $ttl s") -ForegroundColor Green
        } else {
            Write-Host ("   {0,-40} {1,-7} {2}" -f $k, $tipo, 'ya no existe') -ForegroundColor DarkGray
        }
    }
    Ok "$($ls.Count) llaves"
}

if ($Accion -eq 'ver') {
    Paso "Todas las llaves de Mesh, con su TTL"
    Mostrar 'mesh:*'
    exit 0
}

if ($Accion -eq 'borrar') {
    Paso "Quitando las llaves de la demo"
    $ls = Llaves 'mesh:demo:*'
    foreach ($k in $ls) { Redis del $k | Out-Null }
    Ok "$($ls.Count) llaves borradas, solo las que empiezan con mesh:demo"
    exit 0
}

Paso "Creando las llaves"
$escrituras = @(
    @('set', 'mesh:demo:sin_ttl:contador', '42'),
    @('hset', 'mesh:demo:sin_ttl:configuracion', 'modo', 'demo', 'version', '1'),
    @('hset', 'mesh:demo:con_ttl:carrito_de_prueba', 'producto', 'Laptop', 'cantidad', '2'),
    @('expire', 'mesh:demo:con_ttl:carrito_de_prueba', "$TTL_CORTO")
)
foreach ($e in $escrituras) {
    $r = Redis @e
    if ($LASTEXITCODE -ne 0) { Mal "Redis rechazo $($e[0]) $($e[1]), $r"; exit 1 }
}
Ok "listas, dos sin TTL y una con TTL de $TTL_CORTO segundos"

Paso "Como quedaron"
Mostrar 'mesh:demo:*'

Paso "Que explicar"
Write-Host "   El TTL es el tiempo de vida de una llave. Sin TTL se queda hasta que alguien la borre." -ForegroundColor White
Write-Host "   -1 es como Redis dice que no vence. RedisInsight lo muestra como No limit." -ForegroundColor White
Write-Host "   La llave con TTL cuenta hacia atras y se borra sola. Es el caso del carrito de Mesh," -ForegroundColor White
Write-Host "   que vence por inactividad y por eso un carrito abandonado no llena la memoria." -ForegroundColor White
Write-Host "   Una llave real sin TTL es mesh:productos:mas_vendidos. No lo necesita porque un worker" -ForegroundColor White
Write-Host "   la reescribe, no hay nada viejo que limpiar." -ForegroundColor White
Write-Host ""
Write-Host "   Para verlo. RedisInsight en http://localhost:5540, buscar mesh:demo:* y refrescar." -ForegroundColor DarkGray
Write-Host "   Para verlo cambiar. Corre Ver las llaves de Mesh otra vez y el TTL de la tercera baja." -ForegroundColor DarkGray
exit 0
