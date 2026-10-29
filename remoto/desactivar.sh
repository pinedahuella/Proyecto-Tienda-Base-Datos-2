# remoto/desactivar.sh -- sale del modo remoto en esta consola: para el tunel
# y devuelve el PATH (y con el, el docker de verdad). Se carga con source:
#
#   source remoto/desactivar.sh

_remoto_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# El tunel se busca por su linea de comando: si lo levanto PowerShell,
# .tunel.pid tiene el pid de Windows, que kill no conoce (2026-10-28).
_remoto_parados="$(powershell.exe -NoProfile -Command "\$t = @(Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { \$_.CommandLine -like '*remoto*tunel.cjs*' }); \$t | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }; \$t.Count" 2>/dev/null | tr -d '\r')"
[ "${_remoto_parados:-0}" -gt 0 ] 2>/dev/null && echo "Tunel parado."
rm -f "$_remoto_dir/.tunel.pid" "$_remoto_dir/.tunel.ip"
unset _remoto_parados
if [ -n "${MESH_REMOTO_PATH_ANTES:-}" ]; then
    export PATH="$MESH_REMOTO_PATH_ANTES"
fi
# Las contrasenas de la otra PC que cargo activar.sh (remoto/.env.remoto).
if [ -n "${MESH_REMOTO_VARIABLES:-}" ]; then
    unset $MESH_REMOTO_VARIABLES
fi
unset MESH_REMOTO MESH_REMOTO_PATH_ANTES MESH_REMOTO_VARIABLES SIN_CAIDA _remoto_dir
echo "Fuera del modo remoto: docker es otra vez el de verdad."
