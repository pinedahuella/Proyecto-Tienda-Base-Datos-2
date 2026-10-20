# demo-concurrencia.ps1
# Muchos compradores usando la tienda a la vez, y una venta relampago con mas
# gente que unidades que no se sobrevende. Para mostrarla en vivo.
#
#   .\demo-concurrencia.ps1                          40 compradores, 10 unidades
#   .\demo-concurrencia.ps1 -Usuarios 80 -Stock 15
#   .\demo-concurrencia.ps1 -Caida redis             con Redis apagado durante la demo
#   .\demo-concurrencia.ps1 -SinLimpiar              deja los pedidos para verlos en la pagina
#
# Lo hace pruebas\demo_concurrencia.mjs, que explica cada paso. Necesita el
# backend arriba. Con -Caida tambien el interruptor (.\remoto\caidas.ps1
# -Accion levantar), que apaga y prende la base sin tocar la otra PC.
#
# QUE SE VE
# ==================================================
#   1. Todos navegan a la vez (catalogo, buscar, ficha), con los tiempos.
#   2. Todos piden 1 unidad de la venta relampago en el mismo instante. Ganan
#      exactamente las unidades que hay y el resto recibe que ya no hay.
#   3. Los que ganaron pagan todos a la vez. El stock queda en 0, nunca
#      negativo, con un pedido pagado y un movimiento de stock por cada uno.
#   4. Al final cancela los pedidos, cierra la venta y borra de ClickHouse lo
#      de la demo, para que no mueva lo mas vendido ni las tendencias.

param(
    [int]$Usuarios = 40,
    [int]$Stock = 10,
    [ValidateSet('', 'mongo', 'redis', 'elastic', 'neo4j', 'clickhouse')]
    [string]$Caida = '',
    [switch]$SinLimpiar
)

$argumentos = @("$PSScriptRoot\pruebas\demo_concurrencia.mjs", '--usuarios', $Usuarios, '--stock', $Stock)
if ($Caida) { $argumentos += @('--caida', $Caida) }
if ($SinLimpiar) { $argumentos += '--sin-limpiar' }
& node @argumentos
exit $LASTEXITCODE
