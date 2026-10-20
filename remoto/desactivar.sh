# remoto/desactivar.sh -- sale del modo remoto en esta consola: para el tunel
# y devuelve el PATH (y con el, el docker de verdad). Se carga con source:
#
#   source remoto/desactivar.sh

_remoto_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_remoto_dir/.tunel.pid" ]; then
    kill "$(cat "$_remoto_dir/.tunel.pid")" 2>/dev/null && echo "Tunel parado."
    rm -f "$_remoto_dir/.tunel.pid"
fi
if [ -n "${MESH_REMOTO_PATH_ANTES:-}" ]; then
    export PATH="$MESH_REMOTO_PATH_ANTES"
fi
# Las contrasenas de la otra PC que cargo activar.sh (remoto/.env.remoto).
if [ -n "${MESH_REMOTO_VARIABLES:-}" ]; then
    unset $MESH_REMOTO_VARIABLES
fi
unset MESH_REMOTO MESH_REMOTO_PATH_ANTES MESH_REMOTO_VARIABLES SIN_CAIDA _remoto_dir
echo "Fuera del modo remoto: docker es otra vez el de verdad."
